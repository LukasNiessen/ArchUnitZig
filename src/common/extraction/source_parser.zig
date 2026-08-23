const std = @import("std");

const common_error = @import("../error.zig");
const import_kind = @import("import_kind.zig");

const Allocator = std.mem.Allocator;
pub const ImportKind = import_kind.ImportKind;

pub const Strictness = enum { strict, permissive };

pub const SourceLocation = struct {
    byte_offset: u32,
    line: usize,
    column: usize,
};

pub const DependencyReference = struct {
    target: []u8,
    kind: ImportKind,
    location: SourceLocation,

    pub fn deinit(self: *DependencyReference, allocator: Allocator) void {
        allocator.free(self.target);
        self.* = undefined;
    }
};

pub const DiagnosticKind = enum { syntax_error, non_literal_operand, invalid_string_literal };

pub const SyntaxDiagnostic = struct {
    kind: DiagnosticKind,
    location: SourceLocation,
};

pub const ParseResult = struct {
    source_path: []u8,
    references: std.ArrayList(DependencyReference) = .empty,
    diagnostics: std.ArrayList(SyntaxDiagnostic) = .empty,

    pub fn deinit(self: *ParseResult, allocator: Allocator) void {
        allocator.free(self.source_path);
        for (self.references.items) |*reference| reference.deinit(allocator);
        self.references.deinit(allocator);
        self.diagnostics.deinit(allocator);
        self.* = undefined;
    }
};

pub fn parseSource(
    allocator: Allocator,
    source_path: []const u8,
    source: [:0]const u8,
    strictness: Strictness,
    error_context: *common_error.ErrorContext,
) common_error.ArchUnitError!ParseResult {
    var result = ParseResult{
        .source_path = allocator.dupe(u8, source_path) catch {
            return error_context.failTechnical(.out_of_memory, "zig.parse_source", source_path, error.OutOfMemory);
        },
    };
    errdefer result.deinit(allocator);

    var tree = std.zig.Ast.parse(allocator, source, .zig) catch {
        return error_context.failTechnical(.out_of_memory, "zig.parse_source", source_path, error.OutOfMemory);
    };
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) {
        const location = tokenLocation(&tree, tree.errors[0].token);
        if (strictness == .strict) {
            return error_context.failTechnical(.parser_failure, "zig.parse_source", source_path, error.InvalidZigSyntax);
        }
        result.diagnostics.append(allocator, .{ .kind = .syntax_error, .location = location }) catch {
            return error_context.failTechnical(.out_of_memory, "zig.parse_source", source_path, error.OutOfMemory);
        };
        return result;
    }

    const tags = tree.tokens.items(.tag);
    var index: usize = 0;
    while (index < tree.tokens.len) : (index += 1) {
        if (tags[index] != .builtin) continue;
        const builtin = tree.tokenSlice(@intCast(index));
        const kind: ?ImportKind = if (std.mem.eql(u8, builtin, "@import"))
            importKindForToken(&tree, index + 2)
        else if (std.mem.eql(u8, builtin, "@embedFile"))
            .embedded_file
        else if (std.mem.eql(u8, builtin, "@cInclude") and insideCImport(&tree, index))
            .c_header
        else
            null;
        const reference_kind = kind orelse continue;

        if (index + 3 >= tree.tokens.len or tags[index + 1] != .l_paren or
            tags[index + 2] != .string_literal or tags[index + 3] != .r_paren)
        {
            try addDiagnosticOrFail(
                allocator,
                &result,
                strictness,
                error_context,
                .non_literal_operand,
                tokenLocation(&tree, @intCast(index)),
            );
            continue;
        }

        const raw_literal = tree.tokenSlice(@intCast(index + 2));
        const decoded = std.zig.string_literal.parseAlloc(allocator, raw_literal) catch |failure| switch (failure) {
            error.OutOfMemory => return error_context.failTechnical(
                .out_of_memory,
                "zig.decode_import_literal",
                source_path,
                failure,
            ),
            error.InvalidLiteral => {
                try addDiagnosticOrFail(
                    allocator,
                    &result,
                    strictness,
                    error_context,
                    .invalid_string_literal,
                    tokenLocation(&tree, @intCast(index + 2)),
                );
                continue;
            },
        };
        result.references.append(allocator, .{
            .target = decoded,
            .kind = reference_kind,
            .location = tokenLocation(&tree, @intCast(index)),
        }) catch {
            allocator.free(decoded);
            return error_context.failTechnical(.out_of_memory, "zig.parse_source", source_path, error.OutOfMemory);
        };
    }
    return result;
}

fn importKindForToken(tree: *const std.zig.Ast, literal_index: usize) ImportKind {
    if (literal_index >= tree.tokens.len or tree.tokenTag(@intCast(literal_index)) != .string_literal) {
        return .named_module;
    }
    const raw = tree.tokenSlice(@intCast(literal_index));
    if (std.mem.eql(u8, raw, "\"std\"")) return .standard_library;
    if (std.mem.eql(u8, raw, "\"builtin\"")) return .builtin_module;
    if (std.mem.eql(u8, raw, "\"root\"")) return .root_module;
    if (std.mem.endsWith(u8, raw, ".zig\"")) return .zig_file;
    if (std.mem.endsWith(u8, raw, ".zon\"")) return .zon_file;
    return .named_module;
}

fn insideCImport(tree: *const std.zig.Ast, candidate: usize) bool {
    const tags = tree.tokens.items(.tag);
    var index: usize = 0;
    while (index < candidate) : (index += 1) {
        if (tags[index] != .builtin or !std.mem.eql(u8, tree.tokenSlice(@intCast(index)), "@cImport")) continue;
        if (index + 1 >= tree.tokens.len or tags[index + 1] != .l_paren) continue;
        var depth: usize = 0;
        var cursor = index + 1;
        while (cursor < tree.tokens.len) : (cursor += 1) {
            if (tags[cursor] == .l_paren) depth += 1;
            if (tags[cursor] == .r_paren) {
                depth -= 1;
                if (depth == 0) return candidate > index and candidate < cursor;
            }
        }
    }
    return false;
}

fn addDiagnosticOrFail(
    allocator: Allocator,
    result: *ParseResult,
    strictness: Strictness,
    error_context: *common_error.ErrorContext,
    kind: DiagnosticKind,
    location: SourceLocation,
) common_error.ArchUnitError!void {
    if (strictness == .strict) {
        return error_context.failTechnical(.parser_failure, "zig.parse_source", result.source_path, error.InvalidZigSyntax);
    }
    result.diagnostics.append(allocator, .{ .kind = kind, .location = location }) catch {
        return error_context.failTechnical(.out_of_memory, "zig.parse_source", result.source_path, error.OutOfMemory);
    };
}

fn tokenLocation(tree: *const std.zig.Ast, token: std.zig.Ast.TokenIndex) SourceLocation {
    const location = tree.tokenLocation(0, token);
    return .{
        .byte_offset = tree.tokenStart(token),
        .line = location.line + 1,
        .column = location.column + 1,
    };
}

test "extracts imports across Zig constructs and decodes escaped literals" {
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const model = @import("domain\x2fmodel.zig");
        \\fn loadAdapter() type { return @import("adapter.zig"); }
        \\comptime { _ = @import("config.zon"); }
        \\test "dependency" { _ = @import("support"); }
    ;
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();
    var result = try parseSource(std.testing.allocator, "src/main.zig", source, .strict, &context);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), result.references.items.len);
    try std.testing.expectEqualStrings("std", result.references.items[0].target);
    try std.testing.expectEqual(ImportKind.standard_library, result.references.items[0].kind);
    try std.testing.expectEqualStrings("domain/model.zig", result.references.items[1].target);
    try std.testing.expectEqual(ImportKind.zig_file, result.references.items[1].kind);
    try std.testing.expectEqualStrings("adapter.zig", result.references.items[2].target);
    try std.testing.expectEqual(ImportKind.zig_file, result.references.items[2].kind);
    try std.testing.expectEqual(ImportKind.zon_file, result.references.items[3].kind);
    try std.testing.expectEqual(ImportKind.named_module, result.references.items[4].kind);
    try std.testing.expectEqual(@as(usize, 1), result.references.items[0].location.line);
}

test "extracts embedded resources and C includes only inside cImport" {
    const source: [:0]const u8 =
        \\const data = @embedFile("assets/schema.json");
        \\const c = @cImport({
        \\    @cInclude("sqlite3.h");
        \\    @cInclude("vendor/api.h");
        \\});
    ;
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();
    var result = try parseSource(std.testing.allocator, "src/ffi.zig", source, .strict, &context);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), result.references.items.len);
    try std.testing.expectEqual(ImportKind.embedded_file, result.references.items[0].kind);
    try std.testing.expectEqual(ImportKind.c_header, result.references.items[1].kind);
    try std.testing.expectEqualStrings("vendor/api.h", result.references.items[2].target);
}

test "comments and string contents do not create false references" {
    const source: [:0]const u8 =
        "// @import(\"comment.zig\")\n" ++
        "const text = \"@embedFile(\\\"fake.txt\\\")\";\n" ++
        "// @cInclude(\"fake.h\")\n" ++
        "const multiline =\n" ++
        "    \\\\@import(\"multiline-fake.zig\")\n" ++
        ";\n" ++
        "const real = @import(\"real.zig\");\n";
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();
    var result = try parseSource(std.testing.allocator, "src/traps.zig", source, .strict, &context);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.references.items.len);
    try std.testing.expectEqualStrings("real.zig", result.references.items[0].target);
}

test "syntax errors follow strictness policy" {
    const source: [:0]const u8 = "const broken = @import(\"x.zig\";";
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();
    try std.testing.expectError(
        error.ParserFailure,
        parseSource(std.testing.allocator, "src/broken.zig", source, .strict, &context),
    );

    var permissive = try parseSource(
        std.testing.allocator,
        "src/broken.zig",
        source,
        .permissive,
        &context,
    );
    defer permissive.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), permissive.references.items.len);
    try std.testing.expectEqual(@as(usize, 1), permissive.diagnostics.items.len);
    try std.testing.expectEqual(DiagnosticKind.syntax_error, permissive.diagnostics.items[0].kind);
}
