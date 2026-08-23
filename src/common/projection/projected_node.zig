const std = @import("std");

const extraction = @import("../extraction.zig");
const mapped_edge = @import("mapped_edge.zig");

const Allocator = std.mem.Allocator;
pub const Edge = extraction.Edge;
pub const ProjectionError = Allocator.Error || mapped_edge.ProjectionError;

/// One owned graph node with independent incoming and outgoing raw evidence.
pub const ProjectedNode = struct {
    label: []const u8,
    incoming: std.ArrayList(Edge) = .empty,
    outgoing: std.ArrayList(Edge) = .empty,

    pub fn init(allocator: Allocator, label: []const u8) ProjectionError!ProjectedNode {
        if (label.len == 0) return error.InvalidProjectionLabel;
        return .{ .label = try allocator.dupe(u8, label) };
    }

    pub fn deinit(self: *ProjectedNode, allocator: Allocator) void {
        allocator.free(self.label);
        deinitEdges(allocator, &self.incoming);
        deinitEdges(allocator, &self.outgoing);
        self.* = undefined;
    }

    pub fn addIncoming(self: *ProjectedNode, allocator: Allocator, edge: Edge) Allocator.Error!void {
        return appendEdgeClone(allocator, &self.incoming, edge);
    }

    pub fn addOutgoing(self: *ProjectedNode, allocator: Allocator, edge: Edge) Allocator.Error!void {
        return appendEdgeClone(allocator, &self.outgoing, edge);
    }

    pub fn incomingItems(self: *const ProjectedNode) []const Edge {
        return self.incoming.items;
    }

    pub fn outgoingItems(self: *const ProjectedNode) []const Edge {
        return self.outgoing.items;
    }

    pub fn sortEvidence(self: *ProjectedNode) void {
        std.mem.sort(Edge, self.incoming.items, {}, rawEdgeLessThan);
        std.mem.sort(Edge, self.outgoing.items, {}, rawEdgeLessThan);
    }
};

/// Owned deterministic projected-node collection.
pub const ProjectedNodes = struct {
    values: std.ArrayList(ProjectedNode) = .empty,

    pub fn deinit(self: *ProjectedNodes, allocator: Allocator) void {
        for (self.values.items) |*node| node.deinit(allocator);
        self.values.deinit(allocator);
        self.* = undefined;
    }

    pub fn items(self: *const ProjectedNodes) []const ProjectedNode {
        return self.values.items;
    }

    pub fn len(self: *const ProjectedNodes) usize {
        return self.values.items.len;
    }

    pub fn find(self: *const ProjectedNodes, label: []const u8) ?*const ProjectedNode {
        for (self.values.items) |*node| {
            if (std.mem.eql(u8, node.label, label)) return node;
        }
        return null;
    }

    pub fn findMutable(self: *ProjectedNodes, label: []const u8) ?*ProjectedNode {
        for (self.values.items) |*node| {
            if (std.mem.eql(u8, node.label, label)) return node;
        }
        return null;
    }

    pub fn ensure(self: *ProjectedNodes, allocator: Allocator, label: []const u8) ProjectionError!*ProjectedNode {
        if (self.findMutable(label)) |node| return node;
        var node = try ProjectedNode.init(allocator, label);
        self.values.append(allocator, node) catch |failure| {
            node.deinit(allocator);
            return failure;
        };
        return &self.values.items[self.values.items.len - 1];
    }

    pub fn sort(self: *ProjectedNodes) void {
        for (self.values.items) |*node| node.sortEvidence();
        std.mem.sort(ProjectedNode, self.values.items, {}, struct {
            fn lessThan(_: void, left: ProjectedNode, right: ProjectedNode) bool {
                return std.mem.order(u8, left.label, right.label) == .lt;
            }
        }.lessThan);
    }
};

fn appendEdgeClone(allocator: Allocator, destination: *std.ArrayList(Edge), edge: Edge) Allocator.Error!void {
    var cloned = try edge.clone(allocator);
    errdefer cloned.deinit(allocator);
    try destination.append(allocator, cloned);
}

fn deinitEdges(allocator: Allocator, edges: *std.ArrayList(Edge)) void {
    for (edges.items) |*edge| edge.deinit(allocator);
    edges.deinit(allocator);
}

fn rawEdgeLessThan(_: void, left: Edge, right: Edge) bool {
    const source_order = std.mem.order(u8, left.source, right.source);
    if (source_order != .eq) return source_order == .lt;
    const target_order = std.mem.order(u8, left.target, right.target);
    if (target_order != .eq) return target_order == .lt;
    return @intFromBool(left.external) < @intFromBool(right.external);
}

test "projected nodes clone labels and evidence" {
    var raw = try Edge.init(
        std.testing.allocator,
        "src/main.zig",
        "src/domain.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
    );
    defer raw.deinit(std.testing.allocator);
    var node = try ProjectedNode.init(std.testing.allocator, "src/main.zig");
    defer node.deinit(std.testing.allocator);
    try node.addOutgoing(std.testing.allocator, raw);

    try std.testing.expectEqualStrings("src/domain.zig", node.outgoingItems()[0].target);
    try std.testing.expect(node.outgoingItems()[0].target.ptr != raw.target.ptr);
}

test "empty projected node labels are rejected" {
    try std.testing.expectError(
        error.InvalidProjectionLabel,
        ProjectedNode.init(std.testing.allocator, ""),
    );
}
