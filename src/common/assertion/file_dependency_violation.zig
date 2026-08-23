const std = @import("std");

const mood_module = @import("mood.zig");
const projected_edge = @import("../projection/projected_edge.zig");

const Allocator = std.mem.Allocator;
pub const Mood = mood_module.Mood;
pub const ProjectedEdge = projected_edge.ProjectedEdge;
pub const InitError = projected_edge.ProjectionError || error{
    EmptyDependencyEvidence,
    MismatchedDependencySource,
};

/// One selected source and all of its direct file dependencies that disagree with an allowlist or
/// blocklist rule. Projected edges retain the concrete imports and source locations.
pub const FileDependencyViolation = struct {
    source_path: []const u8,
    dependencies: std.ArrayList(ProjectedEdge) = .empty,
    mood: Mood,

    pub fn initClonePointers(
        allocator: Allocator,
        source_path: []const u8,
        source_edges: []const *const ProjectedEdge,
        mood: Mood,
    ) InitError!FileDependencyViolation {
        if (source_edges.len == 0) return error.EmptyDependencyEvidence;
        for (source_edges) |edge| {
            if (!std.mem.eql(u8, source_path, edge.source_label)) {
                return error.MismatchedDependencySource;
            }
        }
        const owned_source = try allocator.dupe(u8, source_path);
        var result = FileDependencyViolation{ .source_path = owned_source, .mood = mood };
        errdefer result.deinit(allocator);
        try result.dependencies.ensureTotalCapacity(allocator, source_edges.len);
        for (source_edges) |edge| result.dependencies.appendAssumeCapacity(try edge.clone(allocator));
        return result;
    }

    pub fn clone(self: FileDependencyViolation, allocator: Allocator) InitError!FileDependencyViolation {
        var pointers: std.ArrayList(*const ProjectedEdge) = .empty;
        defer pointers.deinit(allocator);
        try pointers.ensureTotalCapacity(allocator, self.dependencies.items.len);
        for (self.dependencies.items) |*edge| pointers.appendAssumeCapacity(edge);
        return initClonePointers(allocator, self.source_path, pointers.items, self.mood);
    }

    pub fn deinit(self: *FileDependencyViolation, allocator: Allocator) void {
        allocator.free(self.source_path);
        for (self.dependencies.items) |*edge| edge.deinit(allocator);
        self.dependencies.deinit(allocator);
        self.* = undefined;
    }

    pub fn items(self: *const FileDependencyViolation) []const ProjectedEdge {
        return self.dependencies.items;
    }

    pub fn eql(self: FileDependencyViolation, other: FileDependencyViolation) bool {
        if (!std.mem.eql(u8, self.source_path, other.source_path) or
            self.mood != other.mood or
            self.dependencies.items.len != other.dependencies.items.len) return false;
        for (self.dependencies.items, other.dependencies.items) |left, right| {
            if (!left.eql(right)) return false;
        }
        return true;
    }
};

test "file dependency violations group and clone concrete located edges" {
    const extraction = @import("../extraction.zig");
    var raw = try extraction.Edge.initWithLocations(
        std.testing.allocator,
        "src/api.zig",
        "src/database.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
        &.{.{ .byte_offset = 12, .line = 2, .column = 5 }},
    );
    defer raw.deinit(std.testing.allocator);
    var edge = try ProjectedEdge.init(
        std.testing.allocator,
        .{ .source_label = raw.source, .target_label = raw.target },
        raw,
    );
    defer edge.deinit(std.testing.allocator);
    var violation = try FileDependencyViolation.initClonePointers(
        std.testing.allocator,
        "src/api.zig",
        &.{&edge},
        .should_not,
    );
    defer violation.deinit(std.testing.allocator);
    var cloned = try violation.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expect(violation.eql(cloned));
    try std.testing.expectEqualStrings("src/database.zig", violation.items()[0].target_label);
    try std.testing.expectEqual(@as(u32, 2), violation.items()[0].evidence()[0].locationItems()[0].line);
    try std.testing.expect(violation.items()[0].evidence()[0].source.ptr != raw.source.ptr);
}

test "file dependency violations reject empty and mixed-source groups" {
    try std.testing.expectError(
        error.EmptyDependencyEvidence,
        FileDependencyViolation.initClonePointers(
            std.testing.allocator,
            "src/api.zig",
            &.{},
            .should,
        ),
    );
}
