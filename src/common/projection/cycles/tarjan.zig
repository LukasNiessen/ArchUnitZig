const std = @import("std");

const adjacency_module = @import("adjacency.zig");

const Allocator = std.mem.Allocator;
pub const Adjacency = adjacency_module.Adjacency;

const unvisited = std.math.maxInt(usize);

pub const Components = struct {
    values: std.ArrayList([]usize) = .empty,

    pub fn deinit(self: *Components, allocator: Allocator) void {
        for (self.values.items) |component| allocator.free(component);
        self.values.deinit(allocator);
        self.* = undefined;
    }

    pub fn items(self: *const Components) []const []const usize {
        return self.values.items;
    }

    pub fn len(self: *const Components) usize {
        return self.values.items.len;
    }
};

const Frame = struct {
    vertex: usize,
    parent: ?usize,
    next_neighbour: usize = 0,
    entered: bool = false,
};

/// Iterative Tarjan SCC over the induced subgraph containing IDs `lower_bound..vertex_count`.
pub fn stronglyConnectedComponents(
    allocator: Allocator,
    adjacency: *const Adjacency,
    lower_bound: usize,
) Allocator.Error!Components {
    const vertex_count = adjacency.len();
    if (lower_bound >= vertex_count) return .{};

    const indices = try allocator.alloc(usize, vertex_count);
    defer allocator.free(indices);
    @memset(indices, unvisited);
    const lowlinks = try allocator.alloc(usize, vertex_count);
    defer allocator.free(lowlinks);
    @memset(lowlinks, unvisited);
    const on_stack = try allocator.alloc(bool, vertex_count);
    defer allocator.free(on_stack);
    @memset(on_stack, false);

    var next_index: usize = 0;
    var vertex_stack: std.ArrayList(usize) = .empty;
    defer vertex_stack.deinit(allocator);
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(allocator);
    var components: Components = .{};
    errdefer components.deinit(allocator);

    var root = lower_bound;
    while (root < vertex_count) : (root += 1) {
        if (indices[root] != unvisited) continue;
        try frames.append(allocator, .{ .vertex = root, .parent = null });

        while (frames.items.len != 0) {
            const frame_index = frames.items.len - 1;
            const vertex = frames.items[frame_index].vertex;
            if (!frames.items[frame_index].entered) {
                indices[vertex] = next_index;
                lowlinks[vertex] = next_index;
                next_index += 1;
                try vertex_stack.append(allocator, vertex);
                on_stack[vertex] = true;
                frames.items[frame_index].entered = true;
            }

            var descended = false;
            const neighbours = adjacency.neighbours(vertex);
            while (frames.items[frame_index].next_neighbour < neighbours.len) {
                const neighbour = neighbours[frames.items[frame_index].next_neighbour];
                frames.items[frame_index].next_neighbour += 1;
                if (neighbour < lower_bound) continue;
                if (indices[neighbour] == unvisited) {
                    try frames.append(allocator, .{ .vertex = neighbour, .parent = vertex });
                    descended = true;
                    break;
                }
                if (on_stack[neighbour]) {
                    lowlinks[vertex] = @min(lowlinks[vertex], indices[neighbour]);
                }
            }
            if (descended) continue;

            const finished = frames.pop().?;
            if (finished.parent) |parent| {
                lowlinks[parent] = @min(lowlinks[parent], lowlinks[finished.vertex]);
            }
            if (lowlinks[finished.vertex] == indices[finished.vertex]) {
                try extractComponent(
                    allocator,
                    &components,
                    &vertex_stack,
                    on_stack,
                    finished.vertex,
                );
            }
        }
    }

    std.mem.sort([]usize, components.values.items, {}, struct {
        fn lessThan(_: void, left: []usize, right: []usize) bool {
            return left[0] < right[0];
        }
    }.lessThan);
    return components;
}

fn extractComponent(
    allocator: Allocator,
    components: *Components,
    vertex_stack: *std.ArrayList(usize),
    on_stack: []bool,
    root: usize,
) Allocator.Error!void {
    var component: std.ArrayList(usize) = .empty;
    defer component.deinit(allocator);
    while (true) {
        const vertex = vertex_stack.pop().?;
        on_stack[vertex] = false;
        try component.append(allocator, vertex);
        if (vertex == root) break;
    }
    std.mem.sort(usize, component.items, {}, std.sort.asc(usize));
    const owned = try component.toOwnedSlice(allocator);
    components.values.append(allocator, owned) catch |failure| {
        allocator.free(owned);
        return failure;
    };
}

fn fixtureAdjacency(allocator: Allocator) !Adjacency {
    var adjacency = try Adjacency.init(allocator, 6);
    errdefer adjacency.deinit(allocator);
    const edges = [_][2]usize{
        .{ 0, 1 }, .{ 1, 2 }, .{ 2, 0 }, .{ 2, 3 }, .{ 3, 4 }, .{ 4, 3 },
    };
    for (edges) |edge| try adjacency.add(allocator, edge[0], edge[1]);
    adjacency.normalize();
    return adjacency;
}

test "Tarjan separates strongly connected and acyclic components deterministically" {
    var adjacency = try fixtureAdjacency(std.testing.allocator);
    defer adjacency.deinit(std.testing.allocator);
    var components = try stronglyConnectedComponents(std.testing.allocator, &adjacency, 0);
    defer components.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), components.len());
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, components.items()[0]);
    try std.testing.expectEqualSlices(usize, &.{ 3, 4 }, components.items()[1]);
    try std.testing.expectEqualSlices(usize, &.{5}, components.items()[2]);
}

test "Tarjan honors an induced lower-bound subgraph" {
    var adjacency = try fixtureAdjacency(std.testing.allocator);
    defer adjacency.deinit(std.testing.allocator);
    var components = try stronglyConnectedComponents(std.testing.allocator, &adjacency, 1);
    defer components.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), components.len());
    try std.testing.expectEqualSlices(usize, &.{1}, components.items()[0]);
    try std.testing.expectEqualSlices(usize, &.{2}, components.items()[1]);
    try std.testing.expectEqualSlices(usize, &.{ 3, 4 }, components.items()[2]);
    try std.testing.expectEqualSlices(usize, &.{5}, components.items()[3]);
}

test "iterative Tarjan handles a deep graph without call-stack recursion" {
    const vertex_count = 10_000;
    var adjacency = try Adjacency.init(std.testing.allocator, vertex_count);
    defer adjacency.deinit(std.testing.allocator);
    for (0..vertex_count - 1) |vertex| {
        try adjacency.add(std.testing.allocator, vertex, vertex + 1);
    }
    var components = try stronglyConnectedComponents(std.testing.allocator, &adjacency, 0);
    defer components.deinit(std.testing.allocator);
    try std.testing.expectEqual(vertex_count, components.len());
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var adjacency = try fixtureAdjacency(allocator);
    defer adjacency.deinit(allocator);
    var components = try stronglyConnectedComponents(allocator, &adjacency, 0);
    defer components.deinit(allocator);
}

test "Tarjan cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
