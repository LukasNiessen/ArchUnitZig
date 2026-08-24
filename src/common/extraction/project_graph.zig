const std = @import("std");

const archignore = @import("archignore.zig");
const classifier = @import("classifier.zig");
const common_error = @import("../error.zig");
const extraction_options = @import("extraction_options.zig");
const graph_cache = @import("graph_cache.zig");
const graph_normalizer = @import("graph_normalizer.zig");
const module_resolver = @import("module_resolver.zig");
const project_locator = @import("project_locator.zig");
const relative_resolver = @import("relative_resolver.zig");
const source_files = @import("source_files.zig");
const source_parser = @import("source_parser.zig");
const workspace = @import("workspace.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const ExtractionOptions = extraction_options.ExtractionOptions;
pub const Graph = graph_normalizer.Graph;

/// Builds one owned project graph without evaluating `build.zig`. The process cache stores and
/// returns independent clones, so callers always deinitialize the returned graph themselves.
pub fn extractProjectGraph(
    allocator: Allocator,
    io: Io,
    locator: ?[]const u8,
    working_directory: []const u8,
    options: ExtractionOptions,
    clear_cache: bool,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!Graph {
    return extractProjectGraphObserved(
        allocator,
        io,
        locator,
        working_directory,
        options,
        clear_cache,
        diagnostics,
        NoopLogger{},
    );
}

/// Logging-aware entry point used by fluent operations. The optional logger is deliberately a
/// generic borrowed value so extraction does not import the assertion-aware logging runtime.
pub fn extractProjectGraphLogged(
    allocator: Allocator,
    io: Io,
    locator: ?[]const u8,
    working_directory: []const u8,
    options: ExtractionOptions,
    clear_cache: bool,
    diagnostics: *common_error.ErrorContext,
    logger: anytype,
) anyerror!Graph {
    if (logger) |active| {
        return extractProjectGraphObserved(
            allocator,
            io,
            locator,
            working_directory,
            options,
            clear_cache,
            diagnostics,
            active,
        );
    }
    return extractProjectGraph(
        allocator,
        io,
        locator,
        working_directory,
        options,
        clear_cache,
        diagnostics,
    );
}

fn extractProjectGraphObserved(
    allocator: Allocator,
    io: Io,
    locator: ?[]const u8,
    working_directory: []const u8,
    options: ExtractionOptions,
    clear_cache: bool,
    diagnostics: *common_error.ErrorContext,
    logger: anytype,
) !Graph {
    try logger.logExtraction("project graph extraction started");
    try module_resolver.validateModuleResolutionOverrides(options.module_resolution, diagnostics);

    var project = try project_locator.locateProject(
        allocator,
        io,
        locator,
        working_directory,
        diagnostics,
    );
    defer project.deinit(allocator);
    var root_policy = try archignore.load(allocator, io, project.path, diagnostics);
    defer root_policy.deinit(allocator);
    var topology_storage = try workspace.load(
        allocator,
        io,
        project.path,
        options.workspace,
        &root_policy,
        diagnostics,
    );
    defer topology_storage.deinit(allocator);
    const topology: ?*const workspace.Workspace = if (options.workspace.mode == .single_package)
        null
    else
        &topology_storage;
    if (topology) |resolved| try validateWorkspaceContexts(resolved, options.module_resolution, diagnostics);

    if (clear_cache) {
        graph_cache.clearGraphCache();
        try logger.logCache("cache cleared");
    }
    var cache_key = try graph_cache.buildGraphCacheKeyWithContext(
        allocator,
        io,
        project.path,
        options,
        &root_policy,
        topology,
        diagnostics,
    );
    defer cache_key.deinit(allocator);
    if (graph_cache.cloneGraphFromCache(allocator, cache_key) catch {
        return diagnostics.failTechnical(.out_of_memory, "project_graph.cache_get", project.path, error.OutOfMemory);
    }) |cached| {
        try logger.logCache("cache hit");
        try logger.logExtraction("project graph extraction completed from cache");
        return cached;
    }
    try logger.logCache("cache miss");

    var graph = if (topology) |resolved|
        try extractWorkspaceGraph(
            allocator,
            io,
            project.path,
            resolved,
            options,
            &root_policy,
            diagnostics,
        )
    else
        try extractLocatedGraph(
            allocator,
            io,
            project.path,
            options,
            &root_policy,
            diagnostics,
        );
    errdefer graph.deinit(allocator);
    graph_cache.storeGraphInCache(cache_key, graph) catch {
        return diagnostics.failTechnical(.out_of_memory, "project_graph.cache_put", project.path, error.OutOfMemory);
    };
    try logger.logExtraction("project graph extraction completed");
    return graph;
}

const NoopLogger = struct {
    fn logExtraction(_: NoopLogger, _: []const u8) error{}!void {}
    fn logCache(_: NoopLogger, _: []const u8) error{}!void {}
};

fn extractLocatedGraph(
    allocator: Allocator,
    io: Io,
    project_root: []const u8,
    options: ExtractionOptions,
    root_policy: *const archignore.ArchIgnore,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!Graph {
    var files = try source_files.enumerateSourceFilesWithArchIgnore(
        allocator,
        io,
        project_root,
        .{ .exclusions = options.exclusions },
        root_policy,
        diagnostics,
    );
    defer files.deinit(allocator);

    const sources = allocator.alloc(graph_normalizer.SourceReferences, files.items().len) catch {
        return diagnostics.failTechnical(.out_of_memory, "project_graph.allocate_sources", project_root, error.OutOfMemory);
    };
    defer allocator.free(sources);
    const classified = allocator.alloc(std.ArrayList(classifier.ClassifiedReference), files.items().len) catch {
        return diagnostics.failTechnical(.out_of_memory, "project_graph.allocate_references", project_root, error.OutOfMemory);
    };
    defer allocator.free(classified);
    for (classified) |*references| references.* = .empty;
    defer for (classified) |*references| {
        for (references.items) |*reference| reference.deinit(allocator);
        references.deinit(allocator);
    };

    for (files.items(), sources, classified) |source_path, *source, *references| {
        source.* = .{ .source_path = source_path, .references = references.items };
        if (!std.mem.endsWith(u8, source_path, ".zig")) continue;

        const absolute_path = std.fs.path.join(allocator, &.{ project_root, source_path }) catch {
            return diagnostics.failTechnical(.out_of_memory, "project_graph.source_path", source_path, error.OutOfMemory);
        };
        defer allocator.free(absolute_path);
        const contents = std.Io.Dir.cwd().readFileAllocOptions(
            io,
            absolute_path,
            allocator,
            .limited(std.math.maxInt(usize)),
            .of(u8),
            0,
        ) catch |failure| return mapReadFailure(diagnostics, source_path, failure);
        defer allocator.free(contents);

        var parsed = try source_parser.parseSource(
            allocator,
            source_path,
            contents,
            options.strictness,
            diagnostics,
        );
        defer parsed.deinit(allocator);

        for (parsed.references.items) |reference| {
            if (reference.kind == .embedded_file and !options.include_resources) continue;
            if (reference.kind == .c_header and !options.include_c_imports) continue;
            if (reference.inside_test_declaration and !options.include_test_imports) continue;

            var classified_reference = try classify(
                allocator,
                io,
                project_root,
                source_path,
                reference,
                options,
                diagnostics,
            );
            references.append(allocator, classified_reference) catch {
                classified_reference.deinit(allocator);
                return diagnostics.failTechnical(.out_of_memory, "project_graph.append_reference", source_path, error.OutOfMemory);
            };
        }
        source.references = references.items;
    }

    return graph_normalizer.normalizeGraph(allocator, sources) catch |failure| switch (failure) {
        error.OutOfMemory => diagnostics.failTechnical(.out_of_memory, "project_graph.normalize", project_root, failure),
        error.ConflictingExternalClassification => diagnostics.failTechnical(
            .internal_invariant,
            "project_graph.normalize",
            project_root,
            failure,
        ),
    };
}

const WorkspaceSource = struct {
    source_path: []u8,
    references: std.ArrayList(classifier.ClassifiedReference) = .empty,

    fn deinit(self: *WorkspaceSource, allocator: Allocator) void {
        allocator.free(self.source_path);
        for (self.references.items) |*reference| reference.deinit(allocator);
        self.references.deinit(allocator);
        self.* = undefined;
    }
};

fn extractWorkspaceGraph(
    allocator: Allocator,
    io: Io,
    workspace_root: []const u8,
    topology: *const workspace.Workspace,
    options: ExtractionOptions,
    root_policy: *const archignore.ArchIgnore,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!Graph {
    var root_exclusions = try source_files.ExclusionSet.init(allocator, root_policy.patterns(), diagnostics);
    defer root_exclusions.deinit();
    var option_exclusions = try source_files.ExclusionSet.init(allocator, options.exclusions, diagnostics);
    defer option_exclusions.deinit();

    const package_roots = allocator.alloc(module_resolver.WorkspacePackageRoot, topology.items().len) catch {
        return diagnostics.failTechnical(.out_of_memory, "project_graph.allocate_packages", workspace_root, error.OutOfMemory);
    };
    defer allocator.free(package_roots);
    for (topology.items(), package_roots) |package, *root| {
        root.* = .{ .id = package.id, .path = package.path };
    }

    var owned_sources: std.ArrayList(WorkspaceSource) = .empty;
    defer {
        for (owned_sources.items) |*source| source.deinit(allocator);
        owned_sources.deinit(allocator);
    }

    for (topology.items()) |*package| {
        var files = try source_files.enumerateSourceFilesWithArchIgnore(
            allocator,
            io,
            package.path,
            .{},
            &package.policy,
            diagnostics,
        );
        defer files.deinit(allocator);

        for (files.items()) |package_relative| {
            const physical_path = package.workspaceRelative(allocator, package_relative) catch {
                return diagnostics.failTechnical(.out_of_memory, "project_graph.workspace_path", package_relative, error.OutOfMemory);
            };
            defer allocator.free(physical_path);
            if (root_exclusions.excludes(physical_path, false) catch {
                return diagnostics.failTechnical(.out_of_memory, "project_graph.match_root_exclusion", physical_path, error.OutOfMemory);
            }) continue;

            const qualified_path = package.qualify(allocator, package_relative) catch {
                return diagnostics.failTechnical(.out_of_memory, "project_graph.qualify_source", package_relative, error.OutOfMemory);
            };
            var keep_qualified = false;
            defer if (!keep_qualified) allocator.free(qualified_path);
            if (option_exclusions.excludes(qualified_path, false) catch {
                return diagnostics.failTechnical(.out_of_memory, "project_graph.match_exclusion", qualified_path, error.OutOfMemory);
            }) continue;

            owned_sources.append(allocator, .{ .source_path = qualified_path }) catch {
                return diagnostics.failTechnical(.out_of_memory, "project_graph.append_source", qualified_path, error.OutOfMemory);
            };
            keep_qualified = true;
            const source = &owned_sources.items[owned_sources.items.len - 1];
            if (!std.mem.endsWith(u8, package_relative, ".zig")) continue;
            try extractWorkspaceSourceReferences(
                allocator,
                io,
                package,
                package_roots,
                package_relative,
                source,
                options,
                diagnostics,
            );
        }
    }

    const sources = allocator.alloc(graph_normalizer.SourceReferences, owned_sources.items.len) catch {
        return diagnostics.failTechnical(.out_of_memory, "project_graph.allocate_sources", workspace_root, error.OutOfMemory);
    };
    defer allocator.free(sources);
    for (owned_sources.items, sources) |*owned, *source| {
        source.* = .{ .source_path = owned.source_path, .references = owned.references.items };
    }
    return graph_normalizer.normalizeGraph(allocator, sources) catch |failure| switch (failure) {
        error.OutOfMemory => diagnostics.failTechnical(.out_of_memory, "project_graph.normalize", workspace_root, failure),
        error.ConflictingExternalClassification => diagnostics.failTechnical(
            .internal_invariant,
            "project_graph.normalize",
            workspace_root,
            failure,
        ),
    };
}

fn extractWorkspaceSourceReferences(
    allocator: Allocator,
    io: Io,
    package: *const workspace.Package,
    package_roots: []const module_resolver.WorkspacePackageRoot,
    package_relative: []const u8,
    source: *WorkspaceSource,
    options: ExtractionOptions,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!void {
    const absolute_path = std.fs.path.join(allocator, &.{ package.path, package_relative }) catch {
        return diagnostics.failTechnical(.out_of_memory, "project_graph.source_path", source.source_path, error.OutOfMemory);
    };
    defer allocator.free(absolute_path);
    const contents = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        absolute_path,
        allocator,
        .limited(std.math.maxInt(usize)),
        .of(u8),
        0,
    ) catch |failure| return mapReadFailure(diagnostics, source.source_path, failure);
    defer allocator.free(contents);

    var parsed = try source_parser.parseSource(
        allocator,
        source.source_path,
        contents,
        options.strictness,
        diagnostics,
    );
    defer parsed.deinit(allocator);
    for (parsed.references.items) |reference| {
        if (reference.kind == .embedded_file and !options.include_resources) continue;
        if (reference.kind == .c_header and !options.include_c_imports) continue;
        if (reference.inside_test_declaration and !options.include_test_imports) continue;

        var classified_reference = try classifyWorkspace(
            allocator,
            io,
            package,
            package_roots,
            package_relative,
            reference,
            options,
            diagnostics,
        );
        source.references.append(allocator, classified_reference) catch {
            classified_reference.deinit(allocator);
            return diagnostics.failTechnical(.out_of_memory, "project_graph.append_reference", source.source_path, error.OutOfMemory);
        };
    }
}

fn classifyWorkspace(
    allocator: Allocator,
    io: Io,
    package: *const workspace.Package,
    package_roots: []const module_resolver.WorkspacePackageRoot,
    source_path: []const u8,
    reference: source_parser.DependencyReference,
    options: ExtractionOptions,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!classifier.ClassifiedReference {
    return switch (reference.kind) {
        .zig_file, .zon_file, .embedded_file => blk: {
            var resolution = (try relative_resolver.resolveRelativeReference(
                allocator,
                io,
                package.path,
                source_path,
                reference,
                diagnostics,
            )).?;
            defer resolution.deinit(allocator);
            if (resolution.status != .outside_project) {
                const qualified = package.qualify(allocator, resolution.target) catch {
                    return diagnostics.failTechnical(.out_of_memory, "project_graph.qualify_target", resolution.target, error.OutOfMemory);
                };
                allocator.free(resolution.target);
                resolution.target = qualified;
            }
            break :blk classifier.classifyReference(allocator, .{ .file = .{
                .reference = reference,
                .resolution = resolution,
            } }) catch {
                return diagnostics.failTechnical(.out_of_memory, "project_graph.classify", source_path, error.OutOfMemory);
            };
        },
        .named_module, .standard_library, .builtin_module, .root_module => blk: {
            const unit = compilationUnitForWorkspace(package.id, source_path, options.module_resolution) orelse {
                break :blk classifier.classifyReference(allocator, .{ .raw = reference }) catch {
                    return diagnostics.failTechnical(.out_of_memory, "project_graph.classify", source_path, error.OutOfMemory);
                };
            };
            var resolution = (try module_resolver.resolveWorkspaceModuleReference(
                allocator,
                io,
                package_roots,
                package.id,
                unit,
                reference,
                diagnostics,
            )).?;
            defer resolution.deinit(allocator);
            break :blk classifier.classifyReference(allocator, .{ .module = resolution }) catch {
                return diagnostics.failTechnical(.out_of_memory, "project_graph.classify", source_path, error.OutOfMemory);
            };
        },
        .c_header => classifier.classifyReference(allocator, .{ .raw = reference }) catch {
            return diagnostics.failTechnical(.out_of_memory, "project_graph.classify", source_path, error.OutOfMemory);
        },
    };
}

fn validateWorkspaceContexts(
    topology: *const workspace.Workspace,
    overrides: module_resolver.ModuleResolutionOverrides,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!void {
    for (overrides.compilation_units) |unit| {
        const package_id = unit.package_id orelse return diagnostics.failUser(
            .invalid_module_override,
            "module.validate_workspace_unit",
            unit.id,
            null,
        );
        if (topology.find(package_id) == null) return diagnostics.failUser(
            .invalid_module_override,
            "module.validate_workspace_package",
            package_id,
            null,
        );
        for (unit.modules) |module| {
            if (module.origin != .project) continue;
            if (module.package_id) |target_package_id| {
                if (topology.find(target_package_id) == null) return diagnostics.failUser(
                    .invalid_module_override,
                    "module.validate_workspace_package",
                    target_package_id,
                    null,
                );
            }
        }
    }
}

fn classify(
    allocator: Allocator,
    io: Io,
    project_root: []const u8,
    source_path: []const u8,
    reference: source_parser.DependencyReference,
    options: ExtractionOptions,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!classifier.ClassifiedReference {
    return switch (reference.kind) {
        .zig_file, .zon_file, .embedded_file => blk: {
            var resolution = (try relative_resolver.resolveRelativeReference(
                allocator,
                io,
                project_root,
                source_path,
                reference,
                diagnostics,
            )).?;
            defer resolution.deinit(allocator);
            break :blk classifier.classifyReference(allocator, .{ .file = .{
                .reference = reference,
                .resolution = resolution,
            } }) catch {
                return diagnostics.failTechnical(.out_of_memory, "project_graph.classify", source_path, error.OutOfMemory);
            };
        },
        .named_module, .standard_library, .builtin_module, .root_module => blk: {
            const unit = compilationUnitFor(source_path, options.module_resolution) orelse {
                break :blk classifier.classifyReference(allocator, .{ .raw = reference }) catch {
                    return diagnostics.failTechnical(.out_of_memory, "project_graph.classify", source_path, error.OutOfMemory);
                };
            };
            var resolution = (try module_resolver.resolveModuleReference(
                allocator,
                io,
                project_root,
                unit,
                reference,
                diagnostics,
            )).?;
            defer resolution.deinit(allocator);
            break :blk classifier.classifyReference(allocator, .{ .module = resolution }) catch {
                return diagnostics.failTechnical(.out_of_memory, "project_graph.classify", source_path, error.OutOfMemory);
            };
        },
        .c_header => classifier.classifyReference(allocator, .{ .raw = reference }) catch {
            return diagnostics.failTechnical(.out_of_memory, "project_graph.classify", source_path, error.OutOfMemory);
        },
    };
}

/// With one declared compilation unit every source belongs to it. With several units, only an
/// exact root source can be assigned without guessing about build-graph membership.
fn compilationUnitFor(
    source_path: []const u8,
    overrides: module_resolver.ModuleResolutionOverrides,
) ?module_resolver.CompilationUnitOverride {
    for (overrides.compilation_units) |unit| {
        if (unit.root_source_path) |root_source_path| {
            if (std.mem.eql(u8, source_path, root_source_path)) return unit;
        }
    }
    if (overrides.compilation_units.len == 1) return overrides.compilation_units[0];
    return null;
}

/// Workspace selection is confined to one package. An exact compilation root wins; otherwise a
/// package with exactly one declared unit may safely use that context for all of its sources.
fn compilationUnitForWorkspace(
    package_id: []const u8,
    source_path: []const u8,
    overrides: module_resolver.ModuleResolutionOverrides,
) ?module_resolver.CompilationUnitOverride {
    var only: ?module_resolver.CompilationUnitOverride = null;
    var count: usize = 0;
    for (overrides.compilation_units) |unit| {
        const unit_package_id = unit.package_id orelse continue;
        if (!std.mem.eql(u8, unit_package_id, package_id)) continue;
        count += 1;
        only = unit;
        if (unit.root_source_path) |root_source_path| {
            if (std.mem.eql(u8, source_path, root_source_path)) return unit;
        }
    }
    return if (count == 1) only else null;
}

fn mapReadFailure(
    diagnostics: *common_error.ErrorContext,
    source_path: []const u8,
    failure: anyerror,
) common_error.ArchUnitError {
    if (failure == error.OutOfMemory) {
        return diagnostics.failTechnical(.out_of_memory, "project_graph.read_source", source_path, failure);
    }
    return diagnostics.failTechnical(.file_system, "project_graph.read_source", source_path, failure);
}

test "project graph extracts real relative imports and returns independent cached clones" {
    graph_cache.clearGraphCache();
    defer graph_cache.clearGraphCache();
    var diagnostics = common_error.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();

    var first = try extractProjectGraph(
        std.testing.allocator,
        std.testing.io,
        "test/fixtures/files-selection",
        ".",
        .{},
        false,
        &diagnostics,
    );
    defer first.deinit(std.testing.allocator);
    var second = try extractProjectGraph(
        std.testing.allocator,
        std.testing.io,
        "test/fixtures/files-selection",
        ".",
        .{},
        false,
        &diagnostics,
    );
    defer second.deinit(std.testing.allocator);

    const main_to_handler = first.find("src/main.zig", "src/api/handler.zig") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), main_to_handler.locationItems().len);
    try std.testing.expect(first.find("src/api/handler.zig", "src/domain/order.zig") != null);
    try std.testing.expect(first.items().ptr != second.items().ptr);
    try std.testing.expect(first.items()[0].source.ptr != second.items()[0].source.ptr);
}

test "discovered workspace graph preserves package identity and cross-package dependencies" {
    graph_cache.clearGraphCache();
    defer graph_cache.clearGraphCache();
    var diagnostics = common_error.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();
    const root_modules = [_]module_resolver.ModuleOverride{.{
        .name = "api",
        .package_id = "packages/api",
        .source_path = "src/root.zig",
    }};
    const api_modules = [_]module_resolver.ModuleOverride{.{
        .name = "shared",
        .package_id = "packages/shared",
        .source_path = "src/root.zig",
    }};
    const units = [_]module_resolver.CompilationUnitOverride{
        .{
            .id = "workspace-root",
            .package_id = ".",
            .root_source_path = "src/root.zig",
            .modules = &root_modules,
        },
        .{
            .id = "api-library",
            .package_id = "packages/api",
            .root_source_path = "src/root.zig",
            .modules = &api_modules,
        },
    };
    const base_options = ExtractionOptions{
        .workspace = .{ .mode = .discover_packages },
        .module_resolution = .{ .compilation_units = &units },
    };

    var graph = try extractProjectGraph(
        std.testing.allocator,
        std.testing.io,
        "test/fixtures/workspace-multi",
        ".",
        base_options,
        false,
        &diagnostics,
    );
    defer graph.deinit(std.testing.allocator);
    try std.testing.expect(graph.find(".::src/root.zig", "packages/api::src/root.zig") != null);
    try std.testing.expect(graph.find(
        "packages/api::src/root.zig",
        "packages/api::src/helper.zig",
    ) != null);
    const cross_package = graph.find(
        "packages/api::src/root.zig",
        "packages/shared::src/root.zig",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expect(!cross_package.external);
    try std.testing.expect(graph.find("packages/api::src/root.zig", "packages/api::src/root.zig") != null);
    try std.testing.expect(graph.find("packages/shared::src/root.zig", "packages/shared::src/root.zig") != null);
    try std.testing.expect(graph.find(
        "packages/api::src/ignored_by_package.zig",
        "packages/api::src/ignored_by_package.zig",
    ) == null);
    try std.testing.expect(graph.find(
        "packages/shared::src/ignored_by_root.zig",
        "packages/shared::src/ignored_by_root.zig",
    ) == null);
    try std.testing.expect(graph.find("tools/worker::src/root.zig", "tools/worker::src/root.zig") != null);

    var without_worker = try extractProjectGraph(
        std.testing.allocator,
        std.testing.io,
        "test/fixtures/workspace-multi",
        ".",
        .{
            .workspace = base_options.workspace,
            .module_resolution = base_options.module_resolution,
            .exclusions = &.{"tools/worker::**"},
        },
        false,
        &diagnostics,
    );
    defer without_worker.deinit(std.testing.allocator);
    try std.testing.expect(without_worker.find(
        "tools/worker::src/root.zig",
        "tools/worker::src/root.zig",
    ) == null);
}

test "explicit workspace selections use caller package identities" {
    graph_cache.clearGraphCache();
    defer graph_cache.clearGraphCache();
    var diagnostics = common_error.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();
    const selections = [_]workspace.WorkspacePackage{
        .{ .id = "api", .path = "packages/api" },
        .{ .id = "shared", .path = "packages/shared" },
    };
    const modules = [_]module_resolver.ModuleOverride{.{
        .name = "shared",
        .package_id = "shared",
        .source_path = "src/root.zig",
    }};
    const units = [_]module_resolver.CompilationUnitOverride{.{
        .id = "api-library",
        .package_id = "api",
        .root_source_path = "src/root.zig",
        .modules = &modules,
    }};

    var graph = try extractProjectGraph(
        std.testing.allocator,
        std.testing.io,
        "test/fixtures/workspace-multi",
        ".",
        .{
            .workspace = .{ .mode = .explicit_packages, .packages = &selections },
            .module_resolution = .{ .compilation_units = &units },
        },
        true,
        &diagnostics,
    );
    defer graph.deinit(std.testing.allocator);
    try std.testing.expect(graph.find("api::src/root.zig", "api::src/helper.zig") != null);
    try std.testing.expect(graph.find("api::src/root.zig", "shared::src/root.zig") != null);
    try std.testing.expect(graph.find(".::src/root.zig", ".::src/root.zig") == null);
    try std.testing.expect(graph.find("tools/worker::src/root.zig", "tools/worker::src/root.zig") == null);
}

test "editing root archignore invalidates cached extraction without an explicit clear" {
    graph_cache.clearGraphCache();
    defer graph_cache.clearGraphCache();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "build.zig.zon",
        .data = ".{ .name = .fixture, .version = \"0.0.0\", .fingerprint = 0x2222222222222222 }",
    });
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/generated.zig",
        .data = "const kept = @import(\"kept.zig\");\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/kept.zig", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = archignore.file_name,
        .data = "generated.zig\n",
    });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var diagnostics = common_error.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();

    var ignored = try extractProjectGraph(
        std.testing.allocator,
        std.testing.io,
        root,
        ".",
        .{},
        false,
        &diagnostics,
    );
    defer ignored.deinit(std.testing.allocator);
    try std.testing.expect(ignored.find("src/generated.zig", "src/kept.zig") == null);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = archignore.file_name,
        .data = "other.zig\n",
    });
    var included = try extractProjectGraph(
        std.testing.allocator,
        std.testing.io,
        root,
        ".",
        .{},
        false,
        &diagnostics,
    );
    defer included.deinit(std.testing.allocator);
    try std.testing.expect(included.find("src/generated.zig", "src/kept.zig") != null);
}

test "multiple compilation units are assigned only at exact roots" {
    const units = [_]module_resolver.CompilationUnitOverride{
        .{ .id = "app", .root_source_path = "src/main.zig" },
        .{ .id = "tests", .root_source_path = "test/main.zig" },
    };
    const overrides = module_resolver.ModuleResolutionOverrides{ .compilation_units = &units };

    try std.testing.expectEqualStrings("app", compilationUnitFor("src/main.zig", overrides).?.id);
    try std.testing.expect(compilationUnitFor("src/helper.zig", overrides) == null);
}

test "production-only extraction excludes test imports but retains comptime imports" {
    graph_cache.clearGraphCache();
    defer graph_cache.clearGraphCache();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "build.zig.zon",
        .data = ".{ .name = .fixture, .version = \"0.0.0\", .fingerprint = 0x1111111111111111 }",
    });
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/main.zig",
        .data =
        \\comptime { _ = @import("production.zig"); }
        \\test "support" { _ = @import("test_support.zig"); }
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/production.zig", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/test_support.zig", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var diagnostics = common_error.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();

    var complete = try extractProjectGraph(
        std.testing.allocator,
        std.testing.io,
        root,
        ".",
        .{},
        true,
        &diagnostics,
    );
    defer complete.deinit(std.testing.allocator);
    try std.testing.expect(complete.find("src/main.zig", "src/production.zig") != null);
    try std.testing.expect(complete.find("src/main.zig", "src/test_support.zig") != null);

    var production = try extractProjectGraph(
        std.testing.allocator,
        std.testing.io,
        root,
        ".",
        .{ .include_test_imports = false },
        true,
        &diagnostics,
    );
    defer production.deinit(std.testing.allocator);
    try std.testing.expect(production.find("src/main.zig", "src/production.zig") != null);
    try std.testing.expect(production.find("src/main.zig", "src/test_support.zig") == null);
}
