const std = @import("std");

const assertion = @import("../../common/assertion.zig");
const custom_calculation = @import("../calculation/custom.zig");

const Allocator = std.mem.Allocator;
pub const MetricPredicate = custom_calculation.CustomMetricPredicate;
pub const MetricPredicateInfo = custom_calculation.CustomMetricInfo;
pub const MetricValue = assertion.MetricValue;

/// Borrowed measured subject passed to the pure built-in predicate evaluator.
pub const MetricPredicateSubject = struct {
    info: MetricPredicateInfo,
    metric_name: []const u8,
    value: MetricValue,
};

/// Applies one arbitrary predicate to already-measured built-in metric subjects. The predicate is
/// invoked exactly once per subject, and callback errors destroy every partial violation.
pub fn gatherMetricPredicateViolations(
    allocator: Allocator,
    subjects: []const MetricPredicateSubject,
    predicate: MetricPredicate,
) anyerror!assertion.ViolationList {
    var result = assertion.ViolationList{};
    errdefer result.deinit(allocator);
    for (subjects) |subject| {
        if (!hasText(subject.metric_name)) return error.EmptyMetricName;
        if (!hasText(subject.info.identifier)) return error.EmptyTargetIdentifier;
        try custom_calculation.validateValue(subject.value);
        if (try predicate.satisfies(allocator, subject.value, subject.info)) continue;
        var payload = try assertion.MetricPredicateViolation.init(
            allocator,
            subject.info.identifier,
            subject.info.target_kind,
            subject.metric_name,
            subject.value,
        );
        var violation = assertion.Violation.fromMetricPredicateMove(&payload);
        result.appendMove(allocator, &violation) catch |failure| {
            violation.deinit(allocator);
            return failure;
        };
    }
    return result;
}

fn hasText(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n\x0b\x0c").len != 0;
}

const first = MetricPredicateSubject{
    .info = .{
        .identifier = "src/main.zig",
        .name = "main.zig",
        .file_path = "src/main.zig",
        .target_kind = .file,
        .syntax_valid = true,
        .structural = .{ .functions = 2 },
        .source_file_count = 1,
    },
    .metric_name = "functions",
    .value = .{ .unsigned = 2 },
};

const second = MetricPredicateSubject{
    .info = .{
        .identifier = "src/model.zig:Model",
        .name = "Model",
        .qualified_name = "Model",
        .file_path = "src/model.zig",
        .target_kind = .container,
        .syntax_valid = true,
        .structural = .{ .fields = 1 },
        .source_file_count = 1,
    },
    .metric_name = "signed_balance",
    .value = .{ .signed = -1 },
};

const Observation = struct {
    calls: *usize,

    fn satisfies(
        self: *const Observation,
        _: Allocator,
        value: MetricValue,
        info: MetricPredicateInfo,
    ) !bool {
        self.calls.* += 1;
        return switch (value) {
            .unsigned => |number| info.structural.?.functions == number,
            .signed => |number| number >= 0,
            .floating => |number| number < 1.0,
        };
    }
};

test "built-in metric predicates receive measured values and complete subject context" {
    var calls: usize = 0;
    const observation = Observation{ .calls = &calls };
    var result = try gatherMetricPredicateViolations(
        std.testing.allocator,
        &.{ first, second },
        MetricPredicate.fromContext(Observation, &observation, Observation.satisfies),
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), calls);
    try std.testing.expectEqual(@as(usize, 1), result.items().len);
    const violation = result.items()[0].metric_predicate;
    try std.testing.expectEqualStrings("src/model.zig:Model", violation.target_identifier);
    try std.testing.expectEqualStrings("signed_balance", violation.metric_name);
    try std.testing.expectEqual(@as(i64, -1), violation.measured.signed);
}

fn failSecond(_: Allocator, _: MetricValue, info: MetricPredicateInfo) !bool {
    if (info.target_kind == .container) return error.PredicateAnalysisFailed;
    return false;
}

test "predicate errors clean up partial violations and propagate unchanged" {
    try std.testing.expectError(
        error.PredicateAnalysisFailed,
        gatherMetricPredicateViolations(
            std.testing.allocator,
            &.{ first, second },
            MetricPredicate.fromStateless(failSecond),
        ),
    );
}

fn alwaysTrue(_: Allocator, _: MetricValue, _: MetricPredicateInfo) !bool {
    return true;
}

test "predicate inputs validate identifiers names and finite values before invocation" {
    var invalid_name = first;
    invalid_name.metric_name = " ";
    try std.testing.expectError(
        error.EmptyMetricName,
        gatherMetricPredicateViolations(
            std.testing.allocator,
            &.{invalid_name},
            MetricPredicate.fromStateless(alwaysTrue),
        ),
    );
    var invalid_identifier = first;
    invalid_identifier.info.identifier = "\t";
    try std.testing.expectError(
        error.EmptyTargetIdentifier,
        gatherMetricPredicateViolations(
            std.testing.allocator,
            &.{invalid_identifier},
            MetricPredicate.fromStateless(alwaysTrue),
        ),
    );
    var non_finite = first;
    non_finite.value = .{ .floating = std.math.nan(f64) };
    try std.testing.expectError(
        error.NonFiniteMetricValue,
        gatherMetricPredicateViolations(
            std.testing.allocator,
            &.{non_finite},
            MetricPredicate.fromStateless(alwaysTrue),
        ),
    );
}

fn alwaysFalse(_: Allocator, _: MetricValue, _: MetricPredicateInfo) !bool {
    return false;
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var result = try gatherMetricPredicateViolations(
        allocator,
        &.{ first, second },
        MetricPredicate.fromStateless(alwaysFalse),
    );
    defer result.deinit(allocator);
}

test "built-in predicate gathering releases allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
