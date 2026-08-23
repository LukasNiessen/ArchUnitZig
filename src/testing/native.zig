const std = @import("std");

const assertion = @import("../common/assertion.zig");
const fluentapi = @import("../common/fluentapi.zig");
const result_factory = @import("result_factory.zig");

const Allocator = std.mem.Allocator;
pub const Checkable = fluentapi.Checkable;
pub const CheckOptions = fluentapi.CheckOptions;
pub const ResultOptions = result_factory.ResultOptions;
pub const ViolationGroup = result_factory.ViolationGroup;

/// A disagreement is intentionally distinct from user and technical errors returned by `check`.
pub const ArchitectureAssertionError = error{ArchitectureViolation};

/// Native test integration keeps all ambient choices explicit. `failure_writer`, when present, is
/// borrowed for the call and replaces stderr; this is useful for custom runners and exact tests.
pub const AssertionOptions = struct {
    check: CheckOptions,
    result: ResultOptions = .{},
    failure_writer: ?*std.Io.Writer = null,

    pub fn init(check: CheckOptions) AssertionOptions {
        return .{ .check = check };
    }
};

/// Checks one concrete terminal rule and returns an ordinary Zig test-compatible error on
/// disagreement. Marked inline so the caller remains visible in the error return trace.
pub inline fn expectPasses(rule: anytype, options: AssertionOptions) anyerror!void {
    return expectPassesImpl(rule, options);
}

/// Naming alias for codebases that call their test helpers assertions. This does not panic.
pub inline fn assertPasses(rule: anytype, options: AssertionOptions) anyerror!void {
    return expectPassesImpl(rule, options);
}

/// Checks heterogeneous owned handles sequentially and emits at most one combined failure.
pub inline fn assertAllPass(rules: []Checkable, options: AssertionOptions) anyerror!void {
    return assertAllPassImpl(rules, options);
}

fn expectPassesImpl(rule: anytype, options: AssertionOptions) anyerror!void {
    var violations = try rule.check(options.check);
    defer violations.deinit(options.check.allocator);
    const sentence = try rule.description(options.check.allocator);
    defer options.check.allocator.free(sentence);
    return enforceResult(
        &.{.{ .violations = violations.items(), .rule_sentence = sentence }},
        sentence,
        options,
    );
}

const CollectedRule = struct {
    sentence: []u8,
    violations: assertion.ViolationList,

    fn deinit(self: *CollectedRule, allocator: Allocator) void {
        allocator.free(self.sentence);
        self.violations.deinit(allocator);
        self.* = undefined;
    }
};

fn assertAllPassImpl(rules: []Checkable, options: AssertionOptions) anyerror!void {
    const allocator = options.check.allocator;
    var collected: std.ArrayList(CollectedRule) = .empty;
    defer {
        for (collected.items) |*item| item.deinit(allocator);
        collected.deinit(allocator);
    }

    for (rules) |*rule| {
        var violations = try rule.check(options.check);
        errdefer violations.deinit(allocator);
        const sentence = try rule.description(allocator);
        errdefer allocator.free(sentence);
        try collected.append(allocator, .{ .sentence = sentence, .violations = violations });
    }

    const groups = try allocator.alloc(ViolationGroup, collected.items.len);
    defer allocator.free(groups);
    for (collected.items, groups) |*item, *group| {
        group.* = .{
            .violations = item.violations.items(),
            .rule_sentence = item.sentence,
        };
    }
    const passing_sentence = try std.fmt.allocPrint(
        allocator,
        "all {d} architecture rules",
        .{rules.len},
    );
    defer allocator.free(passing_sentence);
    return enforceResult(groups, passing_sentence, options);
}

fn enforceResult(
    groups: []const ViolationGroup,
    passing_sentence: []const u8,
    options: AssertionOptions,
) anyerror!void {
    if (options.failure_writer) |writer| {
        var result = try result_factory.ResultFactory.fromViolationGroups(
            options.check.allocator,
            groups,
            passing_sentence,
            options.result,
        );
        defer result.deinit(options.check.allocator);
        if (result.passed) return;
        emitFailure(writer, result.message);
        return error.ArchitectureViolation;
    }

    if (!hasViolations(groups)) {
        var result = try result_factory.ResultFactory.fromViolationGroups(
            options.check.allocator,
            groups,
            passing_sentence,
            options.result,
        );
        defer result.deinit(options.check.allocator);
        std.debug.assert(result.passed);
        return;
    }

    var stderr_buffer: [1024]u8 = undefined;
    const stderr = options.check.io.lockStderr(&stderr_buffer, null) catch {
        var fallback = try result_factory.ResultFactory.fromViolationGroups(
            options.check.allocator,
            groups,
            passing_sentence,
            options.result,
        );
        defer fallback.deinit(options.check.allocator);
        std.debug.print("{s}\n", .{fallback.message});
        return error.ArchitectureViolation;
    };
    defer options.check.io.unlockStderr();

    var detected_options = options.result;
    if (detected_options.color.mode == .auto) {
        detected_options.color.ansi_terminal = stderr.terminal_mode == .escape_codes;
    }
    var result = try result_factory.ResultFactory.fromViolationGroups(
        options.check.allocator,
        groups,
        passing_sentence,
        detected_options,
    );
    defer result.deinit(options.check.allocator);
    std.debug.assert(!result.passed);
    emitFailure(&stderr.file_writer.interface, result.message);
    return error.ArchitectureViolation;
}

fn hasViolations(groups: []const ViolationGroup) bool {
    for (groups) |group| if (group.violations.len != 0) return true;
    return false;
}

/// Diagnostic writes are best effort, matching `std.testing`: the assertion error remains the
/// semantic outcome even when a test runner closes its output stream.
fn emitFailure(writer: *std.Io.Writer, message: []const u8) void {
    writer.writeAll(message) catch return;
    writer.writeByte('\n') catch {};
}

const TestBehavior = enum { pass, violate, analysis_error };

const TestRule = struct {
    behavior: TestBehavior,
    sentence: []const u8,
    checks: *usize,
    descriptions: *usize,
    deinits: ?*usize = null,

    pub fn check(self: *const TestRule, options: CheckOptions) !assertion.ViolationList {
        self.checks.* += 1;
        if (self.behavior == .analysis_error) return error.MockAnalysisFailed;
        if (self.behavior == .pass) return .{};

        var payload = try assertion.EmptyTestViolation.init(
            options.allocator,
            "mock.empty",
            &.{},
            false,
        );
        var violation = assertion.Violation.fromEmptyTestMove(&payload);
        var result = assertion.ViolationList{};
        result.appendMove(options.allocator, &violation) catch |failure| {
            violation.deinit(options.allocator);
            return failure;
        };
        return result;
    }

    pub fn description(self: *const TestRule, allocator: Allocator) Allocator.Error![]u8 {
        self.descriptions.* += 1;
        return allocator.dupe(u8, self.sentence);
    }

    pub fn deinit(self: *TestRule, allocator: Allocator) void {
        _ = allocator;
        if (self.deinits) |count| count.* += 1;
        self.* = undefined;
    }
};

fn testOptions(writer: *std.Io.Writer) AssertionOptions {
    return .{
        .check = CheckOptions.init(std.testing.allocator, std.testing.io),
        .result = .{ .color = .{ .mode = .never } },
        .failure_writer = writer,
    };
}

test "expectPasses and assertPasses are ordinary test-block helpers" {
    var checks: usize = 0;
    var descriptions: usize = 0;
    const rule = TestRule{
        .behavior = .pass,
        .sentence = "project files should have no cycles",
        .checks = &checks,
        .descriptions = &descriptions,
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try expectPasses(&rule, testOptions(&output.writer));
    try assertPasses(&rule, testOptions(&output.writer));
    try std.testing.expectEqual(@as(usize, 2), checks);
    try std.testing.expectEqual(@as(usize, 2), descriptions);
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
}

test "failing concrete rule emits the shared result once and returns assertion error" {
    var checks: usize = 0;
    var descriptions: usize = 0;
    const rule = TestRule{
        .behavior = .violate,
        .sentence = "project files should have no cycles",
        .checks = &checks,
        .descriptions = &descriptions,
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try std.testing.expectError(
        error.ArchitectureViolation,
        expectPasses(&rule, testOptions(&output.writer)),
    );
    try std.testing.expectEqual(@as(usize, 1), checks);
    try std.testing.expectEqual(@as(usize, 1), descriptions);
    try std.testing.expectEqualStrings(
        "Architecture rule failed with 1 violation:\n\n" ++
            "1. Empty test violation\n" ++
            "   Rule: project files should have no cycles\n" ++
            "   Rule id: mock.empty\n" ++
            "   Reason: no files matched the rule scope\n" ++
            "   Selectors: unfiltered project scope\n",
        output.written(),
    );
}

test "analysis errors propagate unchanged without assertion output" {
    var checks: usize = 0;
    var descriptions: usize = 0;
    const rule = TestRule{
        .behavior = .analysis_error,
        .sentence = "project files should have no cycles",
        .checks = &checks,
        .descriptions = &descriptions,
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try std.testing.expectError(
        error.MockAnalysisFailed,
        expectPasses(&rule, testOptions(&output.writer)),
    );
    try std.testing.expectEqual(@as(usize, 1), checks);
    try std.testing.expectEqual(@as(usize, 0), descriptions);
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
}

test "assertAllPass keeps heterogeneous rule sentences and leaves handle ownership with caller" {
    var first_checks: usize = 0;
    var first_descriptions: usize = 0;
    var first_deinits: usize = 0;
    var first_rule = TestRule{
        .behavior = .violate,
        .sentence = "API files should not depend on database files",
        .checks = &first_checks,
        .descriptions = &first_descriptions,
        .deinits = &first_deinits,
    };
    var first = try Checkable.fromMove(std.testing.allocator, &first_rule);

    var second_checks: usize = 0;
    var second_descriptions: usize = 0;
    var second_deinits: usize = 0;
    var second_rule = TestRule{
        .behavior = .violate,
        .sentence = "domain files should have no cycles",
        .checks = &second_checks,
        .descriptions = &second_descriptions,
        .deinits = &second_deinits,
    };
    var second = Checkable.fromMove(std.testing.allocator, &second_rule) catch |failure| {
        first.deinit();
        return failure;
    };
    var rules = [_]Checkable{ first, second };
    first = undefined;
    second = undefined;
    var rules_owned = true;
    defer if (rules_owned) for (&rules) |*rule| rule.deinit();

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(
        error.ArchitectureViolation,
        assertAllPass(&rules, testOptions(&output.writer)),
    );
    try std.testing.expectEqual(@as(usize, 1), first_checks);
    try std.testing.expectEqual(@as(usize, 1), second_checks);
    try std.testing.expectEqual(@as(usize, 1), first_descriptions);
    try std.testing.expectEqual(@as(usize, 1), second_descriptions);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "Rule: API files should not depend on database files",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "Rule: domain files should have no cycles",
    ) != null);

    for (&rules) |*rule| rule.deinit();
    rules_owned = false;
    try std.testing.expectEqual(@as(usize, 1), first_deinits);
    try std.testing.expectEqual(@as(usize, 1), second_deinits);
}

test "assertAllPass stops on analysis error without emitting earlier disagreements" {
    var first_checks: usize = 0;
    var first_descriptions: usize = 0;
    var first_rule = TestRule{
        .behavior = .violate,
        .sentence = "API files should not depend on database files",
        .checks = &first_checks,
        .descriptions = &first_descriptions,
    };
    var first = try Checkable.fromMove(std.testing.allocator, &first_rule);

    var second_checks: usize = 0;
    var second_descriptions: usize = 0;
    var second_rule = TestRule{
        .behavior = .analysis_error,
        .sentence = "domain files should have no cycles",
        .checks = &second_checks,
        .descriptions = &second_descriptions,
    };
    var second = Checkable.fromMove(std.testing.allocator, &second_rule) catch |failure| {
        first.deinit();
        return failure;
    };
    var rules = [_]Checkable{ first, second };
    first = undefined;
    second = undefined;
    defer for (&rules) |*rule| rule.deinit();

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(
        error.MockAnalysisFailed,
        assertAllPass(&rules, testOptions(&output.writer)),
    );
    try std.testing.expectEqual(@as(usize, 1), first_checks);
    try std.testing.expectEqual(@as(usize, 1), first_descriptions);
    try std.testing.expectEqual(@as(usize, 1), second_checks);
    try std.testing.expectEqual(@as(usize, 0), second_descriptions);
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var checks: usize = 0;
    var descriptions: usize = 0;
    const rule = TestRule{
        .behavior = .violate,
        .sentence = "project files should have no cycles",
        .checks = &checks,
        .descriptions = &descriptions,
    };
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var options = AssertionOptions.init(CheckOptions.init(allocator, std.testing.io));
    options.failure_writer = &writer;
    expectPasses(&rule, options) catch |failure| switch (failure) {
        error.ArchitectureViolation => return,
        else => return failure,
    };
    return error.ExpectedArchitectureViolation;
}

test "native assertion path cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}

fn exerciseAllAllocationFailures(allocator: Allocator) !void {
    var first_checks: usize = 0;
    var first_descriptions: usize = 0;
    var first_rule = TestRule{
        .behavior = .pass,
        .sentence = "project files should have no cycles",
        .checks = &first_checks,
        .descriptions = &first_descriptions,
    };
    var first = try Checkable.fromMove(allocator, &first_rule);

    var second_checks: usize = 0;
    var second_descriptions: usize = 0;
    var second_rule = TestRule{
        .behavior = .violate,
        .sentence = "API files should not depend on database files",
        .checks = &second_checks,
        .descriptions = &second_descriptions,
    };
    var second = Checkable.fromMove(allocator, &second_rule) catch |failure| {
        first.deinit();
        return failure;
    };
    var rules = [_]Checkable{ first, second };
    first = undefined;
    second = undefined;
    defer for (&rules) |*rule| rule.deinit();

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var options = AssertionOptions.init(CheckOptions.init(allocator, std.testing.io));
    options.failure_writer = &writer;
    assertAllPass(&rules, options) catch |failure| switch (failure) {
        error.ArchitectureViolation => return,
        else => return failure,
    };
    return error.ExpectedArchitectureViolation;
}

test "heterogeneous native assertion path cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllAllocationFailures,
        .{},
    );
}
