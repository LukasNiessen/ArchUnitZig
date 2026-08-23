const std = @import("std");

const extraction = @import("../../common/extraction.zig");
const mapped_edge = @import("../../common/projection/mapped_edge.zig");
const project_cycles = @import("../../common/projection/project_cycles.zig");
const project_edges = @import("../../common/projection/project_edges.zig");

const Allocator = std.mem.Allocator;
pub const CycleProjectionError = project_cycles.CycleProjectionError;
pub const Graph = extraction.Graph;
pub const ProjectedCycles = project_cycles.ProjectedCycles;

const SelectedEdgeMapper = struct {
    selected_paths: []const []const u8,

    fn map(self: *const SelectedEdgeMapper, edge: *const extraction.Edge) ?mapped_edge.MappedEdge {
        if (edge.external or std.mem.eql(u8, edge.source, edge.target)) return null;
        if (!contains(self.selected_paths, edge.source) or !contains(self.selected_paths, edge.target)) return null;
        return .{ .source_label = edge.source, .target_label = edge.target };
    }
};

/// Finds cycles in the induced internal graph of a sorted file selection. Edges through files
/// outside the selection are dropped, never contracted into synthetic selected-to-selected edges.
pub fn projectSelectedFileCycles(
    allocator: Allocator,
    graph: *const Graph,
    selected_paths: []const []const u8,
) CycleProjectionError!ProjectedCycles {
    const context = SelectedEdgeMapper{ .selected_paths = selected_paths };
    var edges = try project_edges.projectEdges(
        allocator,
        graph,
        mapped_edge.MapFunction.fromContext(SelectedEdgeMapper, &context, SelectedEdgeMapper.map),
    );
    defer edges.deinit(allocator);
    return project_cycles.projectCycles(allocator, edges.items());
}

fn contains(sorted_paths: []const []const u8, wanted: []const u8) bool {
    var low: usize = 0;
    var high = sorted_paths.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, sorted_paths[middle], wanted)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return true,
        }
    }
    return false;
}

fn addEdge(
    graph: *Graph,
    source: []const u8,
    target: []const u8,
    external: bool,
) !void {
    try graph.add(
        std.testing.allocator,
        source,
        target,
        external,
        extraction.ImportKinds.initOne(if (external) .named_module else .zig_file),
    );
}

test "selected file cycles use induced graph semantics and ignore self and external edges" {
    var graph: Graph = .{};
    defer graph.deinit(std.testing.allocator);
    try addEdge(&graph, "a.zig", "a.zig", false);
    try addEdge(&graph, "a.zig", "b.zig", false);
    try addEdge(&graph, "b.zig", "outside.zig", false);
    try addEdge(&graph, "outside.zig", "a.zig", false);
    try addEdge(&graph, "b.zig", "package", true);
    try addEdge(&graph, "package", "b.zig", true);
    graph.sort();

    var boundary = try projectSelectedFileCycles(
        std.testing.allocator,
        &graph,
        &.{ "a.zig", "b.zig" },
    );
    defer boundary.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), boundary.len());

    var complete = try projectSelectedFileCycles(
        std.testing.allocator,
        &graph,
        &.{ "a.zig", "b.zig", "outside.zig" },
    );
    defer complete.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), complete.len());
}

test "selected file cycles retain deterministic elementary cycle order" {
    var graph: Graph = .{};
    defer graph.deinit(std.testing.allocator);
    try addEdge(&graph, "b.zig", "a.zig", false);
    try addEdge(&graph, "a.zig", "c.zig", false);
    try addEdge(&graph, "c.zig", "a.zig", false);
    try addEdge(&graph, "a.zig", "b.zig", false);
    graph.sort();

    var cycles = try projectSelectedFileCycles(
        std.testing.allocator,
        &graph,
        &.{ "a.zig", "b.zig", "c.zig" },
    );
    defer cycles.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), cycles.len());
    try std.testing.expectEqualStrings("b.zig", cycles.items()[0].items()[0].target_label);
    try std.testing.expectEqualStrings("c.zig", cycles.items()[1].items()[0].target_label);
}
