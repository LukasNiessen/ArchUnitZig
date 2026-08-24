const std = @import("std");

const metric_violation = @import("metric_violation.zig");

const Allocator = std.mem.Allocator;
pub const MetricComparison = metric_violation.MetricComparison;
pub const MetricTargetKind = metric_violation.MetricTargetKind;
pub const MetricValue = metric_violation.MetricValue;

pub const ThresholdExpectation = struct {
    comparison: MetricComparison,
    threshold: MetricValue,

    pub fn eql(self: ThresholdExpectation, other: ThresholdExpectation) bool {
        return self.comparison == other.comparison and self.threshold.eql(other.threshold);
    }
};

/// The rule evidence for a custom metric disagreement. Predicate callbacks deliberately carry no
/// function pointer or prose into the violation; the owned metric description explains the policy.
pub const CustomMetricExpectation = union(enum) {
    threshold: ThresholdExpectation,
    predicate,

    pub fn eql(self: CustomMetricExpectation, other: CustomMetricExpectation) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .threshold => |value| value.eql(other.threshold),
            .predicate => true,
        };
    }
};

pub const InitError = Allocator.Error || error{
    EmptyMetricDescription,
    EmptyMetricName,
    EmptyTargetIdentifier,
};

/// Owned, data-only evidence emitted by both custom thresholds and custom predicates.
pub const CustomMetricViolation = struct {
    target_identifier: []u8,
    target_kind: MetricTargetKind,
    metric_name: []u8,
    metric_description: []u8,
    measured: MetricValue,
    expectation: CustomMetricExpectation,

    pub fn initThreshold(
        allocator: Allocator,
        target_identifier: []const u8,
        target_kind: MetricTargetKind,
        metric_name: []const u8,
        metric_description: []const u8,
        measured: MetricValue,
        comparison: MetricComparison,
        threshold: MetricValue,
    ) InitError!CustomMetricViolation {
        return init(
            allocator,
            target_identifier,
            target_kind,
            metric_name,
            metric_description,
            measured,
            .{ .threshold = .{ .comparison = comparison, .threshold = threshold } },
        );
    }

    pub fn initPredicate(
        allocator: Allocator,
        target_identifier: []const u8,
        target_kind: MetricTargetKind,
        metric_name: []const u8,
        metric_description: []const u8,
        measured: MetricValue,
    ) InitError!CustomMetricViolation {
        return init(
            allocator,
            target_identifier,
            target_kind,
            metric_name,
            metric_description,
            measured,
            .predicate,
        );
    }

    pub fn clone(self: CustomMetricViolation, allocator: Allocator) InitError!CustomMetricViolation {
        return init(
            allocator,
            self.target_identifier,
            self.target_kind,
            self.metric_name,
            self.metric_description,
            self.measured,
            self.expectation,
        );
    }

    pub fn deinit(self: *CustomMetricViolation, allocator: Allocator) void {
        allocator.free(self.target_identifier);
        allocator.free(self.metric_name);
        allocator.free(self.metric_description);
        self.* = undefined;
    }

    pub fn eql(self: CustomMetricViolation, other: CustomMetricViolation) bool {
        return std.mem.eql(u8, self.target_identifier, other.target_identifier) and
            self.target_kind == other.target_kind and
            std.mem.eql(u8, self.metric_name, other.metric_name) and
            std.mem.eql(u8, self.metric_description, other.metric_description) and
            self.measured.eql(other.measured) and
            self.expectation.eql(other.expectation);
    }

    fn init(
        allocator: Allocator,
        target_identifier: []const u8,
        target_kind: MetricTargetKind,
        metric_name: []const u8,
        metric_description: []const u8,
        measured: MetricValue,
        expectation: CustomMetricExpectation,
    ) InitError!CustomMetricViolation {
        if (!containsNonWhitespace(target_identifier)) return error.EmptyTargetIdentifier;
        if (!containsNonWhitespace(metric_name)) return error.EmptyMetricName;
        if (!containsNonWhitespace(metric_description)) return error.EmptyMetricDescription;

        const owned_target = try allocator.dupe(u8, target_identifier);
        errdefer allocator.free(owned_target);
        const owned_name = try allocator.dupe(u8, metric_name);
        errdefer allocator.free(owned_name);
        return .{
            .target_identifier = owned_target,
            .target_kind = target_kind,
            .metric_name = owned_name,
            .metric_description = try allocator.dupe(u8, metric_description),
            .measured = measured,
            .expectation = expectation,
        };
    }
};

fn containsNonWhitespace(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n\x0b\x0c").len != 0;
}

test "custom metric violations own descriptions and threshold evidence" {
    var original = try CustomMetricViolation.initThreshold(
        std.testing.allocator,
        "src/model.zig:Order",
        .container,
        "public_api_ratio",
        "ratio of public declarations to all declarations",
        .{ .floating = 0.75 },
        .above_or_equal,
        .{ .floating = 0.8 },
    );
    defer original.deinit(std.testing.allocator);
    var cloned = try original.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expect(original.eql(cloned));
    try std.testing.expect(original.target_identifier.ptr != cloned.target_identifier.ptr);
    try std.testing.expect(original.metric_name.ptr != cloned.metric_name.ptr);
    try std.testing.expect(original.metric_description.ptr != cloned.metric_description.ptr);
}

test "custom predicate evidence is distinct and definitions must be described" {
    var predicate = try CustomMetricViolation.initPredicate(
        std.testing.allocator,
        "domain",
        .module,
        "fan_out_policy",
        "domain modules should expose a narrow dependency surface",
        .{ .unsigned = 4 },
    );
    defer predicate.deinit(std.testing.allocator);
    try std.testing.expectEqual(CustomMetricExpectation.predicate, std.meta.activeTag(predicate.expectation));

    try std.testing.expectError(
        error.EmptyMetricDescription,
        CustomMetricViolation.initPredicate(
            std.testing.allocator,
            "domain",
            .module,
            "fan_out_policy",
            " \t",
            .{ .unsigned = 4 },
        ),
    );
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var violation = try CustomMetricViolation.initThreshold(
        allocator,
        "slice:orders",
        .slice,
        "change_risk",
        "weighted change risk",
        .{ .signed = -2 },
        .below,
        .{ .signed = 0 },
    );
    defer violation.deinit(allocator);
    var cloned = try violation.clone(allocator);
    defer cloned.deinit(allocator);
    try std.testing.expect(violation.eql(cloned));
}

test "custom metric violation construction releases allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
