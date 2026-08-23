const std = @import("std");

const assertion = @import("../../common/assertion.zig");
const dependency_violation = @import("../../common/assertion/external_module_dependency_violation.zig");
const extraction = @import("../../common/extraction.zig");
const matching = @import("../../common/matching.zig");
const projection = @import("../../common/projection.zig");

const Allocator = std.mem.Allocator;

pub const ExternalModuleCategory = enum {
    package_module,
    unresolved_module,
    unavailable_module,
    compiler_module,
    c_header,
    resource,
};

pub const ExternalModuleCategories = std.EnumSet(ExternalModuleCategory);

pub fn defaultExternalModuleCategories() ExternalModuleCategories {
    return ExternalModuleCategories.initMany(&.{
        .package_module,
        .unresolved_module,
        .unavailable_module,
    });
}

/// Whether any concrete evidence behind a projected external edge belongs to an enabled category.
pub fn edgeInCategories(
    edge: projection.ProjectedEdge,
    categories: ExternalModuleCategories,
) bool {
    for (edge.evidence()) |raw| if (rawEdgeInCategories(raw, categories)) return true;
    return false;
}

fn rawEdgeInCategories(raw: extraction.Edge, categories: ExternalModuleCategories) bool {
    if (!raw.external) return false;
    if (raw.target_classes.contains(.compiler)) return categories.contains(.compiler_module);
    if (raw.target_classes.contains(.c_header)) return categories.contains(.c_header);
    if (raw.target_classes.contains(.resource)) return categories.contains(.resource);
    if (!raw.import_kinds.contains(.named_module)) return false;
    if (raw.target_availabilities.contains(.resolved) and categories.contains(.package_module)) return true;
    if (raw.target_availabilities.contains(.unresolved) and categories.contains(.unresolved_module)) return true;
    if ((raw.target_availabilities.contains(.missing) or raw.target_availabilities.contains(.outside_project)) and
        categories.contains(.unavailable_module)) return true;
    return false;
}

/// Pure allowlist/blocklist assertion over selected sources and already projected external edges.
/// Module filters are alternatives (OR).
pub fn gatherExternalModuleDependencyViolations(
    allocator: Allocator,
    edges: []const projection.ProjectedEdge,
    subject_paths: []const []const u8,
    module_filters: []const *const matching.Filter,
    categories: ExternalModuleCategories,
    mood: assertion.Mood,
) dependency_violation.InitError!assertion.ViolationList {
    var result = assertion.ViolationList{};
    errdefer result.deinit(allocator);
    var violating_edges: std.ArrayList(*const projection.ProjectedEdge) = .empty;
    defer violating_edges.deinit(allocator);

    for (subject_paths) |source_path| {
        violating_edges.clearRetainingCapacity();
        for (edges) |*edge| {
            if (!std.mem.eql(u8, source_path, edge.source_label) or !edgeInCategories(edge.*, categories)) continue;
            const matches = try matchesAny(allocator, edge.target_label, module_filters);
            if (mood.holds(matches)) continue;
            try violating_edges.append(allocator, edge);
        }
        if (violating_edges.items.len == 0) continue;
        var payload = try assertion.ExternalModuleDependencyViolation.initClonePointers(
            allocator,
            source_path,
            violating_edges.items,
            mood,
        );
        var violation = assertion.Violation.fromExternalModuleDependencyMove(&payload);
        result.appendMove(allocator, &violation) catch |failure| {
            violation.deinit(allocator);
            return failure;
        };
    }
    return result;
}

fn matchesAny(
    allocator: Allocator,
    path: []const u8,
    filters: []const *const matching.Filter,
) Allocator.Error!bool {
    for (filters) |filter| {
        if (filter.matches(allocator, .{ .path = path }) catch |failure| switch (failure) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MissingDeclarationName => unreachable,
        }) return true;
    }
    return false;
}

fn externalEdge(
    allocator: Allocator,
    source: []const u8,
    target: []const u8,
    class: extraction.TargetClass,
    availability: extraction.TargetAvailability,
    kind: extraction.ImportKind,
) !projection.ProjectedEdge {
    var raw = try extraction.Edge.initClassifiedWithLocations(
        allocator,
        source,
        target,
        true,
        extraction.ImportKinds.initOne(kind),
        class,
        availability,
        &.{},
    );
    defer raw.deinit(allocator);
    return projection.ProjectedEdge.init(
        allocator,
        .{ .source_label = source, .target_label = target },
        raw,
    );
}

test "default categories include packages unresolved and unavailable aliases but exclude compiler targets" {
    const categories = defaultExternalModuleCategories();
    var package = try externalEdge(std.testing.allocator, "client.zig", "http", .external, .resolved, .named_module);
    defer package.deinit(std.testing.allocator);
    var unresolved = try externalEdge(std.testing.allocator, "client.zig", "telemetry", .external, .unresolved, .named_module);
    defer unresolved.deinit(std.testing.allocator);
    var missing = try externalEdge(std.testing.allocator, "client.zig", "missing", .external, .missing, .named_module);
    defer missing.deinit(std.testing.allocator);
    var standard = try externalEdge(std.testing.allocator, "client.zig", "std", .compiler, .resolved, .standard_library);
    defer standard.deinit(std.testing.allocator);

    try std.testing.expect(edgeInCategories(package, categories));
    try std.testing.expect(edgeInCategories(unresolved, categories));
    try std.testing.expect(edgeInCategories(missing, categories));
    try std.testing.expect(!edgeInCategories(standard, categories));
    try std.testing.expect(edgeInCategories(standard, categories.unionWith(ExternalModuleCategories.initOne(.compiler_module))));

    var header = try externalEdge(std.testing.allocator, "client.zig", "sqlite3.h", .c_header, .unresolved, .c_header);
    defer header.deinit(std.testing.allocator);
    var resource = try externalEdge(std.testing.allocator, "client.zig", "missing.json", .resource, .missing, .embedded_file);
    defer resource.deinit(std.testing.allocator);
    try std.testing.expect(!edgeInCategories(header, categories));
    try std.testing.expect(!edgeInCategories(resource, categories));
    try std.testing.expect(edgeInCategories(header, ExternalModuleCategories.initOne(.c_header)));
    try std.testing.expect(edgeInCategories(resource, ExternalModuleCategories.initOne(.resource)));
}

test "external module allowlists and blocklists use OR filters and group by source" {
    var edges = projection.ProjectedEdges{};
    defer edges.deinit(std.testing.allocator);
    var http = try externalEdge(std.testing.allocator, "client.zig", "http", .external, .resolved, .named_module);
    try edges.appendMove(std.testing.allocator, &http);
    var telemetry = try externalEdge(std.testing.allocator, "client.zig", "telemetry", .external, .unresolved, .named_module);
    try edges.appendMove(std.testing.allocator, &telemetry);
    edges.sort();
    var http_filter = try matching.Filter.init(std.testing.allocator, .{ .glob = "http" }, .path, .exact);
    defer http_filter.deinit();
    var telemetry_filter = try matching.Filter.init(std.testing.allocator, .{ .regex = "tele" }, .path, .partial);
    defer telemetry_filter.deinit();

    var positive = try gatherExternalModuleDependencyViolations(
        std.testing.allocator,
        edges.items(),
        &.{"client.zig"},
        &.{&http_filter},
        defaultExternalModuleCategories(),
        .should,
    );
    defer positive.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("telemetry", positive.items()[0].external_module_dependency.items()[0].target_label);

    var negative = try gatherExternalModuleDependencyViolations(
        std.testing.allocator,
        edges.items(),
        &.{"client.zig"},
        &.{ &http_filter, &telemetry_filter },
        defaultExternalModuleCategories(),
        .should_not,
    );
    defer negative.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), negative.items()[0].external_module_dependency.items().len);
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var edge = try externalEdge(allocator, "client.zig", "http", .external, .resolved, .named_module);
    defer edge.deinit(allocator);
    var filter = try matching.Filter.init(allocator, .{ .glob = "http" }, .path, .exact);
    defer filter.deinit();
    var result = try gatherExternalModuleDependencyViolations(
        allocator,
        &.{edge},
        &.{"client.zig"},
        &.{&filter},
        defaultExternalModuleCategories(),
        .should_not,
    );
    defer result.deinit(allocator);
    var cloned = try result.clone(allocator);
    defer cloned.deinit(allocator);
    try std.testing.expect(result.items()[0].eql(cloned.items()[0]));
}

test "external module gathering and result cloning clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
