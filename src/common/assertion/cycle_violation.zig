const std = @import("std");

const projected_cycle = @import("../projection/projected_cycle.zig");

const Allocator = std.mem.Allocator;
pub const InitError = projected_cycle.CycleProjectionError;
pub const ProjectedCycle = projected_cycle.ProjectedCycle;

/// Data-only disagreement for one elementary directed cycle. Ordered projected edges retain the
/// concrete raw imports and source locations needed by testing-layer formatters.
pub const CycleViolation = struct {
    cycle: ProjectedCycle,

    pub fn initClone(allocator: Allocator, source: ProjectedCycle) InitError!CycleViolation {
        return .{ .cycle = try source.clone(allocator) };
    }

    pub fn fromCycleMove(source: *ProjectedCycle) CycleViolation {
        const result = CycleViolation{ .cycle = source.* };
        source.* = undefined;
        return result;
    }

    pub fn clone(self: CycleViolation, allocator: Allocator) InitError!CycleViolation {
        return initClone(allocator, self.cycle);
    }

    pub fn deinit(self: *CycleViolation, allocator: Allocator) void {
        self.cycle.deinit(allocator);
        self.* = undefined;
    }

    pub fn eql(self: CycleViolation, other: CycleViolation) bool {
        return self.cycle.eql(other.cycle);
    }
};

test "cycle violations own ordered raw evidence independently" {
    const extraction = @import("../extraction.zig");
    const projected_edge = @import("../projection/projected_edge.zig");
    var raw = try extraction.Edge.initWithLocations(
        std.testing.allocator,
        "src/a.zig",
        "src/b.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
        &.{.{ .byte_offset = 3, .line = 1, .column = 4 }},
    );
    defer raw.deinit(std.testing.allocator);
    var forward = try projected_edge.ProjectedEdge.init(
        std.testing.allocator,
        .{ .source_label = "src/a.zig", .target_label = "src/b.zig" },
        raw,
    );
    defer forward.deinit(std.testing.allocator);
    var reverse = try projected_edge.ProjectedEdge.init(
        std.testing.allocator,
        .{ .source_label = "src/b.zig", .target_label = "src/a.zig" },
        raw,
    );
    defer reverse.deinit(std.testing.allocator);
    var cycle = try ProjectedCycle.initClone(std.testing.allocator, &.{ forward, reverse });
    defer cycle.deinit(std.testing.allocator);
    var violation = try CycleViolation.initClone(std.testing.allocator, cycle);
    defer violation.deinit(std.testing.allocator);

    try std.testing.expect(violation.cycle.eql(cycle));
    try std.testing.expect(cycle.items()[0].evidence()[0].source.ptr !=
        violation.cycle.items()[0].evidence()[0].source.ptr);
    try std.testing.expectEqual(@as(u32, 1), violation.cycle.items()[0].evidence()[0].locationItems()[0].line);
}
