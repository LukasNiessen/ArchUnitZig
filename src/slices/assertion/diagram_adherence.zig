const std = @import("std");

const assertion = @import("../../common/assertion.zig");
const extraction = @import("../../common/extraction.zig");
const projection = @import("../../common/projection.zig");
const slice_violation = @import("../../common/assertion/slice_dependency_violation.zig");
const plantuml = @import("../uml/plantuml.zig");

const Allocator = std.mem.Allocator;
pub const PlantUmlDiagram = plantuml.PlantUmlDiagram;
pub const ProjectedEdge = projection.ProjectedEdge;
pub const ViolationList = assertion.ViolationList;
pub const GatherError = slice_violation.InitError;

pub const DiagramAdherenceOptions = struct {
    ignore_orphan_slices: bool = false,
    ignore_external_slices: bool = false,
};

/// Compares the real and diagram relationship sets. Extra real edges retain evidence; missing real
/// edges deliberately carry none.
pub fn gatherDiagramAdherenceViolations(
    allocator: Allocator,
    edges: []const ProjectedEdge,
    internal_labels: []const []const u8,
    diagram: *const PlantUmlDiagram,
    options: DiagramAdherenceOptions,
) GatherError!ViolationList {
    var result: ViolationList = .{};
    errdefer result.deinit(allocator);

    for (edges) |edge| {
        if (diagram.allows(edge.source_label, edge.target_label)) continue;
        if (options.ignore_external_slices and isPurelyExternal(edge)) continue;
        if (options.ignore_orphan_slices and
            (!diagram.containsComponent(edge.source_label) or
                !diagram.containsComponent(edge.target_label))) continue;
        try appendDiagramViolation(allocator, &result, edge.source_label, edge.target_label, edge);
    }

    for (diagram.dependencyItems()) |expected| {
        if (findDependency(edges, expected.source, expected.target)) |actual| {
            if (!options.ignore_external_slices or !isPurelyExternal(actual)) continue;
            if (!containsLabel(internal_labels, expected.target)) continue;
        } else if (options.ignore_external_slices and
            !containsLabel(internal_labels, expected.target))
        {
            continue;
        }
        try appendDiagramViolation(allocator, &result, expected.source, expected.target, null);
    }
    return result;
}

fn appendDiagramViolation(
    allocator: Allocator,
    destination: *ViolationList,
    source: []const u8,
    target: []const u8,
    dependency: ?ProjectedEdge,
) GatherError!void {
    var payload = try assertion.SliceDependencyViolation.initDiagramClone(
        allocator,
        source,
        target,
        dependency,
    );
    var violation = assertion.Violation.fromSliceDependencyMove(&payload);
    destination.appendMove(allocator, &violation) catch |failure| {
        violation.deinit(allocator);
        return failure;
    };
}

fn findDependency(
    edges: []const ProjectedEdge,
    source: []const u8,
    target: []const u8,
) ?ProjectedEdge {
    for (edges) |edge| {
        if (std.mem.eql(u8, edge.source_label, source) and
            std.mem.eql(u8, edge.target_label, target)) return edge;
    }
    return null;
}

fn containsLabel(labels: []const []const u8, expected: []const u8) bool {
    for (labels) |label| if (std.mem.eql(u8, label, expected)) return true;
    return false;
}

fn isPurelyExternal(edge: ProjectedEdge) bool {
    for (edge.evidence()) |raw| if (!raw.external) return false;
    return true;
}

fn testEdge(
    allocator: Allocator,
    source: []const u8,
    target: []const u8,
    external: bool,
) !ProjectedEdge {
    var raw = try extraction.Edge.init(
        allocator,
        "src/source.zig",
        if (external) target else "src/target.zig",
        external,
        extraction.ImportKinds.initOne(if (external) .named_module else .zig_file),
    );
    defer raw.deinit(allocator);
    return ProjectedEdge.init(allocator, .{ .source_label = source, .target_label = target }, raw);
}

fn testDiagram(allocator: Allocator, text: []const u8) !PlantUmlDiagram {
    var parsed = try plantuml.parsePlantUml(allocator, text);
    return switch (parsed) {
        .diagram => |value| blk: {
            parsed = undefined;
            break :blk value;
        },
        .invalid => error.TestExpectedEqual,
    };
}

test "strict diagram adherence reports extra actual and missing declared relationships" {
    var allowed = try testEdge(std.testing.allocator, "api", "services", false);
    defer allowed.deinit(std.testing.allocator);
    var extra = try testEdge(std.testing.allocator, "api", "retrieval", false);
    defer extra.deinit(std.testing.allocator);
    var external = try testEdge(std.testing.allocator, "api", "json", true);
    defer external.deinit(std.testing.allocator);
    var intended = try testDiagram(std.testing.allocator, "@startuml\n" ++
        "component [api]\ncomponent [services]\ncomponent [models]\n" ++
        "[api] --> [services]\n[services] --> [models]\n@enduml");
    defer intended.deinit(std.testing.allocator);
    var result = try gatherDiagramAdherenceViolations(
        std.testing.allocator,
        &.{ allowed, extra, external },
        &.{ "api", "services", "retrieval", "models" },
        &intended,
        .{},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), result.items().len);
    try std.testing.expect(result.items()[0].slice_dependency.dependency != null);
    try std.testing.expect(result.items()[1].slice_dependency.dependency != null);
    try std.testing.expect(result.items()[2].slice_dependency.dependency == null);
    for (result.items()) |violation| {
        try std.testing.expectEqual(assertion.SliceRuleKind.adhere_to_diagram, violation.slice_dependency.rule);
    }
}

test "external and orphan modifiers ignore only their deliberate relationship classes" {
    var allowed = try testEdge(std.testing.allocator, "api", "services", false);
    defer allowed.deinit(std.testing.allocator);
    var orphan = try testEdge(std.testing.allocator, "api", "retrieval", false);
    defer orphan.deinit(std.testing.allocator);
    var external = try testEdge(std.testing.allocator, "api", "json", true);
    defer external.deinit(std.testing.allocator);
    var intended = try testDiagram(std.testing.allocator, "@startuml\ncomponent [api]\ncomponent [services]\n[api] -> [services]\n@enduml");
    defer intended.deinit(std.testing.allocator);
    var result = try gatherDiagramAdherenceViolations(
        std.testing.allocator,
        &.{ allowed, orphan, external },
        &.{ "api", "services", "retrieval" },
        &intended,
        .{ .ignore_orphan_slices = true, .ignore_external_slices = true },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.passes());
}

test "external modifier cannot hide a projected pair with internal evidence" {
    var mixed = try testEdge(std.testing.allocator, "api", "retrieval", false);
    defer mixed.deinit(std.testing.allocator);
    var external_raw = try extraction.Edge.init(
        std.testing.allocator,
        "src/source.zig",
        "retrieval",
        true,
        extraction.ImportKinds.initOne(.named_module),
    );
    defer external_raw.deinit(std.testing.allocator);
    try mixed.appendEvidence(std.testing.allocator, external_raw);
    var intended = try testDiagram(std.testing.allocator, "@startuml\ncomponent [api]\ncomponent [retrieval]\n@enduml");
    defer intended.deinit(std.testing.allocator);
    var result = try gatherDiagramAdherenceViolations(
        std.testing.allocator,
        &.{mixed},
        &.{ "api", "retrieval" },
        &intended,
        .{ .ignore_external_slices = true },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.items().len);
    try std.testing.expect(result.items()[0].slice_dependency.dependency != null);
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var extra = try testEdge(allocator, "api", "retrieval", false);
    defer extra.deinit(allocator);
    var intended = try testDiagram(allocator, "@startuml\ncomponent [api]\ncomponent [services]\n[api] -> [services]\n@enduml");
    defer intended.deinit(allocator);
    var result = try gatherDiagramAdherenceViolations(
        allocator,
        &.{extra},
        &.{ "api", "retrieval", "services" },
        &intended,
        .{},
    );
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.items().len);
}

test "diagram adherence cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocationFailures, .{});
}
