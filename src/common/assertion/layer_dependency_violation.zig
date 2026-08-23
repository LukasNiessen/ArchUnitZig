const std = @import("std");

const projected_edge = @import("../projection/projected_edge.zig");

const Allocator = std.mem.Allocator;
pub const ProjectedEdge = projected_edge.ProjectedEdge;
pub const InitError = projected_edge.ProjectionError || error{
    EmptyLayerName,
    InvalidLayerAssignments,
};

pub const LayerPolicyKind = enum {
    may_only_depend_on_layers,
    may_not_depend_on_layers,
    unassigned_endpoint,
};

/// Owned evidence for one internal dependency rejected by a named-layer policy.
pub const LayerDependencyViolation = struct {
    dependency: ProjectedEdge,
    source_layer: ?[]const u8,
    target_layer: ?[]const u8,
    policy: LayerPolicyKind,

    pub fn initClone(
        allocator: Allocator,
        dependency: ProjectedEdge,
        source_layer: ?[]const u8,
        target_layer: ?[]const u8,
        policy: LayerPolicyKind,
    ) InitError!LayerDependencyViolation {
        try validateAssignments(source_layer, target_layer, policy);
        var owned_dependency = try dependency.clone(allocator);
        errdefer owned_dependency.deinit(allocator);
        const owned_source = try cloneOptional(allocator, source_layer);
        errdefer if (owned_source) |value| allocator.free(value);
        return .{
            .dependency = owned_dependency,
            .source_layer = owned_source,
            .target_layer = try cloneOptional(allocator, target_layer),
            .policy = policy,
        };
    }

    pub fn clone(self: LayerDependencyViolation, allocator: Allocator) InitError!LayerDependencyViolation {
        return initClone(
            allocator,
            self.dependency,
            self.source_layer,
            self.target_layer,
            self.policy,
        );
    }

    pub fn deinit(self: *LayerDependencyViolation, allocator: Allocator) void {
        self.dependency.deinit(allocator);
        if (self.source_layer) |value| allocator.free(value);
        if (self.target_layer) |value| allocator.free(value);
        self.* = undefined;
    }

    pub fn eql(self: LayerDependencyViolation, other: LayerDependencyViolation) bool {
        return self.dependency.eql(other.dependency) and
            optionalEqual(self.source_layer, other.source_layer) and
            optionalEqual(self.target_layer, other.target_layer) and
            self.policy == other.policy;
    }
};

fn validateAssignments(
    source_layer: ?[]const u8,
    target_layer: ?[]const u8,
    policy: LayerPolicyKind,
) InitError!void {
    if (source_layer) |value| if (!containsNonWhitespace(value)) return error.EmptyLayerName;
    if (target_layer) |value| if (!containsNonWhitespace(value)) return error.EmptyLayerName;
    switch (policy) {
        .may_only_depend_on_layers, .may_not_depend_on_layers => {
            if (source_layer == null or target_layer == null) return error.InvalidLayerAssignments;
        },
        .unassigned_endpoint => {
            if (source_layer != null and target_layer != null) return error.InvalidLayerAssignments;
        },
    }
}

fn cloneOptional(allocator: Allocator, value: ?[]const u8) Allocator.Error!?[]const u8 {
    return if (value) |bytes| try allocator.dupe(u8, bytes) else null;
}

fn optionalEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn containsNonWhitespace(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n\x0b\x0c").len != 0;
}

fn testEdge(allocator: Allocator) !ProjectedEdge {
    const extraction = @import("../extraction.zig");
    var raw = try extraction.Edge.initWithLocations(
        allocator,
        "src/presentation/api.zig",
        "src/infrastructure/db.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
        &.{.{ .byte_offset = 12, .line = 2, .column = 5 }},
    );
    defer raw.deinit(allocator);
    return ProjectedEdge.init(
        allocator,
        .{ .source_label = raw.source, .target_label = raw.target },
        raw,
    );
}

test "layer dependency violation owns assignments and concrete edge evidence" {
    var edge = try testEdge(std.testing.allocator);
    defer edge.deinit(std.testing.allocator);
    var violation = try LayerDependencyViolation.initClone(
        std.testing.allocator,
        edge,
        "presentation",
        "infrastructure",
        .may_not_depend_on_layers,
    );
    defer violation.deinit(std.testing.allocator);
    var cloned = try violation.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expect(violation.eql(cloned));
    try std.testing.expectEqualStrings("presentation", violation.source_layer.?);
    try std.testing.expectEqual(@as(u32, 2), violation.dependency.evidence()[0].locationItems()[0].line);
    try std.testing.expect(violation.source_layer.?.ptr != cloned.source_layer.?.ptr);
}

test "strict unassigned evidence and policy assignments are validated" {
    var edge = try testEdge(std.testing.allocator);
    defer edge.deinit(std.testing.allocator);
    var strict = try LayerDependencyViolation.initClone(
        std.testing.allocator,
        edge,
        "presentation",
        null,
        .unassigned_endpoint,
    );
    defer strict.deinit(std.testing.allocator);
    try std.testing.expect(strict.target_layer == null);

    try std.testing.expectError(
        error.InvalidLayerAssignments,
        LayerDependencyViolation.initClone(
            std.testing.allocator,
            edge,
            "presentation",
            null,
            .may_only_depend_on_layers,
        ),
    );
    try std.testing.expectError(
        error.InvalidLayerAssignments,
        LayerDependencyViolation.initClone(
            std.testing.allocator,
            edge,
            "presentation",
            "infrastructure",
            .unassigned_endpoint,
        ),
    );
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var edge = try testEdge(allocator);
    defer edge.deinit(allocator);
    var violation = try LayerDependencyViolation.initClone(
        allocator,
        edge,
        "presentation",
        "infrastructure",
        .may_not_depend_on_layers,
    );
    defer violation.deinit(allocator);
    var cloned = try violation.clone(allocator);
    defer cloned.deinit(allocator);
    try std.testing.expect(violation.eql(cloned));
}

test "layer dependency violation cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
