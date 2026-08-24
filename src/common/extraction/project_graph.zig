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

    if (clear_cache) {
        graph_cache.clearGraphCache();
        try logger.logCache("cache cleared");
    }
    var cache_key = try graph_cache.buildGraphCacheKeyWithArchIgnore(
        allocator,
        io,
        project.path,
        options,
        &root_policy,
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

    var graph = try extractLocatedGraph(
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
