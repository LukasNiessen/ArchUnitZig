const std = @import("std");

const common_error = @import("../../common/error.zig");
const extraction = @import("../../common/extraction.zig");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Io = std.Io;

pub const Strictness = extraction.Strictness;
pub const SourceLocation = extraction.SourceLocation;

/// A named declaration may directly bind one of Zig's container-like type expressions.
pub const ContainerKind = enum {
    struct_type,
    union_type,
    enum_type,
    opaque_type,
    error_set,
};

pub const DeclarationKind = enum {
    function,
    test_declaration,
    constant,
    variable,
    field,
};

/// Count facts for one file or declaration span. Declaration counts are for immediate members;
/// lexical counts cover the complete span, including nested blocks.
pub const StructuralMetrics = struct {
    declarations: usize = 0,
    functions: usize = 0,
    tests: usize = 0,
    constants: usize = 0,
    variables: usize = 0,
    fields: usize = 0,
    structs: usize = 0,
    unions: usize = 0,
    enums: usize = 0,
    opaque_types: usize = 0,
    error_sets: usize = 0,
    other_declarations: usize = 0,
    anonymous_containers: usize = 0,
    imports: usize = 0,
    statements: usize = 0,
    tokens: usize = 0,
    source_lines: usize = 0,
    non_blank_lines: usize = 0,

    pub fn eql(self: StructuralMetrics, other: StructuralMetrics) bool {
        return std.meta.eql(self, other);
    }

    pub fn add(self: *StructuralMetrics, other: StructuralMetrics) void {
        inline for (std.meta.fields(StructuralMetrics)) |field| {
            @field(self, field.name) += @field(other, field.name);
        }
    }
};

/// One owned named declaration. `qualified_name` uses declaration nesting (`Outer.Inner`) and the
/// identifier combines it with the normalized project-relative path (`src/model.zig:Outer.Inner`).
pub const DeclarationInfo = struct {
    name: []u8,
    qualified_name: []u8,
    identifier: []u8,
    kind: DeclarationKind,
    container_kind: ?ContainerKind,
    location: SourceLocation,
    metrics: StructuralMetrics,

    pub fn deinit(self: *DeclarationInfo, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.qualified_name);
        allocator.free(self.identifier);
        self.* = undefined;
    }

    pub fn isContainer(self: DeclarationInfo) bool {
        return self.container_kind != null;
    }
};

/// Owned structural information for one Zig source file.
pub const FileInfo = struct {
    path: []u8,
    syntax_valid: bool,
    metrics: StructuralMetrics,
    declarations: std.ArrayList(DeclarationInfo) = .empty,

    pub fn deinit(self: *FileInfo, allocator: Allocator) void {
        allocator.free(self.path);
        for (self.declarations.items) |*declaration| declaration.deinit(allocator);
        self.declarations.deinit(allocator);
        self.* = undefined;
    }
};

/// Complete owned structural input for one located Zig project.
pub const ProjectInfo = struct {
    project_root: []u8,
    files: std.ArrayList(FileInfo) = .empty,

    pub fn deinit(self: *ProjectInfo, allocator: Allocator) void {
        allocator.free(self.project_root);
        for (self.files.items) |*file| file.deinit(allocator);
        self.files.deinit(allocator);
        self.* = undefined;
    }
};

const TokenSpan = struct {
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
};

/// Extracts owned structural information from one source buffer. Invalid syntax either fails with
/// the shared parser error or, in permissive mode, returns only trustworthy physical line facts.
pub fn inspectSource(
    allocator: Allocator,
    source_path: []const u8,
    source: [:0]const u8,
    strictness: Strictness,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!FileInfo {
    var result = FileInfo{
        .path = allocator.dupe(u8, source_path) catch {
            return diagnostics.failTechnical(.out_of_memory, "metrics.inspect_source", source_path, error.OutOfMemory);
        },
        .syntax_valid = false,
        .metrics = .{
            .source_lines = countSourceLines(source),
            .non_blank_lines = countNonBlankLines(source),
        },
    };
    errdefer result.deinit(allocator);

    var tree = std.zig.Ast.parse(allocator, source, .zig) catch {
        return diagnostics.failTechnical(.out_of_memory, "metrics.inspect_source", source_path, error.OutOfMemory);
    };
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) {
        if (strictness == .strict) {
            return diagnostics.failTechnical(.parser_failure, "metrics.inspect_source", source_path, error.InvalidZigSyntax);
        }
        return result;
    }
    result.syntax_valid = true;

    var named_containers = std.AutoHashMap(Ast.Node.Index, void).init(allocator);
    defer named_containers.deinit();
    discoverNamedContainers(&tree, tree.rootDecls(), &named_containers) catch {
        return diagnostics.failTechnical(.out_of_memory, "metrics.inspect_source", source_path, error.OutOfMemory);
    };

    result.metrics = lexicalMetricsForFile(&tree, source, &named_containers);
    applyDeclarationCounts(&result.metrics, countMembers(&tree, tree.rootDecls()));
    collectMembers(
        allocator,
        &tree,
        source,
        source_path,
        tree.rootDecls(),
        null,
        &named_containers,
        &result.declarations,
    ) catch {
        return diagnostics.failTechnical(.out_of_memory, "metrics.inspect_source", source_path, error.OutOfMemory);
    };
    return result;
}

/// Locates a project, enumerates its Zig sources deterministically, and extracts each exactly once.
pub fn extractProjectInfo(
    allocator: Allocator,
    io: Io,
    locator: ?[]const u8,
    working_directory: []const u8,
    options: extraction.ExtractionOptions,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!ProjectInfo {
    var located = try extraction.locateProject(
        allocator,
        io,
        locator,
        working_directory,
        diagnostics,
    );
    defer located.deinit(allocator);

    var sources = try extraction.enumerateSourceFiles(
        allocator,
        io,
        located.path,
        .{ .exclusions = options.exclusions, .include_zon = false },
        diagnostics,
    );
    defer sources.deinit(allocator);

    var result = ProjectInfo{
        .project_root = allocator.dupe(u8, located.path) catch {
            return diagnostics.failTechnical(.out_of_memory, "metrics.extract_project", located.path, error.OutOfMemory);
        },
    };
    errdefer result.deinit(allocator);
    result.files.ensureTotalCapacity(allocator, sources.items().len) catch {
        return diagnostics.failTechnical(.out_of_memory, "metrics.extract_project", located.path, error.OutOfMemory);
    };

    for (sources.items()) |relative_path| {
        const absolute_path = std.fs.path.join(allocator, &.{ located.path, relative_path }) catch {
            return diagnostics.failTechnical(.out_of_memory, "metrics.source_path", relative_path, error.OutOfMemory);
        };
        defer allocator.free(absolute_path);
        const source = std.Io.Dir.cwd().readFileAllocOptions(
            io,
            absolute_path,
            allocator,
            .limited(std.math.maxInt(usize)),
            .of(u8),
            0,
        ) catch |failure| return mapReadFailure(diagnostics, relative_path, failure);
        defer allocator.free(source);
        result.files.appendAssumeCapacity(try inspectSource(
            allocator,
            relative_path,
            source,
            options.strictness,
            diagnostics,
        ));
    }
    return result;
}

fn discoverNamedContainers(
    tree: *const Ast,
    members: []const Ast.Node.Index,
    named: *std.AutoHashMap(Ast.Node.Index, void),
) Allocator.Error!void {
    for (members) |member| {
        const init = directInitializer(tree, member) orelse continue;
        if (containerKind(tree, init) == null) continue;
        try named.put(init, {});
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buffer, init)) |container| {
            try discoverNamedContainers(tree, container.ast.members, named);
        }
    }
}

fn collectMembers(
    allocator: Allocator,
    tree: *const Ast,
    source: []const u8,
    source_path: []const u8,
    members: []const Ast.Node.Index,
    parent_name: ?[]const u8,
    named_containers: *const std.AutoHashMap(Ast.Node.Index, void),
    output: *std.ArrayList(DeclarationInfo),
) Allocator.Error!void {
    for (members) |member| {
        const descriptor = declarationDescriptor(tree, member) orelse continue;
        const name = tree.tokenSlice(descriptor.name_token);
        const qualified_name: []const u8 = append_block: {
            const owned_qualified_name = if (parent_name) |parent|
                try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent, name })
            else
                try allocator.dupe(u8, name);
            errdefer allocator.free(owned_qualified_name);
            const owned_name = try allocator.dupe(u8, name);
            errdefer allocator.free(owned_name);
            const identifier = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ source_path, owned_qualified_name });
            errdefer allocator.free(identifier);

            const span = TokenSpan{ .first = tree.firstToken(member), .last = tree.lastToken(member) };
            var metrics = lexicalMetricsForSpan(tree, source, span, named_containers);
            if (descriptor.container_node) |container_node| {
                var buffer: [2]Ast.Node.Index = undefined;
                if (tree.fullContainerDecl(&buffer, container_node)) |container| {
                    applyDeclarationCounts(&metrics, countMembers(tree, container.ast.members));
                }
            }
            const token_location = tree.tokenLocation(0, descriptor.name_token);
            try output.append(allocator, .{
                .name = owned_name,
                .qualified_name = owned_qualified_name,
                .identifier = identifier,
                .kind = descriptor.kind,
                .container_kind = descriptor.container_kind,
                .location = .{
                    .byte_offset = tree.tokenStart(descriptor.name_token),
                    .line = token_location.line + 1,
                    .column = token_location.column + 1,
                },
                .metrics = metrics,
            });
            break :append_block output.items[output.items.len - 1].qualified_name;
        };

        if (descriptor.container_node) |container_node| {
            var buffer: [2]Ast.Node.Index = undefined;
            if (tree.fullContainerDecl(&buffer, container_node)) |container| {
                try collectMembers(
                    allocator,
                    tree,
                    source,
                    source_path,
                    container.ast.members,
                    qualified_name,
                    named_containers,
                    output,
                );
            }
        }
    }
}

const DeclarationDescriptor = struct {
    name_token: Ast.TokenIndex,
    kind: DeclarationKind,
    container_kind: ?ContainerKind = null,
    container_node: ?Ast.Node.Index = null,
};

fn declarationDescriptor(tree: *const Ast, node: Ast.Node.Index) ?DeclarationDescriptor {
    var function_buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&function_buffer, node)) |function| {
        return .{
            .name_token = function.name_token orelse return null,
            .kind = .function,
        };
    }
    if (tree.nodeTag(node) == .test_decl) {
        const name_token = tree.nodeData(node).opt_token_and_node[0].unwrap() orelse return null;
        return .{ .name_token = name_token, .kind = .test_declaration };
    }
    if (tree.fullVarDecl(node)) |variable| {
        const init = variable.ast.init_node.unwrap();
        const direct_kind = if (init) |init_node| containerKind(tree, init_node) else null;
        return .{
            .name_token = variable.ast.mut_token + 1,
            .kind = if (tree.tokenTag(variable.ast.mut_token) == .keyword_const) .constant else .variable,
            .container_kind = direct_kind,
            .container_node = if (direct_kind != null) init else null,
        };
    }
    if (tree.fullContainerField(node) != null) {
        return .{ .name_token = tree.nodeMainToken(node), .kind = .field };
    }
    return null;
}

fn countMembers(tree: *const Ast, members: []const Ast.Node.Index) StructuralMetrics {
    var result = StructuralMetrics{ .declarations = members.len };
    for (members) |member| {
        var function_buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&function_buffer, member) != null) {
            result.functions += 1;
            continue;
        }
        if (tree.nodeTag(member) == .test_decl) {
            result.tests += 1;
            continue;
        }
        if (tree.fullVarDecl(member)) |variable| {
            if (tree.tokenTag(variable.ast.mut_token) == .keyword_const)
                result.constants += 1
            else
                result.variables += 1;
            if (variable.ast.init_node.unwrap()) |init| {
                if (containerKind(tree, init)) |kind| incrementContainer(&result, kind);
            }
            continue;
        }
        if (tree.fullContainerField(member) != null) {
            result.fields += 1;
            continue;
        }
        result.other_declarations += 1;
    }
    return result;
}

fn applyDeclarationCounts(target: *StructuralMetrics, counts: StructuralMetrics) void {
    inline for ([_][]const u8{
        "declarations",
        "functions",
        "tests",
        "constants",
        "variables",
        "fields",
        "structs",
        "unions",
        "enums",
        "opaque_types",
        "error_sets",
        "other_declarations",
    }) |field| @field(target, field) = @field(counts, field);
}

fn incrementContainer(metrics: *StructuralMetrics, kind: ContainerKind) void {
    switch (kind) {
        .struct_type => metrics.structs += 1,
        .union_type => metrics.unions += 1,
        .enum_type => metrics.enums += 1,
        .opaque_type => metrics.opaque_types += 1,
        .error_set => metrics.error_sets += 1,
    }
}

fn directInitializer(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    const variable = tree.fullVarDecl(node) orelse return null;
    return variable.ast.init_node.unwrap();
}

fn containerKind(tree: *const Ast, node: Ast.Node.Index) ?ContainerKind {
    if (tree.nodeTag(node) == .error_set_decl) return .error_set;
    var buffer: [2]Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buffer, node) orelse return null;
    return switch (tree.tokenTag(container.ast.main_token)) {
        .keyword_struct => .struct_type,
        .keyword_union => .union_type,
        .keyword_enum => .enum_type,
        .keyword_opaque => .opaque_type,
        else => null,
    };
}

fn lexicalMetricsForFile(
    tree: *const Ast,
    source: []const u8,
    named_containers: *const std.AutoHashMap(Ast.Node.Index, void),
) StructuralMetrics {
    var result = StructuralMetrics{
        .source_lines = countSourceLines(source),
        .non_blank_lines = countNonBlankLines(source),
    };
    const span = fileTokenSpan(tree) orelse return result;
    const lexical = lexicalMetricsForSpan(tree, source, span, named_containers);
    result.anonymous_containers = lexical.anonymous_containers;
    result.imports = lexical.imports;
    result.statements = lexical.statements;
    result.tokens = lexical.tokens;
    return result;
}

fn lexicalMetricsForSpan(
    tree: *const Ast,
    source: []const u8,
    span: TokenSpan,
    named_containers: *const std.AutoHashMap(Ast.Node.Index, void),
) StructuralMetrics {
    const start = tree.tokenStart(span.first);
    const last_slice = tree.tokenSlice(span.last);
    const end = @min(source.len, tree.tokenStart(span.last) + last_slice.len);
    var result = StructuralMetrics{
        .source_lines = countSourceLines(source[start..end]),
        .non_blank_lines = countNonBlankLines(source[start..end]),
    };
    var token = span.first;
    while (token <= span.last) : (token += 1) {
        if (tree.tokenTag(token) == .eof) continue;
        result.tokens += 1;
        if (tree.tokenTag(token) == .builtin and std.mem.eql(u8, tree.tokenSlice(token), "@import")) {
            result.imports += 1;
        }
    }

    const tags = tree.nodes.items(.tag);
    for (tags, 0..) |tag, raw_index| {
        if (tag == .root) continue;
        const node: Ast.Node.Index = @enumFromInt(raw_index);
        if (!nodeInsideSpan(tree, node, span)) continue;
        var block_buffer: [2]Ast.Node.Index = undefined;
        if (tree.blockStatements(&block_buffer, node)) |statements| result.statements += statements.len;
        if (containerKind(tree, node) != null and !named_containers.contains(node)) {
            result.anonymous_containers += 1;
        }
    }
    return result;
}

fn fileTokenSpan(tree: *const Ast) ?TokenSpan {
    var first: ?Ast.TokenIndex = null;
    var last: ?Ast.TokenIndex = null;
    var index: usize = 0;
    while (index < tree.tokens.len) : (index += 1) {
        const token: Ast.TokenIndex = @intCast(index);
        if (tree.tokenTag(token) == .eof) continue;
        if (first == null) first = token;
        last = token;
    }
    return if (first) |start| .{ .first = start, .last = last.? } else null;
}

fn nodeInsideSpan(tree: *const Ast, node: Ast.Node.Index, span: TokenSpan) bool {
    return tree.firstToken(node) >= span.first and tree.lastToken(node) <= span.last;
}

fn countSourceLines(source: []const u8) usize {
    if (source.len == 0) return 0;
    var result = std.mem.count(u8, source, "\n");
    if (source[source.len - 1] != '\n') result += 1;
    return result;
}

fn countNonBlankLines(source: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r\x0b\x0c").len != 0) count += 1;
    }
    return count;
}

fn mapReadFailure(
    diagnostics: *common_error.ErrorContext,
    source_path: []const u8,
    failure: anyerror,
) common_error.ArchUnitError {
    if (failure == error.OutOfMemory) {
        return diagnostics.failTechnical(.out_of_memory, "metrics.read_source", source_path, failure);
    }
    return diagnostics.failTechnical(.file_system, "metrics.read_source", source_path, failure);
}

test "extracts root and named-container structure without inventing anonymous identities" {
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\pub const Outer = struct {
        \\    const Inner = union(enum) { one: u8, two };
        \\    payload: struct { value: u8 },
        \\    pub fn make(comptime T: type, value: T) T { return value; }
        \\    test "member" {}
        \\};
        \\const Choice = if (@sizeOf(usize) > 0) struct { yes: u8 } else struct { no: u8 };
        \\const Errors = error{ BadInput, Missing };
        \\var state: u8 = 0;
        \\fn helper() void { if (true) { const local = 1; _ = local; } }
        \\test "root" {}
    ;
    var diagnostics = common_error.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();
    var info = try inspectSource(
        std.testing.allocator,
        "src/model.zig",
        source,
        .strict,
        &diagnostics,
    );
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(info.syntax_valid);
    try std.testing.expectEqual(@as(usize, 7), info.metrics.declarations);
    try std.testing.expectEqual(@as(usize, 1), info.metrics.functions);
    try std.testing.expectEqual(@as(usize, 1), info.metrics.tests);
    try std.testing.expectEqual(@as(usize, 4), info.metrics.constants);
    try std.testing.expectEqual(@as(usize, 1), info.metrics.variables);
    try std.testing.expectEqual(@as(usize, 1), info.metrics.structs);
    try std.testing.expectEqual(@as(usize, 1), info.metrics.error_sets);
    try std.testing.expectEqual(@as(usize, 3), info.metrics.anonymous_containers);
    try std.testing.expectEqual(@as(usize, 1), info.metrics.imports);
    try std.testing.expect(info.metrics.statements >= 4);

    const outer = findDeclaration(&info, "Outer") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ContainerKind.struct_type, outer.container_kind.?);
    try std.testing.expectEqual(@as(usize, 4), outer.metrics.declarations);
    try std.testing.expectEqual(@as(usize, 1), outer.metrics.functions);
    try std.testing.expectEqual(@as(usize, 1), outer.metrics.tests);
    try std.testing.expectEqual(@as(usize, 1), outer.metrics.fields);
    try std.testing.expectEqual(@as(usize, 1), outer.metrics.unions);

    const inner = findDeclaration(&info, "Outer.Inner") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("src/model.zig:Outer.Inner", inner.identifier);
    try std.testing.expectEqual(ContainerKind.union_type, inner.container_kind.?);
    try std.testing.expectEqual(@as(usize, 2), inner.metrics.fields);
    try std.testing.expect(findDeclaration(&info, "Choice.yes") == null);
    try std.testing.expect(findDeclaration(&info, "Outer.payload.value") == null);
    try std.testing.expect(findDeclaration(&info, "Outer.make") != null);
}

test "permissive malformed source retains line facts but no parser-derived facts" {
    const source: [:0]const u8 = "const broken = struct {\n\n";
    var diagnostics = common_error.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();
    var permissive = try inspectSource(
        std.testing.allocator,
        "src/broken.zig",
        source,
        .permissive,
        &diagnostics,
    );
    defer permissive.deinit(std.testing.allocator);

    try std.testing.expect(!permissive.syntax_valid);
    try std.testing.expectEqual(@as(usize, 2), permissive.metrics.source_lines);
    try std.testing.expectEqual(@as(usize, 1), permissive.metrics.non_blank_lines);
    try std.testing.expectEqual(@as(usize, 0), permissive.metrics.tokens);
    try std.testing.expectEqual(@as(usize, 0), permissive.declarations.items.len);
    try std.testing.expectError(
        error.ParserFailure,
        inspectSource(std.testing.allocator, "src/broken.zig", source, .strict, &diagnostics),
    );
}

test "source and non-blank line counting exclude a synthetic trailing line" {
    var diagnostics = common_error.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();
    var info = try inspectSource(
        std.testing.allocator,
        "emptyish.zig",
        "\nconst value = 1;\n\n",
        .strict,
        &diagnostics,
    );
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), info.metrics.source_lines);
    try std.testing.expectEqual(@as(usize, 1), info.metrics.non_blank_lines);
}

test "recognizes every declaration-bound Zig container kind" {
    const source: [:0]const u8 =
        \\const Struct = struct {};
        \\const Union = union { value: u8 };
        \\const Enum = enum { value };
        \\const Opaque = opaque {};
        \\const Errors = error{Failure};
    ;
    var diagnostics = common_error.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();
    var info = try inspectSource(std.testing.allocator, "types.zig", source, .strict, &diagnostics);
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), info.metrics.structs);
    try std.testing.expectEqual(@as(usize, 1), info.metrics.unions);
    try std.testing.expectEqual(@as(usize, 1), info.metrics.enums);
    try std.testing.expectEqual(@as(usize, 1), info.metrics.opaque_types);
    try std.testing.expectEqual(@as(usize, 1), info.metrics.error_sets);
    try std.testing.expectEqual(ContainerKind.opaque_type, findDeclaration(&info, "Opaque").?.container_kind.?);
}

test "project extraction returns sorted files and exact fixture structure" {
    var diagnostics = common_error.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();
    var project = try extractProjectInfo(
        std.testing.allocator,
        std.testing.io,
        "test/fixtures/metrics-structural",
        ".",
        .{},
        &diagnostics,
    );
    defer project.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), project.files.items.len);
    try std.testing.expectEqualStrings("build.zig", project.files.items[0].path);
    try std.testing.expectEqualStrings("src/root.zig", project.files.items[1].path);
    try std.testing.expectEqualStrings("src/support.zig", project.files.items[2].path);
    const root = &project.files.items[1];
    try std.testing.expectEqual(@as(usize, 4), root.metrics.declarations);
    try std.testing.expectEqual(@as(usize, 2), root.metrics.constants);
    try std.testing.expectEqual(@as(usize, 1), root.metrics.structs);
    try std.testing.expectEqual(@as(usize, 1), root.metrics.functions);
    try std.testing.expectEqual(@as(usize, 1), root.metrics.tests);
    try std.testing.expectEqual(@as(usize, 1), root.metrics.imports);
    try std.testing.expectEqual(@as(usize, 17), root.metrics.source_lines);
    try std.testing.expectEqual(@as(usize, 13), root.metrics.non_blank_lines);
    try std.testing.expectEqual(@as(usize, 3), root.metrics.statements);
    const worker = findDeclaration(root, "Worker") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 2), worker.metrics.declarations);
    try std.testing.expectEqual(@as(usize, 1), worker.metrics.fields);
    try std.testing.expectEqual(@as(usize, 1), worker.metrics.functions);
}

fn exerciseInspectionAllocationFailures(allocator: Allocator) !void {
    const source: [:0]const u8 =
        \\const Model = struct {
        \\    value: u8,
        \\    fn read(self: Model) u8 { return self.value; }
        \\};
    ;
    var diagnostics = common_error.ErrorContext.init(allocator);
    defer diagnostics.deinit();
    var info = try inspectSource(allocator, "src/model.zig", source, .strict, &diagnostics);
    defer info.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), info.metrics.structs);
}

test "source inspection releases every partial AST model on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseInspectionAllocationFailures,
        .{},
    );
}

fn findDeclaration(info: *const FileInfo, qualified_name: []const u8) ?*const DeclarationInfo {
    for (info.declarations.items) |*declaration| {
        if (std.mem.eql(u8, declaration.qualified_name, qualified_name)) return declaration;
    }
    return null;
}
