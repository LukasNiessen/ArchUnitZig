const std = @import("std");

const extraction = @import("../../common/extraction.zig");

const Allocator = std.mem.Allocator;
pub const ImportKinds = extraction.ImportKinds;
pub const TargetClasses = extraction.TargetClasses;
pub const TargetAvailabilities = extraction.TargetAvailabilities;

/// One owned, stable node in a renderer-independent graph report.
pub const GraphReportNode = struct {
    id: []const u8,
    label: []const u8,

    pub fn init(allocator: Allocator, id: []const u8, label: []const u8) Allocator.Error!GraphReportNode {
        const owned_id = try allocator.dupe(u8, id);
        errdefer allocator.free(owned_id);
        return .{
            .id = owned_id,
            .label = try allocator.dupe(u8, label),
        };
    }

    pub fn clone(self: GraphReportNode, allocator: Allocator) Allocator.Error!GraphReportNode {
        return init(allocator, self.id, self.label);
    }

    pub fn deinit(self: *GraphReportNode, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        self.* = undefined;
    }

    pub fn eql(self: GraphReportNode, other: GraphReportNode) bool {
        return std.mem.eql(u8, self.id, other.id) and std.mem.eql(u8, self.label, other.label);
    }
};

/// One owned, possibly aggregated edge between report-node IDs.
pub const GraphReportEdge = struct {
    source: []const u8,
    target: []const u8,
    count: usize,
    external: bool,
    import_kinds: ImportKinds,
    target_classes: TargetClasses,
    target_availabilities: TargetAvailabilities,

    pub fn init(
        allocator: Allocator,
        source: []const u8,
        target: []const u8,
        count: usize,
        external: bool,
        import_kinds: ImportKinds,
        target_classes: TargetClasses,
        target_availabilities: TargetAvailabilities,
    ) Allocator.Error!GraphReportEdge {
        const owned_source = try allocator.dupe(u8, source);
        errdefer allocator.free(owned_source);
        return .{
            .source = owned_source,
            .target = try allocator.dupe(u8, target),
            .count = count,
            .external = external,
            .import_kinds = import_kinds,
            .target_classes = target_classes,
            .target_availabilities = target_availabilities,
        };
    }

    pub fn clone(self: GraphReportEdge, allocator: Allocator) Allocator.Error!GraphReportEdge {
        return init(
            allocator,
            self.source,
            self.target,
            self.count,
            self.external,
            self.import_kinds,
            self.target_classes,
            self.target_availabilities,
        );
    }

    pub fn deinit(self: *GraphReportEdge, allocator: Allocator) void {
        allocator.free(self.source);
        allocator.free(self.target);
        self.* = undefined;
    }

    pub fn eql(self: GraphReportEdge, other: GraphReportEdge) bool {
        return std.mem.eql(u8, self.source, other.source) and
            std.mem.eql(u8, self.target, other.target) and
            self.count == other.count and
            self.external == other.external and
            self.import_kinds.eql(other.import_kinds) and
            self.target_classes.eql(other.target_classes) and
            self.target_availabilities.eql(other.target_availabilities);
    }
};

pub const GraphReportSummary = struct {
    node_count: usize,
    edge_count: usize,
    raw_edge_count: usize,
    external_edge_count: usize,
};

/// Fully owned report input shared by every graph renderer.
pub const GraphReportSnapshot = struct {
    title: []const u8,
    nodes: []GraphReportNode,
    edges: []GraphReportEdge,
    summary: GraphReportSummary,

    pub fn init(
        allocator: Allocator,
        title: []const u8,
        nodes: []const GraphReportNode,
        edges: []const GraphReportEdge,
        summary: GraphReportSummary,
    ) Allocator.Error!GraphReportSnapshot {
        const owned_title = try allocator.dupe(u8, title);
        errdefer allocator.free(owned_title);
        const owned_nodes = try cloneNodes(allocator, nodes);
        errdefer deinitNodes(allocator, owned_nodes);
        return .{
            .title = owned_title,
            .nodes = owned_nodes,
            .edges = try cloneEdges(allocator, edges),
            .summary = summary,
        };
    }

    pub fn clone(self: GraphReportSnapshot, allocator: Allocator) Allocator.Error!GraphReportSnapshot {
        return init(allocator, self.title, self.nodes, self.edges, self.summary);
    }

    pub fn deinit(self: *GraphReportSnapshot, allocator: Allocator) void {
        allocator.free(self.title);
        deinitNodes(allocator, self.nodes);
        deinitEdges(allocator, self.edges);
        self.* = undefined;
    }

    pub fn eql(self: GraphReportSnapshot, other: GraphReportSnapshot) bool {
        if (!std.mem.eql(u8, self.title, other.title) or
            !std.meta.eql(self.summary, other.summary) or
            self.nodes.len != other.nodes.len or
            self.edges.len != other.edges.len) return false;

        for (self.nodes, other.nodes) |left, right| {
            if (!left.eql(right)) return false;
        }
        for (self.edges, other.edges) |left, right| {
            if (!left.eql(right)) return false;
        }
        return true;
    }
};

fn cloneNodes(allocator: Allocator, nodes: []const GraphReportNode) Allocator.Error![]GraphReportNode {
    const result = try allocator.alloc(GraphReportNode, nodes.len);
    errdefer allocator.free(result);
    var initialized: usize = 0;
    errdefer for (result[0..initialized]) |*node| node.deinit(allocator);
    for (nodes) |node| {
        result[initialized] = try node.clone(allocator);
        initialized += 1;
    }
    return result;
}

fn cloneEdges(allocator: Allocator, edges: []const GraphReportEdge) Allocator.Error![]GraphReportEdge {
    const result = try allocator.alloc(GraphReportEdge, edges.len);
    errdefer allocator.free(result);
    var initialized: usize = 0;
    errdefer for (result[0..initialized]) |*edge| edge.deinit(allocator);
    for (edges) |edge| {
        result[initialized] = try edge.clone(allocator);
        initialized += 1;
    }
    return result;
}

fn deinitNodes(allocator: Allocator, nodes: []GraphReportNode) void {
    for (nodes) |*node| node.deinit(allocator);
    allocator.free(nodes);
}

fn deinitEdges(allocator: Allocator, edges: []GraphReportEdge) void {
    for (edges) |*edge| edge.deinit(allocator);
    allocator.free(edges);
}

fn exampleSnapshot(allocator: Allocator) !GraphReportSnapshot {
    var node = try GraphReportNode.init(allocator, "n0", "src/main.zig");
    defer node.deinit(allocator);
    var edge = try GraphReportEdge.init(
        allocator,
        "n0",
        "n0",
        1,
        false,
        ImportKinds.initOne(.zig_file),
        TargetClasses.initOne(.internal),
        TargetAvailabilities.initOne(.resolved),
    );
    defer edge.deinit(allocator);
    return GraphReportSnapshot.init(allocator, "Architecture", &.{node}, &.{edge}, .{
        .node_count = 1,
        .edge_count = 1,
        .raw_edge_count = 1,
        .external_edge_count = 0,
    });
}

test "snapshot deeply owns values and clones independently" {
    var snapshot = try exampleSnapshot(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);
    var cloned = try snapshot.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expect(snapshot.eql(cloned));
    try std.testing.expect(snapshot.title.ptr != cloned.title.ptr);
    try std.testing.expect(snapshot.nodes[0].label.ptr != cloned.nodes[0].label.ptr);
    try std.testing.expect(snapshot.edges[0].source.ptr != cloned.edges[0].source.ptr);

    @constCast(cloned.nodes[0].label)[0] = 'S';
    try std.testing.expect(!snapshot.eql(cloned));
    try std.testing.expectEqualStrings("src/main.zig", snapshot.nodes[0].label);
}

test "snapshot construction cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        struct {
            fn exercise(allocator: Allocator) !void {
                var snapshot = try exampleSnapshot(allocator);
                defer snapshot.deinit(allocator);
            }
        }.exercise,
        .{},
    );
}
