const std = @import("std");

const module_resolver = @import("module_resolver.zig");
const relative_resolver = @import("relative_resolver.zig");
const source_parser = @import("source_parser.zig");

const Allocator = std.mem.Allocator;
pub const DependencyReference = source_parser.DependencyReference;
pub const ImportKind = source_parser.ImportKind;
pub const ResolvedModuleReference = module_resolver.ResolvedModuleReference;
pub const ResolvedReference = relative_resolver.ResolvedReference;
pub const SourceLocation = source_parser.SourceLocation;

pub const TargetClass = enum {
    internal,
    external,
    compiler,
    resource,
    c_header,
};

pub const TargetAvailability = enum {
    resolved,
    unresolved,
    missing,
    outside_project,
};

/// The original parsed file reference paired with its path-resolution result.
pub const FileResolutionInput = struct {
    reference: DependencyReference,
    resolution: ResolvedReference,
};

/// Borrowed input to classification. The returned `ClassifiedReference` owns independent storage.
pub const ResolutionInput = union(enum) {
    raw: DependencyReference,
    file: FileResolutionInput,
    module: ResolvedModuleReference,
};

/// Fully classified owned dependency ready for graph normalization.
pub const ClassifiedReference = struct {
    raw_target: []const u8,
    target: []const u8,
    mapped_source_path: ?[]const u8,
    kind: ImportKind,
    location: SourceLocation,
    class: TargetClass,
    availability: TargetAvailability,
    external: bool,

    pub fn deinit(self: *ClassifiedReference, allocator: Allocator) void {
        allocator.free(self.raw_target);
        allocator.free(self.target);
        if (self.mapped_source_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

pub fn classifyReference(allocator: Allocator, input: ResolutionInput) Allocator.Error!ClassifiedReference {
    return switch (input) {
        .raw => |reference| classifyRaw(allocator, reference),
        .file => |file| classifyFile(allocator, file),
        .module => |module| classifyModule(allocator, module),
    };
}

fn classifyRaw(allocator: Allocator, reference: DependencyReference) Allocator.Error!ClassifiedReference {
    const properties: struct { class: TargetClass, availability: TargetAvailability, external: bool } = switch (reference.kind) {
        .standard_library, .builtin_module => .{
            .class = .compiler,
            .availability = .resolved,
            .external = true,
        },
        .root_module => .{
            .class = .compiler,
            .availability = .unresolved,
            .external = true,
        },
        .embedded_file => .{
            .class = .resource,
            .availability = .unresolved,
            .external = true,
        },
        .c_header => .{
            .class = .c_header,
            .availability = .unresolved,
            .external = true,
        },
        .zig_file, .zon_file, .named_module => .{
            .class = .external,
            .availability = .unresolved,
            .external = true,
        },
    };
    return makeClassified(
        allocator,
        reference.target,
        reference.target,
        null,
        reference.kind,
        reference.location,
        properties.class,
        properties.availability,
        properties.external,
    );
}

fn classifyFile(allocator: Allocator, file: FileResolutionInput) Allocator.Error!ClassifiedReference {
    const availability: TargetAvailability = switch (file.resolution.status) {
        .resolved => .resolved,
        .missing => .missing,
        .outside_project => .outside_project,
    };
    const is_resolved = file.resolution.status == .resolved;
    const class: TargetClass = if (file.reference.kind == .embedded_file)
        .resource
    else if (is_resolved)
        .internal
    else
        .external;
    return makeClassified(
        allocator,
        file.reference.target,
        file.resolution.target,
        null,
        file.reference.kind,
        file.reference.location,
        class,
        availability,
        !is_resolved,
    );
}

fn classifyModule(allocator: Allocator, module: ResolvedModuleReference) Allocator.Error!ClassifiedReference {
    var class: TargetClass = .external;
    var availability: TargetAvailability = .resolved;
    var external = true;
    var graph_target = module.target;

    switch (module.status) {
        .resolved_project => if (module.source_path) |source_path| {
            class = .internal;
            external = false;
            graph_target = source_path;
        } else {
            availability = .unresolved;
        },
        .resolved_package => {},
        .compiler_provided => class = .compiler,
        .unresolved => {
            availability = .unresolved;
            if (module.kind == .root_module or
                module.kind == .standard_library or
                module.kind == .builtin_module)
            {
                class = .compiler;
            }
        },
        .missing => availability = .missing,
        .outside_project => availability = .outside_project,
    }
    return makeClassified(
        allocator,
        module.target,
        graph_target,
        module.source_path,
        module.kind,
        module.location,
        class,
        availability,
        external,
    );
}

fn makeClassified(
    allocator: Allocator,
    raw_target: []const u8,
    target: []const u8,
    mapped_source_path: ?[]const u8,
    kind: ImportKind,
    location: SourceLocation,
    class: TargetClass,
    availability: TargetAvailability,
    external: bool,
) Allocator.Error!ClassifiedReference {
    const owned_raw_target = try allocator.dupe(u8, raw_target);
    errdefer allocator.free(owned_raw_target);
    const owned_target = try allocator.dupe(u8, target);
    errdefer allocator.free(owned_target);
    const owned_source_path = if (mapped_source_path) |path| try allocator.dupe(u8, path) else null;
    return .{
        .raw_target = owned_raw_target,
        .target = owned_target,
        .mapped_source_path = owned_source_path,
        .kind = kind,
        .location = location,
        .class = class,
        .availability = availability,
        .external = external,
    };
}

const test_location = SourceLocation{ .byte_offset = 22, .line = 2, .column = 7 };

fn makeReference(target: []const u8, kind: ImportKind) DependencyReference {
    return .{ .target = target, .kind = kind, .location = test_location };
}

fn fileInput(
    raw_target: []const u8,
    resolved_target: []const u8,
    kind: ImportKind,
    status: relative_resolver.FileResolutionStatus,
) ResolutionInput {
    return .{ .file = .{
        .reference = makeReference(raw_target, kind),
        .resolution = .{
            .target = resolved_target,
            .kind = kind,
            .location = test_location,
            .status = status,
        },
    } };
}

fn moduleInput(
    target: []const u8,
    source_path: ?[]const u8,
    kind: ImportKind,
    status: module_resolver.ModuleResolutionStatus,
) ResolutionInput {
    return .{ .module = .{
        .target = target,
        .source_path = source_path,
        .kind = kind,
        .location = test_location,
        .status = status,
    } };
}

test "classifies resolved missing and outside file targets" {
    const cases = [_]struct {
        input: ResolutionInput,
        class: TargetClass,
        availability: TargetAvailability,
        external: bool,
    }{
        .{ .input = fileInput("../model.zig", "src/model.zig", .zig_file, .resolved), .class = .internal, .availability = .resolved, .external = false },
        .{ .input = fileInput("../data.zon", "data.zon", .zon_file, .resolved), .class = .internal, .availability = .resolved, .external = false },
        .{ .input = fileInput("missing.zig", "src/missing.zig", .zig_file, .missing), .class = .external, .availability = .missing, .external = true },
        .{ .input = fileInput("../../outside.zig", "../outside.zig", .zig_file, .outside_project), .class = .external, .availability = .outside_project, .external = true },
        .{ .input = fileInput("asset.bin", "assets/asset.bin", .embedded_file, .resolved), .class = .resource, .availability = .resolved, .external = false },
        .{ .input = fileInput("missing.bin", "assets/missing.bin", .embedded_file, .missing), .class = .resource, .availability = .missing, .external = true },
    };
    for (cases) |case| {
        var classified = try classifyReference(std.testing.allocator, case.input);
        defer classified.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.class, classified.class);
        try std.testing.expectEqual(case.availability, classified.availability);
        try std.testing.expectEqual(case.external, classified.external);
        try std.testing.expectEqual(test_location, classified.location);
    }
}

test "classifies project package compiler and unresolved modules" {
    const cases = [_]struct {
        input: ResolutionInput,
        expected_target: []const u8,
        class: TargetClass,
        availability: TargetAvailability,
        external: bool,
    }{
        .{ .input = moduleInput("domain", "src/domain/root.zig", .named_module, .resolved_project), .expected_target = "src/domain/root.zig", .class = .internal, .availability = .resolved, .external = false },
        .{ .input = moduleInput("dependency", "C:/packages/dependency/root.zig", .named_module, .resolved_package), .expected_target = "dependency", .class = .external, .availability = .resolved, .external = true },
        .{ .input = moduleInput("std", null, .standard_library, .compiler_provided), .expected_target = "std", .class = .compiler, .availability = .resolved, .external = true },
        .{ .input = moduleInput("builtin", null, .builtin_module, .compiler_provided), .expected_target = "builtin", .class = .compiler, .availability = .resolved, .external = true },
        .{ .input = moduleInput("root", "src/main.zig", .root_module, .resolved_project), .expected_target = "src/main.zig", .class = .internal, .availability = .resolved, .external = false },
        .{ .input = moduleInput("unknown", null, .named_module, .unresolved), .expected_target = "unknown", .class = .external, .availability = .unresolved, .external = true },
        .{ .input = moduleInput("root", null, .root_module, .unresolved), .expected_target = "root", .class = .compiler, .availability = .unresolved, .external = true },
    };
    for (cases) |case| {
        var classified = try classifyReference(std.testing.allocator, case.input);
        defer classified.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.expected_target, classified.target);
        try std.testing.expectEqual(case.class, classified.class);
        try std.testing.expectEqual(case.availability, classified.availability);
        try std.testing.expectEqual(case.external, classified.external);
    }
}

test "raw C headers and resources retain their identities" {
    var header = try classifyReference(std.testing.allocator, .{ .raw = makeReference("sqlite3.h", .c_header) });
    defer header.deinit(std.testing.allocator);
    try std.testing.expectEqual(TargetClass.c_header, header.class);
    try std.testing.expectEqual(TargetAvailability.unresolved, header.availability);
    try std.testing.expect(header.external);

    var resource = try classifyReference(std.testing.allocator, .{ .raw = makeReference("schema.json", .embedded_file) });
    defer resource.deinit(std.testing.allocator);
    try std.testing.expectEqual(TargetClass.resource, resource.class);
    try std.testing.expectEqual(ImportKind.embedded_file, resource.kind);
}

test "explicit module resolution promotes a stable raw name to an internal target" {
    var unresolved = try classifyReference(std.testing.allocator, .{ .raw = makeReference("domain", .named_module) });
    defer unresolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("domain", unresolved.raw_target);
    try std.testing.expectEqualStrings("domain", unresolved.target);
    try std.testing.expect(unresolved.external);

    var resolved = try classifyReference(
        std.testing.allocator,
        moduleInput("domain", "src/domain/root.zig", .named_module, .resolved_project),
    );
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("domain", resolved.raw_target);
    try std.testing.expectEqualStrings("src/domain/root.zig", resolved.target);
    try std.testing.expect(!resolved.external);
}

fn writeFixture(tmp: *std.testing.TmpDir, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |directory| try tmp.dir.createDirPath(std.testing.io, directory);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "" });
}

test "parsed references flow through resolvers into consistent classifications" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "src/main.zig");
    try writeFixture(&tmp, "src/local.zig");
    try writeFixture(&tmp, "src/domain/root.zig");
    try writeFixture(&tmp, "assets/schema.json");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const source: [:0]const u8 =
        \\const local = @import("local.zig");
        \\const schema = @embedFile("../assets/schema.json");
        \\const std = @import("std");
        \\const domain = @import("domain");
        \\const c = @cImport({ @cInclude("sqlite3.h"); });
    ;
    const modules = [_]module_resolver.ModuleOverride{.{
        .name = "domain",
        .source_path = "src/domain/root.zig",
    }};
    const unit = module_resolver.CompilationUnitOverride{
        .id = "app",
        .root_source_path = "src/main.zig",
        .modules = &modules,
    };
    var context = @import("../error.zig").ErrorContext.init(std.testing.allocator);
    defer context.deinit();
    var parsed = try source_parser.parseSource(
        std.testing.allocator,
        "src/main.zig",
        source,
        .strict,
        &context,
    );
    defer parsed.deinit(std.testing.allocator);
    const expected_classes = [_]TargetClass{ .internal, .resource, .compiler, .internal, .c_header };
    const expected_external = [_]bool{ false, false, true, false, true };

    for (parsed.references.items, expected_classes, expected_external) |parsed_reference, expected_class, external| {
        var classified = switch (parsed_reference.kind) {
            .zig_file, .zon_file, .embedded_file => file: {
                var file_resolution = (try relative_resolver.resolveRelativeReference(
                    std.testing.allocator,
                    std.testing.io,
                    root,
                    parsed.source_path,
                    parsed_reference,
                    &context,
                )).?;
                defer file_resolution.deinit(std.testing.allocator);
                break :file try classifyReference(std.testing.allocator, .{ .file = .{
                    .reference = parsed_reference,
                    .resolution = file_resolution,
                } });
            },
            .named_module, .standard_library, .builtin_module, .root_module => module: {
                var module_resolution = (try module_resolver.resolveModuleReference(
                    std.testing.allocator,
                    std.testing.io,
                    root,
                    unit,
                    parsed_reference,
                    &context,
                )).?;
                defer module_resolution.deinit(std.testing.allocator);
                break :module try classifyReference(std.testing.allocator, .{ .module = module_resolution });
            },
            .c_header => try classifyReference(std.testing.allocator, .{ .raw = parsed_reference }),
        };
        defer classified.deinit(std.testing.allocator);
        try std.testing.expectEqual(expected_class, classified.class);
        try std.testing.expectEqual(external, classified.external);
        try std.testing.expectEqual(parsed_reference.kind, classified.kind);
        try std.testing.expectEqual(parsed_reference.location, classified.location);
    }
}

test "classified output owns raw graph and mapped path bytes" {
    var raw = [_]u8{ 'd', 'o', 'm', 'a', 'i', 'n' };
    var mapped = [_]u8{ 's', 'r', 'c', '/', 'r', 'o', 'o', 't', '.', 'z', 'i', 'g' };
    var classified = try classifyReference(
        std.testing.allocator,
        moduleInput(&raw, &mapped, .named_module, .resolved_project),
    );
    defer classified.deinit(std.testing.allocator);
    raw[0] = 'X';
    mapped[0] = 'Y';
    try std.testing.expectEqualStrings("domain", classified.raw_target);
    try std.testing.expectEqualStrings("src/root.zig", classified.target);
    try std.testing.expectEqualStrings("src/root.zig", classified.mapped_source_path.?);
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var classified = try classifyReference(
        allocator,
        moduleInput("domain", "src/domain/root.zig", .named_module, .resolved_project),
    );
    defer classified.deinit(allocator);
}

test "classification cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
