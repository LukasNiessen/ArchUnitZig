const std = @import("std");

const assertion = @import("../../common/assertion.zig");
const common_error = @import("../../common/error.zig");
const extraction = @import("../../common/extraction.zig");
const fluentapi = @import("../../common/fluentapi.zig");
const matching = @import("../../common/matching.zig");
const projection = @import("../../common/projection.zig");
const layer_assertion = @import("../assertion/layer_dependencies.zig");

const Allocator = std.mem.Allocator;
pub const CheckOptions = fluentapi.CheckOptions;
pub const DependencyPolicyKind = layer_assertion.DependencyPolicyKind;
pub const Graph = extraction.Graph;
pub const LayerDefinition = layer_assertion.LayerDefinition;
pub const LayerPolicy = layer_assertion.LayerPolicy;
pub const Pattern = matching.Pattern;
pub const PatternTarget = matching.PatternTarget;

pub const BuilderError = layer_assertion.LayerError || error{InvalidProjectPath};

pub const ProjectLayerOptions = struct {
    locator: ?[]const u8 = null,
    strict_unassigned_dependencies: bool = false,
};

/// Owned immutable-in-behavior terminal and continuation point for a named-layer policy.
pub const LayeredArchitecture = struct {
    allocator: Allocator,
    project_locator: ?[]u8 = null,
    strict_unassigned_dependencies: bool = false,
    definitions: std.ArrayList(LayerDefinition) = .empty,
    policies: std.ArrayList(LayerPolicy) = .empty,

    fn init(allocator: Allocator, options: ProjectLayerOptions) BuilderError!LayeredArchitecture {
        if (options.locator) |locator| {
            if (!containsNonWhitespace(locator)) return error.InvalidProjectPath;
        }
        return .{
            .allocator = allocator,
            .project_locator = if (options.locator) |locator| try allocator.dupe(u8, locator) else null,
            .strict_unassigned_dependencies = options.strict_unassigned_dependencies,
        };
    }

    pub fn clone(self: *const LayeredArchitecture) BuilderError!LayeredArchitecture {
        var result = LayeredArchitecture{
            .allocator = self.allocator,
            .project_locator = if (self.project_locator) |locator| try self.allocator.dupe(u8, locator) else null,
            .strict_unassigned_dependencies = self.strict_unassigned_dependencies,
        };
        errdefer result.deinit(self.allocator);
        try result.definitions.ensureTotalCapacity(self.allocator, self.definitions.items.len);
        for (self.definitions.items) |definition| {
            result.definitions.appendAssumeCapacity(try definition.clone(self.allocator));
        }
        try result.policies.ensureTotalCapacity(self.allocator, self.policies.items.len);
        for (self.policies.items) |policy| {
            result.policies.appendAssumeCapacity(try policy.clone(self.allocator));
        }
        return result;
    }

    /// The allocator argument belongs to the `Checkable` contract. Builder storage always uses the
    /// allocator captured at `projectLayers`, even after moving through a differently boxed handle.
    pub fn deinit(self: *LayeredArchitecture, allocator: Allocator) void {
        _ = allocator;
        if (self.project_locator) |locator| self.allocator.free(locator);
        for (self.definitions.items) |*definition| definition.deinit(self.allocator);
        self.definitions.deinit(self.allocator);
        for (self.policies.items) |*policy| policy.deinit(self.allocator);
        self.policies.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn layer(
        self: *const LayeredArchitecture,
        name: []const u8,
    ) BuilderError!LayerDefinitionBuilder {
        if (!validLayerName(name)) return error.InvalidLayerName;
        if (self.findDefinition(name) != null) return error.DuplicateLayerName;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        return .{
            .architecture = try self.clone(),
            .layer_name = owned_name,
        };
    }

    pub fn whereLayer(
        self: *const LayeredArchitecture,
        name: []const u8,
    ) BuilderError!LayerDependencyRuleBuilder {
        if (!validLayerName(name)) return error.InvalidLayerName;
        if (self.findDefinition(name) == null) return error.UnknownLayer;
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        return .{
            .architecture = try self.clone(),
            .layer_name = owned_name,
        };
    }

    pub fn description(self: *const LayeredArchitecture, allocator: Allocator) Allocator.Error![]u8 {
        _ = self;
        return allocator.dupe(u8, "project layers should satisfy named dependency policies");
    }

    pub fn check(
        self: *const LayeredArchitecture,
        options: CheckOptions,
    ) anyerror!assertion.ViolationList {
        var diagnostics = common_error.ErrorContext.init(options.allocator);
        defer diagnostics.deinit();
        var graph = try extraction.extractProjectGraph(
            options.allocator,
            options.io,
            self.project_locator,
            options.working_directory,
            options.extraction,
            options.clear_cache,
            &diagnostics,
        );
        defer graph.deinit(options.allocator);
        return self.checkGraph(options, &graph);
    }

    fn checkGraph(
        self: *const LayeredArchitecture,
        options: CheckOptions,
        graph: *const Graph,
    ) anyerror!assertion.ViolationList {
        var nodes = try projection.projectToNodes(options.allocator, graph, .{});
        defer nodes.deinit(options.allocator);
        var edges = try projection.projectEdges(options.allocator, graph, projection.perInternalEdge());
        defer edges.deinit(options.allocator);
        var result = assertion.ViolationList{};
        errdefer result.deinit(options.allocator);

        for (self.definitions.items) |*definition| {
            if (!self.hasSourcePolicy(definition.name)) continue;
            var matched_count: usize = 0;
            for (nodes.items()) |node| {
                if (try definition.matches(options.allocator, node.label)) matched_count += 1;
            }
            var evidence: std.ArrayList(assertion.ScopePattern) = .empty;
            defer evidence.deinit(options.allocator);
            if (matched_count == 0) try definition.appendScopeEvidence(options.allocator, &evidence);
            if (try assertion.guardEmptyTest(
                options.allocator,
                matched_count,
                options.allow_empty_tests,
                "layers.source",
                evidence.items,
                .should,
            )) |guarded| {
                var movable = guarded;
                defer movable.deinit(options.allocator);
                try result.appendListMove(options.allocator, &movable);
            }
        }

        var policy_violations = try layer_assertion.gatherLayerDependencyViolations(
            options.allocator,
            edges.items(),
            self.definitions.items,
            self.policies.items,
            .{ .strict_unassigned_dependencies = self.strict_unassigned_dependencies },
        );
        defer policy_violations.deinit(options.allocator);
        try result.appendListMove(options.allocator, &policy_violations);
        return result;
    }

    pub fn definitionItems(self: *const LayeredArchitecture) []const LayerDefinition {
        return self.definitions.items;
    }

    pub fn policyItems(self: *const LayeredArchitecture) []const LayerPolicy {
        return self.policies.items;
    }

    fn findDefinition(self: *const LayeredArchitecture, name: []const u8) ?*const LayerDefinition {
        for (self.definitions.items) |*definition| {
            if (std.mem.eql(u8, definition.name, name)) return definition;
        }
        return null;
    }

    fn hasSourcePolicy(self: *const LayeredArchitecture, name: []const u8) bool {
        for (self.policies.items) |policy| {
            if (std.mem.eql(u8, policy.source_layer, name)) return true;
        }
        return false;
    }
};

/// Owned stage awaiting the selector for one new layer.
pub const LayerDefinitionBuilder = struct {
    architecture: LayeredArchitecture,
    layer_name: []u8,

    pub fn deinit(self: *LayerDefinitionBuilder) void {
        const allocator = self.architecture.allocator;
        allocator.free(self.layer_name);
        self.architecture.deinit(allocator);
        self.* = undefined;
    }

    pub fn definedBy(
        self: *const LayerDefinitionBuilder,
        pattern: Pattern,
    ) BuilderError!LayeredArchitecture {
        return self.complete(pattern, .path);
    }

    pub fn definedByFolder(
        self: *const LayerDefinitionBuilder,
        pattern: Pattern,
    ) BuilderError!LayeredArchitecture {
        return self.complete(pattern, .path_without_filename);
    }

    fn complete(
        self: *const LayerDefinitionBuilder,
        pattern: Pattern,
        target: PatternTarget,
    ) BuilderError!LayeredArchitecture {
        var result = try self.architecture.clone();
        errdefer result.deinit(result.allocator);
        var definition = try LayerDefinition.init(
            result.allocator,
            self.layer_name,
            &.{pattern},
            target,
        );
        result.definitions.append(result.allocator, definition) catch |failure| {
            definition.deinit(result.allocator);
            return failure;
        };
        return result;
    }
};

/// Owned stage awaiting an allowlist or blocklist for one declared source layer.
pub const LayerDependencyRuleBuilder = struct {
    architecture: LayeredArchitecture,
    layer_name: []u8,

    pub fn deinit(self: *LayerDependencyRuleBuilder) void {
        const allocator = self.architecture.allocator;
        allocator.free(self.layer_name);
        self.architecture.deinit(allocator);
        self.* = undefined;
    }

    pub fn mayOnlyDependOnLayers(
        self: *const LayerDependencyRuleBuilder,
        target_layers: []const []const u8,
    ) BuilderError!LayeredArchitecture {
        return self.complete(target_layers, .allowlist);
    }

    pub fn mayNotDependOnLayers(
        self: *const LayerDependencyRuleBuilder,
        target_layers: []const []const u8,
    ) BuilderError!LayeredArchitecture {
        return self.complete(target_layers, .blocklist);
    }

    fn complete(
        self: *const LayerDependencyRuleBuilder,
        target_layers: []const []const u8,
        kind: DependencyPolicyKind,
    ) BuilderError!LayeredArchitecture {
        if (self.hasPolicy(kind)) return error.DuplicateLayerPolicy;
        for (target_layers, 0..) |target, index| {
            if (self.architecture.findDefinition(target) == null) return error.UnknownLayer;
            for (target_layers[0..index]) |earlier| {
                if (std.mem.eql(u8, earlier, target)) return error.DuplicateLayerTarget;
            }
        }
        var result = try self.architecture.clone();
        errdefer result.deinit(result.allocator);
        var policy = try LayerPolicy.init(result.allocator, self.layer_name, target_layers, kind);
        result.policies.append(result.allocator, policy) catch |failure| {
            policy.deinit(result.allocator);
            return failure;
        };
        return result;
    }

    fn hasPolicy(self: *const LayerDependencyRuleBuilder, kind: DependencyPolicyKind) bool {
        for (self.architecture.policies.items) |policy| {
            if (policy.kind == kind and std.mem.eql(u8, policy.source_layer, self.layer_name)) return true;
        }
        return false;
    }
};

pub fn projectLayers(
    allocator: Allocator,
    options: ProjectLayerOptions,
) BuilderError!LayeredArchitecture {
    return LayeredArchitecture.init(allocator, options);
}

pub fn layers(allocator: Allocator, options: ProjectLayerOptions) BuilderError!LayeredArchitecture {
    return projectLayers(allocator, options);
}

fn validLayerName(value: []const u8) bool {
    return containsNonWhitespace(value);
}

fn containsNonWhitespace(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n\x0b\x0c").len != 0;
}

fn graphEdge(
    allocator: Allocator,
    graph: *Graph,
    source: []const u8,
    target: []const u8,
) !void {
    try graph.add(
        allocator,
        source,
        target,
        false,
        extraction.ImportKinds.initOne(.zig_file),
    );
}

fn sampleArchitecture(allocator: Allocator) !LayeredArchitecture {
    var base = try projectLayers(allocator, .{});
    defer base.deinit(allocator);
    var presentation_stage = try base.layer("presentation");
    defer presentation_stage.deinit();
    var presentation = try presentation_stage.definedByFolder(.{ .glob = "src/presentation" });
    defer presentation.deinit(allocator);
    var application_stage = try presentation.layer("application");
    defer application_stage.deinit();
    var application = try application_stage.definedByFolder(.{ .glob = "src/application" });
    defer application.deinit(allocator);
    var domain_stage = try application.layer("domain");
    defer domain_stage.deinit();
    return domain_stage.definedByFolder(.{ .glob = "src/domain" });
}

test "layer and policy builders are branchable and validate names and references early" {
    var base = try projectLayers(std.testing.allocator, .{ .locator = "fixture" });
    defer base.deinit(std.testing.allocator);
    var presentation_stage = try base.layer("presentation");
    defer presentation_stage.deinit();
    var presentation = try presentation_stage.definedByFolder(.{ .glob = "src/presentation" });
    defer presentation.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), base.definitionItems().len);
    try std.testing.expectEqual(@as(usize, 1), presentation.definitionItems().len);

    try std.testing.expectError(error.InvalidLayerName, base.layer(" "));
    try std.testing.expectError(error.DuplicateLayerName, presentation.layer("presentation"));
    try std.testing.expectError(error.UnknownLayer, presentation.whereLayer("missing"));

    var domain_stage = try presentation.layer("domain");
    defer domain_stage.deinit();
    var domain = try domain_stage.definedBy(.{ .glob = "src/domain/**" });
    defer domain.deinit(std.testing.allocator);
    var policy_stage = try domain.whereLayer("presentation");
    defer policy_stage.deinit();
    var allowed = try policy_stage.mayOnlyDependOnLayers(&.{"domain"});
    defer allowed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), domain.policyItems().len);
    try std.testing.expectEqual(@as(usize, 1), allowed.policyItems().len);
    try std.testing.expectError(error.UnknownLayer, policy_stage.mayOnlyDependOnLayers(&.{"missing"}));
    try std.testing.expectError(error.DuplicateLayerTarget, policy_stage.mayOnlyDependOnLayers(&.{ "domain", "domain" }));
    try std.testing.expectError(error.EmptyBlocklist, policy_stage.mayNotDependOnLayers(&.{}));
}

test "fluent policy check applies blocklist precedence sealed layers and strict assignment" {
    var architecture = try sampleArchitecture(std.testing.allocator);
    defer architecture.deinit(std.testing.allocator);
    var presentation_policy = try architecture.whereLayer("presentation");
    defer presentation_policy.deinit();
    var allowed = try presentation_policy.mayOnlyDependOnLayers(&.{"application"});
    defer allowed.deinit(std.testing.allocator);
    var block_stage = try allowed.whereLayer("presentation");
    defer block_stage.deinit();
    var blocked = try block_stage.mayNotDependOnLayers(&.{"domain"});
    defer blocked.deinit(std.testing.allocator);
    var domain_policy = try blocked.whereLayer("domain");
    defer domain_policy.deinit();
    var complete = try domain_policy.mayOnlyDependOnLayers(&.{});
    defer complete.deinit(std.testing.allocator);
    complete.strict_unassigned_dependencies = true;

    var graph: Graph = .{};
    defer graph.deinit(std.testing.allocator);
    try graphEdge(std.testing.allocator, &graph, "src/presentation/api.zig", "src/application/service.zig");
    try graphEdge(std.testing.allocator, &graph, "src/presentation/api.zig", "src/domain/model.zig");
    try graphEdge(std.testing.allocator, &graph, "src/domain/model.zig", "src/application/service.zig");
    try graphEdge(std.testing.allocator, &graph, "src/application/service.zig", "src/support/log.zig");
    graph.sort();

    var result = try complete.checkGraph(CheckOptions.init(std.testing.allocator, std.testing.io), &graph);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), result.items().len);
    try std.testing.expectEqual(assertion.LayerPolicyKind.unassigned_endpoint, result.items()[0].layer_dependency.policy);
    try std.testing.expectEqual(assertion.LayerPolicyKind.may_only_depend_on_layers, result.items()[1].layer_dependency.policy);
    try std.testing.expectEqual(assertion.LayerPolicyKind.may_not_depend_on_layers, result.items()[2].layer_dependency.policy);
}

test "only empty policy-source layers use the shared guard" {
    var architecture = try sampleArchitecture(std.testing.allocator);
    defer architecture.deinit(std.testing.allocator);
    var policy_stage = try architecture.whereLayer("presentation");
    defer policy_stage.deinit();
    var policy = try policy_stage.mayOnlyDependOnLayers(&.{"application"});
    defer policy.deinit(std.testing.allocator);
    var graph: Graph = .{};
    defer graph.deinit(std.testing.allocator);
    try graphEdge(std.testing.allocator, &graph, "src/domain/model.zig", "src/domain/model.zig");

    var rejected = try policy.checkGraph(CheckOptions.init(std.testing.allocator, std.testing.io), &graph);
    defer rejected.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), rejected.items().len);
    try std.testing.expectEqual(assertion.Violation.Kind.empty_test, rejected.items()[0].kind());
    try std.testing.expectEqualStrings("layers.source", rejected.items()[0].empty_test.rule_id);

    var options = CheckOptions.init(std.testing.allocator, std.testing.io);
    options.allow_empty_tests = true;
    var allowed = try policy.checkGraph(options, &graph);
    defer allowed.deinit(std.testing.allocator);
    try std.testing.expect(allowed.passes());
}

test "layered architecture moves into Checkable with its description and owner allocator" {
    var architecture = try sampleArchitecture(std.testing.allocator);
    var erased = try fluentapi.Checkable.fromMove(std.testing.allocator, &architecture);
    defer erased.deinit();
    const sentence = try erased.description(std.testing.allocator);
    defer std.testing.allocator.free(sentence);
    try std.testing.expectEqualStrings(
        "project layers should satisfy named dependency policies",
        sentence,
    );
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var architecture = try sampleArchitecture(allocator);
    defer architecture.deinit(allocator);
    var policy_stage = try architecture.whereLayer("presentation");
    defer policy_stage.deinit();
    var policy = try policy_stage.mayOnlyDependOnLayers(&.{"application"});
    defer policy.deinit(allocator);
    var cloned = try policy.clone();
    defer cloned.deinit(allocator);
    var graph: Graph = .{};
    defer graph.deinit(allocator);
    try graphEdge(allocator, &graph, "src/presentation/api.zig", "src/domain/model.zig");
    var result = try cloned.checkGraph(CheckOptions.init(allocator, std.testing.io), &graph);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.items().len);
}

test "layer fluent builders checks and clones clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
