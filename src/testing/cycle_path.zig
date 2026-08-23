const std = @import("std");

const projected_cycle = @import("../common/projection/projected_cycle.zig");

const Allocator = std.mem.Allocator;

/// Formats only the stable path fact. Full violation prose and source rendering land with the
/// testing API; the assertion payload itself remains data-only.
pub fn formatCyclePath(
    allocator: Allocator,
    cycle: projected_cycle.ProjectedCycle,
) Allocator.Error![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const edges = cycle.items();
    std.debug.assert(edges.len != 0);
    output.writer.writeAll(edges[0].source_label) catch return error.OutOfMemory;
    for (edges) |edge| {
        output.writer.writeAll(" -> ") catch return error.OutOfMemory;
        output.writer.writeAll(edge.target_label) catch return error.OutOfMemory;
    }
    return output.toOwnedSlice();
}

test "cycle paths close the loop in traversal order" {
    const extraction = @import("../common/extraction.zig");
    const projected_edge = @import("../common/projection/projected_edge.zig");
    var raw = try extraction.Edge.init(
        std.testing.allocator,
        "a.zig",
        "b.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
    );
    defer raw.deinit(std.testing.allocator);
    var forward = try projected_edge.ProjectedEdge.init(
        std.testing.allocator,
        .{ .source_label = "a.zig", .target_label = "b.zig" },
        raw,
    );
    defer forward.deinit(std.testing.allocator);
    var reverse = try projected_edge.ProjectedEdge.init(
        std.testing.allocator,
        .{ .source_label = "b.zig", .target_label = "a.zig" },
        raw,
    );
    defer reverse.deinit(std.testing.allocator);
    var cycle = try projected_cycle.ProjectedCycle.initClone(std.testing.allocator, &.{ forward, reverse });
    defer cycle.deinit(std.testing.allocator);
    const path = try formatCyclePath(std.testing.allocator, cycle);
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("a.zig -> b.zig -> a.zig", path);
}
