const std = @import("std");

const Allocator = std.mem.Allocator;

/// Numeric representation shared by built-in and custom metric families. Keeping integer values
/// tagged avoids silently losing precision by routing structural counts through `f64`.
pub const MetricValue = union(enum) {
    signed: i64,
    unsigned: u64,
    floating: f64,

    pub fn eql(self: MetricValue, other: MetricValue) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .signed => |value| value == other.signed,
            .unsigned => |value| value == other.unsigned,
            .floating => |value| @as(u64, @bitCast(value)) == @as(u64, @bitCast(other.floating)),
        };
    }
};

pub const MetricComparison = enum {
    below,
    above,
    equal,
    below_or_equal,
    above_or_equal,
};

pub const MetricTargetKind = enum {
    file,
    declaration,
    container,
    module,
    slice,
};

pub const InitError = Allocator.Error || error{ EmptyMetricName, EmptyTargetIdentifier };

/// Owned, data-only metric disagreement. Presentation remains in the testing layer.
pub const MetricViolation = struct {
    target_identifier: []u8,
    target_kind: MetricTargetKind,
    metric_name: []u8,
    measured: MetricValue,
    comparison: MetricComparison,
    threshold: MetricValue,

    pub fn init(
        allocator: Allocator,
        target_identifier: []const u8,
        target_kind: MetricTargetKind,
        metric_name: []const u8,
        measured: MetricValue,
        comparison: MetricComparison,
        threshold: MetricValue,
    ) InitError!MetricViolation {
        if (!containsNonWhitespace(target_identifier)) return error.EmptyTargetIdentifier;
        if (!containsNonWhitespace(metric_name)) return error.EmptyMetricName;
        const owned_target = try allocator.dupe(u8, target_identifier);
        errdefer allocator.free(owned_target);
        return .{
            .target_identifier = owned_target,
            .target_kind = target_kind,
            .metric_name = try allocator.dupe(u8, metric_name),
            .measured = measured,
            .comparison = comparison,
            .threshold = threshold,
        };
    }

    pub fn clone(self: MetricViolation, allocator: Allocator) InitError!MetricViolation {
        return init(
            allocator,
            self.target_identifier,
            self.target_kind,
            self.metric_name,
            self.measured,
            self.comparison,
            self.threshold,
        );
    }

    pub fn deinit(self: *MetricViolation, allocator: Allocator) void {
        allocator.free(self.target_identifier);
        allocator.free(self.metric_name);
        self.* = undefined;
    }

    pub fn eql(self: MetricViolation, other: MetricViolation) bool {
        return std.mem.eql(u8, self.target_identifier, other.target_identifier) and
            self.target_kind == other.target_kind and
            std.mem.eql(u8, self.metric_name, other.metric_name) and
            self.measured.eql(other.measured) and
            self.comparison == other.comparison and
            self.threshold.eql(other.threshold);
    }
};

fn containsNonWhitespace(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n\x0b\x0c").len != 0;
}

test "metric violations own integer-safe structured evidence" {
    var original = try MetricViolation.init(
        std.testing.allocator,
        "src/model.zig:Order",
        .container,
        "functions",
        .{ .unsigned = 7 },
        .below_or_equal,
        .{ .unsigned = 5 },
    );
    defer original.deinit(std.testing.allocator);
    var cloned = try original.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expect(original.eql(cloned));
    try std.testing.expect(original.target_identifier.ptr != cloned.target_identifier.ptr);
    try std.testing.expect(original.metric_name.ptr != cloned.metric_name.ptr);
}

test "metric violations reject blank identities and names" {
    try std.testing.expectError(
        error.EmptyTargetIdentifier,
        MetricViolation.init(
            std.testing.allocator,
            "\t",
            .file,
            "tokens",
            .{ .unsigned = 1 },
            .below,
            .{ .unsigned = 2 },
        ),
    );
    try std.testing.expectError(
        error.EmptyMetricName,
        MetricViolation.init(
            std.testing.allocator,
            "src/main.zig",
            .file,
            " ",
            .{ .unsigned = 1 },
            .below,
            .{ .unsigned = 2 },
        ),
    );
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var original = try MetricViolation.init(
        allocator,
        "src/model.zig:Model",
        .container,
        "fields",
        .{ .unsigned = 3 },
        .below,
        .{ .unsigned = 2 },
    );
    defer original.deinit(allocator);
    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);
    try std.testing.expect(original.eql(cloned));
}

test "metric violation construction and cloning release allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
