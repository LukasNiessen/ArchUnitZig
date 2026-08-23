const std = @import("std");

const extraction = @import("../extraction.zig");
const projected_node = @import("projected_node.zig");

const Allocator = std.mem.Allocator;
pub const Graph = extraction.Graph;
pub const ProjectedNode = projected_node.ProjectedNode;
pub const ProjectedNodes = projected_node.ProjectedNodes;
pub const ProjectionError = projected_node.ProjectionError;

pub const NodeProjectionOptions = struct {
    include_externals: bool = false,
};

/// Projects raw graph identifiers to owned nodes while retaining cloned dependency evidence.
pub fn projectToNodes(
    allocator: Allocator,
    graph: *const Graph,
    options: NodeProjectionOptions,
) ProjectionError!ProjectedNodes {
    var result: ProjectedNodes = .{};
    errdefer result.deinit(allocator);

    for (graph.items()) |raw_edge| {
        const source = try result.ensure(allocator, raw_edge.source);
        if (std.mem.eql(u8, raw_edge.source, raw_edge.target)) continue;
        try source.addOutgoing(allocator, raw_edge);

        if (raw_edge.external and !options.include_externals) continue;
        const target = try result.ensure(allocator, raw_edge.target);
        try target.addIncoming(allocator, raw_edge);
    }
    result.sort();
    return result;
}

fn makeGraph(allocator: Allocator) !Graph {
    var graph: Graph = .{};
    errdefer graph.deinit(allocator);
    try graph.add(
        allocator,
        "src/isolated.zig",
        "src/isolated.zig",
        false,
        extraction.ImportKinds.initEmpty(),
    );
    try graph.add(
        allocator,
        "src/a.zig",
        "src/a.zig",
        false,
        extraction.ImportKinds.initEmpty(),
    );
    try graph.add(
        allocator,
        "src/b.zig",
        "src/b.zig",
        false,
        extraction.ImportKinds.initEmpty(),
    );
    try graph.add(
        allocator,
        "src/a.zig",
        "src/b.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
    );
    try graph.add(
        allocator,
        "src/a.zig",
        "std",
        true,
        extraction.ImportKinds.initOne(.standard_library),
    );
    return graph;
}

test "node projection retains isolated nodes and omits self dependencies" {
    var nodes: ProjectedNodes = undefined;
    {
        var graph = try makeGraph(std.testing.allocator);
        defer graph.deinit(std.testing.allocator);
        nodes = try projectToNodes(std.testing.allocator, &graph, .{});
    }
    defer nodes.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), nodes.len());
    try std.testing.expectEqualStrings("src/a.zig", nodes.items()[0].label);
    try std.testing.expectEqual(@as(usize, 0), nodes.items()[0].incomingItems().len);
    try std.testing.expectEqual(@as(usize, 2), nodes.items()[0].outgoingItems().len);
    try std.testing.expectEqualStrings("src/b.zig", nodes.items()[1].label);
    try std.testing.expectEqual(@as(usize, 1), nodes.items()[1].incomingItems().len);
    try std.testing.expectEqualStrings("src/isolated.zig", nodes.items()[2].label);
    try std.testing.expectEqual(@as(usize, 0), nodes.items()[2].incomingItems().len);
    try std.testing.expectEqual(@as(usize, 0), nodes.items()[2].outgoingItems().len);
}

test "external target nodes are opt in while source evidence remains visible" {
    var graph = try makeGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var without_externals = try projectToNodes(std.testing.allocator, &graph, .{});
    defer without_externals.deinit(std.testing.allocator);
    try std.testing.expect(without_externals.findMutable("std") == null);
    try std.testing.expectEqual(@as(usize, 2), without_externals.findMutable("src/a.zig").?.outgoingItems().len);

    var with_externals = try projectToNodes(
        std.testing.allocator,
        &graph,
        .{ .include_externals = true },
    );
    defer with_externals.deinit(std.testing.allocator);
    const external = with_externals.findMutable("std").?;
    try std.testing.expectEqual(@as(usize, 1), external.incomingItems().len);
    try std.testing.expect(external.incomingItems()[0].external);
}

test "empty graphs project to empty node collections" {
    var graph: Graph = .{};
    defer graph.deinit(std.testing.allocator);
    var nodes = try projectToNodes(std.testing.allocator, &graph, .{});
    defer nodes.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), nodes.len());
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var graph = try makeGraph(allocator);
    defer graph.deinit(allocator);
    var nodes = try projectToNodes(allocator, &graph, .{ .include_externals = true });
    defer nodes.deinit(allocator);
}

test "node projection cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
