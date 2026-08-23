const std = @import("std");

const common_error = @import("../error.zig");
const common_path = @import("../path.zig");
const relative_resolver = @import("relative_resolver.zig");
const source_parser = @import("source_parser.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const DependencyReference = source_parser.DependencyReference;
pub const ImportKind = source_parser.ImportKind;
pub const SourceLocation = source_parser.SourceLocation;

pub const ModuleOrigin = enum {
    project,
    package,
};

/// One exact alias in a Zig compilation unit. Package mappings remain external even when their
/// source happens to be stored below the analyzed project root.
pub const ModuleOverride = struct {
    name: []const u8,
    source_path: []const u8,
    origin: ModuleOrigin = .project,
};

/// Borrowed module context for one library, executable, test, or other Zig compilation root.
pub const CompilationUnitOverride = struct {
    id: []const u8,
    root_source_path: ?[]const u8 = null,
    modules: []const ModuleOverride = &.{},
};

/// Borrowed collection of independently validated compilation contexts.
pub const ModuleResolutionOverrides = struct {
    compilation_units: []const CompilationUnitOverride = &.{},
};

pub const ModuleResolutionStatus = enum {
    resolved_project,
    resolved_package,
    compiler_provided,
    unresolved,
    missing,
    outside_project,
};

/// Owned resolution of a named/compiler/root import within one compilation unit.
pub const ResolvedModuleReference = struct {
    target: []const u8,
    source_path: ?[]const u8,
    kind: ImportKind,
    location: SourceLocation,
    status: ModuleResolutionStatus,

    pub fn deinit(self: *ResolvedModuleReference, allocator: Allocator) void {
        allocator.free(self.target);
        if (self.source_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

/// Resolves the module-defined import kinds in one explicit compilation context. Relative file,
/// resource, and C-header references return `null` for their dedicated resolvers.
pub fn resolveModuleReference(
    allocator: Allocator,
    io: Io,
    project_root: []const u8,
    unit: CompilationUnitOverride,
    reference: DependencyReference,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!?ResolvedModuleReference {
    if (!isModuleDefined(reference.kind)) return null;
    try validateCompilationUnit(unit, diagnostics);
    return switch (reference.kind) {
        .standard_library, .builtin_module => try makeResolved(
            allocator,
            reference,
            null,
            .compiler_provided,
            diagnostics,
        ),
        .root_module => if (unit.root_source_path) |root_source_path|
            try resolveProjectMapping(
                allocator,
                io,
                project_root,
                root_source_path,
                reference,
                diagnostics,
            )
        else
            try makeResolved(allocator, reference, null, .unresolved, diagnostics),
        .named_module => if (findModule(unit.modules, reference.target)) |module|
            switch (module.origin) {
                .project => try resolveProjectMapping(
                    allocator,
                    io,
                    project_root,
                    module.source_path,
                    reference,
                    diagnostics,
                ),
                .package => try resolvePackageMapping(
                    allocator,
                    io,
                    project_root,
                    module.source_path,
                    reference,
                    diagnostics,
                ),
            }
        else
            try makeResolved(allocator, reference, null, .unresolved, diagnostics),
        .zig_file, .zon_file, .embedded_file, .c_header => unreachable,
    };
}

/// Validates every explicit context and rejects duplicate context identifiers.
pub fn validateModuleResolutionOverrides(
    overrides: ModuleResolutionOverrides,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!void {
    for (overrides.compilation_units, 0..) |unit, index| {
        try validateCompilationUnit(unit, diagnostics);
        for (overrides.compilation_units[0..index]) |prior| {
            if (std.mem.eql(u8, prior.id, unit.id)) {
                return diagnostics.failUser(.invalid_module_override, "module.validate_unit", unit.id, null);
            }
        }
    }
}

fn validateCompilationUnit(
    unit: CompilationUnitOverride,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!void {
    if (unit.id.len == 0) {
        return diagnostics.failUser(.invalid_module_override, "module.validate_unit", unit.id, null);
    }
    if (unit.root_source_path) |root_source_path| if (root_source_path.len == 0) {
        return diagnostics.failUser(.invalid_module_override, "module.validate_root", unit.id, null);
    };
    for (unit.modules, 0..) |module, index| {
        if (module.name.len == 0 or module.source_path.len == 0 or isReservedModule(module.name)) {
            return diagnostics.failUser(.invalid_module_override, "module.validate_alias", module.name, null);
        }
        for (unit.modules[0..index]) |prior| {
            if (std.mem.eql(u8, prior.name, module.name)) {
                return diagnostics.failUser(.invalid_module_override, "module.validate_alias", module.name, null);
            }
        }
    }
}

fn findModule(modules: []const ModuleOverride, name: []const u8) ?ModuleOverride {
    for (modules) |module| if (std.mem.eql(u8, module.name, name)) return module;
    return null;
}

fn isReservedModule(name: []const u8) bool {
    return std.mem.eql(u8, name, "std") or
        std.mem.eql(u8, name, "builtin") or
        std.mem.eql(u8, name, "root");
}

fn isModuleDefined(kind: ImportKind) bool {
    return switch (kind) {
        .named_module, .standard_library, .builtin_module, .root_module => true,
        .zig_file, .zon_file, .embedded_file, .c_header => false,
    };
}

fn resolveProjectMapping(
    allocator: Allocator,
    io: Io,
    project_root: []const u8,
    mapped_source_path: []const u8,
    reference: DependencyReference,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!ResolvedModuleReference {
    const mapped_reference = DependencyReference{
        .target = mapped_source_path,
        .kind = .zig_file,
        .location = reference.location,
    };
    var file_resolution = (try relative_resolver.resolveRelativeReference(
        allocator,
        io,
        project_root,
        "__archunit_compilation_root__.zig",
        mapped_reference,
        diagnostics,
    )).?;
    defer file_resolution.deinit(allocator);
    const status: ModuleResolutionStatus = switch (file_resolution.status) {
        .resolved => .resolved_project,
        .missing => .missing,
        .outside_project => .outside_project,
    };
    return makeResolved(allocator, reference, file_resolution.target, status, diagnostics);
}

fn resolvePackageMapping(
    allocator: Allocator,
    io: Io,
    project_root: []const u8,
    mapped_source_path: []const u8,
    reference: DependencyReference,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!ResolvedModuleReference {
    const canonical_root = std.Io.Dir.cwd().realPathFileAlloc(io, project_root, allocator) catch |failure| {
        return mapProjectRootFailure(diagnostics, project_root, failure);
    };
    defer allocator.free(canonical_root);
    const root_stat = std.Io.Dir.cwd().statFile(io, canonical_root, .{}) catch |failure| {
        return mapProjectRootFailure(diagnostics, project_root, failure);
    };
    if (root_stat.kind != .directory) {
        return diagnostics.failUser(.invalid_project_path, "module.resolve_project_root", project_root, error.NotDir);
    }

    const normalized_mapping = common_path.normalize(allocator, mapped_source_path) catch {
        return diagnostics.failTechnical(.out_of_memory, "module.resolve_package", reference.target, error.OutOfMemory);
    };
    defer allocator.free(normalized_mapping);
    const candidate = std.fs.path.resolve(allocator, &.{ canonical_root, normalized_mapping }) catch {
        return diagnostics.failTechnical(.out_of_memory, "module.resolve_package", reference.target, error.OutOfMemory);
    };
    defer allocator.free(candidate);
    const canonical_source = std.Io.Dir.cwd().realPathFileAlloc(io, candidate, allocator) catch |failure| switch (failure) {
        error.FileNotFound, error.NotDir => return makeResolved(
            allocator,
            reference,
            normalized_mapping,
            .missing,
            diagnostics,
        ),
        error.OutOfMemory => return diagnostics.failTechnical(
            .out_of_memory,
            "module.resolve_package",
            reference.target,
            failure,
        ),
        else => |other| return diagnostics.failTechnical(
            .file_system,
            "module.resolve_package",
            reference.target,
            other,
        ),
    };
    defer allocator.free(canonical_source);
    const source_stat = std.Io.Dir.cwd().statFile(io, canonical_source, .{}) catch |failure| switch (failure) {
        error.FileNotFound, error.NotDir => return makeResolved(
            allocator,
            reference,
            normalized_mapping,
            .missing,
            diagnostics,
        ),
        else => |other| return diagnostics.failTechnical(
            .file_system,
            "module.resolve_package",
            reference.target,
            other,
        ),
    };
    if (source_stat.kind != .file) {
        return makeResolved(allocator, reference, normalized_mapping, .missing, diagnostics);
    }
    const normalized_source = common_path.normalize(allocator, canonical_source) catch {
        return diagnostics.failTechnical(.out_of_memory, "module.resolve_package", reference.target, error.OutOfMemory);
    };
    defer allocator.free(normalized_source);
    return makeResolved(allocator, reference, normalized_source, .resolved_package, diagnostics);
}

fn makeResolved(
    allocator: Allocator,
    reference: DependencyReference,
    source_path: ?[]const u8,
    status: ModuleResolutionStatus,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!ResolvedModuleReference {
    const owned_target = allocator.dupe(u8, reference.target) catch {
        return diagnostics.failTechnical(.out_of_memory, "module.resolve", reference.target, error.OutOfMemory);
    };
    errdefer allocator.free(owned_target);
    const owned_source_path = if (source_path) |path| allocator.dupe(u8, path) catch {
        return diagnostics.failTechnical(.out_of_memory, "module.resolve", reference.target, error.OutOfMemory);
    } else null;
    return .{
        .target = owned_target,
        .source_path = owned_source_path,
        .kind = reference.kind,
        .location = reference.location,
        .status = status,
    };
}

fn mapProjectRootFailure(
    diagnostics: *common_error.ErrorContext,
    project_root: []const u8,
    failure: anyerror,
) common_error.ArchUnitError {
    if (failure == error.OutOfMemory) {
        return diagnostics.failTechnical(.out_of_memory, "module.resolve_project_root", project_root, failure);
    }
    return switch (failure) {
        error.FileNotFound, error.NotDir => diagnostics.failUser(
            .invalid_project_path,
            "module.resolve_project_root",
            project_root,
            failure,
        ),
        else => diagnostics.failTechnical(.file_system, "module.resolve_project_root", project_root, failure),
    };
}

fn makeReference(target: []const u8, kind: ImportKind) DependencyReference {
    return .{
        .target = target,
        .kind = kind,
        .location = .{ .byte_offset = 31, .line = 3, .column = 9 },
    };
}

fn writeFixture(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |directory| try dir.createDirPath(std.testing.io, directory);
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}

fn temporaryRoot(tmp: *std.testing.TmpDir, sub_path: []const u8) ![:0]u8 {
    return tmp.dir.realPathFileAlloc(std.testing.io, sub_path, std.testing.allocator);
}

test "resolves roots and local aliases per compilation unit without executing build.zig" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "build.zig", "pub fn build(_: anytype) void { @panic(\"must not execute\"); }");
    try writeFixture(tmp.dir, "src/lib.zig", "");
    try writeFixture(tmp.dir, "src/main.zig", "");
    try writeFixture(tmp.dir, "test/main.zig", "");
    try writeFixture(tmp.dir, "src/adapter.zig", "");
    const root = try temporaryRoot(&tmp, ".");
    defer std.testing.allocator.free(root);
    const modules = [_]ModuleOverride{.{ .name = "adapter", .source_path = "src/adapter.zig" }};
    const units = [_]CompilationUnitOverride{
        .{ .id = "library", .root_source_path = "src/lib.zig" },
        .{ .id = "app", .root_source_path = "src/main.zig", .modules = &modules },
        .{ .id = "tests", .root_source_path = "test/main.zig", .modules = &modules },
    };
    const expected_roots = [_][]const u8{ "src/lib.zig", "src/main.zig", "test/main.zig" };
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();

    for (units, expected_roots) |unit, expected_root| {
        var root_reference = (try resolveModuleReference(
            std.testing.allocator,
            std.testing.io,
            root,
            unit,
            makeReference("root", .root_module),
            &context,
        )).?;
        defer root_reference.deinit(std.testing.allocator);
        try std.testing.expectEqual(ModuleResolutionStatus.resolved_project, root_reference.status);
        try std.testing.expectEqualStrings("root", root_reference.target);
        try std.testing.expectEqualStrings(expected_root, root_reference.source_path.?);
    }

    var adapter = (try resolveModuleReference(
        std.testing.allocator,
        std.testing.io,
        root,
        units[1],
        makeReference("adapter", .named_module),
        &context,
    )).?;
    defer adapter.deinit(std.testing.allocator);
    try std.testing.expectEqual(ModuleResolutionStatus.resolved_project, adapter.status);
    try std.testing.expectEqualStrings("src/adapter.zig", adapter.source_path.?);
    try std.testing.expectEqual(@as(usize, 3), adapter.location.line);
}

test "duplicate aliases in different compilation units resolve independently" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "src/main.zig", "");
    try writeFixture(tmp.dir, "test/main.zig", "");
    try writeFixture(tmp.dir, "src/runtime_adapter.zig", "");
    try writeFixture(tmp.dir, "test/test_adapter.zig", "");
    const root = try temporaryRoot(&tmp, ".");
    defer std.testing.allocator.free(root);
    const app_modules = [_]ModuleOverride{.{ .name = "adapter", .source_path = "src/runtime_adapter.zig" }};
    const test_modules = [_]ModuleOverride{.{ .name = "adapter", .source_path = "test/test_adapter.zig" }};
    const app = CompilationUnitOverride{ .id = "app", .root_source_path = "src/main.zig", .modules = &app_modules };
    const tests = CompilationUnitOverride{ .id = "tests", .root_source_path = "test/main.zig", .modules = &test_modules };
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();

    var app_result = (try resolveModuleReference(
        std.testing.allocator,
        std.testing.io,
        root,
        app,
        makeReference("adapter", .named_module),
        &context,
    )).?;
    defer app_result.deinit(std.testing.allocator);
    var test_result = (try resolveModuleReference(
        std.testing.allocator,
        std.testing.io,
        root,
        tests,
        makeReference("adapter", .named_module),
        &context,
    )).?;
    defer test_result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("src/runtime_adapter.zig", app_result.source_path.?);
    try std.testing.expectEqualStrings("test/test_adapter.zig", test_result.source_path.?);
}

test "resolves explicit package dependency roots without making them internal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "project/src/main.zig", "");
    try writeFixture(tmp.dir, "package/src/root.zig", "");
    const project_root = try temporaryRoot(&tmp, "project");
    defer std.testing.allocator.free(project_root);
    const modules = [_]ModuleOverride{.{
        .name = "dep",
        .source_path = "../package/src/root.zig",
        .origin = .package,
    }};
    const unit = CompilationUnitOverride{ .id = "app", .root_source_path = "src/main.zig", .modules = &modules };
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();

    var dependency = (try resolveModuleReference(
        std.testing.allocator,
        std.testing.io,
        project_root,
        unit,
        makeReference("dep", .named_module),
        &context,
    )).?;
    defer dependency.deinit(std.testing.allocator);
    try std.testing.expectEqual(ModuleResolutionStatus.resolved_package, dependency.status);
    try std.testing.expectEqualStrings("dep", dependency.target);
    try std.testing.expect(dependency.source_path != null);
    try std.testing.expect(std.mem.endsWith(u8, dependency.source_path.?, "/package/src/root.zig"));
}

test "compiler modules and unresolved aliases remain visible" {
    const unit = CompilationUnitOverride{ .id = "library" };
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();
    for ([_]DependencyReference{
        makeReference("std", .standard_library),
        makeReference("builtin", .builtin_module),
    }) |compiler_reference| {
        var resolved = (try resolveModuleReference(
            std.testing.allocator,
            std.testing.io,
            "unused-root",
            unit,
            compiler_reference,
            &context,
        )).?;
        defer resolved.deinit(std.testing.allocator);
        try std.testing.expectEqual(ModuleResolutionStatus.compiler_provided, resolved.status);
        try std.testing.expectEqualStrings(compiler_reference.target, resolved.target);
        try std.testing.expectEqual(@as(?[]const u8, null), resolved.source_path);
    }

    var unresolved = (try resolveModuleReference(
        std.testing.allocator,
        std.testing.io,
        "unused-root",
        unit,
        makeReference("unknown-package", .named_module),
        &context,
    )).?;
    defer unresolved.deinit(std.testing.allocator);
    try std.testing.expectEqual(ModuleResolutionStatus.unresolved, unresolved.status);
    try std.testing.expectEqualStrings("unknown-package", unresolved.target);
}

test "parser output preserves compiler root and named module semantics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "src/main.zig", "");
    try writeFixture(tmp.dir, "src/adapter.zig", "");
    const root = try temporaryRoot(&tmp, ".");
    defer std.testing.allocator.free(root);
    const source: [:0]const u8 =
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\const root_module = @import("root");
        \\const adapter = @import("adapter");
    ;
    const modules = [_]ModuleOverride{.{ .name = "adapter", .source_path = "src/adapter.zig" }};
    const unit = CompilationUnitOverride{ .id = "app", .root_source_path = "src/main.zig", .modules = &modules };
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();
    var parsed = try source_parser.parseSource(
        std.testing.allocator,
        "src/main.zig",
        source,
        .strict,
        &context,
    );
    defer parsed.deinit(std.testing.allocator);
    const expected_statuses = [_]ModuleResolutionStatus{
        .compiler_provided,
        .compiler_provided,
        .resolved_project,
        .resolved_project,
    };

    for (parsed.references.items, expected_statuses) |parsed_reference, expected_status| {
        var resolved = (try resolveModuleReference(
            std.testing.allocator,
            std.testing.io,
            root,
            unit,
            parsed_reference,
            &context,
        )).?;
        defer resolved.deinit(std.testing.allocator);
        try std.testing.expectEqual(expected_status, resolved.status);
        try std.testing.expectEqual(parsed_reference.kind, resolved.kind);
        try std.testing.expectEqual(parsed_reference.location, resolved.location);
    }
}

test "missing and outside project mappings remain distinguishable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "src/main.zig", "");
    const root = try temporaryRoot(&tmp, ".");
    defer std.testing.allocator.free(root);
    const modules = [_]ModuleOverride{
        .{ .name = "missing-local", .source_path = "src/missing.zig" },
        .{ .name = "outside-local", .source_path = "../outside.zig" },
        .{ .name = "missing-package", .source_path = "../packages/missing.zig", .origin = .package },
    };
    const unit = CompilationUnitOverride{
        .id = "app",
        .root_source_path = "src/missing-root.zig",
        .modules = &modules,
    };
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();
    const cases = [_]struct { target: []const u8, kind: ImportKind, status: ModuleResolutionStatus }{
        .{ .target = "root", .kind = .root_module, .status = .missing },
        .{ .target = "missing-local", .kind = .named_module, .status = .missing },
        .{ .target = "outside-local", .kind = .named_module, .status = .outside_project },
        .{ .target = "missing-package", .kind = .named_module, .status = .missing },
    };
    for (cases) |case| {
        var resolved = (try resolveModuleReference(
            std.testing.allocator,
            std.testing.io,
            root,
            unit,
            makeReference(case.target, case.kind),
            &context,
        )).?;
        defer resolved.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.status, resolved.status);
        try std.testing.expect(resolved.source_path != null);
    }
}

test "invalid aliases and duplicate unit identifiers are user errors" {
    const duplicate_modules = [_]ModuleOverride{
        .{ .name = "domain", .source_path = "src/domain.zig" },
        .{ .name = "domain", .source_path = "test/domain.zig" },
    };
    const duplicate_units = [_]CompilationUnitOverride{
        .{ .id = "app", .modules = &duplicate_modules },
        .{ .id = "app" },
    };
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();
    try std.testing.expectError(
        error.InvalidModuleOverride,
        validateModuleResolutionOverrides(.{ .compilation_units = &duplicate_units }, &context),
    );
    try std.testing.expectEqual(common_error.ErrorCategory.user, context.diagnostic.?.category());
    try std.testing.expectEqualStrings("module.validate_alias", context.diagnostic.?.operation);
    try std.testing.expectEqualStrings("domain", context.diagnostic.?.subject.?);

    const reserved_modules = [_]ModuleOverride{.{ .name = "std", .source_path = "fake.zig" }};
    try std.testing.expectError(
        error.InvalidModuleOverride,
        validateModuleResolutionOverrides(
            .{ .compilation_units = &.{.{ .id = "reserved", .modules = &reserved_modules }} },
            &context,
        ),
    );
    try std.testing.expectEqualStrings("std", context.diagnostic.?.subject.?);

    const repeated_units = [_]CompilationUnitOverride{ .{ .id = "same" }, .{ .id = "same" } };
    try std.testing.expectError(
        error.InvalidModuleOverride,
        validateModuleResolutionOverrides(.{ .compilation_units = &repeated_units }, &context),
    );
    try std.testing.expectEqualStrings("module.validate_unit", context.diagnostic.?.operation);
}

test "non-module references bypass compilation context validation" {
    const invalid_unit = CompilationUnitOverride{ .id = "" };
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();
    for ([_]DependencyReference{
        makeReference("file.zig", .zig_file),
        makeReference("config.zon", .zon_file),
        makeReference("asset.txt", .embedded_file),
        makeReference("header.h", .c_header),
    }) |file_reference| {
        const resolved = try resolveModuleReference(
            std.testing.allocator,
            std.testing.io,
            "unused-root",
            invalid_unit,
            file_reference,
            &context,
        );
        try std.testing.expectEqual(@as(?ResolvedModuleReference, null), resolved);
    }
    try std.testing.expectEqual(@as(?common_error.Diagnostic, null), context.diagnostic);
}

test "module results own raw target bytes" {
    var raw_target = [_]u8{ 'u', 'n', 'k', 'n', 'o', 'w', 'n' };
    const unit = CompilationUnitOverride{ .id = "library" };
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();
    var resolved = (try resolveModuleReference(
        std.testing.allocator,
        std.testing.io,
        "unused-root",
        unit,
        makeReference(&raw_target, .named_module),
        &context,
    )).?;
    defer resolved.deinit(std.testing.allocator);
    raw_target[0] = 'X';
    try std.testing.expectEqualStrings("unknown", resolved.target);
}

fn exerciseAllocationFailures(allocator: Allocator, root: []const u8) !void {
    const modules = [_]ModuleOverride{
        .{ .name = "local", .source_path = "src/local.zig" },
        .{ .name = "package", .source_path = "package/root.zig", .origin = .package },
    };
    const unit = CompilationUnitOverride{ .id = "app", .root_source_path = "src/main.zig", .modules = &modules };
    var context = common_error.ErrorContext.init(allocator);
    defer context.deinit();
    {
        var local = (try resolveModuleReference(
            allocator,
            std.testing.io,
            root,
            unit,
            makeReference("local", .named_module),
            &context,
        )).?;
        defer local.deinit(allocator);
    }
    {
        var package = (try resolveModuleReference(
            allocator,
            std.testing.io,
            root,
            unit,
            makeReference("package", .named_module),
            &context,
        )).?;
        defer package.deinit(allocator);
    }
}

test "module resolution cleans up every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "src/main.zig", "");
    try writeFixture(tmp.dir, "src/local.zig", "");
    try writeFixture(tmp.dir, "package/root.zig", "");
    const root = try temporaryRoot(&tmp, ".");
    defer std.testing.allocator.free(root);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{root},
    );
}
