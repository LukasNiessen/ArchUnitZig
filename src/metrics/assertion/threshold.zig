const std = @import("std");

const common_assertion = @import("../../common/assertion.zig");

pub const MetricComparison = common_assertion.MetricComparison;
pub const MetricValue = common_assertion.MetricValue;
pub const ComparisonError = error{ IncompatibleMetricValues, NonFiniteMetricValue };

/// One comparison implementation shared by every metric family. Integer comparisons never pass
/// through floating point. Mixed integer/float inputs are rejected until a caller chooses a type.
pub fn passes(
    measured: MetricValue,
    comparison: MetricComparison,
    threshold: MetricValue,
) ComparisonError!bool {
    const order = try compare(measured, threshold);
    return switch (comparison) {
        .below => order == .lt,
        .above => order == .gt,
        .equal => order == .eq,
        .below_or_equal => order != .gt,
        .above_or_equal => order != .lt,
    };
}

fn compare(left: MetricValue, right: MetricValue) ComparisonError!std.math.Order {
    return switch (left) {
        .signed => |left_value| switch (right) {
            .signed => |right_value| std.math.order(left_value, right_value),
            .unsigned => |right_value| compareSignedUnsigned(left_value, right_value),
            .floating => error.IncompatibleMetricValues,
        },
        .unsigned => |left_value| switch (right) {
            .signed => |right_value| invert(compareSignedUnsigned(right_value, left_value)),
            .unsigned => |right_value| std.math.order(left_value, right_value),
            .floating => error.IncompatibleMetricValues,
        },
        .floating => |left_value| switch (right) {
            .floating => |right_value| {
                if (!std.math.isFinite(left_value) or !std.math.isFinite(right_value)) {
                    return error.NonFiniteMetricValue;
                }
                return std.math.order(left_value, right_value);
            },
            else => error.IncompatibleMetricValues,
        },
    };
}

fn compareSignedUnsigned(signed: i64, unsigned: u64) std.math.Order {
    if (signed < 0) return .lt;
    return std.math.order(@as(u64, @intCast(signed)), unsigned);
}

fn invert(order: std.math.Order) std.math.Order {
    return switch (order) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
    };
}

test "shared threshold comparison preserves integer boundaries" {
    try std.testing.expect(try passes(.{ .unsigned = 4 }, .below, .{ .unsigned = 5 }));
    try std.testing.expect(!(try passes(.{ .unsigned = 5 }, .below, .{ .unsigned = 5 })));
    try std.testing.expect(try passes(.{ .unsigned = 5 }, .below_or_equal, .{ .unsigned = 5 }));
    try std.testing.expect(try passes(.{ .signed = -1 }, .below, .{ .unsigned = 0 }));
    try std.testing.expect(try passes(.{ .unsigned = 9 }, .above, .{ .signed = -1 }));
    try std.testing.expect(try passes(.{ .signed = 7 }, .equal, .{ .signed = 7 }));
    try std.testing.expect(try passes(.{ .unsigned = std.math.maxInt(u64) }, .above, .{ .signed = std.math.maxInt(i64) }));
}

test "shared threshold comparison requires deliberate float policy" {
    try std.testing.expect(try passes(.{ .floating = 0.5 }, .above_or_equal, .{ .floating = 0.5 }));
    try std.testing.expectError(
        error.IncompatibleMetricValues,
        passes(.{ .floating = 1.0 }, .equal, .{ .unsigned = 1 }),
    );
    try std.testing.expectError(
        error.NonFiniteMetricValue,
        passes(.{ .floating = std.math.nan(f64) }, .equal, .{ .floating = 1.0 }),
    );
}
