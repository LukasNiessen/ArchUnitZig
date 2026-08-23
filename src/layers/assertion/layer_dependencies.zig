const std = @import("std");

const assertion = @import("../../common/assertion.zig");
const extraction = @import("../../common/extraction.zig");
const matching = @import("../../common/matching.zig");
const projection = @import("../../common/projection.zig");

const Allocator = std.mem.Allocator;
pub const Filter = matching.Filter;
pub const LayerPolicyKind = assertion.LayerPolicyKind;
pub const Pattern = matching.Pattern;
pub const PatternTarget = matching.PatternTarget;
pub const ProjectedEdge = projection.ProjectedEdge;
pub const ScopePattern = assertion.ScopePattern;
pub const ViolationList = assertion.ViolationList;

pub const LayerError = Allocator.Error || error{
    DuplicateLayerName,
    DuplicateLayerPolicy,
    DuplicateLayerTarget,
    EmptyBlocklist,
    EmptyLayerDefinition,
    InvalidLayerName,
    InvalidPattern,
    UnknownLayer,
};

const LayerSelector = struct {
    evidence: ScopePattern,
    filter: Filter,

    fn init(
        allocator: Allocator,
        pattern: Pattern,
        target: PatternTarget,
    ) LayerError!LayerSelector {
        if (pattern.source().len == 0) return error.InvalidPattern;
        const mode: matching.MatchingMode = switch (pattern) {
            .glob => .exact,
            .regex => .partial,
        };
        var filter = Filter.init(allocator, pattern, target, mode) catch |failure| {
            return if (failure == error.OutOfMemory) error.OutOfMemory else error.InvalidPattern;
        };
        errdefer filter.deinit();
        return .{
            .evidence = try ScopePattern.init(allocator, 0, pattern, target, mode),
            .filter = filter,
        };
    }

    fn clone(self: *const LayerSelector, allocator: Allocator) LayerError!LayerSelector {
        const pattern: Pattern = switch (self.evidence.syntax) {
            .glob => .{ .glob = self.evidence.expression },
            .regex => .{ .regex = self.evidence.expression },
            .literal => unreachable,
        };
        return init(allocator, pattern, self.evidence.target);
    }

    fn deinit(self: *LayerSelector, allocator: Allocator) void {
        self.filter.deinit();
        self.evidence.deinit(allocator);
        self.* = undefined;
    }
};

/// Owned ordered definition. Selectors within one definition are alternatives (OR).
pub const LayerDefinition = struct {
    name: []const u8,
    selectors: std.ArrayList(LayerSelector) = .empty,

    pub fn init(
        allocator: Allocator,
        name: []const u8,
        patterns: []const Pattern,
        target: PatternTarget,
    ) LayerError!LayerDefinition {
        if (!validLayerName(name)) return error.InvalidLayerName;
        if (patterns.len == 0) return error.EmptyLayerDefinition;
        if (target != .path and target != .path_without_filename) return error.InvalidPattern;
        var result = LayerDefinition{ .name = try allocator.dupe(u8, name) };
        errdefer result.deinit(allocator);
        try result.selectors.ensureTotalCapacity(allocator, patterns.len);
        for (patterns) |pattern| {
            result.selectors.appendAssumeCapacity(try LayerSelector.init(allocator, pattern, target));
        }
        return result;
    }

    pub fn clone(self: LayerDefinition, allocator: Allocator) LayerError!LayerDefinition {
        var result = LayerDefinition{ .name = try allocator.dupe(u8, self.name) };
        errdefer result.deinit(allocator);
        try result.selectors.ensureTotalCapacity(allocator, self.selectors.items.len);
        for (self.selectors.items) |*selector| {
            result.selectors.appendAssumeCapacity(try selector.clone(allocator));
        }
        return result;
    }

    pub fn deinit(self: *LayerDefinition, allocator: Allocator) void {
        allocator.free(self.name);
        for (self.selectors.items) |*selector| selector.deinit(allocator);
        self.selectors.deinit(allocator);
        self.* = undefined;
    }

    pub fn matches(self: *const LayerDefinition, allocator: Allocator, path: []const u8) Allocator.Error!bool {
        for (self.selectors.items) |*selector| {
            if (selector.filter.matches(allocator, .{ .path = path }) catch |failure| {
                return if (failure == error.OutOfMemory) error.OutOfMemory else unreachable;
            }) return true;
        }
        return false;
    }

    pub fn appendScopeEvidence(
        self: *const LayerDefinition,
        allocator: Allocator,
        destination: *std.ArrayList(ScopePattern),
    ) Allocator.Error!void {
        try destination.ensureUnusedCapacity(allocator, self.selectors.items.len);
        for (self.selectors.items) |selector| destination.appendAssumeCapacity(selector.evidence);
    }

    pub fn eql(self: LayerDefinition, other: LayerDefinition) bool {
        if (!std.mem.eql(u8, self.name, other.name) or
            self.selectors.items.len != other.selectors.items.len) return false;
        for (self.selectors.items, other.selectors.items) |left, right| {
            if (!left.evidence.eql(right.evidence)) return false;
        }
        return true;
    }
};

pub const DependencyPolicyKind = enum { allowlist, blocklist };

/// Owned allowlist or blocklist for one already-declared source layer.
pub const LayerPolicy = struct {
    source_layer: []const u8,
    target_layers: std.ArrayList([]u8) = .empty,
    kind: DependencyPolicyKind,

    pub fn init(
        allocator: Allocator,
        source_layer: []const u8,
        target_layers: []const []const u8,
        kind: DependencyPolicyKind,
    ) LayerError!LayerPolicy {
        if (!validLayerName(source_layer)) return error.InvalidLayerName;
        if (kind == .blocklist and target_layers.len == 0) return error.EmptyBlocklist;
        var result = LayerPolicy{
            .source_layer = try allocator.dupe(u8, source_layer),
            .kind = kind,
        };
        errdefer result.deinit(allocator);
        try result.target_layers.ensureTotalCapacity(allocator, target_layers.len);
        for (target_layers, 0..) |target, index| {
            if (!validLayerName(target)) return error.InvalidLayerName;
            for (target_layers[0..index]) |earlier| {
                if (std.mem.eql(u8, earlier, target)) return error.DuplicateLayerTarget;
            }
            result.target_layers.appendAssumeCapacity(try allocator.dupe(u8, target));
        }
        return result;
    }

    pub fn clone(self: LayerPolicy, allocator: Allocator) LayerError!LayerPolicy {
        return init(allocator, self.source_layer, self.targetItems(), self.kind);
    }

    pub fn deinit(self: *LayerPolicy, allocator: Allocator) void {
        allocator.free(self.source_layer);
        for (self.target_layers.items) |target| allocator.free(target);
        self.target_layers.deinit(allocator);
        self.* = undefined;
    }

    pub fn targetItems(self: *const LayerPolicy) []const []const u8 {
        return self.target_layers.items;
    }

    pub fn containsTarget(self: *const LayerPolicy, target: []const u8) bool {
        for (self.target_layers.items) |candidate| {
            if (std.mem.eql(u8, candidate, target)) return true;
        }
        return false;
    }

    pub fn eql(self: LayerPolicy, other: LayerPolicy) bool {
        if (!std.mem.eql(u8, self.source_layer, other.source_layer) or
            self.kind != other.kind or
            self.target_layers.items.len != other.target_layers.items.len) return false;
        for (self.target_layers.items, other.target_layers.items) |left, right| {
            if (!std.mem.eql(u8, left, right)) return false;
        }
        return true;
    }
};

pub const GatherOptions = struct {
    strict_unassigned_dependencies: bool = false,
};

/// Pure named-layer evaluation over deterministic internal projected edges.
pub fn gatherLayerDependencyViolations(
    allocator: Allocator,
    edges: []const ProjectedEdge,
    layers: []const LayerDefinition,
    policies: []const LayerPolicy,
    options: GatherOptions,
) LayerError!ViolationList {
    try validateConfiguration(layers, policies);
    var result = ViolationList{};
    errdefer result.deinit(allocator);
    const ordered = try allocator.alloc(*const ProjectedEdge, edges.len);
    defer allocator.free(ordered);
    for (edges, ordered) |*edge, *destination| destination.* = edge;
    std.mem.sort(*const ProjectedEdge, ordered, {}, struct {
        fn lessThan(_: void, left: *const ProjectedEdge, right: *const ProjectedEdge) bool {
            const source_order = std.mem.order(u8, left.source_label, right.source_label);
            if (source_order != .eq) return source_order == .lt;
            return std.mem.order(u8, left.target_label, right.target_label) == .lt;
        }
    }.lessThan);
    for (ordered) |edge_pointer| {
        const edge = edge_pointer.*;
        if (edge.evidence()[0].external) continue;
        const source = try findLayer(allocator, edge.source_label, layers);
        const target = try findLayer(allocator, edge.target_label, layers);
        if (source == null or target == null) {
            if (!options.strict_unassigned_dependencies) continue;
            try appendViolation(allocator, &result, edge, source, target, .unassigned_endpoint);
            continue;
        }
        if (std.mem.eql(u8, source.?, target.?)) continue;
        if (violatedPolicy(policies, source.?, target.?)) |policy| {
            try appendViolation(allocator, &result, edge, source, target, policy);
        }
    }
    return result;
}

fn appendViolation(
    allocator: Allocator,
    destination: *ViolationList,
    edge: ProjectedEdge,
    source_layer: ?[]const u8,
    target_layer: ?[]const u8,
    policy: LayerPolicyKind,
) LayerError!void {
    var payload = assertion.LayerDependencyViolation.initClone(
        allocator,
        edge,
        source_layer,
        target_layer,
        policy,
    ) catch |failure| return if (failure == error.OutOfMemory) error.OutOfMemory else unreachable;
    var violation = assertion.Violation.fromLayerDependencyMove(&payload);
    destination.appendMove(allocator, &violation) catch |failure| {
        violation.deinit(allocator);
        return failure;
    };
}

fn findLayer(
    allocator: Allocator,
    path: []const u8,
    layers: []const LayerDefinition,
) Allocator.Error!?[]const u8 {
    for (layers) |*layer| {
        if (try layer.matches(allocator, path)) return layer.name;
    }
    return null;
}

fn violatedPolicy(
    policies: []const LayerPolicy,
    source_layer: []const u8,
    target_layer: []const u8,
) ?LayerPolicyKind {
    for (policies) |*policy| {
        if (policy.kind == .blocklist and
            std.mem.eql(u8, policy.source_layer, source_layer) and
            policy.containsTarget(target_layer)) return .may_not_depend_on_layers;
    }
    for (policies) |*policy| {
        if (policy.kind == .allowlist and std.mem.eql(u8, policy.source_layer, source_layer)) {
            return if (policy.containsTarget(target_layer)) null else .may_only_depend_on_layers;
        }
    }
    return null;
}

fn validateConfiguration(layers: []const LayerDefinition, policies: []const LayerPolicy) LayerError!void {
    for (layers, 0..) |layer, index| {
        for (layers[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, layer.name)) return error.DuplicateLayerName;
        }
    }
    for (policies, 0..) |policy, index| {
        if (findLayerByName(layers, policy.source_layer) == null) return error.UnknownLayer;
        for (policy.target_layers.items) |target| {
            if (findLayerByName(layers, target) == null) return error.UnknownLayer;
        }
        for (policies[0..index]) |earlier| {
            if (earlier.kind == policy.kind and
                std.mem.eql(u8, earlier.source_layer, policy.source_layer))
            {
                return error.DuplicateLayerPolicy;
            }
        }
    }
}

fn findLayerByName(layers: []const LayerDefinition, name: []const u8) ?*const LayerDefinition {
    for (layers) |*layer| if (std.mem.eql(u8, layer.name, name)) return layer;
    return null;
}

fn validLayerName(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n\x0b\x0c").len != 0;
}

fn definition(allocator: Allocator, name: []const u8, pattern: []const u8) !LayerDefinition {
    return LayerDefinition.init(allocator, name, &.{.{ .glob = pattern }}, .path_without_filename);
}

fn projected(allocator: Allocator, source: []const u8, target: []const u8, kind: extraction.ImportKind) !ProjectedEdge {
    return projectedClassified(allocator, source, target, false, kind);
}

fn projectedClassified(
    allocator: Allocator,
    source: []const u8,
    target: []const u8,
    external: bool,
    kind: extraction.ImportKind,
) !ProjectedEdge {
    var raw = try extraction.Edge.init(
        allocator,
        source,
        target,
        external,
        extraction.ImportKinds.initOne(kind),
    );
    defer raw.deinit(allocator);
    return ProjectedEdge.init(
        allocator,
        .{ .source_label = source, .target_label = target },
        raw,
    );
}

test "allowlists reject cross-layer edges while intra-layer and unassigned edges pass" {
    var presentation = try definition(std.testing.allocator, "presentation", "src/presentation");
    defer presentation.deinit(std.testing.allocator);
    var application = try definition(std.testing.allocator, "application", "src/application");
    defer application.deinit(std.testing.allocator);
    var domain = try definition(std.testing.allocator, "domain", "src/domain");
    defer domain.deinit(std.testing.allocator);
    var allowed = try projected(std.testing.allocator, "src/presentation/api.zig", "src/application/service.zig", .zig_file);
    defer allowed.deinit(std.testing.allocator);
    var rejected = try projected(std.testing.allocator, "src/presentation/api.zig", "src/domain/model.zig", .zig_file);
    defer rejected.deinit(std.testing.allocator);
    var intra = try projected(std.testing.allocator, "src/presentation/api.zig", "src/presentation/base.zig", .zig_file);
    defer intra.deinit(std.testing.allocator);
    var unassigned = try projected(std.testing.allocator, "src/presentation/api.zig", "src/support/log.zig", .zig_file);
    defer unassigned.deinit(std.testing.allocator);
    var external = try projectedClassified(std.testing.allocator, "src/presentation/api.zig", "src/domain/model.zig", true, .named_module);
    defer external.deinit(std.testing.allocator);
    var policy = try LayerPolicy.init(std.testing.allocator, "presentation", &.{"application"}, .allowlist);
    defer policy.deinit(std.testing.allocator);

    var result = try gatherLayerDependencyViolations(
        std.testing.allocator,
        &.{ external, unassigned, intra, rejected, allowed },
        &.{ presentation, application, domain },
        &.{policy},
        .{},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.items().len);
    try std.testing.expectEqual(LayerPolicyKind.may_only_depend_on_layers, result.items()[0].layer_dependency.policy);
    try std.testing.expectEqualStrings("domain", result.items()[0].layer_dependency.target_layer.?);
}

test "sealed allowlists reject all cross-layer edges and blocklists take precedence" {
    var services = try definition(std.testing.allocator, "services", "src/services");
    defer services.deinit(std.testing.allocator);
    var models = try definition(std.testing.allocator, "models", "src/models");
    defer models.deinit(std.testing.allocator);
    var edge = try projected(std.testing.allocator, "src/services/orders.zig", "src/models/order.zig", .zig_file);
    defer edge.deinit(std.testing.allocator);
    var sealed = try LayerPolicy.init(std.testing.allocator, "services", &.{}, .allowlist);
    defer sealed.deinit(std.testing.allocator);
    var blocked = try LayerPolicy.init(std.testing.allocator, "services", &.{"models"}, .blocklist);
    defer blocked.deinit(std.testing.allocator);

    var result = try gatherLayerDependencyViolations(
        std.testing.allocator,
        &.{edge},
        &.{ services, models },
        &.{ sealed, blocked },
        .{},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.items().len);
    try std.testing.expectEqual(LayerPolicyKind.may_not_depend_on_layers, result.items()[0].layer_dependency.policy);
}

test "first declared overlapping layer wins deterministically" {
    var broad = try LayerDefinition.init(
        std.testing.allocator,
        "application",
        &.{.{ .glob = "src/**" }},
        .path,
    );
    defer broad.deinit(std.testing.allocator);
    var services = try definition(std.testing.allocator, "services", "src/services");
    defer services.deinit(std.testing.allocator);
    var models = try definition(std.testing.allocator, "models", "src/models");
    defer models.deinit(std.testing.allocator);
    var edge = try projected(std.testing.allocator, "src/services/orders.zig", "src/models/order.zig", .zig_file);
    defer edge.deinit(std.testing.allocator);
    var sealed = try LayerPolicy.init(std.testing.allocator, "application", &.{}, .allowlist);
    defer sealed.deinit(std.testing.allocator);

    var result = try gatherLayerDependencyViolations(
        std.testing.allocator,
        &.{edge},
        &.{ broad, services, models },
        &.{sealed},
        .{},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.passes());
}

test "strict mode reports unassigned endpoints and includes root module edges" {
    var presentation = try definition(std.testing.allocator, "presentation", "src/presentation");
    defer presentation.deinit(std.testing.allocator);
    var application = try definition(std.testing.allocator, "application", "src/application");
    defer application.deinit(std.testing.allocator);
    var alias = try projected(std.testing.allocator, "src/presentation/api.zig", "src/application/root.zig", .root_module);
    defer alias.deinit(std.testing.allocator);
    var support = try projected(std.testing.allocator, "src/presentation/api.zig", "src/support/log.zig", .zig_file);
    defer support.deinit(std.testing.allocator);
    var policy = try LayerPolicy.init(std.testing.allocator, "presentation", &.{"application"}, .allowlist);
    defer policy.deinit(std.testing.allocator);

    var result = try gatherLayerDependencyViolations(
        std.testing.allocator,
        &.{ alias, support },
        &.{ presentation, application },
        &.{policy},
        .{ .strict_unassigned_dependencies = true },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.items().len);
    try std.testing.expectEqual(LayerPolicyKind.unassigned_endpoint, result.items()[0].layer_dependency.policy);
    try std.testing.expect(result.items()[0].layer_dependency.target_layer == null);
}

test "definitions and policies validate names patterns duplicates and references" {
    try std.testing.expectError(
        error.InvalidLayerName,
        LayerDefinition.init(std.testing.allocator, " ", &.{.{ .glob = "src/**" }}, .path),
    );
    try std.testing.expectError(
        error.EmptyLayerDefinition,
        LayerDefinition.init(std.testing.allocator, "api", &.{}, .path),
    );
    try std.testing.expectError(
        error.EmptyBlocklist,
        LayerPolicy.init(std.testing.allocator, "api", &.{}, .blocklist),
    );

    var first = try definition(std.testing.allocator, "api", "src/api");
    defer first.deinit(std.testing.allocator);
    var duplicate = try definition(std.testing.allocator, "api", "legacy/api");
    defer duplicate.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.DuplicateLayerName,
        gatherLayerDependencyViolations(std.testing.allocator, &.{}, &.{ first, duplicate }, &.{}, .{}),
    );
    var unknown = try LayerPolicy.init(std.testing.allocator, "api", &.{"missing"}, .allowlist);
    defer unknown.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.UnknownLayer,
        gatherLayerDependencyViolations(std.testing.allocator, &.{}, &.{first}, &.{unknown}, .{}),
    );
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var presentation = try definition(allocator, "presentation", "src/presentation");
    defer presentation.deinit(allocator);
    var application = try definition(allocator, "application", "src/application");
    defer application.deinit(allocator);
    var edge = try projected(allocator, "src/presentation/api.zig", "src/application/service.zig", .zig_file);
    defer edge.deinit(allocator);
    var policy = try LayerPolicy.init(allocator, "presentation", &.{}, .allowlist);
    defer policy.deinit(allocator);
    var result = try gatherLayerDependencyViolations(
        allocator,
        &.{edge},
        &.{ presentation, application },
        &.{policy},
        .{},
    );
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.items().len);
}

test "layer definitions policies and violations clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
