const std = @import("std");

const adjacency_module = @import("adjacency.zig");
const tarjan = @import("tarjan.zig");

const Allocator = std.mem.Allocator;
pub const Adjacency = adjacency_module.Adjacency;

pub const VertexCycles = struct {
    values: std.ArrayList([]usize) = .empty,

    pub fn deinit(self: *VertexCycles, allocator: Allocator) void {
        for (self.values.items) |cycle| allocator.free(cycle);
        self.values.deinit(allocator);
        self.* = undefined;
    }

    pub fn items(self: *const VertexCycles) []const []const usize {
        return self.values.items;
    }

    pub fn len(self: *const VertexCycles) usize {
        return self.values.items.len;
    }
};

const Frame = struct {
    vertex: usize,
    next_neighbour: usize = 0,
    found_cycle: bool = false,
};

/// Iterative Johnson enumeration. Each directed elementary cycle is emitted once.
pub fn elementaryCycles(
    allocator: Allocator,
    adjacency: *const Adjacency,
) Allocator.Error!VertexCycles {
    var cycles: VertexCycles = .{};
    errdefer cycles.deinit(allocator);

    var lower_bound: usize = 0;
    while (lower_bound < adjacency.len()) {
        var components = try tarjan.stronglyConnectedComponents(allocator, adjacency, lower_bound);
        const component = firstCyclicComponent(components.items()) orelse {
            components.deinit(allocator);
            break;
        };
        const start = component[0];
        enumerateComponent(allocator, adjacency, component, start, &cycles) catch |failure| {
            components.deinit(allocator);
            return failure;
        };
        components.deinit(allocator);
        lower_bound = start + 1;
    }

    std.mem.sort([]usize, cycles.values.items, {}, struct {
        fn lessThan(_: void, left: []usize, right: []usize) bool {
            const shared = @min(left.len, right.len);
            for (left[0..shared], right[0..shared]) |left_vertex, right_vertex| {
                if (left_vertex != right_vertex) return left_vertex < right_vertex;
            }
            return left.len < right.len;
        }
    }.lessThan);
    return cycles;
}

fn firstCyclicComponent(components: []const []const usize) ?[]const usize {
    for (components) |component| if (component.len > 1) return component;
    return null;
}

fn enumerateComponent(
    allocator: Allocator,
    adjacency: *const Adjacency,
    component: []const usize,
    start: usize,
    cycles: *VertexCycles,
) Allocator.Error!void {
    const vertex_count = adjacency.len();
    const member = try allocator.alloc(bool, vertex_count);
    defer allocator.free(member);
    @memset(member, false);
    for (component) |vertex| member[vertex] = true;
    const blocked = try allocator.alloc(bool, vertex_count);
    defer allocator.free(blocked);
    @memset(blocked, false);
    const blocked_by = try allocator.alloc(std.ArrayList(usize), vertex_count);
    for (blocked_by) |*list| list.* = .empty;
    defer {
        for (blocked_by) |*list| list.deinit(allocator);
        allocator.free(blocked_by);
    }

    var path: std.ArrayList(usize) = .empty;
    defer path.deinit(allocator);
    var frames: std.ArrayList(Frame) = .empty;
    defer frames.deinit(allocator);
    var unblock_stack: std.ArrayList(usize) = .empty;
    defer unblock_stack.deinit(allocator);

    try path.append(allocator, start);
    blocked[start] = true;
    try frames.append(allocator, .{ .vertex = start });

    while (frames.items.len != 0) {
        const frame_index = frames.items.len - 1;
        const vertex = frames.items[frame_index].vertex;
        const neighbours = adjacency.neighbours(vertex);
        var descended = false;
        while (frames.items[frame_index].next_neighbour < neighbours.len) {
            const neighbour = neighbours[frames.items[frame_index].next_neighbour];
            frames.items[frame_index].next_neighbour += 1;
            if (!member[neighbour] or neighbour == vertex) continue;
            if (neighbour == start) {
                try appendCycle(allocator, cycles, path.items);
                frames.items[frame_index].found_cycle = true;
                continue;
            }
            if (blocked[neighbour]) continue;

            blocked[neighbour] = true;
            try path.append(allocator, neighbour);
            frames.append(allocator, .{ .vertex = neighbour }) catch |failure| {
                _ = path.pop();
                blocked[neighbour] = false;
                return failure;
            };
            descended = true;
            break;
        }
        if (descended) continue;

        const finished = frames.pop().?;
        if (finished.found_cycle) {
            try unblock(allocator, finished.vertex, blocked, blocked_by, &unblock_stack);
        } else {
            try recordBlockers(allocator, adjacency, member, finished.vertex, blocked_by);
        }
        std.debug.assert(path.pop().? == finished.vertex);
        if (frames.items.len != 0 and finished.found_cycle) {
            frames.items[frames.items.len - 1].found_cycle = true;
        }
    }
}

fn appendCycle(
    allocator: Allocator,
    cycles: *VertexCycles,
    path: []const usize,
) Allocator.Error!void {
    const owned = try allocator.dupe(usize, path);
    cycles.values.append(allocator, owned) catch |failure| {
        allocator.free(owned);
        return failure;
    };
}

fn unblock(
    allocator: Allocator,
    initial: usize,
    blocked: []bool,
    blocked_by: []std.ArrayList(usize),
    work: *std.ArrayList(usize),
) Allocator.Error!void {
    work.clearRetainingCapacity();
    try work.append(allocator, initial);
    while (work.pop()) |vertex| {
        if (!blocked[vertex]) continue;
        blocked[vertex] = false;
        for (blocked_by[vertex].items) |dependant| {
            if (blocked[dependant]) try work.append(allocator, dependant);
        }
        blocked_by[vertex].clearRetainingCapacity();
    }
}

fn recordBlockers(
    allocator: Allocator,
    adjacency: *const Adjacency,
    member: []const bool,
    vertex: usize,
    blocked_by: []std.ArrayList(usize),
) Allocator.Error!void {
    for (adjacency.neighbours(vertex)) |neighbour| {
        if (!member[neighbour] or neighbour == vertex) continue;
        if (std.mem.indexOfScalar(usize, blocked_by[neighbour].items, vertex) == null) {
            try blocked_by[neighbour].append(allocator, vertex);
        }
    }
}

fn buildAdjacency(
    allocator: Allocator,
    vertex_count: usize,
    edges: []const [2]usize,
) !Adjacency {
    var adjacency = try Adjacency.init(allocator, vertex_count);
    errdefer adjacency.deinit(allocator);
    for (edges) |edge| try adjacency.add(allocator, edge[0], edge[1]);
    adjacency.normalize();
    return adjacency;
}

test "Johnson returns no cycles for DAGs and self edges" {
    var adjacency = try buildAdjacency(std.testing.allocator, 4, &.{
        .{ 0, 0 }, .{ 0, 1 }, .{ 1, 2 }, .{ 3, 3 },
    });
    defer adjacency.deinit(std.testing.allocator);
    var cycles = try elementaryCycles(std.testing.allocator, &adjacency);
    defer cycles.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), cycles.len());
}

test "Johnson finds disconnected and overlapping directed cycles exactly once" {
    var adjacency = try buildAdjacency(std.testing.allocator, 5, &.{
        .{ 0, 1 }, .{ 0, 2 }, .{ 1, 0 }, .{ 1, 2 }, .{ 2, 0 }, .{ 2, 1 },
        .{ 3, 4 }, .{ 4, 3 },
    });
    defer adjacency.deinit(std.testing.allocator);
    var cycles = try elementaryCycles(std.testing.allocator, &adjacency);
    defer cycles.deinit(std.testing.allocator);

    const expected = [_][]const usize{
        &.{ 0, 1 }, &.{ 0, 1, 2 }, &.{ 0, 2 }, &.{ 0, 2, 1 }, &.{ 1, 2 }, &.{ 3, 4 },
    };
    try std.testing.expectEqual(expected.len, cycles.len());
    for (expected, cycles.items()) |wanted, actual| {
        try std.testing.expectEqualSlices(usize, wanted, actual);
    }
}

test "Johnson enumerates the dense four-vertex reference fixture" {
    var adjacency = try Adjacency.init(std.testing.allocator, 4);
    defer adjacency.deinit(std.testing.allocator);
    for (0..4) |source| for (0..4) |target| {
        if (source != target) try adjacency.add(std.testing.allocator, source, target);
    };
    adjacency.normalize();
    var cycles = try elementaryCycles(std.testing.allocator, &adjacency);
    defer cycles.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 20), cycles.len());
    for (cycles.items()) |cycle| {
        for (cycle, 0..) |vertex, index| {
            try std.testing.expect(std.mem.indexOfScalar(usize, cycle[0..index], vertex) == null);
        }
    }
}

test "iterative Johnson handles a deep cycle without call-stack recursion" {
    const vertex_count = 5_000;
    var adjacency = try Adjacency.init(std.testing.allocator, vertex_count);
    defer adjacency.deinit(std.testing.allocator);
    for (0..vertex_count) |vertex| {
        try adjacency.add(std.testing.allocator, vertex, (vertex + 1) % vertex_count);
    }
    var cycles = try elementaryCycles(std.testing.allocator, &adjacency);
    defer cycles.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), cycles.len());
    try std.testing.expectEqual(vertex_count, cycles.items()[0].len);
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var adjacency = try buildAdjacency(allocator, 3, &.{
        .{ 0, 1 }, .{ 1, 0 }, .{ 1, 2 }, .{ 2, 1 },
    });
    defer adjacency.deinit(allocator);
    var cycles = try elementaryCycles(allocator, &adjacency);
    defer cycles.deinit(allocator);
}

test "Johnson cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
