const std = @import("std");

const extraction = @import("../extraction.zig");
const adjacency_module = @import("cycles/adjacency.zig");
const edge_projections = @import("edge_projections.zig");
const johnson = @import("cycles/johnson.zig");
const mapped_edge = @import("mapped_edge.zig");
const project_edges = @import("project_edges.zig");
const projected_cycle = @import("projected_cycle.zig");
const projected_edge = @import("projected_edge.zig");

const Allocator = std.mem.Allocator;
pub const CycleProjectionError = projected_cycle.CycleProjectionError;
pub const Graph = extraction.Graph;
pub const ProjectedCycle = projected_cycle.ProjectedCycle;
pub const ProjectedCycles = projected_cycle.ProjectedCycles;
pub const ProjectedEdge = projected_edge.ProjectedEdge;
pub const ProjectedEdges = projected_edge.ProjectedEdges;

/// Finds all elementary directed cycles after normalizing projected edge pairs and evidence.
pub fn projectCycles(
    allocator: Allocator,
    source_edges: []const ProjectedEdge,
) CycleProjectionError!ProjectedCycles {
    var normalized = try normalizeProjectedEdges(allocator, source_edges);
    defer normalized.deinit(allocator);
    if (normalized.len() == 0) return .{};

    var labels = try collectLabels(allocator, normalized.items());
    defer labels.deinit(allocator);
    var adjacency = try buildAdjacency(allocator, normalized.items(), labels.items);
    defer adjacency.deinit(allocator);
    var vertex_cycles = try johnson.elementaryCycles(allocator, &adjacency);
    defer vertex_cycles.deinit(allocator);

    var result: ProjectedCycles = .{};
    errdefer result.deinit(allocator);
    var edge_pointers: std.ArrayList(*const ProjectedEdge) = .empty;
    defer edge_pointers.deinit(allocator);
    for (vertex_cycles.items()) |vertex_cycle| {
        edge_pointers.clearRetainingCapacity();
        try edge_pointers.ensureTotalCapacity(allocator, vertex_cycle.len);
        for (vertex_cycle, 0..) |source_id, index| {
            const target_id = vertex_cycle[(index + 1) % vertex_cycle.len];
            const edge = normalized.find(labels.items[source_id], labels.items[target_id]) orelse
                return error.MissingProjectedEdge;
            edge_pointers.appendAssumeCapacity(edge);
        }
        var cycle = try ProjectedCycle.initClonePointers(allocator, edge_pointers.items);
        result.appendMove(allocator, &cycle) catch |failure| {
            cycle.deinit(allocator);
            return failure;
        };
    }
    return result;
}

/// Convenience entry point for file cycles over non-external, non-self raw graph edges.
pub fn projectInternalCycles(
    allocator: Allocator,
    graph: *const Graph,
) CycleProjectionError!ProjectedCycles {
    var edges = try project_edges.projectEdges(allocator, graph, edge_projections.perInternalEdge());
    defer edges.deinit(allocator);
    return projectCycles(allocator, edges.items());
}

fn normalizeProjectedEdges(
    allocator: Allocator,
    source_edges: []const ProjectedEdge,
) CycleProjectionError!ProjectedEdges {
    var result: ProjectedEdges = .{};
    errdefer result.deinit(allocator);
    for (source_edges) |source_edge| {
        const mapped = mapped_edge.MappedEdge{
            .source_label = source_edge.source_label,
            .target_label = source_edge.target_label,
        };
        try mapped.validate();
        if (std.mem.eql(u8, mapped.source_label, mapped.target_label)) continue;
        const evidence = source_edge.evidence();
        if (evidence.len == 0) return error.EmptyProjectedEvidence;

        if (result.findMutable(mapped.source_label, mapped.target_label)) |existing| {
            for (evidence) |raw_edge| try existing.appendEvidenceUnique(allocator, raw_edge);
            continue;
        }

        var projected = try ProjectedEdge.init(allocator, mapped, evidence[0]);
        for (evidence[1..]) |raw_edge| {
            projected.appendEvidenceUnique(allocator, raw_edge) catch |failure| {
                projected.deinit(allocator);
                return failure;
            };
        }
        result.appendMove(allocator, &projected) catch |failure| {
            projected.deinit(allocator);
            return failure;
        };
    }
    result.sort();
    return result;
}

fn collectLabels(
    allocator: Allocator,
    edges: []const ProjectedEdge,
) Allocator.Error!std.ArrayList([]const u8) {
    var labels: std.ArrayList([]const u8) = .empty;
    errdefer labels.deinit(allocator);
    try labels.ensureTotalCapacity(allocator, edges.len * 2);
    for (edges) |edge| {
        labels.appendAssumeCapacity(edge.source_label);
        labels.appendAssumeCapacity(edge.target_label);
    }
    std.mem.sort([]const u8, labels.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);
    if (labels.items.len > 1) {
        var output: usize = 1;
        for (labels.items[1..]) |label| {
            if (std.mem.eql(u8, labels.items[output - 1], label)) continue;
            labels.items[output] = label;
            output += 1;
        }
        labels.items.len = output;
    }
    return labels;
}

fn buildAdjacency(
    allocator: Allocator,
    edges: []const ProjectedEdge,
    labels: []const []const u8,
) CycleProjectionError!adjacency_module.Adjacency {
    var adjacency = try adjacency_module.Adjacency.init(allocator, labels.len);
    errdefer adjacency.deinit(allocator);
    for (edges) |edge| {
        const source = labelId(labels, edge.source_label) orelse return error.MissingProjectedEdge;
        const target = labelId(labels, edge.target_label) orelse return error.MissingProjectedEdge;
        try adjacency.add(allocator, source, target);
    }
    adjacency.normalize();
    return adjacency;
}

fn labelId(labels: []const []const u8, wanted: []const u8) ?usize {
    var low: usize = 0;
    var high: usize = labels.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, labels[middle], wanted)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return middle,
        }
    }
    return null;
}

fn makeProjectedEdge(
    allocator: Allocator,
    source_label: []const u8,
    target_label: []const u8,
    raw_source: []const u8,
    raw_target: []const u8,
    external: bool,
) !ProjectedEdge {
    var raw = try extraction.Edge.init(
        allocator,
        raw_source,
        raw_target,
        external,
        extraction.ImportKinds.initOne(if (external) .named_module else .zig_file),
    );
    defer raw.deinit(allocator);
    return ProjectedEdge.init(
        allocator,
        .{ .source_label = source_label, .target_label = target_label },
        raw,
    );
}

fn appendProjected(
    allocator: Allocator,
    edges: *ProjectedEdges,
    edge: ProjectedEdge,
) !void {
    var owned = edge;
    edges.appendMove(allocator, &owned) catch |failure| {
        owned.deinit(allocator);
        return failure;
    };
}

test "cycle projection filters self edges and returns empty DAG results" {
    var edges: ProjectedEdges = .{};
    defer edges.deinit(std.testing.allocator);
    try appendProjected(std.testing.allocator, &edges, try makeProjectedEdge(
        std.testing.allocator,
        "a",
        "a",
        "src/a.zig",
        "src/a.zig",
        false,
    ));
    try appendProjected(std.testing.allocator, &edges, try makeProjectedEdge(
        std.testing.allocator,
        "a",
        "b",
        "src/a.zig",
        "src/b.zig",
        false,
    ));
    var cycles = try projectCycles(std.testing.allocator, edges.items());
    defer cycles.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), cycles.len());
}

test "cycle projection returns ordered edges with evidence after source destruction" {
    var cycles: ProjectedCycles = undefined;
    {
        var edges: ProjectedEdges = .{};
        defer edges.deinit(std.testing.allocator);
        try appendProjected(std.testing.allocator, &edges, try makeProjectedEdge(
            std.testing.allocator,
            "a",
            "b",
            "src/a.zig",
            "src/b.zig",
            false,
        ));
        try appendProjected(std.testing.allocator, &edges, try makeProjectedEdge(
            std.testing.allocator,
            "b",
            "c",
            "src/b.zig",
            "src/c.zig",
            false,
        ));
        try appendProjected(std.testing.allocator, &edges, try makeProjectedEdge(
            std.testing.allocator,
            "c",
            "a",
            "src/c.zig",
            "src/a.zig",
            false,
        ));
        cycles = try projectCycles(std.testing.allocator, edges.items());
    }
    defer cycles.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), cycles.len());
    const cycle = cycles.items()[0].items();
    try std.testing.expectEqualStrings("a", cycle[0].source_label);
    try std.testing.expectEqualStrings("b", cycle[1].source_label);
    try std.testing.expectEqualStrings("c", cycle[2].source_label);
    try std.testing.expectEqualStrings("src/a.zig", cycle[0].evidence()[0].source);
}

test "duplicate projected pairs aggregate distinct raw evidence once" {
    var edges: ProjectedEdges = .{};
    defer edges.deinit(std.testing.allocator);
    try appendProjected(std.testing.allocator, &edges, try makeProjectedEdge(
        std.testing.allocator,
        "a",
        "b",
        "src/first.zig",
        "src/b.zig",
        false,
    ));
    try appendProjected(std.testing.allocator, &edges, try makeProjectedEdge(
        std.testing.allocator,
        "a",
        "b",
        "src/second.zig",
        "src/b.zig",
        false,
    ));
    try appendProjected(std.testing.allocator, &edges, try makeProjectedEdge(
        std.testing.allocator,
        "a",
        "b",
        "src/first.zig",
        "src/b.zig",
        false,
    ));
    try appendProjected(std.testing.allocator, &edges, try makeProjectedEdge(
        std.testing.allocator,
        "b",
        "a",
        "src/b.zig",
        "src/first.zig",
        false,
    ));

    var cycles = try projectCycles(std.testing.allocator, edges.items());
    defer cycles.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), cycles.len());
    const forward = cycles.items()[0].items()[0];
    try std.testing.expectEqual(@as(usize, 2), forward.evidence().len);
    try std.testing.expectEqualStrings("src/first.zig", forward.evidence()[0].source);
    try std.testing.expectEqualStrings("src/second.zig", forward.evidence()[1].source);
}

test "overlapping and disconnected cycles are canonical and input-order independent" {
    const fixture = [_][2][]const u8{
        .{ "c", "b" }, .{ "e", "d" }, .{ "a", "c" }, .{ "b", "a" },
        .{ "d", "e" }, .{ "c", "a" }, .{ "a", "b" }, .{ "b", "c" },
    };
    var forward: ProjectedEdges = .{};
    defer forward.deinit(std.testing.allocator);
    var reversed: ProjectedEdges = .{};
    defer reversed.deinit(std.testing.allocator);
    for (fixture) |pair| try appendLabelEdge(std.testing.allocator, &forward, pair);
    var index = fixture.len;
    while (index > 0) {
        index -= 1;
        try appendLabelEdge(std.testing.allocator, &reversed, fixture[index]);
    }

    var forward_cycles = try projectCycles(std.testing.allocator, forward.items());
    defer forward_cycles.deinit(std.testing.allocator);
    var reversed_cycles = try projectCycles(std.testing.allocator, reversed.items());
    defer reversed_cycles.deinit(std.testing.allocator);

    const expected = [_][]const []const u8{
        &.{ "a", "b" },
        &.{ "a", "b", "c" },
        &.{ "a", "c" },
        &.{ "a", "c", "b" },
        &.{ "b", "c" },
        &.{ "d", "e" },
    };
    try std.testing.expectEqual(expected.len, forward_cycles.len());
    try std.testing.expectEqual(forward_cycles.len(), reversed_cycles.len());
    for (expected, forward_cycles.items(), reversed_cycles.items()) |wanted, actual, reordered| {
        try expectCycleSources(wanted, actual.items());
        try expectCycleSources(wanted, reordered.items());
    }
}

test "cycle projection rejects projected dependencies without evidence" {
    const malformed = ProjectedEdge{
        .source_label = "a",
        .target_label = "b",
    };
    try std.testing.expectError(
        error.EmptyProjectedEvidence,
        projectCycles(std.testing.allocator, &.{malformed}),
    );
}

test "internal cycle projection excludes external graph dependencies" {
    var graph: Graph = .{};
    defer graph.deinit(std.testing.allocator);
    try graph.add(
        std.testing.allocator,
        "src/a.zig",
        "src/b.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
    );
    try graph.add(
        std.testing.allocator,
        "src/b.zig",
        "src/a.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
    );
    try graph.add(
        std.testing.allocator,
        "src/a.zig",
        "std",
        true,
        extraction.ImportKinds.initOne(.standard_library),
    );
    var cycles = try projectInternalCycles(std.testing.allocator, &graph);
    defer cycles.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), cycles.len());
    for (cycles.items()[0].items()) |edge| for (edge.evidence()) |raw| {
        try std.testing.expect(!raw.external);
    };
}

fn appendLabelEdge(
    allocator: Allocator,
    edges: *ProjectedEdges,
    pair: [2][]const u8,
) !void {
    try appendProjected(allocator, edges, try makeProjectedEdge(
        allocator,
        pair[0],
        pair[1],
        pair[0],
        pair[1],
        false,
    ));
}

fn expectCycleSources(wanted: []const []const u8, actual: []const ProjectedEdge) !void {
    try std.testing.expectEqual(wanted.len, actual.len);
    for (wanted, actual) |label, edge| {
        try std.testing.expectEqualStrings(label, edge.source_label);
    }
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var edges: ProjectedEdges = .{};
    defer edges.deinit(allocator);
    try appendProjected(allocator, &edges, try makeProjectedEdge(
        allocator,
        "a",
        "b",
        "src/a.zig",
        "src/b.zig",
        false,
    ));
    try appendProjected(allocator, &edges, try makeProjectedEdge(
        allocator,
        "b",
        "a",
        "src/b.zig",
        "src/a.zig",
        false,
    ));
    var cycles = try projectCycles(allocator, edges.items());
    defer cycles.deinit(allocator);
}

test "cycle projection cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
