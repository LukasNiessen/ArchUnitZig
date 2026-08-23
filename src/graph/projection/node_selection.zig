const std = @import("std");

const adjacency_module = @import("../../common/projection/cycles/adjacency.zig");
const extraction = @import("../../common/extraction.zig");
const query_options = @import("query_options.zig");
const regex_module = @import("../../common/matching/regex.zig");

const Adjacency = adjacency_module.Adjacency;
const Allocator = std.mem.Allocator;
pub const Graph = extraction.Graph;
pub const GraphQueryOptions = query_options.GraphQueryOptions;
pub const SelectionError = Allocator.Error ||
    @import("../../common/matching/pattern.zig").CompileError ||
    regex_module.Regex.MatchError;

/// Sorted node labels borrowed from the source graph; only the outer slice is owned.
pub const NodeSelection = struct {
    labels: [][]const u8,

    pub fn deinit(self: *NodeSelection, allocator: Allocator) void {
        allocator.free(self.labels);
        self.* = undefined;
    }

    pub fn contains(self: *const NodeSelection, label: []const u8) bool {
        return indexOf(self.labels, label) != null;
    }
};

pub fn selectNodes(
    allocator: Allocator,
    graph: *const Graph,
    options: GraphQueryOptions,
) SelectionError!NodeSelection {
    const universe = try collectUniverse(allocator, graph, options.include_external_dependencies);
    errdefer allocator.free(universe);
    const has_query = options.focus != null or
        options.reachable_from != null or
        options.dependents_of != null;
    if (!has_query) return .{ .labels = universe };

    var relationships = try Relationships.init(allocator, universe.len);
    defer relationships.deinit(allocator);
    try relationships.populate(
        allocator,
        graph,
        universe,
        options.include_external_dependencies,
    );

    const selected = try allocator.alloc(bool, universe.len);
    defer allocator.free(selected);
    @memset(selected, false);
    if (options.focus) |focus| {
        try selectDepthLimited(
            allocator,
            universe,
            focus.pattern,
            focus.depth,
            &relationships.connected,
            selected,
        );
    }
    if (options.reachable_from) |pattern| {
        try selectClosure(allocator, universe, pattern, &relationships.outgoing, selected);
    }
    if (options.dependents_of) |pattern| {
        try selectClosure(allocator, universe, pattern, &relationships.incoming, selected);
    }

    var labels: std.ArrayList([]const u8) = .empty;
    errdefer labels.deinit(allocator);
    for (universe, selected) |label, is_selected| {
        if (is_selected) try labels.append(allocator, label);
    }
    const owned_labels = try labels.toOwnedSlice(allocator);
    allocator.free(universe);
    return .{ .labels = owned_labels };
}

const Relationships = struct {
    outgoing: Adjacency,
    incoming: Adjacency,
    connected: Adjacency,

    fn init(allocator: Allocator, node_count: usize) Allocator.Error!Relationships {
        var outgoing = try Adjacency.init(allocator, node_count);
        errdefer outgoing.deinit(allocator);
        var incoming = try Adjacency.init(allocator, node_count);
        errdefer incoming.deinit(allocator);
        return .{
            .outgoing = outgoing,
            .incoming = incoming,
            .connected = try Adjacency.init(allocator, node_count),
        };
    }

    fn deinit(self: *Relationships, allocator: Allocator) void {
        self.outgoing.deinit(allocator);
        self.incoming.deinit(allocator);
        self.connected.deinit(allocator);
        self.* = undefined;
    }

    fn populate(
        self: *Relationships,
        allocator: Allocator,
        graph: *const Graph,
        universe: []const []const u8,
        include_external: bool,
    ) Allocator.Error!void {
        for (graph.items()) |edge| {
            if (edge.external and !include_external) continue;
            if (std.mem.eql(u8, edge.source, edge.target)) continue;
            const source = indexOf(universe, edge.source) orelse continue;
            const target = indexOf(universe, edge.target) orelse continue;
            try self.outgoing.add(allocator, source, target);
            try self.incoming.add(allocator, target, source);
            try self.connected.add(allocator, source, target);
            try self.connected.add(allocator, target, source);
        }
        self.outgoing.normalize();
        self.incoming.normalize();
        self.connected.normalize();
    }
};

fn collectUniverse(
    allocator: Allocator,
    graph: *const Graph,
    include_external: bool,
) Allocator.Error![][]const u8 {
    var labels: std.ArrayList([]const u8) = .empty;
    errdefer labels.deinit(allocator);
    for (graph.items()) |edge| {
        try labels.append(allocator, edge.source);
        if (!edge.external or include_external) try labels.append(allocator, edge.target);
    }
    std.mem.sort([]const u8, labels.items, {}, lessThanLabel);
    if (labels.items.len > 1) {
        var output: usize = 1;
        for (labels.items[1..]) |label| {
            if (std.mem.eql(u8, labels.items[output - 1], label)) continue;
            labels.items[output] = label;
            output += 1;
        }
        labels.items.len = output;
    }
    return labels.toOwnedSlice(allocator);
}

fn selectDepthLimited(
    allocator: Allocator,
    labels: []const []const u8,
    pattern: query_options.Pattern,
    maximum_depth: usize,
    adjacency: *const Adjacency,
    selected: []bool,
) SelectionError!void {
    const DepthNode = struct { index: usize, depth: usize };
    var matcher = try pattern.compile(allocator);
    defer matcher.deinit();
    var queue: std.ArrayList(DepthNode) = .empty;
    defer queue.deinit(allocator);
    const visited = try allocator.alloc(bool, labels.len);
    defer allocator.free(visited);
    @memset(visited, false);

    for (labels, 0..) |label, index| {
        if (!try matcher.isMatch(allocator, label)) continue;
        visited[index] = true;
        selected[index] = true;
        try queue.append(allocator, .{ .index = index, .depth = 0 });
    }
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const current = queue.items[head];
        if (current.depth == maximum_depth) continue;
        for (adjacency.neighbours(current.index)) |neighbour| {
            if (visited[neighbour]) continue;
            visited[neighbour] = true;
            selected[neighbour] = true;
            try queue.append(allocator, .{ .index = neighbour, .depth = current.depth + 1 });
        }
    }
}

fn selectClosure(
    allocator: Allocator,
    labels: []const []const u8,
    pattern: query_options.Pattern,
    adjacency: *const Adjacency,
    selected: []bool,
) SelectionError!void {
    var matcher = try pattern.compile(allocator);
    defer matcher.deinit();
    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(allocator);
    const visited = try allocator.alloc(bool, labels.len);
    defer allocator.free(visited);
    @memset(visited, false);

    for (labels, 0..) |label, index| {
        if (!try matcher.isMatch(allocator, label)) continue;
        visited[index] = true;
        selected[index] = true;
        try queue.append(allocator, index);
    }
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        for (adjacency.neighbours(queue.items[head])) |neighbour| {
            if (visited[neighbour]) continue;
            visited[neighbour] = true;
            selected[neighbour] = true;
            try queue.append(allocator, neighbour);
        }
    }
}

fn indexOf(labels: []const []const u8, sought: []const u8) ?usize {
    var low: usize = 0;
    var high: usize = labels.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, labels[middle], sought)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return middle,
        }
    }
    return null;
}

fn lessThanLabel(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn makeGraph(allocator: Allocator) !Graph {
    var graph: Graph = .{};
    errdefer graph.deinit(allocator);
    const labels = [_][]const u8{
        "src/a.zig",
        "src/b.zig",
        "src/c.zig",
        "src/d.zig",
        "other/x.zig",
        "other/y.zig",
        "isolated.zig",
    };
    for (&labels) |label| try graph.add(allocator, label, label, false, extraction.ImportKinds.initEmpty());
    try graph.add(allocator, "src/a.zig", "src/b.zig", false, extraction.ImportKinds.initOne(.zig_file));
    try graph.add(allocator, "src/b.zig", "src/c.zig", false, extraction.ImportKinds.initOne(.zig_file));
    try graph.add(allocator, "src/c.zig", "src/a.zig", false, extraction.ImportKinds.initOne(.zig_file));
    try graph.add(allocator, "src/d.zig", "src/c.zig", false, extraction.ImportKinds.initOne(.zig_file));
    try graph.add(allocator, "other/x.zig", "other/y.zig", false, extraction.ImportKinds.initOne(.zig_file));
    try graph.add(allocator, "src/a.zig", "std", true, extraction.ImportKinds.initOne(.standard_library));
    return graph;
}

fn expectLabels(selection: NodeSelection, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, selection.labels.len);
    for (expected, selection.labels) |expected_label, actual| {
        try std.testing.expectEqualStrings(expected_label, actual);
    }
}

test "no query selects every internal node including disconnected and isolated nodes" {
    var graph = try makeGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var selection = try selectNodes(std.testing.allocator, &graph, .{});
    defer selection.deinit(std.testing.allocator);
    try expectLabels(selection, &.{
        "isolated.zig",
        "other/x.zig",
        "other/y.zig",
        "src/a.zig",
        "src/b.zig",
        "src/c.zig",
        "src/d.zig",
    });
}

test "focus performs depth-limited undirected traversal through a cycle" {
    var graph = try makeGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var seeds = try selectNodes(std.testing.allocator, &graph, .{
        .focus = .{ .pattern = .{ .glob = "src/b.zig" }, .depth = 0 },
    });
    defer seeds.deinit(std.testing.allocator);
    try expectLabels(seeds, &.{"src/b.zig"});
    var neighbours = try selectNodes(std.testing.allocator, &graph, .{
        .focus = .{ .pattern = .{ .glob = "src/b.zig" }, .depth = 1 },
    });
    defer neighbours.deinit(std.testing.allocator);
    try expectLabels(neighbours, &.{ "src/a.zig", "src/b.zig", "src/c.zig" });
}

test "reachable and dependent queries follow their respective directions" {
    var graph = try makeGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var reachable = try selectNodes(std.testing.allocator, &graph, .{
        .reachable_from = .{ .glob = "src/d.zig" },
    });
    defer reachable.deinit(std.testing.allocator);
    try expectLabels(reachable, &.{ "src/a.zig", "src/b.zig", "src/c.zig", "src/d.zig" });
    var dependents = try selectNodes(std.testing.allocator, &graph, .{
        .dependents_of = .{ .glob = "src/d.zig" },
    });
    defer dependents.deinit(std.testing.allocator);
    try expectLabels(dependents, &.{"src/d.zig"});
}

test "query modifiers union selections and external traversal is opt in" {
    var graph = try makeGraph(std.testing.allocator);
    defer graph.deinit(std.testing.allocator);
    var combined = try selectNodes(std.testing.allocator, &graph, .{
        .focus = .{ .pattern = .{ .glob = "isolated.zig" }, .depth = 0 },
        .reachable_from = .{ .glob = "other/x.zig" },
    });
    defer combined.deinit(std.testing.allocator);
    try expectLabels(combined, &.{ "isolated.zig", "other/x.zig", "other/y.zig" });

    var external = try selectNodes(std.testing.allocator, &graph, .{
        .include_external_dependencies = true,
        .reachable_from = .{ .glob = "src/a.zig" },
    });
    defer external.deinit(std.testing.allocator);
    try std.testing.expect(external.contains("std"));
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var graph = try makeGraph(allocator);
    defer graph.deinit(allocator);
    var selection = try selectNodes(allocator, &graph, .{
        .include_external_dependencies = true,
        .focus = .{ .pattern = .{ .regex = "(src|other)/" }, .depth = 2 },
        .reachable_from = .{ .glob = "src/d.zig" },
        .dependents_of = .{ .glob = "src/c.zig" },
    });
    defer selection.deinit(allocator);
}

test "combined selection cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
