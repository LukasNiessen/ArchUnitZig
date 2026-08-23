const std = @import("std");

const mapped_edge = @import("mapped_edge.zig");
const projected_edge = @import("projected_edge.zig");

const Allocator = std.mem.Allocator;
pub const ProjectedEdge = projected_edge.ProjectedEdge;
pub const CycleProjectionError = Allocator.Error || mapped_edge.ProjectionError || error{
    EmptyProjectedCycle,
    DiscontinuousProjectedCycle,
    EmptyProjectedEvidence,
    MissingProjectedEdge,
};

/// One owned directed cycle in traversal order. Issue #18 supplies cycle discovery.
pub const ProjectedCycle = struct {
    edges: std.ArrayList(ProjectedEdge) = .empty,

    pub fn initClone(allocator: Allocator, source_edges: []const ProjectedEdge) CycleProjectionError!ProjectedCycle {
        if (source_edges.len == 0) return error.EmptyProjectedCycle;
        for (source_edges, 0..) |edge, index| {
            const next = source_edges[(index + 1) % source_edges.len];
            if (!std.mem.eql(u8, edge.target_label, next.source_label)) {
                return error.DiscontinuousProjectedCycle;
            }
        }
        var cycle: ProjectedCycle = .{};
        errdefer cycle.deinit(allocator);
        try cycle.edges.ensureTotalCapacity(allocator, source_edges.len);
        for (source_edges) |edge| {
            cycle.edges.appendAssumeCapacity(try edge.clone(allocator));
        }
        return cycle;
    }

    pub fn initClonePointers(
        allocator: Allocator,
        source_edges: []const *const ProjectedEdge,
    ) CycleProjectionError!ProjectedCycle {
        if (source_edges.len == 0) return error.EmptyProjectedCycle;
        for (source_edges, 0..) |edge, index| {
            const next = source_edges[(index + 1) % source_edges.len];
            if (!std.mem.eql(u8, edge.target_label, next.source_label)) {
                return error.DiscontinuousProjectedCycle;
            }
        }
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
    var forward_raw = try extraction.Edge.init(
        std.testing.allocator,
        "src/a.zig",
        "src/b.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
    );
    defer forward_raw.deinit(std.testing.allocator);
    var reverse_raw = try extraction.Edge.init(
        std.testing.allocator,
        "src/b.zig",
        "src/a.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
    );
    defer reverse_raw.deinit(std.testing.allocator);
    var forward = try ProjectedEdge.init(
        std.testing.allocator,
        .{ .source_label = "a", .target_label = "b" },
        forward_raw,
    );
    defer forward.deinit(std.testing.allocator);
    var reverse = try ProjectedEdge.init(
        std.testing.allocator,
        .{ .source_label = "b", .target_label = "a" },
        reverse_raw,
    );
    defer reverse.deinit(std.testing.allocator);
    var cycle = try ProjectedCycle.initClone(std.testing.allocator, &.{ forward, reverse });
    defer cycle.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("a", cycle.items()[0].source_label);
    try std.testing.expect(cycle.items()[0].source_label.ptr != forward.source_label.ptr);
    try std.testing.expect(cycle.items()[0].evidence()[0].source.ptr != forward.evidence()[0].source.ptr);
}

test "projected cycles reject empty paths" {
    try std.testing.expectError(
        error.EmptyProjectedCycle,
        ProjectedCycle.initClone(std.testing.allocator, &.{}),
    );
}

test "projected cycles reject discontinuous edge paths" {
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
    try std.testing.expectError(
        error.DiscontinuousProjectedCycle,
        ProjectedCycle.initClone(std.testing.allocator, &.{edge}),
    );
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    const extraction = @import("../extraction.zig");
    var forward_raw = try extraction.Edge.init(
        allocator,
        "src/a.zig",
        "src/b.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
    );
    defer forward_raw.deinit(allocator);
    var reverse_raw = try extraction.Edge.init(
        allocator,
        "src/b.zig",
        "src/a.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
    );
    defer reverse_raw.deinit(allocator);
    var forward = try ProjectedEdge.init(
        allocator,
        .{ .source_label = "a", .target_label = "b" },
        forward_raw,
    );
    defer forward.deinit(allocator);
    var reverse = try ProjectedEdge.init(
        allocator,
        .{ .source_label = "b", .target_label = "a" },
        reverse_raw,
    );
    defer reverse.deinit(allocator);
    var cycle = try ProjectedCycle.initClone(allocator, &.{ forward, reverse });
    var cycles: ProjectedCycles = .{};
    defer cycles.deinit(allocator);
    cycles.appendMove(allocator, &cycle) catch |failure| {
        cycle.deinit(allocator);
        return failure;
    };
}

test "projected cycle containers clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
