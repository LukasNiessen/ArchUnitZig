const std = @import("std");

const common_error = @import("../error.zig");
const common_path = @import("../path.zig");
const matching = @import("../matching.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const ErrorContext = common_error.ErrorContext;

pub const default_excluded_directories = [_][]const u8{
    ".git",      ".hg",       ".svn",         ".zig-cache",
    "zig-cache", "zig-out",   "zig-pkg",      ".cache",
    "vendor",    "deps",      "node_modules", "coverage",
    "dist",      "generated", "doc",          "docs",
};

pub const EnumerationOptions = struct {
    exclusions: []const []const u8 = &.{},
    include_default_exclusions: bool = true,
    include_zon: bool = true,
    stop_at_nested_projects: bool = true,
};

pub const SourceFiles = struct {
    storage: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *SourceFiles, allocator: Allocator) void {
        for (self.storage.items) |path| allocator.free(path);
        self.storage.deinit(allocator);
        self.* = undefined;
    }

    pub fn items(self: *const SourceFiles) []const []const u8 {
        return self.storage.items;
    }
};

pub fn enumerateSourceFiles(
    allocator: Allocator,
    io: Io,
    project_root: []const u8,
    options: EnumerationOptions,
    diagnostics: *ErrorContext,
) common_error.ArchUnitError!SourceFiles {
    if (project_root.len == 0) {
        return diagnostics.failUser(.invalid_project_path, "project.enumerate", project_root, null);
    }

    const canonical_root = std.Io.Dir.cwd().realPathFileAlloc(io, project_root, allocator) catch |failure| {
        return mapEnumerationFailure(diagnostics, project_root, failure);
    };
    defer allocator.free(canonical_root);
    const stat = std.Io.Dir.cwd().statFile(io, canonical_root, .{}) catch |failure| {
        return mapEnumerationFailure(diagnostics, project_root, failure);
    };
    if (stat.kind != .directory) {
        return diagnostics.failUser(.invalid_project_path, "project.enumerate", project_root, error.NotDir);
    }

    var exclusions = compileExclusions(allocator, options.exclusions, diagnostics) catch |failure| {
        return failure;
    };
    defer {
        for (exclusions.items) |*filter| filter.deinit();
        exclusions.deinit(allocator);
    }

    var root_dir = std.Io.Dir.openDirAbsolute(io, canonical_root, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |failure| return mapEnumerationFailure(diagnostics, project_root, failure);
    defer root_dir.close(io);
    var walker = root_dir.walkSelectively(allocator) catch {
        return diagnostics.failTechnical(.out_of_memory, "project.enumerate", project_root, error.OutOfMemory);
    };
    defer walker.deinit();

    var result = SourceFiles{};
    errdefer result.deinit(allocator);
    while (walker.next(io) catch |failure| {
        return mapEnumerationFailure(diagnostics, project_root, failure);
    }) |entry| {
        const relative = common_path.normalize(allocator, entry.path) catch {
            return diagnostics.failTechnical(.out_of_memory, "project.enumerate", entry.path, error.OutOfMemory);
        };
        var keep_relative = false;
        defer if (!keep_relative) allocator.free(relative);

        if (entry.kind == .directory) {
            if (options.include_default_exclusions and isDefaultExcluded(entry.basename)) continue;
            if (isCustomExcluded(allocator, relative, true, exclusions.items) catch {
                return diagnostics.failTechnical(.out_of_memory, "project.match_exclusion", relative, error.OutOfMemory);
            }) continue;
            if (options.stop_at_nested_projects and hasNestedMarker(io, entry) catch |failure| {
                return mapEnumerationFailure(diagnostics, relative, failure);
            }) continue;
            walker.enter(io, entry) catch |failure| {
                return mapEnumerationFailure(diagnostics, relative, failure);
            };
            continue;
        }

        // Symlinks/reparse points and non-regular filesystem entries are never followed.
        if (entry.kind != .file or !isAnalyzable(relative, options.include_zon)) continue;
        if (isCustomExcluded(allocator, relative, false, exclusions.items) catch {
            return diagnostics.failTechnical(.out_of_memory, "project.match_exclusion", relative, error.OutOfMemory);
        }) continue;

        result.storage.append(allocator, relative) catch {
            return diagnostics.failTechnical(.out_of_memory, "project.enumerate", relative, error.OutOfMemory);
        };
        keep_relative = true;
    }

    std.mem.sort([]u8, result.storage.items, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);
    return result;
}

fn compileExclusions(
    allocator: Allocator,
    patterns: []const []const u8,
    diagnostics: *ErrorContext,
) common_error.ArchUnitError!std.ArrayList(matching.Filter) {
    var filters: std.ArrayList(matching.Filter) = .empty;
    errdefer {
        for (filters.items) |*filter| filter.deinit();
        filters.deinit(allocator);
    }

    for (patterns) |raw_pattern| {
        const anchored = std.mem.startsWith(u8, raw_pattern, "/");
        const without_anchor = if (anchored) raw_pattern[1..] else raw_pattern;
        if (without_anchor.len == 0) {
            return diagnostics.failUser(.invalid_pattern, "project.compile_exclusion", raw_pattern, null);
        }
        const target: matching.PatternTarget = if (anchored or std.mem.indexOfAny(u8, without_anchor, "/\\") != null)
            .path
        else
            .filename;
        const filter = matching.Filter.init(
            allocator,
            .{ .glob = without_anchor },
            target,
            .partial,
        ) catch |failure| {
            if (failure == error.OutOfMemory) {
                return diagnostics.failTechnical(.out_of_memory, "project.compile_exclusion", raw_pattern, failure);
            }
            return diagnostics.failUser(.invalid_pattern, "project.compile_exclusion", raw_pattern, failure);
        };
        filters.append(allocator, filter) catch {
            var owned_filter = filter;
            owned_filter.deinit();
            return diagnostics.failTechnical(.out_of_memory, "project.compile_exclusion", raw_pattern, error.OutOfMemory);
        };
    }
    return filters;
}

fn isCustomExcluded(
    allocator: Allocator,
    relative: []const u8,
    is_directory: bool,
    filters: []const matching.Filter,
) Allocator.Error!bool {
    for (filters) |*filter| {
        if (filter.matches(allocator, .{ .path = relative }) catch |failure| switch (failure) {
            error.MissingDeclarationName => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
        }) return true;
        if (is_directory and filter.target() == .path) {
            const with_separator = try std.fmt.allocPrint(allocator, "{s}/", .{relative});
            defer allocator.free(with_separator);
            if (filter.matches(allocator, .{ .path = with_separator }) catch |failure| switch (failure) {
                error.MissingDeclarationName => unreachable,
                error.OutOfMemory => return error.OutOfMemory,
            }) return true;
        }
    }
    return false;
}

fn isDefaultExcluded(basename: []const u8) bool {
    for (default_excluded_directories) |excluded| {
        if (std.mem.eql(u8, basename, excluded)) return true;
    }
    return false;
}

fn hasNestedMarker(io: Io, entry: std.Io.Dir.Walker.Entry) !bool {
    var child = try entry.dir.openDir(io, entry.basename, .{ .follow_symlinks = false });
    defer child.close(io);
    for ([_][]const u8{ "build.zig.zon", "build.zig" }) |marker| {
        const stat = child.statFile(io, marker, .{ .follow_symlinks = false }) catch |failure| switch (failure) {
            error.FileNotFound => continue,
            else => |other| return other,
        };
        if (stat.kind == .file) return true;
    }
    return false;
}

fn isAnalyzable(path: []const u8, include_zon: bool) bool {
    return std.mem.endsWith(u8, path, ".zig") or
        (include_zon and std.mem.endsWith(u8, path, ".zon"));
}

fn mapEnumerationFailure(
    diagnostics: *ErrorContext,
    subject: []const u8,
    failure: anyerror,
) common_error.ArchUnitError {
    if (failure == error.OutOfMemory) {
        return diagnostics.failTechnical(.out_of_memory, "project.enumerate", subject, failure);
    }
    return switch (failure) {
        error.FileNotFound, error.NotDir => diagnostics.failUser(
            .invalid_project_path,
            "project.enumerate",
            subject,
            failure,
        ),
        else => diagnostics.failTechnical(.file_system, "project.enumerate", subject, failure),
    };
}

fn writeFixture(dir: std.Io.Dir, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        var target = try dir.createDirPathOpen(std.testing.io, parent, .{});
        defer target.close(std.testing.io);
        try target.writeFile(std.testing.io, .{ .sub_path = std.fs.path.basename(path), .data = "" });
    } else {
        try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "" });
    }
}

fn temporaryRoot(tmp: *std.testing.TmpDir) ![:0]u8 {
    return tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
}

test "enumeration returns sorted relative Zig and ZON paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "src/zeta.zig");
    try writeFixture(tmp.dir, "src/domain/alpha.zig");
    try writeFixture(tmp.dir, "build.zig.zon");
    try writeFixture(tmp.dir, "README.md");
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    var context = ErrorContext.init(std.testing.allocator);
    defer context.deinit();

    var files = try enumerateSourceFiles(
        std.testing.allocator,
        std.testing.io,
        root,
        .{},
        &context,
    );
    defer files.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), files.items().len);
    try std.testing.expectEqualStrings("build.zig.zon", files.items()[0]);
    try std.testing.expectEqualStrings("src/domain/alpha.zig", files.items()[1]);
    try std.testing.expectEqualStrings("src/zeta.zig", files.items()[2]);
}

test "default and custom exclusions prune directories and files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, ".zig-cache/ignored.zig");
    try writeFixture(tmp.dir, "nested/vendor/ignored.zig");
    try writeFixture(tmp.dir, "src/autogen/client.zig");
    try writeFixture(tmp.dir, "src/domain/generated_model.zig");
    try writeFixture(tmp.dir, "src/domain/service.zig");
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    var context = ErrorContext.init(std.testing.allocator);
    defer context.deinit();

    var files = try enumerateSourceFiles(
        std.testing.allocator,
        std.testing.io,
        root,
        .{ .exclusions = &.{ "src/autogen/**", "**/*_model.zig" } },
        &context,
    );
    defer files.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), files.items().len);
    try std.testing.expectEqualStrings("src/domain/service.zig", files.items()[0]);
}

test "root-anchored and basename custom exclusions remain distinct" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "vendor/root.zig");
    try writeFixture(tmp.dir, "nested/vendor/child.zig");
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    var context = ErrorContext.init(std.testing.allocator);
    defer context.deinit();

    var anchored = try enumerateSourceFiles(
        std.testing.allocator,
        std.testing.io,
        root,
        .{ .include_default_exclusions = false, .exclusions = &.{"/vendor"} },
        &context,
    );
    defer anchored.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), anchored.items().len);
    try std.testing.expectEqualStrings("nested/vendor/child.zig", anchored.items()[0]);

    var basename = try enumerateSourceFiles(
        std.testing.allocator,
        std.testing.io,
        root,
        .{ .include_default_exclusions = false, .exclusions = &.{"vendor"} },
        &context,
    );
    defer basename.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), basename.items().len);
}

test "nested marked Zig projects are boundaries by default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "src/main.zig");
    try writeFixture(tmp.dir, "examples/child/build.zig.zon");
    try writeFixture(tmp.dir, "examples/child/src/child.zig");
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    var context = ErrorContext.init(std.testing.allocator);
    defer context.deinit();

    var bounded = try enumerateSourceFiles(std.testing.allocator, std.testing.io, root, .{}, &context);
    defer bounded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), bounded.items().len);
    try std.testing.expectEqualStrings("src/main.zig", bounded.items()[0]);

    var inclusive = try enumerateSourceFiles(
        std.testing.allocator,
        std.testing.io,
        root,
        .{ .stop_at_nested_projects = false },
        &context,
    );
    defer inclusive.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), inclusive.items().len);
}

test "empty projects and disabled ZON inclusion return deterministic empty results" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "package.zon");
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    var context = ErrorContext.init(std.testing.allocator);
    defer context.deinit();
    var files = try enumerateSourceFiles(
        std.testing.allocator,
        std.testing.io,
        root,
        .{ .include_zon = false },
        &context,
    );
    defer files.deinit(std.testing.allocator);
    try std.testing.expect(files.items().len == 0);
}

test "symlink directories are not followed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "src/main.zig");
    tmp.dir.symLink(std.testing.io, ".", "src/loop", .{ .is_directory = true }) catch return;
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    var context = ErrorContext.init(std.testing.allocator);
    defer context.deinit();
    var files = try enumerateSourceFiles(std.testing.allocator, std.testing.io, root, .{}, &context);
    defer files.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), files.items().len);
}

test "unreadable entry failures map to technical errors" {
    var context = ErrorContext.init(std.testing.allocator);
    defer context.deinit();
    const failure = mapEnumerationFailure(&context, "src/private", error.AccessDenied);
    try std.testing.expectEqual(error.FileSystemFailure, failure);
    try std.testing.expectEqual(common_error.ErrorCategory.technical, context.diagnostic.?.category());
    try std.testing.expectEqual(error.AccessDenied, context.diagnostic.?.cause.?);
}

fn exerciseAllocationFailures(allocator: Allocator, root: []const u8) !void {
    var context = ErrorContext.init(allocator);
    defer context.deinit();
    var files = try enumerateSourceFiles(
        allocator,
        std.testing.io,
        root,
        .{ .exclusions = &.{"generated/**"} },
        &context,
    );
    defer files.deinit(allocator);
}

test "enumeration cleans up every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "src/main.zig");
    try writeFixture(tmp.dir, "generated/client.zig");
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{root},
    );
}
