const std = @import("std");

const common_error = @import("../error.zig");
const common_path = @import("../path.zig");
const extraction_options = @import("extraction_options.zig");
const graph_module = @import("graph.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const BuildGraphMode = extraction_options.BuildGraphMode;
pub const ExtractionOptions = extraction_options.ExtractionOptions;
pub const Graph = graph_module.Graph;

const cache_key_schema_version: u64 = 1;
const keyed_option_fields = [_][]const u8{
    "exclusions",
    "strictness",
    "include_resources",
    "include_c_imports",
    "module_resolution",
    "build_graph_mode",
};

/// Owned canonical cache identity. Hashes accelerate lookup; equality always compares full bytes.
pub const GraphCacheKey = struct {
    bytes: []const u8,
    hash_value: u64,

    pub fn clone(self: GraphCacheKey, allocator: Allocator) Allocator.Error!GraphCacheKey {
        return .{ .bytes = try allocator.dupe(u8, self.bytes), .hash_value = self.hash_value };
    }

    pub fn deinit(self: *GraphCacheKey, allocator: Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn eql(self: GraphCacheKey, other: GraphCacheKey) bool {
        return self.hash_value == other.hash_value and std.mem.eql(u8, self.bytes, other.bytes);
    }
};

/// Constructs the complete graph-cache identity from a canonical project root and extraction input.
pub fn buildGraphCacheKey(
    allocator: Allocator,
    io: Io,
    project_root: []const u8,
    options: ExtractionOptions,
    diagnostics: *common_error.ErrorContext,
) common_error.ArchUnitError!GraphCacheKey {
    if (project_root.len == 0) {
        return diagnostics.failUser(.invalid_project_path, "graph_cache.build_key", project_root, null);
    }
    const canonical_root = std.Io.Dir.cwd().realPathFileAlloc(io, project_root, allocator) catch |failure| {
        return mapRootFailure(diagnostics, project_root, failure);
    };
    defer allocator.free(canonical_root);
    const root_stat = std.Io.Dir.cwd().statFile(io, canonical_root, .{}) catch |failure| {
        return mapRootFailure(diagnostics, project_root, failure);
    };
    if (root_stat.kind != .directory) {
        return diagnostics.failUser(.invalid_project_path, "graph_cache.build_key", project_root, error.NotDir);
    }
    const normalized_root = common_path.normalize(allocator, canonical_root) catch {
        return diagnostics.failTechnical(.out_of_memory, "graph_cache.build_key", project_root, error.OutOfMemory);
    };
    defer allocator.free(normalized_root);

    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(allocator);
    appendKey(allocator, &encoded, normalized_root, options) catch {
        return diagnostics.failTechnical(.out_of_memory, "graph_cache.build_key", project_root, error.OutOfMemory);
    };
    const bytes = encoded.toOwnedSlice(allocator) catch {
        return diagnostics.failTechnical(.out_of_memory, "graph_cache.build_key", project_root, error.OutOfMemory);
    };
    return .{ .bytes = bytes, .hash_value = std.hash.Wyhash.hash(0, bytes) };
}

fn appendKey(
    allocator: Allocator,
    encoded: *std.ArrayList(u8),
    canonical_root: []const u8,
    options: ExtractionOptions,
) Allocator.Error!void {
    try appendU64(allocator, encoded, cache_key_schema_version);
    try appendString(allocator, encoded, canonical_root);
    try appendU64(allocator, encoded, @intFromEnum(options.strictness));
    try encoded.append(allocator, @intFromBool(options.include_resources));
    try encoded.append(allocator, @intFromBool(options.include_c_imports));
    try appendU64(allocator, encoded, @intFromEnum(options.build_graph_mode));

    try appendU64(allocator, encoded, options.exclusions.len);
    for (options.exclusions) |exclusion| try appendString(allocator, encoded, exclusion);

    const units = options.module_resolution.compilation_units;
    try appendU64(allocator, encoded, units.len);
    for (units) |unit| {
        try appendString(allocator, encoded, unit.id);
        if (unit.root_source_path) |root_source_path| {
            try encoded.append(allocator, 1);
            try appendString(allocator, encoded, root_source_path);
        } else {
            try encoded.append(allocator, 0);
        }
        try appendU64(allocator, encoded, unit.modules.len);
        for (unit.modules) |module| {
            try appendString(allocator, encoded, module.name);
            try appendString(allocator, encoded, module.source_path);
            try appendU64(allocator, encoded, @intFromEnum(module.origin));
        }
    }
}

fn appendString(
    allocator: Allocator,
    encoded: *std.ArrayList(u8),
    value: []const u8,
) Allocator.Error!void {
    try appendU64(allocator, encoded, value.len);
    try encoded.appendSlice(allocator, value);
}

fn appendU64(allocator: Allocator, encoded: *std.ArrayList(u8), raw_value: anytype) Allocator.Error!void {
    var value: u64 = @intCast(raw_value);
    var index: usize = 0;
    while (index < @sizeOf(u64)) : (index += 1) {
        try encoded.append(allocator, @truncate(value));
        value >>= 8;
    }
}

fn mapRootFailure(
    diagnostics: *common_error.ErrorContext,
    project_root: []const u8,
    failure: anyerror,
) common_error.ArchUnitError {
    if (failure == error.OutOfMemory) {
        return diagnostics.failTechnical(.out_of_memory, "graph_cache.build_key", project_root, failure);
    }
    return switch (failure) {
        error.FileNotFound, error.NotDir => diagnostics.failUser(
            .invalid_project_path,
            "graph_cache.build_key",
            project_root,
            failure,
        ),
        else => diagnostics.failTechnical(.file_system, "graph_cache.build_key", project_root, failure),
    };
}

const Entry = struct {
    key: GraphCacheKey,
    graph: Graph,

    fn deinit(self: *Entry, allocator: Allocator) void {
        self.key.deinit(allocator);
        self.graph.deinit(allocator);
        self.* = undefined;
    }
};

/// Caller-owned cache. It is not internally synchronized; use the global helpers for shared access.
pub const GraphCache = struct {
    allocator: Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: Allocator) GraphCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *GraphCache) void {
        self.clear();
        self.* = undefined;
    }

    pub fn clear(self: *GraphCache) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.entries = .empty;
    }

    pub fn len(self: *const GraphCache) usize {
        return self.entries.items.len;
    }

    /// Returns an independent graph clone; cached storage is never exposed mutably.
    pub fn get(
        self: *const GraphCache,
        result_allocator: Allocator,
        key: GraphCacheKey,
    ) Allocator.Error!?Graph {
        for (self.entries.items) |entry| {
            if (entry.key.eql(key)) return try entry.graph.clone(result_allocator);
        }
        return null;
    }

    /// Stores immutable clones. Re-inserting an existing key keeps the first complete graph.
    pub fn put(self: *GraphCache, key: GraphCacheKey, graph: Graph) Allocator.Error!void {
        for (self.entries.items) |entry| if (entry.key.eql(key)) return;
        var owned_key = try key.clone(self.allocator);
        errdefer owned_key.deinit(self.allocator);
        var owned_graph = try graph.clone(self.allocator);
        errdefer owned_graph.deinit(self.allocator);
        try self.entries.append(self.allocator, .{ .key = owned_key, .graph = owned_graph });
    }
};

var global_lock: std.atomic.Mutex = .unlocked;
var global_cache = GraphCache.init(std.heap.page_allocator);

fn lockGlobalCache() void {
    while (!global_lock.tryLock()) std.atomic.spinLoopHint();
}

/// Returns an independent clone from the process-wide graph cache.
pub fn cloneGraphFromCache(allocator: Allocator, key: GraphCacheKey) Allocator.Error!?Graph {
    lockGlobalCache();
    defer global_lock.unlock();
    return global_cache.get(allocator, key);
}

/// Stores owned clones in the process-wide graph cache.
pub fn storeGraphInCache(key: GraphCacheKey, graph: Graph) Allocator.Error!void {
    lockGlobalCache();
    defer global_lock.unlock();
    return global_cache.put(key, graph);
}

/// Thread-safe process-wide invalidation. Existing caller-owned graph clones remain valid.
pub fn clearGraphCache() void {
    lockGlobalCache();
    defer global_lock.unlock();
    global_cache.clear();
}

fn temporaryRoot(tmp: *std.testing.TmpDir) ![:0]u8 {
    return tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
}

fn makeGraph(allocator: Allocator, target: []const u8) !Graph {
    var graph: Graph = .{};
    errdefer graph.deinit(allocator);
    try graph.add(
        allocator,
        "src/main.zig",
        target,
        true,
        graph_module.ImportKinds.initOne(.named_module),
    );
    return graph;
}

test "canonical roots produce equal keys and every option separates keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    const dotted_root = try std.fs.path.join(std.testing.allocator, &.{ root, "." });
    defer std.testing.allocator.free(dotted_root);
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();
    var baseline = try buildGraphCacheKey(std.testing.allocator, std.testing.io, root, .{}, &context);
    defer baseline.deinit(std.testing.allocator);
    var equivalent = try buildGraphCacheKey(std.testing.allocator, std.testing.io, dotted_root, .{}, &context);
    defer equivalent.deinit(std.testing.allocator);
    try std.testing.expect(baseline.eql(equivalent));

    const module_resolver = @import("module_resolver.zig");
    const exclusions = [_][]const u8{"generated/**"};
    const modules = [_]module_resolver.ModuleOverride{.{ .name = "domain", .source_path = "src/domain/root.zig" }};
    const units = [_]module_resolver.CompilationUnitOverride{.{
        .id = "app",
        .root_source_path = "src/main.zig",
        .modules = &modules,
    }};
    const variants = [_]ExtractionOptions{
        .{ .exclusions = &exclusions },
        .{ .strictness = .permissive },
        .{ .include_resources = false },
        .{ .include_c_imports = false },
        .{ .module_resolution = .{ .compilation_units = &units } },
        .{ .build_graph_mode = .disabled },
    };
    for (variants) |options| {
        var variant = try buildGraphCacheKey(std.testing.allocator, std.testing.io, root, options, &context);
        defer variant.deinit(std.testing.allocator);
        try std.testing.expect(!baseline.eql(variant));
    }
}

test "instance cache hits own keys and return independent graphs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();
    var key = try buildGraphCacheKey(std.testing.allocator, std.testing.io, root, .{}, &context);
    defer key.deinit(std.testing.allocator);
    var graph = try makeGraph(std.testing.allocator, "dependency");
    var cache = GraphCache.init(std.testing.allocator);
    defer cache.deinit();
    try cache.put(key, graph);
    graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), cache.len());

    var first = (try cache.get(std.testing.allocator, key)).?;
    defer first.deinit(std.testing.allocator);
    var second = (try cache.get(std.testing.allocator, key)).?;
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("dependency", first.items()[0].target);
    try std.testing.expect(first.items()[0].target.ptr != second.items()[0].target.ptr);
    cache.clear();
    try std.testing.expectEqual(@as(usize, 0), cache.len());
    try std.testing.expectEqual(@as(?Graph, null), try cache.get(std.testing.allocator, key));
}

test "global cache clears safely without invalidating caller clones" {
    clearGraphCache();
    defer clearGraphCache();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    var context = common_error.ErrorContext.init(std.testing.allocator);
    defer context.deinit();
    var key = try buildGraphCacheKey(std.testing.allocator, std.testing.io, root, .{}, &context);
    defer key.deinit(std.testing.allocator);
    var source = try makeGraph(std.testing.allocator, "global-dependency");
    defer source.deinit(std.testing.allocator);
    try storeGraphInCache(key, source);
    var clone = (try cloneGraphFromCache(std.testing.allocator, key)).?;
    defer clone.deinit(std.testing.allocator);
    clearGraphCache();
    try std.testing.expectEqualStrings("global-dependency", clone.items()[0].target);
    try std.testing.expectEqual(@as(?Graph, null), try cloneGraphFromCache(std.testing.allocator, key));
}

test "cache key schema lists every extraction option" {
    const fields = @typeInfo(ExtractionOptions).@"struct".fields;
    try std.testing.expectEqual(fields.len, keyed_option_fields.len);
    inline for (fields) |field| {
        var found = false;
        for (keyed_option_fields) |keyed| if (std.mem.eql(u8, field.name, keyed)) {
            found = true;
            break;
        };
        try std.testing.expect(found);
    }
}

fn exerciseAllocationFailures(allocator: Allocator, root: []const u8) !void {
    var context = common_error.ErrorContext.init(allocator);
    defer context.deinit();
    var key = try buildGraphCacheKey(allocator, std.testing.io, root, .{}, &context);
    defer key.deinit(allocator);
    var graph = try makeGraph(allocator, "dependency");
    defer graph.deinit(allocator);
    var cache = GraphCache.init(allocator);
    defer cache.deinit();
    try cache.put(key, graph);
    var cloned = (try cache.get(allocator, key)).?;
    defer cloned.deinit(allocator);
}

test "key and cache operations clean up every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try temporaryRoot(&tmp);
    defer std.testing.allocator.free(root);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{root},
    );
}
