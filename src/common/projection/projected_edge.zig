const std = @import("std");

const extraction = @import("../extraction.zig");
const mapped_edge = @import("mapped_edge.zig");

const Allocator = std.mem.Allocator;
pub const Edge = extraction.Edge;
pub const MappedEdge = mapped_edge.MappedEdge;
pub const ProjectionError = Allocator.Error || mapped_edge.ProjectionError;

/// One owned relabelled dependency with deep-cloned raw evidence.
pub const ProjectedEdge = struct {
    source_label: []const u8,
    target_label: []const u8,
    cumulated_edges: std.ArrayList(Edge) = .empty,

    pub fn init(
        allocator: Allocator,
        mapped: MappedEdge,
        first_evidence: Edge,
    ) ProjectionError!ProjectedEdge {
        try mapped.validate();
        const owned_source = try allocator.dupe(u8, mapped.source_label);
        errdefer allocator.free(owned_source);
        const owned_target = try allocator.dupe(u8, mapped.target_label);
        errdefer allocator.free(owned_target);
        var result = ProjectedEdge{
            .source_label = owned_source,
            .target_label = owned_target,
        };
        try result.appendEvidence(allocator, first_evidence);
        return result;
    }

    pub fn deinit(self: *ProjectedEdge, allocator: Allocator) void {
        allocator.free(self.source_label);
        allocator.free(self.target_label);
        for (self.cumulated_edges.items) |*edge| edge.deinit(allocator);
        self.cumulated_edges.deinit(allocator);
        self.* = undefined;
    }

    pub fn clone(self: ProjectedEdge, allocator: Allocator) ProjectionError!ProjectedEdge {
        std.debug.assert(self.cumulated_edges.items.len != 0);
        var cloned = try ProjectedEdge.init(
            allocator,
            .{ .source_label = self.source_label, .target_label = self.target_label },
            self.cumulated_edges.items[0],
        );
        errdefer cloned.deinit(allocator);
        for (self.cumulated_edges.items[1..]) |edge| try cloned.appendEvidence(allocator, edge);
        return cloned;
    }

    pub fn appendEvidence(self: *ProjectedEdge, allocator: Allocator, edge: Edge) Allocator.Error!void {
        var cloned = try edge.clone(allocator);
        errdefer cloned.deinit(allocator);
        try self.cumulated_edges.append(allocator, cloned);
    }

    pub fn evidence(self: *const ProjectedEdge) []const Edge {
        return self.cumulated_edges.items;
    }

    pub fn sortEvidence(self: *ProjectedEdge) void {
        std.mem.sort(Edge, self.cumulated_edges.items, {}, rawEdgeLessThan);
    }

    pub fn eql(self: ProjectedEdge, other: ProjectedEdge) bool {
        if (!std.mem.eql(u8, self.source_label, other.source_label) or
            !std.mem.eql(u8, self.target_label, other.target_label) or
            self.cumulated_edges.items.len != other.cumulated_edges.items.len)
        {
            return false;
        }
        for (self.cumulated_edges.items, other.cumulated_edges.items) |left, right| {
            if (!left.eql(right)) return false;
        }
        return true;
    }
};

/// Owned deterministic projected-edge collection.
pub const ProjectedEdges = struct {
    values: std.ArrayList(ProjectedEdge) = .empty,

    pub fn deinit(self: *ProjectedEdges, allocator: Allocator) void {
        for (self.values.items) |*edge| edge.deinit(allocator);
        self.values.deinit(allocator);
        self.* = undefined;
    }

    pub fn items(self: *const ProjectedEdges) []const ProjectedEdge {
        return self.values.items;
    }

    pub fn len(self: *const ProjectedEdges) usize {
        return self.values.items.len;
    }

    pub fn findMutable(
        self: *ProjectedEdges,
        source_label: []const u8,
        target_label: []const u8,
    ) ?*ProjectedEdge {
        for (self.values.items) |*edge| {
            if (std.mem.eql(u8, edge.source_label, source_label) and
                std.mem.eql(u8, edge.target_label, target_label)) return edge;
        }
        return null;
    }

    pub fn appendMove(
        self: *ProjectedEdges,
        allocator: Allocator,
        edge: *ProjectedEdge,
    ) Allocator.Error!void {
        try self.values.append(allocator, edge.*);
        edge.* = undefined;
    }

    pub fn sort(self: *ProjectedEdges) void {
        for (self.values.items) |*edge| edge.sortEvidence();
        std.mem.sort(ProjectedEdge, self.values.items, {}, projectedEdgeLessThan);
    }
};

fn projectedEdgeLessThan(_: void, left: ProjectedEdge, right: ProjectedEdge) bool {
    const source_order = std.mem.order(u8, left.source_label, right.source_label);
    if (source_order != .eq) return source_order == .lt;
    return std.mem.order(u8, left.target_label, right.target_label) == .lt;
}

fn rawEdgeLessThan(_: void, left: Edge, right: Edge) bool {
    const source_order = std.mem.order(u8, left.source, right.source);
    if (source_order != .eq) return source_order == .lt;
    const target_order = std.mem.order(u8, left.target, right.target);
    if (target_order != .eq) return target_order == .lt;
    return @intFromBool(left.external) < @intFromBool(right.external);
}

test "projected edges own labels and independent raw evidence" {
    var projected: ProjectedEdge = undefined;
    var raw_source_pointer: [*]const u8 = undefined;
    var mapped_source: [11]u8 = "application".*;
    {
        var raw = try Edge.init(
            std.testing.allocator,
            "src/main.zig",
            "src/domain.zig",
            false,
            extraction.ImportKinds.initOne(.zig_file),
        );
        defer raw.deinit(std.testing.allocator);
        raw_source_pointer = raw.source.ptr;
        projected = try ProjectedEdge.init(
            std.testing.allocator,
            .{ .source_label = &mapped_source, .target_label = "domain" },
            raw,
        );
    }
    defer projected.deinit(std.testing.allocator);
    mapped_source[0] = 'X';

    try std.testing.expectEqualStrings("application", projected.source_label);
    try std.testing.expectEqualStrings("src/main.zig", projected.evidence()[0].source);
    try std.testing.expect(projected.evidence()[0].source.ptr != raw_source_pointer);
}

test "cloned projected edges share no owned storage" {
    var raw = try Edge.init(
        std.testing.allocator,
        "src/main.zig",
        "std",
        true,
        extraction.ImportKinds.initOne(.standard_library),
    );
    defer raw.deinit(std.testing.allocator);
    var original = try ProjectedEdge.init(
        std.testing.allocator,
        .{ .source_label = "application", .target_label = "compiler" },
        raw,
    );
    defer original.deinit(std.testing.allocator);
    var cloned = try original.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expect(original.eql(cloned));
    try std.testing.expect(original.source_label.ptr != cloned.source_label.ptr);
    try std.testing.expect(original.evidence()[0].target.ptr != cloned.evidence()[0].target.ptr);
}
