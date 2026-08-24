const std = @import("std");

const extraction = @import("../../common/extraction.zig");
const projection = @import("../../common/projection.zig");

const Allocator = std.mem.Allocator;
pub const ProjectedEdge = projection.ProjectedEdge;

pub const CalculationError = Allocator.Error || error{
    DuplicateSubjectLabel,
    EmptySubjectLabel,
    DanglingInternalEdge,
};

/// Owned dependency facts for one subject in a projected internal topology.
pub const DependencyMetricInfo = struct {
    identifier: []u8,
    afferent_coupling: usize,
    efferent_coupling: usize,
    instability: f64,
    coupling_factor: f64,

    pub fn clone(self: DependencyMetricInfo, allocator: Allocator) Allocator.Error!DependencyMetricInfo {
        return .{
            .identifier = try allocator.dupe(u8, self.identifier),
            .afferent_coupling = self.afferent_coupling,
            .efferent_coupling = self.efferent_coupling,
            .instability = self.instability,
            .coupling_factor = self.coupling_factor,
        };
    }

    pub fn deinit(self: *DependencyMetricInfo, allocator: Allocator) void {
        allocator.free(self.identifier);
        self.* = undefined;
    }
};

/// Owned, lexically ordered metrics for a projected internal subject universe.
pub const DependencyMetricSnapshot = struct {
    projected_subject_count: usize,
    values: std.ArrayList(DependencyMetricInfo) = .empty,

    pub fn deinit(self: *DependencyMetricSnapshot, allocator: Allocator) void {
        for (self.values.items) |*value| value.deinit(allocator);
        self.values.deinit(allocator);
        self.* = undefined;
    }

    pub fn items(self: *const DependencyMetricSnapshot) []const DependencyMetricInfo {
        return self.values.items;
    }

    pub fn find(self: *const DependencyMetricSnapshot, identifier: []const u8) ?*const DependencyMetricInfo {
        for (self.values.items) |*value| {
            if (std.mem.eql(u8, value.identifier, identifier)) return value;
        }
        return null;
    }
};

/// Calculates coupling over distinct directed projected pairs. `internal_labels` is the complete
/// internal subject universe, including isolated subjects. Purely external edges are ignored.
pub fn calculateDependencyMetrics(
    allocator: Allocator,
    internal_labels: []const []const u8,
    edges: []const ProjectedEdge,
) CalculationError!DependencyMetricSnapshot {
    var label_set = std.StringHashMap(void).init(allocator);
    defer label_set.deinit();
    for (internal_labels) |label| {
        if (label.len == 0) return error.EmptySubjectLabel;
        const entry = try label_set.getOrPut(label);
        if (entry.found_existing) return error.DuplicateSubjectLabel;
    }
    for (edges) |edge| {
        if (!hasInternalEvidence(edge) or std.mem.eql(u8, edge.source_label, edge.target_label)) continue;
        if (!label_set.contains(edge.source_label) or !label_set.contains(edge.target_label)) {
            return error.DanglingInternalEdge;
        }
    }

    var result = DependencyMetricSnapshot{ .projected_subject_count = internal_labels.len };
    errdefer result.deinit(allocator);
    try result.values.ensureTotalCapacity(allocator, internal_labels.len);
    for (internal_labels) |label| {
        var incoming = std.StringHashMap(void).init(allocator);
        defer incoming.deinit();
        var outgoing = std.StringHashMap(void).init(allocator);
        defer outgoing.deinit();
        for (edges) |edge| {
            if (!hasInternalEvidence(edge) or std.mem.eql(u8, edge.source_label, edge.target_label)) continue;
            if (std.mem.eql(u8, edge.source_label, label)) try outgoing.put(edge.target_label, {});
            if (std.mem.eql(u8, edge.target_label, label)) try incoming.put(edge.source_label, {});
        }
        const afferent = incoming.count();
        const efferent = outgoing.count();
        result.values.appendAssumeCapacity(.{
            .identifier = try allocator.dupe(u8, label),
            .afferent_coupling = afferent,
            .efferent_coupling = efferent,
            .instability = instability(afferent, efferent),
            .coupling_factor = couplingFactor(internal_labels.len, afferent, efferent),
        });
    }
    std.mem.sort(DependencyMetricInfo, result.values.items, {}, struct {
        fn lessThan(_: void, left: DependencyMetricInfo, right: DependencyMetricInfo) bool {
            return std.mem.order(u8, left.identifier, right.identifier) == .lt;
        }
    }.lessThan);
    return result;
}

pub fn instability(afferent_coupling: usize, efferent_coupling: usize) f64 {
    const total = afferent_coupling + efferent_coupling;
    if (total == 0) return 0.0;
    return @as(f64, @floatFromInt(efferent_coupling)) / @as(f64, @floatFromInt(total));
}

pub fn couplingFactor(
    projected_subject_count: usize,
    afferent_coupling: usize,
    efferent_coupling: usize,
) f64 {
    if (projected_subject_count <= 1) return 0.0;
    const incident = @as(f64, @floatFromInt(afferent_coupling + efferent_coupling));
    const maximum = 2.0 * @as(f64, @floatFromInt(projected_subject_count - 1));
    return incident / maximum;
}

fn hasInternalEvidence(edge: ProjectedEdge) bool {
    for (edge.evidence()) |evidence| if (!evidence.external) return true;
    return false;
}

fn appendProjected(
    allocator: Allocator,
    edges: *std.ArrayList(ProjectedEdge),
    source: []const u8,
    target: []const u8,
    external: bool,
) !void {
    var raw = try extraction.Edge.init(
        allocator,
        source,
        target,
        external,
        if (external)
            extraction.ImportKinds.initOne(.named_module)
        else
            extraction.ImportKinds.initOne(.zig_file),
    );
    defer raw.deinit(allocator);
    var edge = try ProjectedEdge.init(
        allocator,
        .{ .source_label = source, .target_label = target },
        raw,
    );
    edges.append(allocator, edge) catch |failure| {
        edge.deinit(allocator);
        return failure;
    };
}

fn deinitProjected(allocator: Allocator, edges: *std.ArrayList(ProjectedEdge)) void {
    for (edges.items) |*edge| edge.deinit(allocator);
    edges.deinit(allocator);
}

test "calculates exact directed coupling for cycles and isolated nodes" {
    var edges: std.ArrayList(ProjectedEdge) = .empty;
    defer deinitProjected(std.testing.allocator, &edges);
    try appendProjected(std.testing.allocator, &edges, "a", "b", false);
    try appendProjected(std.testing.allocator, &edges, "a", "c", false);
    try appendProjected(std.testing.allocator, &edges, "b", "c", false);
    try appendProjected(std.testing.allocator, &edges, "c", "a", false);
    try appendProjected(std.testing.allocator, &edges, "a", "std", true);
    var snapshot = try calculateDependencyMetrics(
        std.testing.allocator,
        &.{ "c", "isolated", "a", "b" },
        edges.items,
    );
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), snapshot.projected_subject_count);
    try std.testing.expectEqualStrings("a", snapshot.items()[0].identifier);
    const a = snapshot.find("a").?;
    try std.testing.expectEqual(@as(usize, 1), a.afferent_coupling);
    try std.testing.expectEqual(@as(usize, 2), a.efferent_coupling);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), a.instability, 0.000_001);
    try std.testing.expectEqual(@as(f64, 0.5), a.coupling_factor);
    const b = snapshot.find("b").?;
    try std.testing.expectEqual(@as(f64, 0.5), b.instability);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), b.coupling_factor, 0.000_001);
    const isolated = snapshot.find("isolated").?;
    try std.testing.expectEqual(@as(usize, 0), isolated.afferent_coupling);
    try std.testing.expectEqual(@as(usize, 0), isolated.efferent_coupling);
    try std.testing.expectEqual(@as(f64, 0.0), isolated.instability);
    try std.testing.expectEqual(@as(f64, 0.0), isolated.coupling_factor);
}

test "collapsed parallel evidence and duplicate projected pairs count one neighbor" {
    var raw_one = try extraction.Edge.init(
        std.testing.allocator,
        "src/api/a.zig",
        "src/domain/a.zig",
        false,
        extraction.ImportKinds.initOne(.zig_file),
    );
    defer raw_one.deinit(std.testing.allocator);
    var raw_two = try extraction.Edge.init(
        std.testing.allocator,
        "src/api/b.zig",
        "src/domain/b.zig",
        false,
        extraction.ImportKinds.initOne(.root_module),
    );
    defer raw_two.deinit(std.testing.allocator);
    var first = try ProjectedEdge.init(
        std.testing.allocator,
        .{ .source_label = "api", .target_label = "domain" },
        raw_one,
    );
    try first.appendEvidence(std.testing.allocator, raw_two);
    const second = try ProjectedEdge.init(
        std.testing.allocator,
        .{ .source_label = "api", .target_label = "domain" },
        raw_two,
    );
    var edges = [_]ProjectedEdge{ first, second };
    defer for (&edges) |*edge| edge.deinit(std.testing.allocator);
    var snapshot = try calculateDependencyMetrics(
        std.testing.allocator,
        &.{ "api", "domain" },
        &edges,
    );
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), snapshot.find("api").?.efferent_coupling);
    try std.testing.expectEqual(@as(usize, 1), snapshot.find("domain").?.afferent_coupling);
    try std.testing.expectEqual(@as(f64, 0.5), snapshot.find("api").?.coupling_factor);
}

test "external edges are ignored while dangling internal edges are rejected" {
    var edges: std.ArrayList(ProjectedEdge) = .empty;
    defer deinitProjected(std.testing.allocator, &edges);
    try appendProjected(std.testing.allocator, &edges, "a", "package", true);
    var external_only = try calculateDependencyMetrics(std.testing.allocator, &.{"a"}, edges.items);
    defer external_only.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), external_only.find("a").?.efferent_coupling);

    try appendProjected(std.testing.allocator, &edges, "a", "missing", false);
    try std.testing.expectError(
        error.DanglingInternalEdge,
        calculateDependencyMetrics(std.testing.allocator, &.{"a"}, edges.items),
    );
}

test "label validation and numerical edge cases are explicit" {
    try std.testing.expectError(
        error.EmptySubjectLabel,
        calculateDependencyMetrics(std.testing.allocator, &.{""}, &.{}),
    );
    try std.testing.expectError(
        error.DuplicateSubjectLabel,
        calculateDependencyMetrics(std.testing.allocator, &.{ "same", "same" }, &.{}),
    );
    var one = try calculateDependencyMetrics(std.testing.allocator, &.{"one"}, &.{});
    defer one.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f64, 0.0), one.find("one").?.coupling_factor);
    try std.testing.expectEqual(@as(f64, 0.0), instability(0, 0));
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var edges: std.ArrayList(ProjectedEdge) = .empty;
    defer deinitProjected(allocator, &edges);
    try appendProjected(allocator, &edges, "api", "domain", false);
    var snapshot = try calculateDependencyMetrics(
        allocator,
        &.{ "api", "domain", "isolated" },
        edges.items,
    );
    defer snapshot.deinit(allocator);
    var cloned = try snapshot.find("api").?.clone(allocator);
    defer cloned.deinit(allocator);
}

test "dependency calculation releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
