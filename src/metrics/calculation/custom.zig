const std = @import("std");

const assertion = @import("../../common/assertion.zig");
const threshold_assertion = @import("../assertion/threshold.zig");
const structural = @import("../extraction/structural.zig");

const Allocator = std.mem.Allocator;
pub const MetricComparison = assertion.MetricComparison;
pub const MetricTargetKind = assertion.MetricTargetKind;
pub const MetricValue = assertion.MetricValue;
pub const StructuralMetrics = structural.StructuralMetrics;

/// Scalar dependency facts that are safe to expose after a file/module/slice projection. The
/// identifier lives in `CustomMetricInfo`; no owned dependency snapshot is exposed to callbacks.
pub const CustomDependencyFacts = struct {
    afferent_coupling: usize,
    efferent_coupling: usize,
    instability: f64,
    coupling_factor: f64,
};

/// Borrowed callback view. Slices remain valid only for the callback invocation. Structural and
/// dependency values are copied scalars; AST nodes, token buffers, and source bytes never cross
/// this boundary.
pub const CustomMetricInfo = struct {
    identifier: []const u8,
    name: []const u8,
    qualified_name: ?[]const u8 = null,
    file_path: ?[]const u8 = null,
    target_kind: MetricTargetKind,
    syntax_valid: ?bool = null,
    structural: ?StructuralMetrics = null,
    dependency: ?CustomDependencyFacts = null,
    source_file_count: usize = 0,
};

/// Type-erased custom calculation. `context` is borrowed and must outlive every invocation made
/// through this value or a builder/rule that stores a copy of it.
pub const CustomMetricCalculation = struct {
    context: ?*const anyopaque,
    calculate_fn: *const fn (
        context: ?*const anyopaque,
        allocator: Allocator,
        info: CustomMetricInfo,
    ) anyerror!MetricValue,

    pub fn init(
        context: ?*const anyopaque,
        calculate_fn: *const fn (
            context: ?*const anyopaque,
            allocator: Allocator,
            info: CustomMetricInfo,
        ) anyerror!MetricValue,
    ) CustomMetricCalculation {
        return .{ .context = context, .calculate_fn = calculate_fn };
    }

    pub fn fromStateless(
        comptime calculate_fn: *const fn (allocator: Allocator, info: CustomMetricInfo) anyerror!MetricValue,
    ) CustomMetricCalculation {
        return .{
            .context = null,
            .calculate_fn = struct {
                fn calculate(
                    _: ?*const anyopaque,
                    allocator: Allocator,
                    info: CustomMetricInfo,
                ) anyerror!MetricValue {
                    return calculate_fn(allocator, info);
                }
            }.calculate,
        };
    }

    pub fn fromContext(
        comptime Context: type,
        context: *const Context,
        comptime calculate_fn: *const fn (
            context: *const Context,
            allocator: Allocator,
            info: CustomMetricInfo,
        ) anyerror!MetricValue,
    ) CustomMetricCalculation {
        return .{
            .context = context,
            .calculate_fn = struct {
                fn calculate(
                    raw_context: ?*const anyopaque,
                    allocator: Allocator,
                    info: CustomMetricInfo,
                ) anyerror!MetricValue {
                    const typed: *const Context = @ptrCast(@alignCast(raw_context.?));
                    return calculate_fn(typed, allocator, info);
                }
            }.calculate,
        };
    }

    pub fn calculate(
        self: CustomMetricCalculation,
        allocator: Allocator,
        info: CustomMetricInfo,
    ) anyerror!MetricValue {
        return self.calculate_fn(self.context, allocator, info);
    }
};

/// Type-erased arbitrary custom assertion. Its context has the same borrowed lifetime contract as
/// `CustomMetricCalculation`.
pub const CustomMetricPredicate = struct {
    context: ?*const anyopaque,
    predicate_fn: *const fn (
        context: ?*const anyopaque,
        allocator: Allocator,
        value: MetricValue,
        info: CustomMetricInfo,
    ) anyerror!bool,

    pub fn init(
        context: ?*const anyopaque,
        predicate_fn: *const fn (
            context: ?*const anyopaque,
            allocator: Allocator,
            value: MetricValue,
            info: CustomMetricInfo,
        ) anyerror!bool,
    ) CustomMetricPredicate {
        return .{ .context = context, .predicate_fn = predicate_fn };
    }

    pub fn fromStateless(
        comptime predicate_fn: *const fn (
            allocator: Allocator,
            value: MetricValue,
            info: CustomMetricInfo,
        ) anyerror!bool,
    ) CustomMetricPredicate {
        return .{
            .context = null,
            .predicate_fn = struct {
                fn predicate(
                    _: ?*const anyopaque,
                    allocator: Allocator,
                    value: MetricValue,
                    info: CustomMetricInfo,
                ) anyerror!bool {
                    return predicate_fn(allocator, value, info);
                }
            }.predicate,
        };
    }

    pub fn fromContext(
        comptime Context: type,
        context: *const Context,
        comptime predicate_fn: *const fn (
            context: *const Context,
            allocator: Allocator,
            value: MetricValue,
            info: CustomMetricInfo,
        ) anyerror!bool,
    ) CustomMetricPredicate {
        return .{
            .context = context,
            .predicate_fn = struct {
                fn predicate(
                    raw_context: ?*const anyopaque,
                    allocator: Allocator,
                    value: MetricValue,
                    info: CustomMetricInfo,
                ) anyerror!bool {
                    const typed: *const Context = @ptrCast(@alignCast(raw_context.?));
                    return predicate_fn(typed, allocator, value, info);
                }
            }.predicate,
        };
    }

    pub fn satisfies(
        self: CustomMetricPredicate,
        allocator: Allocator,
        value: MetricValue,
        info: CustomMetricInfo,
    ) anyerror!bool {
        return self.predicate_fn(self.context, allocator, value, info);
    }
};

/// Borrowed definition passed to pure calculation functions. Fluent builders own cloned name and
/// description storage and keep the callback context borrowed.
pub const CustomMetricDefinition = struct {
    name: []const u8,
    description: []const u8,
    calculation: CustomMetricCalculation,
};

pub const CustomMetricMeasurement = struct {
    target_identifier: []u8,
    target_kind: MetricTargetKind,
    value: MetricValue,

    pub fn deinit(self: *CustomMetricMeasurement, allocator: Allocator) void {
        allocator.free(self.target_identifier);
        self.* = undefined;
    }
};

pub const CustomMetricMeasurements = struct {
    values: std.ArrayList(CustomMetricMeasurement) = .empty,

    pub fn deinit(self: *CustomMetricMeasurements, allocator: Allocator) void {
        for (self.values.items) |*value| value.deinit(allocator);
        self.values.deinit(allocator);
        self.* = undefined;
    }

    pub fn items(self: *const CustomMetricMeasurements) []const CustomMetricMeasurement {
        return self.values.items;
    }
};

pub const ValidationError = error{
    EmptyMetricDescription,
    EmptyMetricName,
    EmptyTargetIdentifier,
    NonFiniteMetricValue,
};

/// Calculates a custom value once per borrowed subject and returns independently owned evidence.
pub fn measure(
    allocator: Allocator,
    infos: []const CustomMetricInfo,
    definition: CustomMetricDefinition,
) anyerror!CustomMetricMeasurements {
    try validateDefinition(definition);
    var result = CustomMetricMeasurements{};
    errdefer result.deinit(allocator);
    try result.values.ensureTotalCapacity(allocator, infos.len);
    for (infos) |info| {
        try validateInfo(info);
        const value = try definition.calculation.calculate(allocator, info);
        try validateValue(value);
        result.values.appendAssumeCapacity(.{
            .target_identifier = try allocator.dupe(u8, info.identifier),
            .target_kind = info.target_kind,
            .value = value,
        });
    }
    return result;
}

/// Applies the shared threshold comparator without recalculating a subject or converting integers
/// through floating point.
pub fn gatherThresholdViolations(
    allocator: Allocator,
    infos: []const CustomMetricInfo,
    definition: CustomMetricDefinition,
    comparison: MetricComparison,
    threshold: MetricValue,
) anyerror!assertion.ViolationList {
    try validateDefinition(definition);
    try validateValue(threshold);
    var result = assertion.ViolationList{};
    errdefer result.deinit(allocator);
    for (infos) |info| {
        try validateInfo(info);
        const value = try definition.calculation.calculate(allocator, info);
        try validateValue(value);
        if (try threshold_assertion.passes(value, comparison, threshold)) continue;
        var payload = try assertion.CustomMetricViolation.initThreshold(
            allocator,
            info.identifier,
            info.target_kind,
            definition.name,
            definition.description,
            value,
            comparison,
            threshold,
        );
        var violation = assertion.Violation.fromCustomMetricMove(&payload);
        result.appendMove(allocator, &violation) catch |failure| {
            violation.deinit(allocator);
            return failure;
        };
    }
    return result;
}

/// Calculates and asserts each subject while its borrowed context is still alive. Callback errors
/// abort the check and destroy every violation already produced.
pub fn gatherPredicateViolations(
    allocator: Allocator,
    infos: []const CustomMetricInfo,
    definition: CustomMetricDefinition,
    predicate: CustomMetricPredicate,
) anyerror!assertion.ViolationList {
    try validateDefinition(definition);
    var result = assertion.ViolationList{};
    errdefer result.deinit(allocator);
    for (infos) |info| {
        try validateInfo(info);
        const value = try definition.calculation.calculate(allocator, info);
        try validateValue(value);
        if (try predicate.satisfies(allocator, value, info)) continue;
        var payload = try assertion.CustomMetricViolation.initPredicate(
            allocator,
            info.identifier,
            info.target_kind,
            definition.name,
            definition.description,
            value,
        );
        var violation = assertion.Violation.fromCustomMetricMove(&payload);
        result.appendMove(allocator, &violation) catch |failure| {
            violation.deinit(allocator);
            return failure;
        };
    }
    return result;
}

pub fn validateValue(value: MetricValue) ValidationError!void {
    switch (value) {
        .floating => |number| if (!std.math.isFinite(number)) return error.NonFiniteMetricValue,
        else => {},
    }
}

fn validateDefinition(definition: CustomMetricDefinition) ValidationError!void {
    if (!containsNonWhitespace(definition.name)) return error.EmptyMetricName;
    if (!containsNonWhitespace(definition.description)) return error.EmptyMetricDescription;
}

fn validateInfo(info: CustomMetricInfo) ValidationError!void {
    if (!containsNonWhitespace(info.identifier)) return error.EmptyTargetIdentifier;
}

fn containsNonWhitespace(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n\x0b\x0c").len != 0;
}

const file_info = CustomMetricInfo{
    .identifier = "src/main.zig",
    .name = "main.zig",
    .file_path = "src/main.zig",
    .target_kind = .file,
    .syntax_valid = true,
    .structural = .{ .functions = 3, .imports = 2 },
    .source_file_count = 1,
};

const module_info = CustomMetricInfo{
    .identifier = "domain",
    .name = "domain",
    .target_kind = .module,
    .dependency = .{
        .afferent_coupling = 2,
        .efferent_coupling = 1,
        .instability = 1.0 / 3.0,
        .coupling_factor = 0.5,
    },
    .source_file_count = 4,
};

fn structuralOrInstability(_: Allocator, info: CustomMetricInfo) !MetricValue {
    return switch (info.target_kind) {
        .file => .{ .unsigned = @intCast(info.structural.?.functions) },
        .module => .{ .floating = info.dependency.?.instability },
        else => error.UnexpectedTarget,
    };
}

test "custom calculation measures integer and floating values with owned identities" {
    var measurements = try measure(
        std.testing.allocator,
        &.{ file_info, module_info },
        .{
            .name = "risk",
            .description = "project-specific risk score",
            .calculation = CustomMetricCalculation.fromStateless(structuralOrInstability),
        },
    );
    defer measurements.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), measurements.items().len);
    try std.testing.expectEqual(@as(u64, 3), measurements.items()[0].value.unsigned);
    try std.testing.expectApproxEqAbs(
        @as(f64, 1.0 / 3.0),
        measurements.items()[1].value.floating,
        0.000_001,
    );
    try std.testing.expect(measurements.items()[0].target_identifier.ptr != file_info.identifier.ptr);
}

const CalculationContext = struct {
    multiplier: i64,

    fn calculate(self: *const CalculationContext, _: Allocator, info: CustomMetricInfo) !MetricValue {
        return .{ .signed = self.multiplier * @as(i64, @intCast(info.source_file_count)) };
    }
};

test "context-backed calculations remain explicit borrowed handles" {
    const context = CalculationContext{ .multiplier = -2 };
    const calculation = CustomMetricCalculation.fromContext(
        CalculationContext,
        &context,
        CalculationContext.calculate,
    );
    try std.testing.expectEqual(
        @as(i64, -8),
        (try calculation.calculate(std.testing.allocator, module_info)).signed,
    );
}

test "custom thresholds reuse shared comparisons and described violations" {
    const definition = CustomMetricDefinition{
        .name = "risk",
        .description = "project-specific risk score",
        .calculation = CustomMetricCalculation.fromStateless(structuralOrInstability),
    };
    var result = try gatherThresholdViolations(
        std.testing.allocator,
        &.{file_info},
        definition,
        .below,
        .{ .unsigned = 3 },
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.items().len);
    const violation = result.items()[0].custom_metric;
    try std.testing.expectEqualStrings("project-specific risk score", violation.metric_description);
    try std.testing.expectEqual(@as(u64, 3), violation.measured.unsigned);
    try std.testing.expectEqual(@as(u64, 3), violation.expectation.threshold.threshold.unsigned);
}

test "custom callbacks integrate every threshold comparison in pass and fail directions" {
    const definition = CustomMetricDefinition{
        .name = "risk",
        .description = "project-specific risk score",
        .calculation = CustomMetricCalculation.fromStateless(structuralOrInstability),
    };
    const Case = struct {
        comparison: MetricComparison,
        threshold: MetricValue,
        should_pass: bool,
    };
    const cases = [_]Case{
        .{ .comparison = .below, .threshold = .{ .unsigned = 4 }, .should_pass = true },
        .{ .comparison = .below, .threshold = .{ .unsigned = 3 }, .should_pass = false },
        .{ .comparison = .above, .threshold = .{ .unsigned = 2 }, .should_pass = true },
        .{ .comparison = .above, .threshold = .{ .unsigned = 3 }, .should_pass = false },
        .{ .comparison = .equal, .threshold = .{ .unsigned = 3 }, .should_pass = true },
        .{ .comparison = .equal, .threshold = .{ .unsigned = 2 }, .should_pass = false },
        .{ .comparison = .below_or_equal, .threshold = .{ .unsigned = 3 }, .should_pass = true },
        .{ .comparison = .below_or_equal, .threshold = .{ .unsigned = 2 }, .should_pass = false },
        .{ .comparison = .above_or_equal, .threshold = .{ .unsigned = 3 }, .should_pass = true },
        .{ .comparison = .above_or_equal, .threshold = .{ .unsigned = 4 }, .should_pass = false },
    };
    for (cases) |case| {
        var result = try gatherThresholdViolations(
            std.testing.allocator,
            &.{file_info},
            definition,
            case.comparison,
            case.threshold,
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, @intFromBool(!case.should_pass)), result.items().len);
        if (!case.should_pass) {
            const expectation = result.items()[0].custom_metric.expectation.threshold;
            try std.testing.expectEqual(case.comparison, expectation.comparison);
            try std.testing.expect(expectation.threshold.eql(case.threshold));
            try std.testing.expectEqual(@as(u64, 3), result.items()[0].custom_metric.measured.unsigned);
        }
    }
}

const PredicateContext = struct {
    calls: *usize,

    fn satisfies(
        self: *const PredicateContext,
        _: Allocator,
        value: MetricValue,
        info: CustomMetricInfo,
    ) !bool {
        self.calls.* += 1;
        return info.target_kind == .module and value.floating < 0.25;
    }
};

test "custom predicates receive the value and its subject context" {
    var calls: usize = 0;
    const context = PredicateContext{ .calls = &calls };
    var result = try gatherPredicateViolations(
        std.testing.allocator,
        &.{module_info},
        .{
            .name = "risk",
            .description = "project-specific risk score",
            .calculation = CustomMetricCalculation.fromStateless(structuralOrInstability),
        },
        CustomMetricPredicate.fromContext(PredicateContext, &context, PredicateContext.satisfies),
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(usize, 1), result.items().len);
    try std.testing.expectEqual(assertion.CustomMetricExpectation.predicate, std.meta.activeTag(
        result.items()[0].custom_metric.expectation,
    ));
}

fn failingCalculation(_: Allocator, _: CustomMetricInfo) !MetricValue {
    return error.CalculationFailed;
}

fn failingPredicate(_: Allocator, _: MetricValue, _: CustomMetricInfo) !bool {
    return error.PredicateFailed;
}

fn nonFiniteCalculation(_: Allocator, _: CustomMetricInfo) !MetricValue {
    return .{ .floating = std.math.inf(f64) };
}

test "calculation predicate and non-finite errors propagate unchanged" {
    const failing_definition = CustomMetricDefinition{
        .name = "risk",
        .description = "project-specific risk score",
        .calculation = CustomMetricCalculation.fromStateless(failingCalculation),
    };
    try std.testing.expectError(
        error.CalculationFailed,
        measure(std.testing.allocator, &.{file_info}, failing_definition),
    );
    try std.testing.expectError(
        error.PredicateFailed,
        gatherPredicateViolations(
            std.testing.allocator,
            &.{file_info},
            .{
                .name = "risk",
                .description = "project-specific risk score",
                .calculation = CustomMetricCalculation.fromStateless(structuralOrInstability),
            },
            CustomMetricPredicate.fromStateless(failingPredicate),
        ),
    );
    try std.testing.expectError(
        error.NonFiniteMetricValue,
        measure(
            std.testing.allocator,
            &.{file_info},
            .{
                .name = "risk",
                .description = "project-specific risk score",
                .calculation = CustomMetricCalculation.fromStateless(nonFiniteCalculation),
            },
        ),
    );
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    const definition = CustomMetricDefinition{
        .name = "risk",
        .description = "project-specific risk score",
        .calculation = CustomMetricCalculation.fromStateless(structuralOrInstability),
    };
    var measurements = try measure(allocator, &.{ file_info, module_info }, definition);
    defer measurements.deinit(allocator);
    var violations = try gatherThresholdViolations(
        allocator,
        &.{file_info},
        definition,
        .below,
        .{ .unsigned = 3 },
    );
    defer violations.deinit(allocator);
}

test "custom metric calculation releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
