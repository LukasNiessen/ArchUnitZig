const std = @import("std");

const collapse_module = @import("collapse.zig");
const extraction = @import("../../common/extraction.zig");
const node_selection = @import("node_selection.zig");
const query_options = @import("query_options.zig");
const report = @import("report.zig");

const Allocator = std.mem.Allocator;
const Collapser = collapse_module.Collapser;
pub const Graph = extraction.Graph;
pub const GraphQueryOptions = query_options.GraphQueryOptions;
pub const GraphReportEdge = report.GraphReportEdge;
pub const GraphReportNode = report.GraphReportNode;
pub const GraphReportSnapshot = report.GraphReportSnapshot;
pub const SnapshotError = node_selection.SelectionError || collapse_module.CollapseError || error{
    InvalidTitle,
};

/// Runs the renderer-independent filter, select, collapse, aggregate, sort, and count pipeline.
pub fn createSnapshot(
    allocator: Allocator,
    graph: *const Graph,
    options: GraphQueryOptions,
) SnapshotError!GraphReportSnapshot {
    if (options.title.len == 0) return error.InvalidTitle;

    var selection = try node_selection.selectNodes(allocator, graph, options);
    defer selection.deinit(allocator);
    var collapser = try Collapser.init(allocator, options.collapse);
    defer collapser.deinit();
    var collapsed = try CollapsedLabels.init(allocator, selection.labels, &collapser);
    defer collapsed.deinit(allocator);

    const nodes = try buildNodes(allocator, collapsed.values);
    errdefer deinitNodes(allocator, nodes);
    var counts: RawCounts = .{};
    const edges = try buildEdges(
        allocator,
        graph,
        &selection,
        &collapsed,
        options,
        &counts,
    );
    errdefer deinitEdges(allocator, edges);
    const title = try allocator.dupe(u8, options.title);

    return .{
        .title = title,
        .nodes = nodes,
        .edges = edges,
        .summary = .{
            .node_count = nodes.len,
            .edge_count = edges.len,
            .raw_edge_count = counts.total,
            .external_edge_count = counts.external,
        },
    };
}

const CollapsedLabels = struct {
    originals: []const []const u8,
    values: [][]u8,

    fn init(
        allocator: Allocator,
        originals: []const []const u8,
        collapser: *const Collapser,
    ) collapse_module.CollapseError!CollapsedLabels {
        const values = try allocator.alloc([]u8, originals.len);
        errdefer allocator.free(values);
        var initialized: usize = 0;
        errdefer for (values[0..initialized]) |value| allocator.free(value);
        for (originals) |label| {
            values[initialized] = try collapser.collapse(allocator, label);
            initialized += 1;
        }
        return .{ .originals = originals, .values = values };
    }

    fn deinit(self: *CollapsedLabels, allocator: Allocator) void {
        for (self.values) |value| allocator.free(value);
        allocator.free(self.values);
        self.* = undefined;
    }

    fn get(self: *const CollapsedLabels, original: []const u8) ?[]const u8 {
        var low: usize = 0;
        var high: usize = self.originals.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            switch (std.mem.order(u8, self.originals[middle], original)) {
                .lt => low = middle + 1,
                .gt => high = middle,
                .eq => return self.values[middle],
            }
        }
        return null;
    }
};

fn buildNodes(allocator: Allocator, collapsed: []const []u8) Allocator.Error![]GraphReportNode {
    var labels: std.ArrayList([]const u8) = .empty;
    defer labels.deinit(allocator);
    try labels.appendSlice(allocator, collapsed);
    std.mem.sort([]const u8, labels.items, {}, lessThanLabel);
    deduplicateLabels(&labels);

    var nodes: std.ArrayList(GraphReportNode) = .empty;
    errdefer {
        for (nodes.items) |*node| node.deinit(allocator);
        nodes.deinit(allocator);
    }
    try nodes.ensureTotalCapacity(allocator, labels.items.len);
    for (labels.items, 0..) |label, index| {
        const id = try std.fmt.allocPrint(allocator, "n{d}", .{index});
        defer allocator.free(id);
        nodes.appendAssumeCapacity(try GraphReportNode.init(allocator, id, label));
    }
    return nodes.toOwnedSlice(allocator);
}

fn deduplicateLabels(labels: *std.ArrayList([]const u8)) void {
    if (labels.items.len < 2) return;
    var output: usize = 1;
    for (labels.items[1..]) |label| {
        if (std.mem.eql(u8, labels.items[output - 1], label)) continue;
        labels.items[output] = label;
        output += 1;
    }
    labels.items.len = output;
}

fn lessThanLabel(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

const RawCounts = struct {
    total: usize = 0,
    external: usize = 0,
};

const AggregatedEdge = struct {
    source: []const u8,
    target: []const u8,
    count: usize,
    external: bool,
    import_kinds: extraction.ImportKinds,
    target_classes: extraction.TargetClasses,
    target_availabilities: extraction.TargetAvailabilities,
};

fn buildEdges(
    allocator: Allocator,
    graph: *const Graph,
    selection: *const node_selection.NodeSelection,
    collapsed: *const CollapsedLabels,
    options: GraphQueryOptions,
    counts: *RawCounts,
) Allocator.Error![]GraphReportEdge {
    var groups: std.ArrayList(AggregatedEdge) = .empty;
    defer groups.deinit(allocator);
    for (graph.items()) |edge| {
        if (edge.external and !options.include_external_dependencies) continue;
        if (!options.include_self_dependencies and std.mem.eql(u8, edge.source, edge.target)) continue;
        if (!selection.contains(edge.source) or !selection.contains(edge.target)) continue;
        counts.total += 1;
        counts.external += @intFromBool(edge.external);

        const source = collapsed.get(edge.source).?;
        const target = collapsed.get(edge.target).?;
        if (!options.include_self_dependencies and std.mem.eql(u8, source, target)) continue;
        if (findGroup(groups.items, source, target)) |group| {
            group.count += 1;
            group.external = group.external or edge.external;
            group.import_kinds.setUnion(edge.import_kinds);
            group.target_classes.setUnion(edge.target_classes);
            group.target_availabilities.setUnion(edge.target_availabilities);
            continue;
        }
        try groups.append(allocator, .{
            .source = source,
            .target = target,
            .count = 1,
            .external = edge.external,
            .import_kinds = edge.import_kinds,
            .target_classes = edge.target_classes,
            .target_availabilities = edge.target_availabilities,
        });
    }
    std.mem.sort(AggregatedEdge, groups.items, {}, lessThanAggregatedEdge);

    var edges: std.ArrayList(GraphReportEdge) = .empty;
    errdefer {
        for (edges.items) |*edge| edge.deinit(allocator);
        edges.deinit(allocator);
    }
    try edges.ensureTotalCapacity(allocator, groups.items.len);
    for (groups.items) |group| {
        edges.appendAssumeCapacity(try GraphReportEdge.init(
            allocator,
            group.source,
            group.target,
            group.count,
            group.external,
            group.import_kinds,
            group.target_classes,
            group.target_availabilities,
        ));
    }
    return edges.toOwnedSlice(allocator);
}

fn findGroup(groups: []AggregatedEdge, source: []const u8, target: []const u8) ?*AggregatedEdge {
    for (groups) |*group| {
        if (std.mem.eql(u8, group.source, source) and std.mem.eql(u8, group.target, target)) {
            return group;
        }
    }
    return null;
}

fn lessThanAggregatedEdge(_: void, left: AggregatedEdge, right: AggregatedEdge) bool {
    const source_order = std.mem.order(u8, left.source, right.source);
    if (source_order != .eq) return source_order == .lt;
    return std.mem.order(u8, left.target, right.target) == .lt;
}

fn deinitNodes(allocator: Allocator, nodes: []GraphReportNode) void {
    for (nodes) |*node| node.deinit(allocator);
    allocator.free(nodes);
}

fn deinitEdges(allocator: Allocator, edges: []GraphReportEdge) void {
    for (edges) |*edge| edge.deinit(allocator);
    allocator.free(edges);
}

fn makeGraph(allocator: Allocator) !Graph {
    var graph: Graph = .{};
    errdefer graph.deinit(allocator);
    const labels = [_][]const u8{
        "src\\app\\a.zig",
        "src/app/b.zig",
        "src/domain/service.zig",
        "src/orphan/alone.zig",
    };
    for (&labels) |label| try graph.add(allocator, label, label, false, extraction.ImportKinds.initEmpty());
    try graph.add(
        allocator,
        "src/app/a.zig",
        "src/app/b.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
    );
    try graph.add(
        allocator,
        "src/app/a.zig",
        "src/domain/service.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
    );
    try graph.add(
        allocator,
        "src/app/b.zig",
        "src/domain/service.zig",
        false,
        extraction.ImportKinds.initOne(.root_module),
    );
    try graph.addClassifiedLocated(
        allocator,
        "src/app/a.zig",
        "deps/std/a",
        true,
        extraction.ImportKinds.initOne(.standard_library),
        .compiler,
        .resolved,
        &.{},
    );
    try graph.addClassifiedLocated(
        allocator,
        "src/app/b.zig",
        "deps/std/b",
        true,
        extraction.ImportKinds.initOne(.embedded_file),
        .resource,
        .unresolved,
        &.{},
    );
    return graph;
}

fn findEdge(snapshot: *const GraphReportSnapshot, source: []const u8, target: []const u8) ?*const GraphReportEdge {
    for (snapshot.edges) |*edge| {
        if (std.mem.eql(u8, edge.source, source) and std.mem.eql(u8, edge.target, target)) return edge;
    }
    return null;
}

test "snapshot defaults exclude external and self edges while retaining isolated nodes" {
    var graph = try makeGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var snapshot = try createSnapshot(std.testing.allocator, &graph, .{});
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Project dependency graph", snapshot.title);
    try std.testing.expectEqual(report.GraphReportSummary{
        .node_count = 4,
        .edge_count = 3,
        .raw_edge_count = 3,
        .external_edge_count = 0,
    }, snapshot.summary);
    try std.testing.expectEqualStrings("n0", snapshot.nodes[0].id);
    try std.testing.expectEqualStrings("src/app/a.zig", snapshot.nodes[0].label);
    try std.testing.expectEqualStrings("src/orphan/alone.zig", snapshot.nodes[3].label);
    try std.testing.expect(findEdge(&snapshot, "src/app/a.zig", "src/app/b.zig") != null);
}

test "folder collapse aggregates edges and keeps pre-collapse summary counts" {
    var graph = try makeGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var snapshot = try createSnapshot(std.testing.allocator, &graph, .{
        .collapse = .{ .folder_depth = 2 },
        .title = "Application Architecture",
    });
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Application Architecture", snapshot.title);
    try std.testing.expectEqual(@as(usize, 3), snapshot.summary.node_count);
    try std.testing.expectEqual(@as(usize, 1), snapshot.summary.edge_count);
    try std.testing.expectEqual(@as(usize, 3), snapshot.summary.raw_edge_count);
    const dependency = findEdge(&snapshot, "src/app", "src/domain").?;
    try std.testing.expectEqual(@as(usize, 2), dependency.count);
    try std.testing.expect(dependency.import_kinds.contains(.zig_file));
    try std.testing.expect(dependency.import_kinds.contains(.root_module));
    try std.testing.expect(findEdge(&snapshot, "src/app", "src/app") == null);
}

test "external aggregation retains compiler resource availability and import classifications" {
    var graph = try makeGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var snapshot = try createSnapshot(std.testing.allocator, &graph, .{
        .include_external_dependencies = true,
        .collapse = .{ .folder_depth = 2 },
    });
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), snapshot.summary.node_count);
    try std.testing.expectEqual(@as(usize, 2), snapshot.summary.edge_count);
    try std.testing.expectEqual(@as(usize, 5), snapshot.summary.raw_edge_count);
    try std.testing.expectEqual(@as(usize, 2), snapshot.summary.external_edge_count);
    const dependency = findEdge(&snapshot, "src/app", "deps/std").?;
    try std.testing.expectEqual(@as(usize, 2), dependency.count);
    try std.testing.expect(dependency.external);
    try std.testing.expect(dependency.import_kinds.contains(.standard_library));
    try std.testing.expect(dependency.import_kinds.contains(.embedded_file));
    try std.testing.expect(dependency.target_classes.contains(.compiler));
    try std.testing.expect(dependency.target_classes.contains(.resource));
    try std.testing.expect(dependency.target_availabilities.contains(.resolved));
    try std.testing.expect(dependency.target_availabilities.contains(.unresolved));
}

test "self dependencies are independently selectable" {
    var graph = try makeGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var snapshot = try createSnapshot(std.testing.allocator, &graph, .{
        .include_self_dependencies = true,
    });
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 7), snapshot.summary.raw_edge_count);
    try std.testing.expectEqual(@as(usize, 7), snapshot.summary.edge_count);
    try std.testing.expect(findEdge(&snapshot, "src/orphan/alone.zig", "src/orphan/alone.zig") != null);
}

test "pattern collapse composes with selection and removes newly created self edges" {
    var graph = try makeGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var snapshot = try createSnapshot(std.testing.allocator, &graph, .{
        .include_external_dependencies = true,
        .focus = .{ .pattern = .{ .glob = "src/app/a.zig" }, .depth = 1 },
        .collapse = .{ .pattern = .{
            .expression = "^(?:src|deps)/([^/]+)/.*$",
            .replacement = "$1",
        } },
    });
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("app", snapshot.nodes[0].label);
    try std.testing.expect(findEdge(&snapshot, "app", "app") == null);
    try std.testing.expect(findEdge(&snapshot, "app", "domain") != null);
    try std.testing.expect(findEdge(&snapshot, "app", "std") != null);
}

test "empty graphs are deterministic owned snapshots and empty titles are rejected" {
    var graph: Graph = .{};
    defer graph.deinit(std.testing.allocator);
    var first = try createSnapshot(std.testing.allocator, &graph, .{});
    defer first.deinit(std.testing.allocator);
    var second = try createSnapshot(std.testing.allocator, &graph, .{});
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(first.eql(second));
    try std.testing.expectEqual(@as(usize, 0), first.nodes.len);
    try std.testing.expectEqual(@as(usize, 0), first.edges.len);
    try std.testing.expectError(
        error.InvalidTitle,
        createSnapshot(std.testing.allocator, &graph, .{ .title = "" }),
    );
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var graph = try makeGraph(allocator);
    defer graph.deinit(allocator);
    var snapshot = try createSnapshot(allocator, &graph, .{
        .include_external_dependencies = true,
        .focus = .{ .pattern = .{ .regex = "src/app" }, .depth = 2 },
        .reachable_from = .{ .glob = "src/app/a.zig" },
        .collapse = .{ .pattern = .{
            .expression = "^(?:src|deps)/([^/]+)/.*$",
            .replacement = "$1",
        } },
        .title = "Allocation-safe graph",
    });
    defer snapshot.deinit(allocator);
}

test "the complete snapshot pipeline cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
