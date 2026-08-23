const std = @import("std");

const mapped_edge = @import("mapped_edge.zig");
const projected_edge = @import("projected_edge.zig");

const Allocator = std.mem.Allocator;
pub const ProjectedEdge = projected_edge.ProjectedEdge;
pub const ProjectionError = Allocator.Error || mapped_edge.ProjectionError;

/// One owned directed cycle in traversal order. Issue #18 supplies cycle discovery.
pub const ProjectedCycle = struct {
    edges: std.ArrayList(ProjectedEdge) = .empty,

    pub fn initClone(allocator: Allocator, source_edges: []const ProjectedEdge) ProjectionError!ProjectedCycle {
        if (source_edges.len == 0) return error.EmptyProjectedCycle;
        var cycle: ProjectedCycle = .{};
        errdefer cycle.deinit(allocator);
        try cycle.edges.ensureTotalCapacity(allocator, source_edges.len);
        for (source_edges) |edge| {
            cycle.edges.appendAssumeCapacity(try edge.clone(allocator));
        }
        return cycle;
    }

    pub fn deinit(self: *ProjectedCycle, allocator: Allocator) void {
        for (self.edges.items) |*edge| edge.deinit(allocator);
        self.edges.deinit(allocator);
        self.* = undefined;
    }

    pub fn items(self: *const ProjectedCycle) []const ProjectedEdge {
        return self.edges.items;
    }
};

/// Owned projected-cycle collection used by the cycle engine and rule violations.
pub const ProjectedCycles = struct {
    values: std.ArrayList(ProjectedCycle) = .empty,

    pub fn deinit(self: *ProjectedCycles, allocator: Allocator) void {
        for (self.values.items) |*cycle| cycle.deinit(allocator);
        self.values.deinit(allocator);
        self.* = undefined;
    }

    pub fn appendMove(
        self: *ProjectedCycles,
        allocator: Allocator,
        cycle: *ProjectedCycle,
    ) Allocator.Error!void {
        try self.values.append(allocator, cycle.*);
        cycle.* = undefined;
    }

    pub fn items(self: *const ProjectedCycles) []const ProjectedCycle {
        return self.values.items;
    }

    pub fn len(self: *const ProjectedCycles) usize {
        return self.values.items.len;
    }
};

test "projected cycles clone ordered projected edges and raw evidence" {
    const extraction = @import("../extraction.zig");
    var raw = try extraction.Edge.init(
        std.testing.allocator,
        "src/a.zig",
        "src/b.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
    );
    defer raw.deinit(std.testing.allocator);
    var edge = try ProjectedEdge.init(
        std.testing.allocator,
        .{ .source_label = "a", .target_label = "b" },
        raw,
    );
    defer edge.deinit(std.testing.allocator);
    var cycle = try ProjectedCycle.initClone(std.testing.allocator, &.{edge});
    defer cycle.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("a", cycle.items()[0].source_label);
    try std.testing.expect(cycle.items()[0].source_label.ptr != edge.source_label.ptr);
    try std.testing.expect(cycle.items()[0].evidence()[0].source.ptr != edge.evidence()[0].source.ptr);
}

test "projected cycles reject empty paths" {
    try std.testing.expectError(
        error.EmptyProjectedCycle,
        ProjectedCycle.initClone(std.testing.allocator, &.{}),
    );
}
