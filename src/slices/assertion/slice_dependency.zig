const std = @import("std");

const assertion = @import("../../common/assertion.zig");
const extraction = @import("../../common/extraction.zig");
const projection = @import("../../common/projection.zig");
const slice_violation = @import("../../common/assertion/slice_dependency_violation.zig");

const Allocator = std.mem.Allocator;
pub const Mood = assertion.Mood;
pub const ProjectedEdge = projection.ProjectedEdge;
pub const ViolationList = assertion.ViolationList;
pub const GatherError = slice_violation.InitError;

/// Evaluates one required or forbidden dependency over already-projected slice edges.
pub fn gatherSliceDependencyViolations(
    allocator: Allocator,
    edges: []const ProjectedEdge,
    source_slice: []const u8,
    target_slice: []const u8,
    mood: Mood,
) GatherError!ViolationList {
    if (!containsNonWhitespace(source_slice) or !containsNonWhitespace(target_slice)) {
        return error.EmptySliceLabel;
    }
    const dependency = findDependency(edges, source_slice, target_slice);
    var result: ViolationList = .{};
    errdefer result.deinit(allocator);
    if (mood.holds(dependency != null)) return result;

    var payload = try assertion.SliceDependencyViolation.initClone(
        allocator,
        source_slice,
        target_slice,
        mood,
        if (dependency) |edge| edge.* else null,
    );
    var violation = assertion.Violation.fromSliceDependencyMove(&payload);
    result.appendMove(allocator, &violation) catch |failure| {
        violation.deinit(allocator);
        return failure;
    };
    return result;
}

fn findDependency(
    edges: []const ProjectedEdge,
    source_slice: []const u8,
    target_slice: []const u8,
) ?*const ProjectedEdge {
    for (edges) |*edge| {
        if (std.mem.eql(u8, edge.source_label, source_slice) and
            std.mem.eql(u8, edge.target_label, target_slice)) return edge;
    }
    return null;
}

fn containsNonWhitespace(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n\x0b\x0c").len != 0;
}

fn testEdge(allocator: Allocator, source: []const u8, target: []const u8) !ProjectedEdge {
    var raw = try extraction.Edge.initWithLocations(
        allocator,
        "src/features/api/root.zig",
        "src/features/retrieval/repository.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
        &.{.{ .byte_offset = 25, .line = 2, .column = 21 }},
    );
    defer raw.deinit(allocator);
    return ProjectedEdge.init(
        allocator,
        .{ .source_label = source, .target_label = target },
        raw,
    );
}

test "forbidden present and required missing slice dependencies produce structured violations" {
    var edge = try testEdge(std.testing.allocator, "api", "retrieval");
    defer edge.deinit(std.testing.allocator);
    var forbidden = try gatherSliceDependencyViolations(
        std.testing.allocator,
        &.{edge},
        "api",
        "retrieval",
        .should_not,
    );
    defer forbidden.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), forbidden.items().len);
    try std.testing.expectEqualStrings("retrieval", forbidden.items()[0].slice_dependency.target_slice);
    try std.testing.expectEqual(@as(u32, 2), forbidden.items()[0].slice_dependency.dependency.?.evidence()[0].locationItems()[0].line);

    var required = try gatherSliceDependencyViolations(
        std.testing.allocator,
        &.{edge},
        "models",
        "api",
        .should,
    );
    defer required.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), required.items().len);
    try std.testing.expect(required.items()[0].slice_dependency.dependency == null);
}

test "forbidden absent and required present slice dependencies pass" {
    var edge = try testEdge(std.testing.allocator, "api", "services");
    defer edge.deinit(std.testing.allocator);
    var forbidden_absent = try gatherSliceDependencyViolations(
        std.testing.allocator,
        &.{edge},
        "models",
        "api",
        .should_not,
    );
    defer forbidden_absent.deinit(std.testing.allocator);
    var required_present = try gatherSliceDependencyViolations(
        std.testing.allocator,
        &.{edge},
        "api",
        "services",
        .should,
    );
    defer required_present.deinit(std.testing.allocator);
    try std.testing.expect(forbidden_absent.passes());
    try std.testing.expect(required_present.passes());
}

test "slice dependency gather validates labels independently of edge presence" {
    try std.testing.expectError(
        error.EmptySliceLabel,
        gatherSliceDependencyViolations(std.testing.allocator, &.{}, "", "api", .should),
    );
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var edge = try testEdge(allocator, "api", "retrieval");
    defer edge.deinit(allocator);
    var result = try gatherSliceDependencyViolations(
        allocator,
        &.{edge},
        "api",
        "retrieval",
        .should_not,
    );
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.items().len);
}

test "slice dependency gather cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocationFailures, .{});
}
