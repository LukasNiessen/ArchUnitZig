const std = @import("std");
const archunit = @import("archunit");

const Allocator = std.mem.Allocator;
const clean_root = "test/fixtures/acceptance projects/clean";
const violating_root = "test/fixtures/acceptance projects/violating";
const archignore_root = "test/fixtures/archignore";
const analysis_exclusions = [_][]const u8{"testdata/**"};

const app_modules = [_]archunit.ModuleOverride{
    .{ .name = "application", .source_path = "src/application/root.zig" },
    .{ .name = "infrastructure", .source_path = "src/infrastructure/repository.zig" },
    .{ .name = "vendor_pkg", .source_path = "vendor/vendor_pkg/root.zig", .origin = .package },
};
const domain_modules = [_]archunit.ModuleOverride{
    .{ .name = "domain", .source_path = "src/domain/root.zig" },
};
const integration_modules = [_]archunit.ModuleOverride{
    .{ .name = "app", .source_path = "src/presentation/main.zig" },
    .{ .name = "vendor_pkg", .source_path = "vendor/vendor_pkg/root.zig", .origin = .package },
};
const compilation_units = [_]archunit.CompilationUnitOverride{
    .{ .id = "app", .root_source_path = "src/presentation/main.zig", .modules = &app_modules },
    .{ .id = "application", .root_source_path = "src/application/root.zig", .modules = &domain_modules },
    .{ .id = "domain", .root_source_path = "src/domain/root.zig" },
    .{ .id = "infrastructure", .root_source_path = "src/infrastructure/repository.zig", .modules = &domain_modules },
    .{ .id = "integration", .root_source_path = "tests/integration.zig", .modules = &integration_modules },
};

fn checkOptions(root: []const u8) archunit.CheckOptions {
    var options = archunit.CheckOptions.init(std.testing.allocator, std.testing.io);
    options.working_directory = root;
    options.clear_cache = true;
    options.extraction.exclusions = &analysis_exclusions;
    options.extraction.module_resolution = .{ .compilation_units = &compilation_units };
    return options;
}

fn addLayer(
    architecture: *const archunit.LayeredArchitecture,
    name: []const u8,
    pattern: []const u8,
) !archunit.LayeredArchitecture {
    var stage = try architecture.layer(name);
    defer stage.deinit();
    return stage.definedBy(.{ .glob = pattern });
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

fn acceptanceArchitecture(allocator: Allocator) !archunit.LayeredArchitecture {
    var base = try archunit.projectLayers(allocator, .{ .locator = "." });
    defer base.deinit(allocator);
    var presentation = try addLayer(&base, "presentation", "src/presentation/**");
    defer presentation.deinit(allocator);
    var application = try addLayer(&presentation, "application", "src/application/**");
    defer application.deinit(allocator);
    var domain = try addLayer(&application, "domain", "src/domain/**");
    defer domain.deinit(allocator);
    var infrastructure = try addLayer(&domain, "infrastructure", "src/infrastructure/**");
    defer infrastructure.deinit(allocator);
    var presentation_policy = try addAllowlist(&infrastructure, "presentation", &.{"application"});
    defer presentation_policy.deinit(allocator);
    var application_policy = try addAllowlist(&presentation_policy, "application", &.{"domain"});
    defer application_policy.deinit(allocator);
    var domain_policy = try addAllowlist(&application_policy, "domain", &.{});
    defer domain_policy.deinit(allocator);
    return addAllowlist(&domain_policy, "infrastructure", &.{"domain"});
}

fn expectClassifiedEdge(
    graph: *const archunit.Graph,
    source: []const u8,
    target: []const u8,
    kind: archunit.ImportKind,
    class: archunit.TargetClass,
    availability: archunit.TargetAvailability,
    external: bool,
) !*const archunit.Edge {
    const edge = graph.find(source, target) orelse return error.MissingAcceptanceEdge;
    try std.testing.expect(edge.import_kinds.contains(kind));
    try std.testing.expect(edge.target_classes.contains(class));
    try std.testing.expect(edge.target_availabilities.contains(availability));
    try std.testing.expectEqual(external, edge.external);
    return edge;
}

test "public extraction classifies Zig-specific dependencies across spaced paths" {
    var diagnostics = archunit.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();
    const options = checkOptions(clean_root);
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

    const source = "src/presentation/main.zig";
    _ = try expectClassifiedEdge(&graph, source, "src/application/root.zig", .named_module, .internal, .resolved, false);
    _ = try expectClassifiedEdge(&graph, source, "vendor_pkg", .named_module, .external, .resolved, true);
    _ = try expectClassifiedEdge(&graph, source, "std", .standard_library, .compiler, .resolved, true);
    _ = try expectClassifiedEdge(&graph, source, "builtin", .builtin_module, .compiler, .resolved, true);
    _ = try expectClassifiedEdge(&graph, source, source, .root_module, .internal, .resolved, false);
    _ = try expectClassifiedEdge(&graph, source, "src/presentation/data/app.zon", .zon_file, .internal, .resolved, false);
    _ = try expectClassifiedEdge(&graph, source, "src/presentation/assets/banner.txt", .embedded_file, .resource, .resolved, false);
    _ = try expectClassifiedEdge(&graph, source, "acceptance.h", .c_header, .c_header, .unresolved, true);
    const support = try expectClassifiedEdge(
        &graph,
        source,
        "src/presentation/test_support.zig",
        .zig_file,
        .internal,
        .resolved,
        false,
    );
    try std.testing.expectEqual(@as(usize, 2), support.locationItems().len);

    _ = try expectClassifiedEdge(
        &graph,
        "src/application/root.zig",
        "src/domain/root.zig",
        .named_module,
        .internal,
        .resolved,
        false,
    );
    _ = try expectClassifiedEdge(
        &graph,
        "src/infrastructure/repository.zig",
        "src/domain/root.zig",
        .named_module,
        .internal,
        .resolved,
        false,
    );
    _ = try expectClassifiedEdge(
        &graph,
        "tests/integration.zig",
        "src/presentation/main.zig",
        .named_module,
        .internal,
        .resolved,
        false,
    );
    try std.testing.expect(graph.find("src/orphan/unused.zig", "src/orphan/unused.zig") != null);
}

test "clean layers pass and violating twin yields one exact readable disagreement" {
    var architecture = try acceptanceArchitecture(std.testing.allocator);
    defer architecture.deinit(std.testing.allocator);
    var clean = try architecture.check(checkOptions(clean_root));
    defer clean.deinit(std.testing.allocator);
    try std.testing.expect(clean.passes());

    var violations = try architecture.check(checkOptions(violating_root));
    defer violations.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), violations.items().len);
    const violation = violations.items()[0].layer_dependency;
    try std.testing.expectEqual(archunit.LayerPolicyKind.may_only_depend_on_layers, violation.policy);
    try std.testing.expectEqualStrings("presentation", violation.source_layer.?);
    try std.testing.expectEqualStrings("infrastructure", violation.target_layer.?);
    try std.testing.expectEqualStrings("src/presentation/main.zig", violation.dependency.source_label);
    try std.testing.expectEqualStrings("src/infrastructure/repository.zig", violation.dependency.target_label);
    const evidence = violation.dependency.evidence()[0];
    try std.testing.expect(evidence.import_kinds.contains(.named_module));
    try std.testing.expectEqual(@as(u32, 6), evidence.locationItems()[0].line);
    try std.testing.expectEqual(@as(u32, 30), evidence.locationItems()[0].column);

    const sentence = try architecture.description(std.testing.allocator);
    defer std.testing.allocator.free(sentence);
    var result = try archunit.ResultFactory.fromViolations(
        std.testing.allocator,
        violations.items(),
        sentence,
        .{ .color = .{ .mode = .never } },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "Architecture rule failed with 1 violation:\n\n" ++
            "1. Layer dependency violation\n" ++
            "   Rule: project layers should satisfy named dependency policies\n" ++
            "   Dependency: src/presentation/main.zig -> src/infrastructure/repository.zig\n" ++
            "   Source layer: presentation\n" ++
            "   Target layer: infrastructure\n" ++
            "   Reason: layer \"presentation\" may only depend on its declared allowlist\n" ++
            "   Imports:\n" ++
            "     - src/presentation/main.zig:6:30 -> src/infrastructure/repository.zig [named_module]",
        result.message,
    );
}

fn cycleRule(allocator: Allocator) !archunit.FilesHaveNoCycles {
    var project = try archunit.projectFiles(allocator, .{ .locator = "." });
    defer project.deinit();
    var source = try project.inPath(&.{.{ .glob = "src/**/*.zig" }});
    defer source.deinit();
    var positive = try source.should();
    defer positive.deinit();
    return positive.haveNoCycles();
}

test "cycle and orphan acceptance facts distinguish the project twins" {
    var rule = try cycleRule(std.testing.allocator);
    defer rule.deinit(std.testing.allocator);
    var clean = try rule.check(checkOptions(clean_root));
    defer clean.deinit(std.testing.allocator);
    try std.testing.expect(clean.passes());

    var violations = try rule.check(checkOptions(violating_root));
    defer violations.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), violations.items().len);
    const edges = violations.items()[0].cycle.path.items();
    try std.testing.expectEqual(@as(usize, 2), edges.len);
    try std.testing.expectEqualStrings("src/cycles/a.zig", edges[0].source_label);
    try std.testing.expectEqualStrings("src/cycles/b.zig", edges[0].target_label);
    try std.testing.expectEqualStrings("src/cycles/a.zig", edges[1].target_label);
}

fn forbiddenSliceRule(allocator: Allocator) !archunit.SliceDependencyRule {
    var project = try archunit.projectSlices(allocator, .{ .locator = "." });
    defer project.deinit();
    var slices = try project.definedByRegex("^src/([^/]+)/");
    defer slices.deinit();
    var negative = try slices.shouldNot();
    defer negative.deinit();
    return negative.containDependency("presentation", "infrastructure");
}

test "slice acceptance uses the same forbidden edge evidence" {
    var rule = try forbiddenSliceRule(std.testing.allocator);
    defer rule.deinit(std.testing.allocator);
    var clean = try rule.check(checkOptions(clean_root));
    defer clean.deinit(std.testing.allocator);
    try std.testing.expect(clean.passes());

    var violations = try rule.check(checkOptions(violating_root));
    defer violations.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), violations.items().len);
    const violation = violations.items()[0].slice_dependency;
    try std.testing.expectEqualStrings("presentation", violation.source_slice);
    try std.testing.expectEqualStrings("infrastructure", violation.target_slice);
    try std.testing.expectEqual(archunit.Mood.should_not, violation.mood);
    try std.testing.expect(violation.dependency.?.evidence()[0].import_kinds.contains(.named_module));
}

test "malformed source is an exact strict error and a permissive owned graph node" {
    var strict_diagnostics = archunit.ErrorContext.init(std.testing.allocator);
    defer strict_diagnostics.deinit();
    try std.testing.expectError(
        error.ParserFailure,
        archunit.extractProjectGraph(
            std.testing.allocator,
            std.testing.io,
            ".",
            clean_root,
            .{ .module_resolution = .{ .compilation_units = &compilation_units } },
            true,
            &strict_diagnostics,
        ),
    );
    const strict = strict_diagnostics.diagnostic.?;
    try std.testing.expectEqual(archunit.ErrorCategory.technical, strict.category());
    try std.testing.expectEqualStrings("zig.parse_source", strict.operation);
    try std.testing.expectEqualStrings("testdata/malformed/broken.zig", strict.subject.?);
    try std.testing.expectEqual(error.InvalidZigSyntax, strict.cause.?);

    var permissive_diagnostics = archunit.ErrorContext.init(std.testing.allocator);
    defer permissive_diagnostics.deinit();
    var graph = try archunit.extractProjectGraph(
        std.testing.allocator,
        std.testing.io,
        ".",
        clean_root,
        .{
            .strictness = .permissive,
            .module_resolution = .{ .compilation_units = &compilation_units },
        },
        true,
        &permissive_diagnostics,
    );
    defer graph.deinit(std.testing.allocator);
    try std.testing.expect(graph.find(
        "testdata/malformed/broken.zig",
        "testdata/malformed/broken.zig",
    ) != null);
}

test "public enumeration and extraction honor the root archignore fixture" {
    var diagnostics = archunit.ErrorContext.init(std.testing.allocator);
    defer diagnostics.deinit();
    var files = try archunit.enumerateSourceFiles(
        std.testing.allocator,
        std.testing.io,
        archignore_root,
        .{ .exclusions = &.{"testdata/**"} },
        &diagnostics,
    );
    defer files.deinit(std.testing.allocator);
    const expected = [_][]const u8{
        "build.zig.zon",
        "nested/hidden/kept.zig",
        "nested/src/autogen/kept.zig",
        "src/domain/model.zig",
        "src/main.zig",
    };
    try std.testing.expectEqual(expected.len, files.items().len);
    for (expected, files.items()) |wanted, actual| {
        try std.testing.expectEqualStrings(wanted, actual);
    }

    var graph = try archunit.extractProjectGraph(
        std.testing.allocator,
        std.testing.io,
        ".",
        archignore_root,
        .{ .exclusions = &.{"testdata/**"} },
        true,
        &diagnostics,
    );
    defer graph.deinit(std.testing.allocator);
    try std.testing.expect(graph.find("src/main.zig", "src/domain/model.zig") != null);
    try std.testing.expect(graph.find("src/autogen/client.zig", "src/domain/model.zig") == null);
}
