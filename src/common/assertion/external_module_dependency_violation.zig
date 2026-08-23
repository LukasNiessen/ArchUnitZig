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

/// One source and all external-module dependencies that disagree with its policy.
pub const ExternalModuleDependencyViolation = struct {
    source_path: []const u8,
    dependencies: std.ArrayList(ProjectedEdge) = .empty,
    mood: Mood,

    pub fn initClonePointers(
        allocator: Allocator,
        source_path: []const u8,
        source_edges: []const *const ProjectedEdge,
        mood: Mood,
    ) InitError!ExternalModuleDependencyViolation {
        if (source_edges.len == 0) return error.EmptyDependencyEvidence;
        for (source_edges) |edge| {
            if (!std.mem.eql(u8, source_path, edge.source_label)) return error.MismatchedDependencySource;
        }
        const owned_source = try allocator.dupe(u8, source_path);
        var result = ExternalModuleDependencyViolation{ .source_path = owned_source, .mood = mood };
        errdefer result.deinit(allocator);
        try result.dependencies.ensureTotalCapacity(allocator, source_edges.len);
        for (source_edges) |edge| result.dependencies.appendAssumeCapacity(try edge.clone(allocator));
        return result;
    }

    pub fn clone(
        self: ExternalModuleDependencyViolation,
        allocator: Allocator,
    ) InitError!ExternalModuleDependencyViolation {
        var pointers: std.ArrayList(*const ProjectedEdge) = .empty;
        defer pointers.deinit(allocator);
        try pointers.ensureTotalCapacity(allocator, self.dependencies.items.len);
        for (self.dependencies.items) |*edge| pointers.appendAssumeCapacity(edge);
        return initClonePointers(allocator, self.source_path, pointers.items, self.mood);
    }

    pub fn deinit(self: *ExternalModuleDependencyViolation, allocator: Allocator) void {
        allocator.free(self.source_path);
        for (self.dependencies.items) |*edge| edge.deinit(allocator);
        self.dependencies.deinit(allocator);
        self.* = undefined;
    }

    pub fn items(self: *const ExternalModuleDependencyViolation) []const ProjectedEdge {
        return self.dependencies.items;
    }

    pub fn eql(self: ExternalModuleDependencyViolation, other: ExternalModuleDependencyViolation) bool {
        if (!std.mem.eql(u8, self.source_path, other.source_path) or
            self.mood != other.mood or
            self.dependencies.items.len != other.dependencies.items.len) return false;
        for (self.dependencies.items, other.dependencies.items) |left, right| {
            if (!left.eql(right)) return false;
        }
        return true;
    }
};

test "external module violations own classification and location evidence" {
    const extraction = @import("../extraction.zig");
    var raw = try extraction.Edge.initClassifiedWithLocations(
        std.testing.allocator,
        "src/client.zig",
        "http",
        true,
        extraction.ImportKinds.initOne(.named_module),
        .external,
        .resolved,
        &.{.{ .byte_offset = 4, .line = 1, .column = 5 }},
    );
    defer raw.deinit(std.testing.allocator);
    var edge = try ProjectedEdge.init(
        std.testing.allocator,
        .{ .source_label = raw.source, .target_label = raw.target },
        raw,
    );
    defer edge.deinit(std.testing.allocator);
    var violation = try ExternalModuleDependencyViolation.initClonePointers(
        std.testing.allocator,
        "src/client.zig",
        &.{&edge},
        .should_not,
    );
    defer violation.deinit(std.testing.allocator);
    var cloned = try violation.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expect(violation.eql(cloned));
    const evidence = violation.items()[0].evidence()[0];
    try std.testing.expect(evidence.target_classes.contains(.external));
    try std.testing.expect(evidence.target_availabilities.contains(.resolved));
    try std.testing.expectEqual(@as(u32, 1), evidence.locationItems()[0].line);
}
