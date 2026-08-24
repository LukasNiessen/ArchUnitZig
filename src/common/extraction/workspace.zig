const std = @import("std");

const archignore = @import("archignore.zig");
const common_error = @import("../error.zig");
const common_path = @import("../path.zig");
const source_files = @import("source_files.zig");
const workspace_options = @import("workspace_options.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const WorkspaceMode = workspace_options.WorkspaceMode;
pub const WorkspaceOptions = workspace_options.WorkspaceOptions;
pub const WorkspacePackage = workspace_options.WorkspacePackage;

pub const Package = struct {
    id: []const u8,
    relative_path: []const u8,
    path: [:0]u8,
    manifest_path: []const u8,
    manifest_fingerprint: [32]u8,
    policy: archignore.ArchIgnore,

    pub fn deinit(self: *Package, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.relative_path);
        allocator.free(self.path);
        allocator.free(self.manifest_path);
        self.policy.deinit(allocator);
        self.* = undefined;
    }

    pub fn qualify(self: *const Package, allocator: Allocator, relative: []const u8) Allocator.Error![]u8 {
        const normalized = try common_path.normalize(allocator, relative);
        defer allocator.free(normalized);
        return std.fmt.allocPrint(allocator, "{s}::{s}", .{ self.id, normalized });
    }

    pub fn workspaceRelative(
        self: *const Package,
        allocator: Allocator,
        package_relative: []const u8,
    ) Allocator.Error![]u8 {
        if (std.mem.eql(u8, self.relative_path, ".")) {
            return common_path.normalize(allocator, package_relative);
        }
        const joined = try std.fs.path.join(allocator, &.{ self.relative_path, package_relative });
        defer allocator.free(joined);
        return common_path.normalize(allocator, joined);
    }
};

pub const Workspace = struct {
    packages: std.ArrayList(Package) = .empty,

    pub fn deinit(self: *Workspace, allocator: Allocator) void {
        for (self.packages.items) |*package| package.deinit(allocator);
        self.packages.deinit(allocator);
        self.* = undefined;
    }

    pub fn items(self: *const Workspace) []const Package {
        return self.packages.items;
    }

    pub fn find(self: *const Workspace, id: []const u8) ?*const Package {
        for (self.packages.items) |*package| {
            if (std.mem.eql(u8, package.id, id)) return package;
        }
        return null;
    }
};

/// Resolves an explicit or discovered workspace into one sorted, owned topology snapshot.
pub fn load(
    allocator: Allocator,
    io: Io,
    workspace_root: []const u8,
    options: WorkspaceOptions,
    root_policy: *const archignore.ArchIgnore,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!Workspace {
    if (options.mode == .single_package) {
        if (options.packages.len != 0) return diagnostics.failUser(
            .invalid_options,
            "workspace.validate_options",
            options.packages[0].path,
            error.PackagesRequireExplicitMode,
        );
        return .{};
    }
    if (options.mode == .discover_packages and options.packages.len != 0) {
        return diagnostics.failUser(
            .invalid_options,
            "workspace.validate_options",
            options.packages[0].path,
            error.DiscoveryRejectsExplicitPackages,
        );
    }
    if (options.mode == .explicit_packages and options.packages.len == 0) {
        return diagnostics.failUser(
            .invalid_options,
            "workspace.validate_options",
            workspace_root,
            error.EmptyWorkspace,
        );
    }

    const canonical_root = canonicalDirectory(allocator, io, workspace_root, diagnostics) catch |failure| return failure;
    defer allocator.free(canonical_root);
    var result = Workspace{};
    errdefer result.deinit(allocator);
    switch (options.mode) {
        .single_package => unreachable,
        .explicit_packages => for (options.packages) |selection| {
            try appendExplicitPackage(
                allocator,
                io,
                canonical_root,
                selection,
                &result,
                diagnostics,
            );
        },
        .discover_packages => try discoverPackages(
            allocator,
            io,
            canonical_root,
            root_policy,
            &result,
            diagnostics,
        ),
    }
    if (result.packages.items.len == 0) return diagnostics.failUser(
        .invalid_options,
        "workspace.load",
        canonical_root,
        error.NoPackageManifests,
    );
    sortPackages(&result);
    try validateUniquePackages(&result, diagnostics);
    return result;
}

fn appendExplicitPackage(
    allocator: Allocator,
    io: Io,
    canonical_root: []const u8,
    selection: WorkspacePackage,
    result: *Workspace,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!void {
    try validateIdentity(selection.id, diagnostics);
    if (selection.path.len == 0) return diagnostics.failUser(
        .invalid_options,
        "workspace.validate_package_path",
        selection.path,
        error.EmptyPackagePath,
    );
    const resolved = std.fs.path.resolve(allocator, &.{ canonical_root, selection.path }) catch {
        return diagnostics.failTechnical(.out_of_memory, "workspace.resolve_package", selection.path, error.OutOfMemory);
    };
    defer allocator.free(resolved);
    const canonical_package = canonicalDirectory(allocator, io, resolved, diagnostics) catch |failure| return failure;
    defer allocator.free(canonical_package);
    const relative = try relativeInsideRoot(allocator, canonical_root, canonical_package, diagnostics);
    defer allocator.free(relative);
    const normalized_id = common_path.normalize(allocator, selection.id) catch {
        return diagnostics.failTechnical(.out_of_memory, "workspace.validate_package_id", selection.id, error.OutOfMemory);
    };
    defer allocator.free(normalized_id);
    try appendPackage(
        allocator,
        io,
        canonical_root,
        normalized_id,
        relative,
        result,
        diagnostics,
    );
}

fn discoverPackages(
    allocator: Allocator,
    io: Io,
    canonical_root: []const u8,
    root_policy: *const archignore.ArchIgnore,
    result: *Workspace,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!void {
    var exclusions = try source_files.ExclusionSet.init(allocator, root_policy.patterns(), diagnostics);
    defer exclusions.deinit();
    var root_dir = std.Io.Dir.openDirAbsolute(io, canonical_root, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |failure| return mapFileFailure(diagnostics, "workspace.discover", canonical_root, failure);
    defer root_dir.close(io);
    var walker = root_dir.walkSelectively(allocator) catch {
        return diagnostics.failTechnical(.out_of_memory, "workspace.discover", canonical_root, error.OutOfMemory);
    };
    defer walker.deinit();

    while (walker.next(io) catch |failure| {
        return mapFileFailure(diagnostics, "workspace.discover", canonical_root, failure);
    }) |entry| {
        const relative = common_path.normalize(allocator, entry.path) catch {
            return diagnostics.failTechnical(.out_of_memory, "workspace.discover", entry.path, error.OutOfMemory);
        };
        defer allocator.free(relative);
        if (entry.kind == .directory) {
            if (source_files.isDefaultExcluded(entry.basename)) continue;
            if (exclusions.excludes(relative, true) catch {
                return diagnostics.failTechnical(.out_of_memory, "workspace.match_exclusion", relative, error.OutOfMemory);
            }) continue;
            walker.enter(io, entry) catch |failure| {
                return mapFileFailure(diagnostics, "workspace.discover", relative, failure);
            };
            continue;
        }
        if (entry.kind != .file or !std.mem.eql(u8, entry.basename, "build.zig.zon")) continue;
        if (exclusions.excludes(relative, false) catch {
            return diagnostics.failTechnical(.out_of_memory, "workspace.match_exclusion", relative, error.OutOfMemory);
        }) continue;
        const package_relative = std.fs.path.dirname(relative) orelse ".";
        try appendPackage(
            allocator,
            io,
            canonical_root,
            package_relative,
            package_relative,
            result,
            diagnostics,
        );
    }
}

fn appendPackage(
    allocator: Allocator,
    io: Io,
    canonical_root: []const u8,
    id: []const u8,
    relative: []const u8,
    result: *Workspace,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!void {
    try validateIdentity(id, diagnostics);
    const resolved = std.fs.path.resolve(allocator, &.{ canonical_root, relative }) catch {
        return diagnostics.failTechnical(.out_of_memory, "workspace.resolve_package", relative, error.OutOfMemory);
    };
    defer allocator.free(resolved);
    const canonical_package = canonicalDirectory(allocator, io, resolved, diagnostics) catch |failure| return failure;
    errdefer allocator.free(canonical_package);
    normalizeSeparators(canonical_package);
    const manifest_native = std.fs.path.join(allocator, &.{ canonical_package, "build.zig.zon" }) catch {
        return diagnostics.failTechnical(.out_of_memory, "workspace.read_manifest", relative, error.OutOfMemory);
    };
    defer allocator.free(manifest_native);
    const manifest_contents = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        manifest_native,
        allocator,
        .limited(std.math.maxInt(usize)),
        .of(u8),
        0,
    ) catch |failure| return mapManifestFailure(diagnostics, manifest_native, failure);
    defer allocator.free(manifest_contents);
    var digest: [32]u8 = undefined;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(manifest_contents);
    hash.final(&digest);

    const owned_id = allocator.dupe(u8, id) catch {
        return diagnostics.failTechnical(.out_of_memory, "workspace.load", id, error.OutOfMemory);
    };
    errdefer allocator.free(owned_id);
    const normalized_relative = common_path.normalize(allocator, relative) catch {
        return diagnostics.failTechnical(.out_of_memory, "workspace.load", relative, error.OutOfMemory);
    };
    errdefer allocator.free(normalized_relative);
    const manifest_path = common_path.normalize(allocator, manifest_native) catch {
        return diagnostics.failTechnical(.out_of_memory, "workspace.load", manifest_native, error.OutOfMemory);
    };
    errdefer allocator.free(manifest_path);
    var policy = try archignore.load(allocator, io, canonical_package, diagnostics);
    errdefer policy.deinit(allocator);
    result.packages.append(allocator, .{
        .id = owned_id,
        .relative_path = normalized_relative,
        .path = canonical_package,
        .manifest_path = manifest_path,
        .manifest_fingerprint = digest,
        .policy = policy,
    }) catch {
        return diagnostics.failTechnical(.out_of_memory, "workspace.load", relative, error.OutOfMemory);
    };
}

fn canonicalDirectory(
    allocator: Allocator,
    io: Io,
    path: []const u8,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError![:0]u8 {
    const canonical = std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch |failure| {
        return mapFileFailure(diagnostics, "workspace.resolve_package", path, failure);
    };
    errdefer allocator.free(canonical);
    const stat = std.Io.Dir.cwd().statFile(io, canonical, .{}) catch |failure| {
        return mapFileFailure(diagnostics, "workspace.resolve_package", path, failure);
    };
    if (stat.kind != .directory) return diagnostics.failUser(
        .invalid_project_path,
        "workspace.resolve_package",
        path,
        error.NotDir,
    );
    return canonical;
}

fn relativeInsideRoot(
    allocator: Allocator,
    canonical_root: []const u8,
    canonical_package: []const u8,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError![]u8 {
    const native = std.fs.path.relative(
        allocator,
        canonical_root,
        null,
        canonical_root,
        canonical_package,
    ) catch {
        return diagnostics.failTechnical(.out_of_memory, "workspace.resolve_package", canonical_package, error.OutOfMemory);
    };
    defer allocator.free(native);
    const normalized = common_path.normalize(allocator, native) catch {
        return diagnostics.failTechnical(.out_of_memory, "workspace.resolve_package", canonical_package, error.OutOfMemory);
    };
    if (std.mem.eql(u8, normalized, "..") or std.mem.startsWith(u8, normalized, "../") or std.fs.path.isAbsolute(normalized)) {
        defer allocator.free(normalized);
        return diagnostics.failUser(
            .invalid_project_path,
            "workspace.resolve_package",
            canonical_package,
            error.OutsideWorkspace,
        );
    }
    return normalized;
}

fn validateIdentity(id: []const u8, diagnostics: *common_error.ErrorContext) common_error.ArchUnitError!void {
    if (id.len == 0 or std.mem.indexOf(u8, id, "::") != null or std.mem.indexOfScalar(u8, id, 0) != null) {
        return diagnostics.failUser(.invalid_options, "workspace.validate_package_id", id, error.InvalidPackageId);
    }
}

fn validateUniquePackages(workspace: *const Workspace, diagnostics: *common_error.ErrorContext) common_error.ArchUnitError!void {
    for (workspace.packages.items, 0..) |package, index| {
        for (workspace.packages.items[0..index]) |prior| {
            if (std.mem.eql(u8, prior.id, package.id)) return diagnostics.failUser(
                .invalid_options,
                "workspace.validate_package_id",
                package.id,
                error.DuplicatePackageId,
            );
            if (std.mem.eql(u8, prior.path, package.path)) return diagnostics.failUser(
                .invalid_options,
                "workspace.validate_package_path",
                package.relative_path,
                error.DuplicatePackagePath,
            );
        }
    }
}

fn sortPackages(workspace: *Workspace) void {
    std.mem.sort(Package, workspace.packages.items, {}, struct {
        fn lessThan(_: void, left: Package, right: Package) bool {
            const id_order = std.mem.order(u8, left.id, right.id);
            if (id_order != .eq) return id_order == .lt;
            return std.mem.order(u8, left.relative_path, right.relative_path) == .lt;
        }
    }.lessThan);
}

fn mapManifestFailure(
    diagnostics: *common_error.ErrorContext,
    path: []const u8,
    failure: anyerror,
) common_error.ArchUnitError {
    if (failure == error.OutOfMemory) {
        return diagnostics.failTechnical(.out_of_memory, "workspace.read_manifest", path, failure);
    }
    return switch (failure) {
        error.FileNotFound, error.NotDir => diagnostics.failUser(
            .invalid_project_path,
            "workspace.read_manifest",
            path,
            failure,
        ),
        else => diagnostics.failTechnical(.file_system, "workspace.read_manifest", path, failure),
    };
}

fn mapFileFailure(
    diagnostics: *common_error.ErrorContext,
    operation: []const u8,
    path: []const u8,
    failure: anyerror,
) common_error.ArchUnitError {
    if (failure == error.OutOfMemory) return diagnostics.failTechnical(.out_of_memory, operation, path, failure);
    return switch (failure) {
        error.FileNotFound, error.NotDir => diagnostics.failUser(.invalid_project_path, operation, path, failure),
        else => diagnostics.failTechnical(.file_system, operation, path, failure),
    };
}

fn normalizeSeparators(path: []u8) void {
    for (path) |*byte| if (byte.* == '\\') {
        byte.* = '/';
    };
}

fn writeManifest(dir: std.Io.Dir, path: []const u8, marker: u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(std.testing.io, parent);
    const contents = try std.fmt.allocPrint(
        std.testing.allocator,
        ".{{ .name = .fixture_{c}, .version = \"0.0.0\", .fingerprint = 0x1111111111111111 }}",
        .{marker},
    );
    defer std.testing.allocator.free(contents);
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = contents });
}

fn temporaryRoot(tmp: *std.testing.TmpDir) ![:0]u8 {
    return tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
}

test "discovery finds nested manifests while pruning defaults and root policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeManifest(tmp.dir, "build.zig.zon", 'r');
    try writeManifest(tmp.dir, "packages/api/build.zig.zon", 'a');
    try writeManifest(tmp.dir, "packages/api/plugins/deep/build.zig.zon", 'd');
    try writeManifest(tmp.dir, "packages/shared/build.zig.zon", 's');
    try writeManifest(tmp.dir, "vendor/hidden/build.zig.zon", 'v');
    try writeManifest(tmp.dir, ".zig-cache/hidden/build.zig.zon", 'c');
    try writeManifest(tmp.dir, "ignored/build.zig.zon", 'i');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = archignore.file_name, .data = "ignored/**\n" });
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    var diagnostics = common_error.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();
    var root_policy = try archignore.load(std.testing.allocator, std.testing.io, root, &diagnostics);
    defer root_policy.deinit(std.testing.allocator);

    var workspace = try load(
        std.testing.allocator,
        std.testing.io,
        root,
        .{ .mode = .discover_packages },
        &root_policy,
        &diagnostics,
    );
    defer workspace.deinit(std.testing.allocator);
    const expected = [_][]const u8{ ".", "packages/api", "packages/api/plugins/deep", "packages/shared" };
    try std.testing.expectEqual(expected.len, workspace.items().len);
    for (expected, workspace.items()) |id, package| try std.testing.expectEqualStrings(id, package.id);
    const qualified = try workspace.items()[1].qualify(std.testing.allocator, "src/main.zig");
    defer std.testing.allocator.free(qualified);
    try std.testing.expectEqualStrings("packages/api::src/main.zig", qualified);
}

test "explicit packages own caller ids and reject duplicate canonical roots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeManifest(tmp.dir, "apps/api/build.zig.zon", 'a');
    try writeManifest(tmp.dir, "libs/shared/build.zig.zon", 's');
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    var diagnostics = common_error.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();
    var root_policy = try archignore.load(std.testing.allocator, std.testing.io, root, &diagnostics);
    defer root_policy.deinit(std.testing.allocator);
    const selections = [_]WorkspacePackage{
        .{ .id = "api", .path = "apps/api" },
        .{ .id = "shared", .path = "libs/shared" },
    };
    var workspace = try load(
        std.testing.allocator,
        std.testing.io,
        root,
        .{ .mode = .explicit_packages, .packages = &selections },
        &root_policy,
        &diagnostics,
    );
    defer workspace.deinit(std.testing.allocator);
    try std.testing.expect(workspace.find("api") != null);
    try std.testing.expectEqualStrings("apps/api", workspace.find("api").?.relative_path);

    const duplicate_paths = [_]WorkspacePackage{
        .{ .id = "first", .path = "apps/api" },
        .{ .id = "second", .path = "apps/api/." },
    };
    try std.testing.expectError(
        error.InvalidOptions,
        load(
            std.testing.allocator,
            std.testing.io,
            root,
            .{ .mode = .explicit_packages, .packages = &duplicate_paths },
            &root_policy,
            &diagnostics,
        ),
    );
    try std.testing.expectEqualStrings("workspace.validate_package_path", diagnostics.diagnostic.?.operation);
}

fn exerciseAllocationFailures(allocator: Allocator, root: []const u8) !void {
    var diagnostics = common_error.ErrorContext.init(allocator);
    defer diagnostics.deinit();
    var root_policy = try archignore.load(allocator, std.testing.io, root, &diagnostics);
    defer root_policy.deinit(allocator);
    var workspace = try load(
        allocator,
        std.testing.io,
        root,
        .{ .mode = .discover_packages },
        &root_policy,
        &diagnostics,
    );
    defer workspace.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), workspace.items().len);
}

test "workspace snapshots clean up every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeManifest(tmp.dir, "build.zig.zon", 'r');
    try writeManifest(tmp.dir, "packages/api/build.zig.zon", 'a');
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{root},
    );
}
