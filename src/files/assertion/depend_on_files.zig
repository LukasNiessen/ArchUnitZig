const std = @import("std");

const assertion = @import("../../common/assertion.zig");
const dependency_violation = @import("../../common/assertion/file_dependency_violation.zig");
const projection = @import("../../common/projection.zig");

const Allocator = std.mem.Allocator;

/// Pure direct-dependency assertion. Inputs are sorted selected paths and internal non-self
/// projected edges. Violations are grouped deterministically by selected source.
pub fn gatherFileDependencyViolations(
    allocator: Allocator,
    edges: []const projection.ProjectedEdge,
    subject_paths: []const []const u8,
    object_paths: []const []const u8,
    mood: assertion.Mood,
) dependency_violation.InitError!assertion.ViolationList {
    var result = assertion.ViolationList{};
    errdefer result.deinit(allocator);
    var violating_edges: std.ArrayList(*const projection.ProjectedEdge) = .empty;
    defer violating_edges.deinit(allocator);

    for (subject_paths) |source_path| {
        violating_edges.clearRetainingCapacity();
        for (edges) |*edge| {
            if (!std.mem.eql(u8, source_path, edge.source_label)) continue;
            if (mood.holds(contains(object_paths, edge.target_label))) continue;
            try violating_edges.append(allocator, edge);
        }
        if (violating_edges.items.len == 0) continue;
        var payload = try assertion.FileDependencyViolation.initClonePointers(
            allocator,
            source_path,
            violating_edges.items,
            mood,
        );
        var violation = assertion.Violation.fromFileDependencyMove(&payload);
        result.appendMove(allocator, &violation) catch |failure| {
            violation.deinit(allocator);
            return failure;
        };
    }
    return result;
}

fn contains(sorted_paths: []const []const u8, wanted: []const u8) bool {
    var low: usize = 0;
    var high = sorted_paths.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, sorted_paths[middle], wanted)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return true,
        }
    }
    return false;
}

fn projected(
    allocator: Allocator,
    source: []const u8,
    target: []const u8,
) !projection.ProjectedEdge {
    const extraction = @import("../../common/extraction.zig");
    var raw = try extraction.Edge.init(
        allocator,
        source,
        target,
        false,
        extraction.ImportKinds.initOne(.zig_file),
    );
    defer raw.deinit(allocator);
    return projection.ProjectedEdge.init(
        allocator,
        .{ .source_label = source, .target_label = target },
        raw,
    );
}

test "positive allowlists and negative blocklists group targets by source" {
    var edges = projection.ProjectedEdges{};
    defer edges.deinit(std.testing.allocator);
    var api_database = try projected(std.testing.allocator, "api.zig", "database.zig");
    try edges.appendMove(std.testing.allocator, &api_database);
    var api_config = try projected(std.testing.allocator, "api.zig", "config.zon");
    try edges.appendMove(std.testing.allocator, &api_config);
    var worker_database = try projected(std.testing.allocator, "worker.zig", "database.zig");
    try edges.appendMove(std.testing.allocator, &worker_database);
    edges.sort();
    const subjects = [_][]const u8{ "api.zig", "worker.zig" };

    var positive = try gatherFileDependencyViolations(
        std.testing.allocator,
        edges.items(),
        &subjects,
        &.{"database.zig"},
        .should,
    );
    defer positive.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), positive.items().len);
    try std.testing.expectEqualStrings("api.zig", positive.items()[0].file_dependency.source_path);
    try std.testing.expectEqualStrings("config.zon", positive.items()[0].file_dependency.items()[0].target_label);

    var negated = try gatherFileDependencyViolations(
        std.testing.allocator,
        edges.items(),
        &subjects,
        &.{ "config.zon", "database.zig" },
        .should_not,
    );
    defer negated.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), negated.items().len);
    try std.testing.expectEqual(@as(usize, 2), negated.items()[0].file_dependency.items().len);
    try std.testing.expectEqual(assertion.Mood.should_not, negated.items()[0].file_dependency.mood);
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var edge = try projected(allocator, "api.zig", "database.zig");
    defer edge.deinit(allocator);
    var result = try gatherFileDependencyViolations(
        allocator,
        &.{edge},
        &.{"api.zig"},
        &.{"database.zig"},
        .should_not,
    );
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.items().len);
}

test "file dependency gatherer cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
