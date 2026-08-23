const std = @import("std");

const common_error = @import("../error.zig");
const common_path = @import("../path.zig");
const source_parser = @import("source_parser.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const DependencyReference = source_parser.DependencyReference;
pub const ImportKind = source_parser.ImportKind;
pub const SourceLocation = source_parser.SourceLocation;

pub const FileResolutionStatus = enum {
    resolved,
    missing,
    outside_project,
};

/// Owned path-resolution output for a Zig, ZON, or embedded-file reference.
pub const ResolvedReference = struct {
    target: []const u8,
    kind: ImportKind,
    location: SourceLocation,
    status: FileResolutionStatus,

    pub fn deinit(self: *ResolvedReference, allocator: Allocator) void {
        allocator.free(self.target);
        self.* = undefined;
    }
};

const LexicalPath = union(enum) {
    inside: []u8,
    outside: []u8,
};

const LexicalError = Allocator.Error || error{InvalidSourcePath};

/// Resolves path-defined dependencies relative to the importing file. Build-defined and
/// compiler-provided imports return `null` and are handled by the module resolver.
pub fn resolveRelativeReference(
    allocator: Allocator,
    io: Io,
    project_root: []const u8,
    source_path: []const u8,
    reference: DependencyReference,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!?ResolvedReference {
    if (!isPathDefined(reference.kind)) return null;
    if (project_root.len == 0) {
        return diagnostics.failUser(.invalid_project_path, "import.resolve_project_root", project_root, null);
    }

    const canonical_root = std.Io.Dir.cwd().realPathFileAlloc(io, project_root, allocator) catch |failure| {
        return mapRootFailure(diagnostics, project_root, failure);
    };
    defer allocator.free(canonical_root);
    const root_stat = std.Io.Dir.cwd().statFile(io, canonical_root, .{}) catch |failure| {
        return mapRootFailure(diagnostics, project_root, failure);
    };
    if (root_stat.kind != .directory) {
        return diagnostics.failUser(.invalid_project_path, "import.resolve_project_root", project_root, error.NotDir);
    }

    const lexical = resolveLexically(allocator, source_path, reference.target) catch |failure| switch (failure) {
        error.OutOfMemory => return diagnostics.failTechnical(
            .out_of_memory,
            "import.resolve_path",
            reference.target,
            failure,
        ),
        error.InvalidSourcePath => return diagnostics.failUser(
            .invalid_project_path,
            "import.resolve_source",
            source_path,
            failure,
        ),
    };
    switch (lexical) {
        .outside => |outside| return .{
            .target = outside,
            .kind = reference.kind,
            .location = reference.location,
            .status = .outside_project,
        },
        .inside => |inside| return try resolveExistingTarget(
            allocator,
            io,
            canonical_root,
            inside,
            reference,
            diagnostics,
        ),
    }
}

fn resolveExistingTarget(
    allocator: Allocator,
    io: Io,
    canonical_root: []const u8,
    lexical_target: []u8,
    reference: DependencyReference,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!ResolvedReference {
    var result = ResolvedReference{
        .target = lexical_target,
        .kind = reference.kind,
        .location = reference.location,
        .status = .missing,
    };
    errdefer result.deinit(allocator);

    const absolute_target = std.fs.path.join(allocator, &.{ canonical_root, lexical_target }) catch {
        return diagnostics.failTechnical(.out_of_memory, "import.resolve_path", lexical_target, error.OutOfMemory);
    };
    defer allocator.free(absolute_target);
    const canonical_target = std.Io.Dir.cwd().realPathFileAlloc(io, absolute_target, allocator) catch |failure| switch (failure) {
        error.FileNotFound, error.NotDir => return result,
        error.OutOfMemory => return diagnostics.failTechnical(
            .out_of_memory,
            "import.resolve_target",
            lexical_target,
            failure,
        ),
        else => |other| return diagnostics.failTechnical(
            .file_system,
            "import.resolve_target",
            lexical_target,
            other,
        ),
    };
    defer allocator.free(canonical_target);
    const target_stat = std.Io.Dir.cwd().statFile(io, canonical_target, .{}) catch |failure| switch (failure) {
        error.FileNotFound, error.NotDir => return result,
        else => |other| return diagnostics.failTechnical(
            .file_system,
            "import.resolve_target",
            lexical_target,
            other,
        ),
    };
    if (target_stat.kind != .file) return result;

    const native_relative = std.fs.path.relative(
        allocator,
        canonical_root,
        null,
        canonical_root,
        canonical_target,
    ) catch {
        return diagnostics.failTechnical(.out_of_memory, "import.resolve_path", lexical_target, error.OutOfMemory);
    };
    defer allocator.free(native_relative);
    const canonical_relative = common_path.normalize(allocator, native_relative) catch {
        return diagnostics.failTechnical(.out_of_memory, "import.resolve_path", lexical_target, error.OutOfMemory);
    };
    if (isAbsoluteLike(canonical_relative) or startsOutside(canonical_relative)) {
        allocator.free(canonical_relative);
        result.status = .outside_project;
        return result;
    }

    allocator.free(result.target);
    result.target = canonical_relative;
    result.status = .resolved;
    return result;
}

fn resolveLexically(allocator: Allocator, source_path: []const u8, raw_target: []const u8) LexicalError!LexicalPath {
    const normalized_source = try common_path.normalize(allocator, source_path);
    defer allocator.free(normalized_source);
    const normalized_target = try common_path.normalize(allocator, raw_target);
    defer allocator.free(normalized_target);

    if (normalized_source.len == 0 or
        normalized_source[normalized_source.len - 1] == '/' or
        isAbsoluteLike(normalized_source))
    {
        return error.InvalidSourcePath;
    }
    if (isAbsoluteLike(normalized_target)) {
        return .{ .outside = try allocator.dupe(u8, normalized_target) };
    }

    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(allocator);
    var source_parts = std.mem.splitScalar(u8, normalized_source, '/');
    while (source_parts.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (segments.items.len == 0) return error.InvalidSourcePath;
            _ = segments.pop();
            continue;
        }
        try segments.append(allocator, segment);
    }
    if (segments.items.len == 0) return error.InvalidSourcePath;
    _ = segments.pop();

    var target_parts = std.mem.splitScalar(u8, normalized_target, '/');
    while (target_parts.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (segments.items.len != 0 and !std.mem.eql(u8, segments.items[segments.items.len - 1], "..")) {
                _ = segments.pop();
            } else {
                try segments.append(allocator, segment);
            }
            continue;
        }
        try segments.append(allocator, segment);
    }

    const joined = try std.mem.join(allocator, "/", segments.items);
    if (startsOutside(joined)) return .{ .outside = joined };
    return .{ .inside = joined };
}

fn isPathDefined(kind: ImportKind) bool {
    return switch (kind) {
        .zig_file, .zon_file, .embedded_file => true,
        .named_module, .standard_library, .builtin_module, .root_module, .c_header => false,
    };
}

fn isAbsoluteLike(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return true;
    return path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
}

fn startsOutside(path: []const u8) bool {
    return std.mem.eql(u8, path, "..") or std.mem.startsWith(u8, path, "../");
}

fn mapRootFailure(
    diagnostics: *common_error.ErrorContext,
    project_root: []const u8,
    failure: anyerror,
) common_error.ArchUnitError {
    if (failure == error.OutOfMemory) {
        return diagnostics.failTechnical(.out_of_memory, "import.resolve_project_root", project_root, failure);
    }
    return switch (failure) {
        error.FileNotFound, error.NotDir => diagnostics.failUser(
            .invalid_project_path,
            "import.resolve_project_root",
            project_root,
            failure,
        ),
        else => diagnostics.failTechnical(.file_system, "import.resolve_project_root", project_root, failure),
    };
}

fn makeReference(target: []const u8, kind: ImportKind) DependencyReference {
    return .{
        .target = target,
        .kind = kind,
        .location = .{ .byte_offset = 17, .line = 2, .column = 5 },
    };
}

fn writeFixture(tmp: *std.testing.TmpDir, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |directory| try tmp.dir.createDirPath(std.testing.io, directory);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "" });
}

fn temporaryRoot(tmp: *std.testing.TmpDir) ![:0]u8 {
    return tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
}

test "resolves nested, root-level, and mixed-separator Zig paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "src/features/api/main.zig");
    try writeFixture(&tmp, "src/domain/model.zig");
    try writeFixture(&tmp, "root.zig");
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();

    var nested = (try resolveRelativeReference(
        std.testing.allocator,
        std.testing.io,
        root,
        "src/features/api/main.zig",
        makeReference("../../domain/./model.zig", .zig_file),
        &context,
    )).?;
    defer nested.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("src/domain/model.zig", nested.target);
    try std.testing.expectEqual(FileResolutionStatus.resolved, nested.status);
    try std.testing.expectEqual(ImportKind.zig_file, nested.kind);
    try std.testing.expectEqual(@as(usize, 2), nested.location.line);

    var root_level = (try resolveRelativeReference(
        std.testing.allocator,
        std.testing.io,
        root,
        "src\\features\\api\\main.zig",
        makeReference("..\\..\\..\\root.zig", .zig_file),
        &context,
    )).?;
    defer root_level.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("root.zig", root_level.target);
    try std.testing.expectEqual(FileResolutionStatus.resolved, root_level.status);
}

test "distinguishes missing and lexically escaped targets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "src/main.zig");
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();

    var missing = (try resolveRelativeReference(
        std.testing.allocator,
        std.testing.io,
        root,
        "src/main.zig",
        makeReference("../missing.zig", .zig_file),
        &context,
    )).?;
    defer missing.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("missing.zig", missing.target);
    try std.testing.expectEqual(FileResolutionStatus.missing, missing.status);

    var outside = (try resolveRelativeReference(
        std.testing.allocator,
        std.testing.io,
        root,
        "src/main.zig",
        makeReference("../../outside.zig", .zig_file),
        &context,
    )).?;
    defer outside.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("../outside.zig", outside.target);
    try std.testing.expectEqual(FileResolutionStatus.outside_project, outside.status);
}

test "keeps ZON and embedded targets internal with their original kinds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "src/main.zig");
    try writeFixture(&tmp, "config/settings.zon");
    try writeFixture(&tmp, "assets/schema.json");
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();

    var zon = (try resolveRelativeReference(
        std.testing.allocator,
        std.testing.io,
        root,
        "src/main.zig",
        makeReference("../config/settings.zon", .zon_file),
        &context,
    )).?;
    defer zon.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("config/settings.zon", zon.target);
    try std.testing.expectEqual(FileResolutionStatus.resolved, zon.status);
    try std.testing.expectEqual(ImportKind.zon_file, zon.kind);

    var embedded = (try resolveRelativeReference(
        std.testing.allocator,
        std.testing.io,
        root,
        "src/main.zig",
        makeReference("../assets/schema.json", .embedded_file),
        &context,
    )).?;
    defer embedded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("assets/schema.json", embedded.target);
    try std.testing.expectEqual(FileResolutionStatus.resolved, embedded.status);
    try std.testing.expectEqual(ImportKind.embedded_file, embedded.kind);
}

test "named modules are never inferred as Zig files" {
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();
    const resolved = try resolveRelativeReference(
        std.testing.allocator,
        std.testing.io,
        "unused-root",
        "src/main.zig",
        makeReference("support", .named_module),
        &context,
    );
    try std.testing.expectEqual(@as(?ResolvedReference, null), resolved);
}

test "parallel references resolve independently to the same target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "src/main.zig");
    try writeFixture(&tmp, "src/shared.zig");
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();

    var first = (try resolveRelativeReference(
        std.testing.allocator,
        std.testing.io,
        root,
        "src/main.zig",
        makeReference("shared.zig", .zig_file),
        &context,
    )).?;
    defer first.deinit(std.testing.allocator);
    var second = (try resolveRelativeReference(
        std.testing.allocator,
        std.testing.io,
        root,
        "src/main.zig",
        makeReference("./shared.zig", .zig_file),
        &context,
    )).?;
    defer second.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(first.target, second.target);
    try std.testing.expect(first.target.ptr != second.target.ptr);
}

fn exerciseAllocationFailures(allocator: Allocator, root: []const u8) !void {
    var context = common_error.ErrorContext.init(allocator);
    defer context.deinit();
    var resolved = (try resolveRelativeReference(
        allocator,
        std.testing.io,
        root,
        "src/nested/main.zig",
        makeReference("../../config/settings.zon", .zon_file),
        &context,
    )).?;
    defer resolved.deinit(allocator);
}

test "relative resolution cleans up every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "src/nested/main.zig");
    try writeFixture(&tmp, "config/settings.zon");
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{root},
    );
}
