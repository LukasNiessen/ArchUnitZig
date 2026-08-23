const std = @import("std");

const Allocator = std.mem.Allocator;

/// Owned dense directed adjacency with sorted unique neighbours.
pub const Adjacency = struct {
    lists: []std.ArrayList(usize),

    pub fn init(allocator: Allocator, vertex_count: usize) Allocator.Error!Adjacency {
        const lists = try allocator.alloc(std.ArrayList(usize), vertex_count);
        for (lists) |*list| list.* = .empty;
        return .{ .lists = lists };
    }

    pub fn deinit(self: *Adjacency, allocator: Allocator) void {
        for (self.lists) |*list| list.deinit(allocator);
        allocator.free(self.lists);
        self.* = undefined;
    }

    pub fn add(self: *Adjacency, allocator: Allocator, source: usize, target: usize) Allocator.Error!void {
        std.debug.assert(source < self.lists.len and target < self.lists.len);
        try self.lists[source].append(allocator, target);
    }

    pub fn normalize(self: *Adjacency) void {
        for (self.lists) |*list| {
            std.mem.sort(usize, list.items, {}, std.sort.asc(usize));
            if (list.items.len < 2) continue;
            var output: usize = 1;
            for (list.items[1..]) |vertex| {
                if (list.items[output - 1] == vertex) continue;
                list.items[output] = vertex;
                output += 1;
            }
            list.items.len = output;
        }
    }

    pub fn neighbours(self: *const Adjacency, vertex: usize) []const usize {
        return self.lists[vertex].items;
    }

    pub fn len(self: *const Adjacency) usize {
        return self.lists.len;
    }
};

test "adjacency normalizes neighbour order and duplicates" {
    var adjacency = try Adjacency.init(std.testing.allocator, 3);
    defer adjacency.deinit(std.testing.allocator);
    try adjacency.add(std.testing.allocator, 0, 2);
    try adjacency.add(std.testing.allocator, 0, 1);
    try adjacency.add(std.testing.allocator, 0, 2);
    adjacency.normalize();
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, adjacency.neighbours(0));
}
