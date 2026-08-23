const std = @import("std");

const extraction = @import("../extraction.zig");
const mapped_edge = @import("mapped_edge.zig");
const projected_edge = @import("projected_edge.zig");

const Allocator = std.mem.Allocator;
pub const Graph = extraction.Graph;
pub const MapFunction = mapped_edge.MapFunction;
pub const MappedEdge = mapped_edge.MappedEdge;
pub const ProjectedEdge = projected_edge.ProjectedEdge;
pub const ProjectedEdges = projected_edge.ProjectedEdges;
pub const ProjectionError = projected_edge.ProjectionError;

/// Applies one mapping hook and aggregates all raw evidence with equal mapped labels.
pub fn projectEdges(
    allocator: Allocator,
    graph: *const Graph,
    mapper: MapFunction,
) ProjectionError!ProjectedEdges {
    var result: ProjectedEdges = .{};
    errdefer result.deinit(allocator);

    for (graph.items()) |*raw_edge| {
        const mapped = mapper.map(raw_edge) orelse continue;
        try mapped.validate();
        if (result.findMutable(mapped.source_label, mapped.target_label)) |existing| {
            try existing.appendEvidence(allocator, raw_edge.*);
            continue;
        }

        var projected = try ProjectedEdge.init(allocator, mapped, raw_edge.*);
        result.appendMove(allocator, &projected) catch |failure| {
            projected.deinit(allocator);
            return failure;
        };
    }
    result.sort();
    return result;
}

fn aggregateInternal(_: ?*const anyopaque, edge: *const extraction.Edge) ?MappedEdge {
    if (edge.external) return null;
    return .{ .source_label = "application", .target_label = "domain" };
}

fn identity(_: ?*const anyopaque, edge: *const extraction.Edge) ?MappedEdge {
    return .{ .source_label = edge.source, .target_label = edge.target };
}

fn invalidMapper(_: ?*const anyopaque, _: *const extraction.Edge) ?MappedEdge {
    return .{ .source_label = "", .target_label = "target" };
}

fn makeGraph(allocator: Allocator) !Graph {
    var graph: Graph = .{};
    errdefer graph.deinit(allocator);
    try graph.add(
        allocator,
        "src/service.zig",
        "src/domain/order.zig",
        false,
        extraction.ImportKinds.initOne(.root_module),
    );
    try graph.add(
        allocator,
        "src/api/handler.zig",
        "src/domain/model.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
    );
    try graph.add(
        allocator,
        "src/api/handler.zig",
        "std",
        true,
        extraction.ImportKinds.initOne(.standard_library),
    );
    return graph;
}

test "edge projection drops relabels aggregates and owns raw evidence" {
    var projected: ProjectedEdges = undefined;
    {
        var graph = try makeGraph(std.testing.allocator);
        defer graph.deinit(std.testing.allocator);
        projected = try projectEdges(
            std.testing.allocator,
            &graph,
            MapFunction.init(null, aggregateInternal),
        );
    }
    defer projected.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), projected.len());
    const dependency = projected.items()[0];
    try std.testing.expectEqualStrings("application", dependency.source_label);
    try std.testing.expectEqualStrings("domain", dependency.target_label);
    try std.testing.expectEqual(@as(usize, 2), dependency.evidence().len);
    try std.testing.expectEqualStrings("src/api/handler.zig", dependency.evidence()[0].source);
    try std.testing.expectEqualStrings("src/service.zig", dependency.evidence()[1].source);
}

test "projected pairs and evidence are sorted deterministically" {
    var graph = try makeGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var projected = try projectEdges(
        std.testing.allocator,
        &graph,
        MapFunction.init(null, identity),
    );
    defer projected.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("src/api/handler.zig", projected.items()[0].source_label);
    try std.testing.expectEqualStrings("src/domain/model.zig", projected.items()[0].target_label);
    try std.testing.expectEqualStrings("std", projected.items()[1].target_label);
    try std.testing.expectEqualStrings("src/service.zig", projected.items()[2].source_label);
}

test "empty graphs and invalid mapped labels have explicit results" {
    var empty: Graph = .{};
    defer empty.deinit(std.testing.allocator);
    var projected = try projectEdges(
        std.testing.allocator,
        &empty,
        MapFunction.init(null, identity),
    );
    defer projected.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), projected.len());

    var graph = try makeGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidProjectionLabel,
        projectEdges(std.testing.allocator, &graph, MapFunction.init(null, invalidMapper)),
    );
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var graph = try makeGraph(allocator);
    defer graph.deinit(allocator);
    var projected = try projectEdges(allocator, &graph, MapFunction.init(null, aggregateInternal));
    defer projected.deinit(allocator);
}

test "edge projection cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
