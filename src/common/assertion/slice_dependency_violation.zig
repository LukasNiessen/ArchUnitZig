const std = @import("std");

const mood_module = @import("mood.zig");
const projected_edge = @import("../projection/projected_edge.zig");

const Allocator = std.mem.Allocator;
pub const Mood = mood_module.Mood;
pub const ProjectedEdge = projected_edge.ProjectedEdge;
pub const InitError = projected_edge.ProjectionError || error{
    EmptySliceLabel,
    InvalidSliceDependencyEvidence,
};

/// Owned evidence for a required missing or forbidden present dependency between two slices.
pub const SliceDependencyViolation = struct {
    source_slice: []const u8,
    target_slice: []const u8,
    mood: Mood,
    dependency: ?ProjectedEdge,

    pub fn initClone(
        allocator: Allocator,
        source_slice: []const u8,
        target_slice: []const u8,
        mood: Mood,
        dependency: ?ProjectedEdge,
    ) InitError!SliceDependencyViolation {
        if (!containsNonWhitespace(source_slice) or !containsNonWhitespace(target_slice)) {
            return error.EmptySliceLabel;
        }
        if ((mood == .should and dependency != null) or
            (mood == .should_not and dependency == null))
        {
            return error.InvalidSliceDependencyEvidence;
        }
        if (dependency) |edge| {
            if (!std.mem.eql(u8, source_slice, edge.source_label) or
                !std.mem.eql(u8, target_slice, edge.target_label))
            {
                return error.InvalidSliceDependencyEvidence;
            }
        }

        const owned_source = try allocator.dupe(u8, source_slice);
        errdefer allocator.free(owned_source);
        const owned_target = try allocator.dupe(u8, target_slice);
        errdefer allocator.free(owned_target);
        return .{
            .source_slice = owned_source,
            .target_slice = owned_target,
            .mood = mood,
            .dependency = if (dependency) |edge| try edge.clone(allocator) else null,
        };
    }

    pub fn clone(
        self: SliceDependencyViolation,
        allocator: Allocator,
    ) InitError!SliceDependencyViolation {
        return initClone(
            allocator,
            self.source_slice,
            self.target_slice,
            self.mood,
            self.dependency,
        );
    }

    pub fn deinit(self: *SliceDependencyViolation, allocator: Allocator) void {
        allocator.free(self.source_slice);
        allocator.free(self.target_slice);
        if (self.dependency) |*edge| edge.deinit(allocator);
        self.* = undefined;
    }

    pub fn eql(self: SliceDependencyViolation, other: SliceDependencyViolation) bool {
        if (!std.mem.eql(u8, self.source_slice, other.source_slice) or
            !std.mem.eql(u8, self.target_slice, other.target_slice) or
            self.mood != other.mood or
            (self.dependency == null) != (other.dependency == null))
        {
            return false;
        }
        return if (self.dependency) |edge| edge.eql(other.dependency.?) else true;
    }
};

fn containsNonWhitespace(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n\x0b\x0c").len != 0;
}

fn testEdge(allocator: Allocator) !ProjectedEdge {
    const extraction = @import("../extraction.zig");
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
        .{ .source_label = "api", .target_label = "retrieval" },
        raw,
    );
}

test "slice dependency violations own present and absent dependency evidence" {
    var edge = try testEdge(std.testing.allocator);
    defer edge.deinit(std.testing.allocator);
    var forbidden = try SliceDependencyViolation.initClone(
        std.testing.allocator,
        "api",
        "retrieval",
        .should_not,
        edge,
    );
    defer forbidden.deinit(std.testing.allocator);
    var required = try SliceDependencyViolation.initClone(
        std.testing.allocator,
        "models",
        "api",
        .should,
        null,
    );
    defer required.deinit(std.testing.allocator);
    var cloned = try forbidden.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expect(forbidden.eql(cloned));
    try std.testing.expectEqual(@as(u32, 2), forbidden.dependency.?.evidence()[0].locationItems()[0].line);
    try std.testing.expect(required.dependency == null);
}

test "slice dependency violation evidence and labels are validated" {
    var edge = try testEdge(std.testing.allocator);
    defer edge.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidSliceDependencyEvidence,
        SliceDependencyViolation.initClone(std.testing.allocator, "api", "retrieval", .should, edge),
    );
    try std.testing.expectError(
        error.InvalidSliceDependencyEvidence,
        SliceDependencyViolation.initClone(std.testing.allocator, "api", "services", .should_not, edge),
    );
    try std.testing.expectError(
        error.EmptySliceLabel,
        SliceDependencyViolation.initClone(std.testing.allocator, " ", "api", .should, null),
    );
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var edge = try testEdge(allocator);
    defer edge.deinit(allocator);
    var violation = try SliceDependencyViolation.initClone(
        allocator,
        "api",
        "retrieval",
        .should_not,
        edge,
    );
    defer violation.deinit(allocator);
    var cloned = try violation.clone(allocator);
    defer cloned.deinit(allocator);
    try std.testing.expect(violation.eql(cloned));
}

test "slice dependency violation cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocationFailures, .{});
}
