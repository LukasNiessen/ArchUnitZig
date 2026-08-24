const std = @import("std");

const metric_violation = @import("metric_violation.zig");

const Allocator = std.mem.Allocator;
pub const MetricTargetKind = metric_violation.MetricTargetKind;
pub const MetricValue = metric_violation.MetricValue;
pub const InitError = Allocator.Error || error{ EmptyMetricName, EmptyTargetIdentifier };

/// Owned evidence for a built-in metric value rejected by `shouldSatisfy`. A predicate has no
/// numeric comparison or threshold, so those facts remain exclusive to `MetricViolation`.
pub const MetricPredicateViolation = struct {
    target_identifier: []u8,
    target_kind: MetricTargetKind,
    metric_name: []u8,
    measured: MetricValue,

    pub fn init(
        allocator: Allocator,
        target_identifier: []const u8,
        target_kind: MetricTargetKind,
        metric_name: []const u8,
        measured: MetricValue,
    ) InitError!MetricPredicateViolation {
        if (!containsNonWhitespace(target_identifier)) return error.EmptyTargetIdentifier;
        if (!containsNonWhitespace(metric_name)) return error.EmptyMetricName;
        const owned_target = try allocator.dupe(u8, target_identifier);
        errdefer allocator.free(owned_target);
        return .{
            .target_identifier = owned_target,
            .target_kind = target_kind,
            .metric_name = try allocator.dupe(u8, metric_name),
            .measured = measured,
        };
    }

    pub fn clone(self: MetricPredicateViolation, allocator: Allocator) InitError!MetricPredicateViolation {
        return init(
            allocator,
            self.target_identifier,
            self.target_kind,
            self.metric_name,
            self.measured,
        );
    }

    pub fn deinit(self: *MetricPredicateViolation, allocator: Allocator) void {
        allocator.free(self.target_identifier);
        allocator.free(self.metric_name);
        self.* = undefined;
    }

    pub fn eql(self: MetricPredicateViolation, other: MetricPredicateViolation) bool {
        return std.mem.eql(u8, self.target_identifier, other.target_identifier) and
            self.target_kind == other.target_kind and
            std.mem.eql(u8, self.metric_name, other.metric_name) and
            self.measured.eql(other.measured);
    }
};

fn containsNonWhitespace(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n\x0b\x0c").len != 0;
}

test "metric predicate violations own target name and signed value evidence" {
    var original = try MetricPredicateViolation.init(
        std.testing.allocator,
        "src/model.zig:Order",
        .container,
        "function_balance",
        .{ .signed = -2 },
    );
    defer original.deinit(std.testing.allocator);
    var cloned = try original.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expect(original.eql(cloned));
    try std.testing.expect(original.target_identifier.ptr != cloned.target_identifier.ptr);
    try std.testing.expect(original.metric_name.ptr != cloned.metric_name.ptr);
}

test "metric predicate violations validate their stable identities" {
    try std.testing.expectError(
        error.EmptyTargetIdentifier,
        MetricPredicateViolation.init(
            std.testing.allocator,
            " ",
            .file,
            "imports",
            .{ .unsigned = 1 },
        ),
    );
    try std.testing.expectError(
        error.EmptyMetricName,
        MetricPredicateViolation.init(
            std.testing.allocator,
            "src/main.zig",
            .file,
            "\t",
            .{ .unsigned = 1 },
        ),
    );
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var violation = try MetricPredicateViolation.init(
        allocator,
        "src/main.zig",
        .file,
        "instability",
        .{ .floating = 0.5 },
    );
    defer violation.deinit(allocator);
    var cloned = try violation.clone(allocator);
    defer cloned.deinit(allocator);
    try std.testing.expect(violation.eql(cloned));
}

test "metric predicate violation construction releases allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
