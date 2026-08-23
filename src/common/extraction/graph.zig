const std = @import("std");

const edge_module = @import("edge.zig");

const Allocator = std.mem.Allocator;
pub const Edge = edge_module.Edge;
pub const ImportKind = edge_module.ImportKind;
pub const ImportKinds = edge_module.ImportKinds;

pub const AddError = Allocator.Error || error{ConflictingExternalClassification};

/// An owned graph with at most one edge per `(source, target)` pair.
///
/// Adding a parallel edge unions its import kinds. A target cannot be both internal and external;
/// callers must resolve that contradiction before it reaches the shared model.
pub const Graph = struct {
    edges: std.ArrayList(Edge) = .empty,

    pub fn deinit(self: *Graph, allocator: Allocator) void {
        for (self.edges.items) |*edge| edge.deinit(allocator);
        self.edges.deinit(allocator);
        self.* = .{};
    }

    pub fn add(
        self: *Graph,
        allocator: Allocator,
        source: []const u8,
        target: []const u8,
        external: bool,
        import_kinds: ImportKinds,
    ) AddError!void {
        return self.addLocated(allocator, source, target, external, import_kinds, &.{});
    }

    pub fn addLocated(
        self: *Graph,
        allocator: Allocator,
        source: []const u8,
        target: []const u8,
        external: bool,
        import_kinds: ImportKinds,
        locations: []const edge_module.SourceLocation,
    ) AddError!void {
        var candidate = try Edge.initWithLocations(allocator, source, target, external, import_kinds, locations);
        errdefer candidate.deinit(allocator);

        for (self.edges.items) |*existing| {
            if (!std.mem.eql(u8, existing.source, candidate.source)) continue;
            if (!std.mem.eql(u8, existing.target, candidate.target)) continue;

            if (existing.external != candidate.external) {
                return error.ConflictingExternalClassification;
            }

            try existing.mergeLocations(allocator, candidate.locationItems());
            existing.import_kinds.setUnion(candidate.import_kinds);
            candidate.deinit(allocator);
            return;
        }

        try self.edges.append(allocator, candidate);
    }

    pub fn sort(self: *Graph) void {
        std.mem.sort(Edge, self.edges.items, {}, struct {
            fn lessThan(_: void, left: Edge, right: Edge) bool {
                const source_order = std.mem.order(u8, left.source, right.source);
                if (source_order != .eq) return source_order == .lt;
                return std.mem.order(u8, left.target, right.target) == .lt;
            }
        }.lessThan);
    }

    pub fn clone(self: Graph, allocator: Allocator) Allocator.Error!Graph {
        var cloned: Graph = .{};
        errdefer cloned.deinit(allocator);

        try cloned.edges.ensureTotalCapacity(allocator, self.edges.items.len);
        for (self.edges.items) |edge| {
            cloned.edges.appendAssumeCapacity(try edge.clone(allocator));
        }

        return cloned;
    }

    pub fn items(self: *const Graph) []const Edge {
        return self.edges.items;
    }

    pub fn len(self: *const Graph) usize {
        return self.edges.items.len;
    }

    pub fn find(self: *const Graph, source: []const u8, target: []const u8) ?*const Edge {
        for (self.edges.items) |*edge| {
            if (std.mem.eql(u8, edge.source, source) and std.mem.eql(u8, edge.target, target)) {
                return edge;
            }
        }
        return null;
    }
};

test "a graph owns unique edges and unions parallel import kinds" {
    var graph: Graph = .{};
    defer graph.deinit(std.testing.allocator);

    try graph.add(
        std.testing.allocator,
        "src\\main.zig",
        "src/domain.zig",
        false,
        ImportKinds.initOne(.zig_file),
    );
    try graph.add(
        std.testing.allocator,
        "src/main.zig",
        "src//domain.zig",
        false,
        ImportKinds.initOne(.root_module),
    );

    try std.testing.expectEqual(@as(usize, 1), graph.len());
    const dependency = graph.find("src/main.zig", "src/domain.zig") orelse
        return error.TestExpectedEqual;
    try std.testing.expect(dependency.import_kinds.contains(.zig_file));
    try std.testing.expect(dependency.import_kinds.contains(.root_module));
}

test "a graph rejects contradictory classification for one pair" {
    var graph: Graph = .{};
    defer graph.deinit(std.testing.allocator);

    try graph.add(
        std.testing.allocator,
        "src/main.zig",
        "dependency",
        true,
        ImportKinds.initOne(.named_module),
    );

    try std.testing.expectError(
        error.ConflictingExternalClassification,
        graph.add(
            std.testing.allocator,
            "src/main.zig",
            "dependency",
            false,
            ImportKinds.initOne(.named_module),
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), graph.len());
}

test "cloning a graph owns independent edges" {
    var graph: Graph = .{};
    defer graph.deinit(std.testing.allocator);

    try graph.add(
        std.testing.allocator,
        "src/main.zig",
        "std",
        true,
        ImportKinds.initOne(.standard_library),
    );

    var cloned = try graph.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expectEqual(graph.len(), cloned.len());
    try std.testing.expect(graph.items()[0].eql(cloned.items()[0]));
    try std.testing.expect(graph.items()[0].source.ptr != cloned.items()[0].source.ptr);
    try std.testing.expect(graph.items()[0].target.ptr != cloned.items()[0].target.ptr);
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var graph: Graph = .{};
    defer graph.deinit(allocator);

    try graph.add(
        allocator,
        "src/main.zig",
        "src/service.zig",
        false,
        ImportKinds.initOne(.zig_file),
    );
    try graph.add(
        allocator,
        "src/main.zig",
        "std",
        true,
        ImportKinds.initOne(.standard_library),
    );
    try graph.add(
        allocator,
        "src/main.zig",
        "src/service.zig",
        false,
        ImportKinds.initOne(.root_module),
    );

    var cloned = try graph.clone(allocator);
    defer cloned.deinit(allocator);
}

test "graph construction and cloning clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
