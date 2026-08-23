const std = @import("std");

const common_error = @import("../error.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const ErrorContext = common_error.ErrorContext;

pub const ProjectMarker = enum {
    explicit_directory,
    build_zig_zon,
    build_zig,
};

pub const LocatedProject = struct {
    path: [:0]u8,
    marker: ProjectMarker,

    pub fn deinit(self: *LocatedProject, allocator: Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

/// Returns an owned canonical project root. Automatic discovery searches the nearest ancestor and
/// prefers `build.zig.zon` over `build.zig` in the same directory.
pub fn locateProject(
    allocator: Allocator,
    io: Io,
    locator: ?[]const u8,
    working_directory: []const u8,
    diagnostics: *ErrorContext,
) common_error.ArchUnitError!LocatedProject {
    if (working_directory.len == 0) {
        return diagnostics.failUser(
            .invalid_project_path,
            "project.locate_working_directory",
            working_directory,
            null,
        );
    }

    const working_root = canonicalPath(allocator, io, working_directory) catch |failure| {
        return mapPathFailure(diagnostics, "project.locate_working_directory", working_directory, failure);
    };
    defer allocator.free(working_root);
    const working_stat = std.Io.Dir.cwd().statFile(io, working_root, .{}) catch |failure| {
        return mapPathFailure(diagnostics, "project.locate_working_directory", working_directory, failure);
    };
    if (working_stat.kind != .directory) {
        return diagnostics.failUser(
            .invalid_project_path,
            "project.locate_working_directory",
            working_directory,
            error.NotDir,
        );
    }

    if (locator) |explicit| {
        return locateExplicit(allocator, io, explicit, working_root, diagnostics);
    }
    return detectAncestor(allocator, io, working_root, diagnostics);
}

fn locateExplicit(
    allocator: Allocator,
    io: Io,
    locator: []const u8,
    working_root: []const u8,
    diagnostics: *ErrorContext,
) common_error.ArchUnitError!LocatedProject {
    if (locator.len == 0) {
        return diagnostics.failUser(.invalid_project_path, "project.locate_explicit", locator, null);
    }

    const resolved = std.fs.path.resolve(allocator, &.{ working_root, locator }) catch {
        return diagnostics.failTechnical(.out_of_memory, "project.locate_explicit", locator, error.OutOfMemory);
    };
    defer allocator.free(resolved);
    var canonical = canonicalPath(allocator, io, resolved) catch |failure| {
        return mapPathFailure(diagnostics, "project.locate_explicit", locator, failure);
    };
    errdefer allocator.free(canonical);
    const stat = std.Io.Dir.cwd().statFile(io, canonical, .{}) catch |failure| {
        return mapPathFailure(diagnostics, "project.locate_explicit", locator, failure);
    };

    if (stat.kind == .directory) {
        normalizeSeparators(canonical);
        return .{ .path = canonical, .marker = .explicit_directory };
    }
    if (stat.kind != .file) {
        return diagnostics.failUser(.invalid_project_path, "project.locate_explicit", locator, null);
    }

    const basename = std.fs.path.basename(canonical);
    const marker: ProjectMarker = if (std.mem.eql(u8, basename, "build.zig.zon"))
        .build_zig_zon
    else if (std.mem.eql(u8, basename, "build.zig"))
        .build_zig
    else
        return diagnostics.failUser(.invalid_project_path, "project.locate_explicit", locator, null);
    const parent = std.fs.path.dirname(canonical) orelse
        return diagnostics.failUser(.invalid_project_path, "project.locate_explicit", locator, null);
    const owned_parent = allocator.dupeZ(u8, parent) catch {
        return diagnostics.failTechnical(.out_of_memory, "project.locate_explicit", locator, error.OutOfMemory);
    };
    allocator.free(canonical);
    canonical = undefined;
    normalizeSeparators(owned_parent);
    return .{ .path = owned_parent, .marker = marker };
}

fn detectAncestor(
    allocator: Allocator,
    io: Io,
    working_root: []const u8,
    diagnostics: *ErrorContext,
) common_error.ArchUnitError!LocatedProject {
    var current = allocator.dupeZ(u8, working_root) catch {
        return diagnostics.failTechnical(.out_of_memory, "project.detect_ancestor", working_root, error.OutOfMemory);
    };
    defer allocator.free(current);

    while (true) {
        if (hasMarker(io, current, "build.zig.zon") catch |failure| {
            return mapPathFailure(diagnostics, "project.detect_ancestor", current, failure);
        }) {
            const result = allocator.dupeZ(u8, current) catch {
                return diagnostics.failTechnical(.out_of_memory, "project.detect_ancestor", current, error.OutOfMemory);
            };
            normalizeSeparators(result);
            return .{ .path = result, .marker = .build_zig_zon };
        }
        if (hasMarker(io, current, "build.zig") catch |failure| {
            return mapPathFailure(diagnostics, "project.detect_ancestor", current, failure);
        }) {
            const result = allocator.dupeZ(u8, current) catch {
                return diagnostics.failTechnical(.out_of_memory, "project.detect_ancestor", current, error.OutOfMemory);
            };
            normalizeSeparators(result);
            return .{ .path = result, .marker = .build_zig };
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const next = allocator.dupeZ(u8, parent) catch {
            return diagnostics.failTechnical(.out_of_memory, "project.detect_ancestor", current, error.OutOfMemory);
        };
        allocator.free(current);
        current = next;
    }

    return diagnostics.failUser(
        .invalid_project_path,
        "project.detect_ancestor",
        working_root,
        error.FileNotFound,
    );
}

fn canonicalPath(allocator: Allocator, io: Io, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
}

fn hasMarker(io: Io, directory_path: []const u8, marker: []const u8) !bool {
    var directory = try std.Io.Dir.openDirAbsolute(io, directory_path, .{});
    defer directory.close(io);
    const stat = directory.statFile(io, marker, .{ .follow_symlinks = false }) catch |failure| switch (failure) {
        error.FileNotFound => return false,
        else => |other| return other,
    };
    return stat.kind == .file;
}

fn mapPathFailure(
    diagnostics: *ErrorContext,
    operation: []const u8,
    subject: []const u8,
    failure: anyerror,
) common_error.ArchUnitError {
    if (failure == error.OutOfMemory) {
        return diagnostics.failTechnical(.out_of_memory, operation, subject, failure);
    }
    return switch (failure) {
        error.FileNotFound, error.NotDir => diagnostics.failUser(
            .invalid_project_path,
            operation,
            subject,
            failure,
        ),
        else => diagnostics.failTechnical(.file_system, operation, subject, failure),
    };
}

fn normalizeSeparators(path: []u8) void {
    for (path) |*byte| if (byte.* == '\\') {
        byte.* = '/';
    };
}

fn temporaryRoot(tmp: *std.testing.TmpDir) ![:0]u8 {
    return tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
}

test "explicit directory works without a project marker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    var context = ErrorContext.init(std.testing.allocator);
    defer context.deinit();

    var project = try locateProject(
        std.testing.allocator,
        std.testing.io,
        root,
        root,
        &context,
    );
    defer project.deinit(std.testing.allocator);
    try std.testing.expectEqual(ProjectMarker.explicit_directory, project.marker);
    try std.testing.expect(std.fs.path.isAbsolute(project.path));
    try std.testing.expect(std.mem.indexOfScalar(u8, project.path, '\\') == null);
}

test "automatic detection prefers nearest ZON marker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data = "" });
    var nested_project = try tmp.dir.createDirPathOpen(std.testing.io, "examples/inner/src", .{});
    nested_project.close(std.testing.io);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "examples/inner/build.zig.zon", .data = ".{}" });
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    const nested = try std.fs.path.join(std.testing.allocator, &.{ root, "examples", "inner", "src" });
    defer std.testing.allocator.free(nested);
    var context = ErrorContext.init(std.testing.allocator);
    defer context.deinit();

    var project = try locateProject(std.testing.allocator, std.testing.io, null, nested, &context);
    defer project.deinit(std.testing.allocator);
    try std.testing.expectEqual(ProjectMarker.build_zig_zon, project.marker);
    try std.testing.expect(std.mem.endsWith(u8, project.path, "examples/inner"));
}

test "explicit marker file resolves its containing directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data = "" });
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    var context = ErrorContext.init(std.testing.allocator);
    defer context.deinit();

    var project = try locateProject(
        std.testing.allocator,
        std.testing.io,
        "build.zig",
        root,
        &context,
    );
    defer project.deinit(std.testing.allocator);
    try std.testing.expectEqual(ProjectMarker.build_zig, project.marker);
    const normalized_root = try @import("../path.zig").normalize(std.testing.allocator, root);
    defer std.testing.allocator.free(normalized_root);
    try std.testing.expectEqualStrings(normalized_root, project.path);
}

test "missing explicit roots are user errors with context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    var context = ErrorContext.init(std.testing.allocator);
    defer context.deinit();

    try std.testing.expectError(
        error.InvalidProjectPath,
        locateProject(std.testing.allocator, std.testing.io, "missing", root, &context),
    );
    try std.testing.expectEqual(common_error.ErrorCategory.user, context.diagnostic.?.category());
}
