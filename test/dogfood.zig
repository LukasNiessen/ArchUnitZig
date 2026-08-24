const std = @import("std");
const archunit = @import("archunit");

const Allocator = std.mem.Allocator;
const production_exclusions = [_][]const u8{
    "build.zig",
    "test/**",
};
const fixture_exclusions = [_][]const u8{"testdata/**"};
const all_production_files = [_]archunit.Pattern{
    .{ .glob = "src/*.zig" },
    .{ .glob = "src/**/*.zig" },
};
const common_files = [_]archunit.Pattern{.{ .glob = "src/common/**" }};
const testing_files = [_]archunit.Pattern{
    .{ .glob = "src/testing.zig" },
    .{ .glob = "src/testing/**" },
};

fn productionOptions() archunit.CheckOptions {
    var options = archunit.CheckOptions.init(std.testing.allocator, std.testing.io);
    options.clear_cache = true;
    options.extraction.exclusions = &production_exclusions;
    options.extraction.include_test_imports = false;
    return options;
}

fn fixtureOptions() archunit.CheckOptions {
    var options = archunit.CheckOptions.init(std.testing.allocator, std.testing.io);
    options.working_directory = "test/fixtures/acceptance projects/violating";
    options.clear_cache = true;
    options.extraction.exclusions = &fixture_exclusions;
    return options;
}

fn addLayer(
    architecture: *const archunit.LayeredArchitecture,
    name: []const u8,
    pattern: archunit.Pattern,
) !archunit.LayeredArchitecture {
    var stage = try architecture.layer(name);
    defer stage.deinit();
    return stage.definedBy(pattern);
}

fn addAllowlist(
    architecture: *const archunit.LayeredArchitecture,
    source: []const u8,
    targets: []const []const u8,
) !archunit.LayeredArchitecture {
    var stage = try architecture.whereLayer(source);
    defer stage.deinit();
    return stage.mayOnlyDependOnLayers(targets);
}

fn dogfoodArchitecture(
    allocator: Allocator,
    files_targets: []const []const u8,
) !archunit.LayeredArchitecture {
    var base = try archunit.projectLayers(allocator, .{
        .locator = ".",
        .strict_unassigned_dependencies = true,
    });
    defer base.deinit(allocator);
    var common = try addLayer(&base, "common", .{ .regex = "^src/common/" });
    defer common.deinit(allocator);
    var files = try addLayer(&common, "files", .{ .regex = "^src/files(?:\\.zig|/)" });
    defer files.deinit(allocator);
    var graph = try addLayer(&files, "graph", .{ .regex = "^src/graph(?:\\.zig|/)" });
    defer graph.deinit(allocator);
    var layers = try addLayer(&graph, "layers", .{ .regex = "^src/layers(?:\\.zig|/)" });
    defer layers.deinit(allocator);
    var metrics = try addLayer(&layers, "metrics", .{ .regex = "^src/metrics(?:\\.zig|/)" });
    defer metrics.deinit(allocator);
    var slices = try addLayer(&metrics, "slices", .{ .regex = "^src/slices(?:\\.zig|/)" });
    defer slices.deinit(allocator);
    var testing = try addLayer(&slices, "testing", .{ .regex = "^src/testing(?:\\.zig|/)" });
    defer testing.deinit(allocator);
    var public_root = try addLayer(&testing, "public_root", .{ .glob = "src/root.zig" });
    defer public_root.deinit(allocator);

    var common_policy = try addAllowlist(&public_root, "common", &.{});
    defer common_policy.deinit(allocator);
    var files_policy = try addAllowlist(&common_policy, "files", files_targets);
    defer files_policy.deinit(allocator);
    var graph_policy = try addAllowlist(&files_policy, "graph", &.{"common"});
    defer graph_policy.deinit(allocator);
    var layers_policy = try addAllowlist(&graph_policy, "layers", &.{"common"});
    defer layers_policy.deinit(allocator);
    var metrics_policy = try addAllowlist(&layers_policy, "metrics", &.{"common"});
    defer metrics_policy.deinit(allocator);
    var slices_policy = try addAllowlist(&metrics_policy, "slices", &.{"common"});
    defer slices_policy.deinit(allocator);
    var testing_policy = try addAllowlist(&slices_policy, "testing", &.{"common"});
    defer testing_policy.deinit(allocator);
    return addAllowlist(
        &testing_policy,
        "public_root",
        &.{ "common", "files", "graph", "layers", "metrics", "slices", "testing" },
    );
}

fn dependencyRule(
    allocator: Allocator,
    subjects: []const archunit.Pattern,
    allowed_objects: []const archunit.Pattern,
) !archunit.FilesDependOn {
    var project = try archunit.files(allocator, .{ .locator = "." });
    defer project.deinit();
    var selected = try project.inPath(subjects);
    defer selected.deinit();
    var should = try selected.should();
    defer should.deinit();
    var builder = try should.dependOnFiles();
    defer builder.deinit();
    return builder.inPath(allowed_objects);
}

fn commonExternalRule(
    allocator: Allocator,
    approved_modules: []const archunit.Pattern,
) !archunit.FilesExternalModules {
    var project = try archunit.files(allocator, .{ .locator = "." });
    defer project.deinit();
    var selected = try project.inPath(&common_files);
    defer selected.deinit();
    var should = try selected.should();
    defer should.deinit();
    var builder = try should.dependOnExternalModules();
    defer builder.deinit();
    var compiler_modules = try builder.includingCompilerModules();
    defer compiler_modules.deinit();
    return compiler_modules.matching(approved_modules);
}

fn forbiddenDependencyRule(
    allocator: Allocator,
    forbidden_path: []const u8,
) !archunit.FilesDependOn {
    var project = try archunit.files(allocator, .{ .locator = "." });
    defer project.deinit();
    var production = try project.inPath(&all_production_files);
    defer production.deinit();
    var without_root = try production.except(&.{.{ .glob = "src/root.zig" }});
    defer without_root.deinit();
    var should_not = try without_root.shouldNot();
    defer should_not.deinit();
    var builder = try should_not.dependOnFiles();
    defer builder.deinit();
    return builder.inFile(&.{forbidden_path});
}

fn cycleRule(allocator: Allocator) !archunit.FilesHaveNoCycles {
    var project = try archunit.files(allocator, .{ .locator = "." });
    defer project.deinit();
    var production = try project.inPath(&all_production_files);
    defer production.deinit();
    var should = try production.should();
    defer should.deinit();
    return should.haveNoCycles();
}

fn allNamedFolder(_: Allocator, info: archunit.FileInfo) anyerror!bool {
    return namedFolder(info.path, true);
}

fn graphIsUnnamed(_: Allocator, info: archunit.FileInfo) anyerror!bool {
    return namedFolder(info.path, false);
}

fn namedFolder(path: []const u8, include_graph: bool) bool {
    if (!std.mem.startsWith(u8, path, "src/")) return false;
    const relative = path["src/".len..];
    const separator = std.mem.indexOfScalar(u8, relative, '/') orelse return true;
    const folder = relative[0..separator];
    if (std.mem.eql(u8, folder, "common") or
        std.mem.eql(u8, folder, "files") or
        std.mem.eql(u8, folder, "layers") or
        std.mem.eql(u8, folder, "metrics") or
        std.mem.eql(u8, folder, "slices") or
        std.mem.eql(u8, folder, "testing")) return true;
    return include_graph and std.mem.eql(u8, folder, "graph");
}

fn namedFolderRule(
    allocator: Allocator,
    predicate: archunit.CustomFilePredicate,
    description: []const u8,
) !archunit.FilesAdhereTo {
    var project = try archunit.files(allocator, .{ .locator = "." });
    defer project.deinit();
    var production = try project.inPath(&all_production_files);
    defer production.deinit();
    var should = try production.should();
    defer should.deinit();
    return should.adhereTo(predicate, description);
}

fn expectReportedPath(rule: anytype, violations: *const archunit.ViolationList, path: []const u8) !void {
    const sentence = try rule.description(std.testing.allocator);
    defer std.testing.allocator.free(sentence);
    var result = try archunit.ResultFactory.fromViolations(
        std.testing.allocator,
        violations.items(),
        sentence,
        .{ .color = .{ .mode = .never } },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.passed);
    try std.testing.expect(std.mem.indexOf(u8, result.message, path) != null);
}

test "production corpus exclusions are explicit" {
    try std.testing.expectEqual(@as(usize, 2), production_exclusions.len);
    try std.testing.expectEqualStrings("build.zig", production_exclusions[0]);
    try std.testing.expectEqualStrings("test/**", production_exclusions[1]);

    var diagnostics = archunit.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();
    const options = productionOptions();
    var graph = try archunit.extractProjectGraph(
        std.testing.allocator,
        std.testing.io,
        ".",
        options.working_directory,
        options.extraction,
        true,
        &diagnostics,
    );
    defer graph.deinit(std.testing.allocator);
    try std.testing.expect(graph.find("build.zig", "build.zig") == null);
    try std.testing.expect(graph.find("test/dogfood.zig", "test/dogfood.zig") == null);
    for (graph.items()) |edge| {
        try std.testing.expect(!std.mem.startsWith(u8, edge.source, "test/fixtures/"));
        try std.testing.expect(!std.mem.startsWith(u8, edge.target, "test/fixtures/"));
    }
}

test "common depends only on common internals and approved external modules" {
    var internal_rule = try dependencyRule(
        std.testing.allocator,
        &common_files,
        &common_files,
    );
    defer internal_rule.deinit(std.testing.allocator);
    var internal_result = try internal_rule.check(productionOptions());
    defer internal_result.deinit(std.testing.allocator);
    try std.testing.expect(internal_result.passes());

    var restrictive_internal = try dependencyRule(
        std.testing.allocator,
        &.{.{ .glob = "src/common/error.zig" }},
        &.{.{ .glob = "src/common/assertion/**" }},
    );
    defer restrictive_internal.deinit(std.testing.allocator);
    var internal_violations = try restrictive_internal.check(productionOptions());
    defer internal_violations.deinit(std.testing.allocator);
    try std.testing.expect(!internal_violations.passes());
    try std.testing.expectEqualStrings(
        "src/common/error.zig",
        internal_violations.items()[0].file_dependency.source_path,
    );
    try expectReportedPath(&restrictive_internal, &internal_violations, "src/common/error.zig");

    var external_rule = try commonExternalRule(
        std.testing.allocator,
        &.{ .{ .glob = "std" }, .{ .glob = "regex" } },
    );
    defer external_rule.deinit(std.testing.allocator);
    var external_result = try external_rule.check(productionOptions());
    defer external_result.deinit(std.testing.allocator);
    try std.testing.expect(external_result.passes());

    var restrictive_external = try commonExternalRule(
        std.testing.allocator,
        &.{.{ .glob = "std" }},
    );
    defer restrictive_external.deinit(std.testing.allocator);
    var external_violations = try restrictive_external.check(productionOptions());
    defer external_violations.deinit(std.testing.allocator);
    try std.testing.expect(!external_violations.passes());
    try std.testing.expectEqualStrings(
        "src/common/matching/regex.zig",
        external_violations.items()[0].external_module_dependency.source_path,
    );
    try expectReportedPath(
        &restrictive_external,
        &external_violations,
        "src/common/matching/regex.zig",
    );
}

test "domain layers are independent and root is the only facade" {
    var architecture = try dogfoodArchitecture(std.testing.allocator, &.{"common"});
    defer architecture.deinit(std.testing.allocator);
    var result = try architecture.check(productionOptions());
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.passes());

    var restrictive = try dogfoodArchitecture(std.testing.allocator, &.{});
    defer restrictive.deinit(std.testing.allocator);
    var violations = try restrictive.check(productionOptions());
    defer violations.deinit(std.testing.allocator);
    try std.testing.expect(!violations.passes());
    var concrete_path: ?[]const u8 = null;
    for (violations.items()) |violation| switch (violation) {
        .layer_dependency => |layer| if (std.mem.startsWith(u8, layer.dependency.source_label, "src/files/")) {
            concrete_path = layer.dependency.source_label;
            break;
        },
        else => {},
    };
    try std.testing.expect(concrete_path != null);
    try expectReportedPath(&restrictive, &violations, concrete_path.?);
}

test "testing code reads common violation data only" {
    var rule = try dependencyRule(
        std.testing.allocator,
        &testing_files,
        &.{
            .{ .glob = "src/common/**" },
            .{ .glob = "src/testing.zig" },
            .{ .glob = "src/testing/**" },
        },
    );
    defer rule.deinit(std.testing.allocator);
    var result = try rule.check(productionOptions());
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.passes());

    var restrictive = try dependencyRule(
        std.testing.allocator,
        &.{.{ .glob = "src/testing/cycle_path.zig" }},
        &testing_files,
    );
    defer restrictive.deinit(std.testing.allocator);
    var violations = try restrictive.check(productionOptions());
    defer violations.deinit(std.testing.allocator);
    try std.testing.expect(!violations.passes());
    try std.testing.expectEqualStrings(
        "src/testing/cycle_path.zig",
        violations.items()[0].file_dependency.source_path,
    );
    try expectReportedPath(&restrictive, &violations, "src/testing/cycle_path.zig");
}

test "production code never imports the public root facade" {
    var rule = try forbiddenDependencyRule(std.testing.allocator, "src/root.zig");
    defer rule.deinit(std.testing.allocator);
    var result = try rule.check(productionOptions());
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.passes());

    var control = try forbiddenDependencyRule(
        std.testing.allocator,
        "src/common/projection/projected_cycle.zig",
    );
    defer control.deinit(std.testing.allocator);
    var violations = try control.check(productionOptions());
    defer violations.deinit(std.testing.allocator);
    try std.testing.expect(!violations.passes());
    var found_cycle_path = false;
    for (violations.items()) |violation| switch (violation) {
        .file_dependency => |dependency| {
            if (std.mem.eql(u8, dependency.source_path, "src/testing/cycle_path.zig")) {
                found_cycle_path = true;
                break;
            }
        },
        else => {},
    };
    try std.testing.expect(found_cycle_path);
    try expectReportedPath(&control, &violations, "src/testing/cycle_path.zig");
}

test "production files have no cycles and the violating twin proves the rule" {
    var rule = try cycleRule(std.testing.allocator);
    defer rule.deinit(std.testing.allocator);
    var result = try rule.check(productionOptions());
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.passes());

    var violations = try rule.check(fixtureOptions());
    defer violations.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), violations.items().len);
    try std.testing.expectEqualStrings(
        "src/cycles/a.zig",
        violations.items()[0].cycle.path.items()[0].source_label,
    );
    try expectReportedPath(&rule, &violations, "src/cycles/a.zig");
}

test "every top-level production folder belongs to the architecture" {
    var rule = try namedFolderRule(
        std.testing.allocator,
        allNamedFolder,
        "belong to a named top-level architecture folder",
    );
    defer rule.deinit(std.testing.allocator);
    var result = try rule.check(productionOptions());
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.passes());

    var control = try namedFolderRule(
        std.testing.allocator,
        graphIsUnnamed,
        "belong to a named top-level architecture folder other than graph",
    );
    defer control.deinit(std.testing.allocator);
    var violations = try control.check(productionOptions());
    defer violations.deinit(std.testing.allocator);
    try std.testing.expect(!violations.passes());
    try std.testing.expectEqualStrings(
        "src/graph/fluentapi/project_graph.zig",
        violations.items()[0].custom_file.source_path,
    );
    try expectReportedPath(
        &control,
        &violations,
        "src/graph/fluentapi/project_graph.zig",
    );
}
