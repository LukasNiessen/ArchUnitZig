const std = @import("std");

const assertion = @import("../common/assertion.zig");
const color = @import("color.zig");
const violation_factory = @import("violation_factory.zig");

const Allocator = std.mem.Allocator;
pub const ColorOptions = color.ColorOptions;
pub const FormattedViolation = violation_factory.FormattedViolation;
pub const Violation = assertion.Violation;
pub const BuildError = violation_factory.FormatError;

pub const ResultOptions = struct {
    color: ColorOptions = .{},
};

/// Borrowed violations paired with the sentence of the rule that produced them.
pub const ViolationGroup = struct {
    violations: []const Violation,
    rule_sentence: []const u8,
};

/// Owned framework-neutral architecture-test result.
pub const TestResult = struct {
    passed: bool,
    message: []const u8,

    pub fn clone(self: TestResult, allocator: Allocator) Allocator.Error!TestResult {
        return .{ .passed = self.passed, .message = try allocator.dupe(u8, self.message) };
    }

    pub fn deinit(self: *TestResult, allocator: Allocator) void {
        allocator.free(self.message);
        self.* = undefined;
    }

    pub fn eql(self: TestResult, other: TestResult) bool {
        return self.passed == other.passed and std.mem.eql(u8, self.message, other.message);
    }
};

pub const ResultFactory = struct {
    pub fn fromViolations(
        allocator: Allocator,
        violations: []const Violation,
        rule_sentence: []const u8,
        options: ResultOptions,
    ) BuildError!TestResult {
        return fromViolationGroups(
            allocator,
            &.{.{ .violations = violations, .rule_sentence = rule_sentence }},
            rule_sentence,
            options,
        );
    }

    /// Shapes one result for heterogeneous rules without losing which sentence produced each
    /// violation. Each structured violation still crosses `ViolationFactory` exactly once.
    pub fn fromViolationGroups(
        allocator: Allocator,
        groups: []const ViolationGroup,
        passing_sentence: []const u8,
        options: ResultOptions,
    ) BuildError!TestResult {
        if (!containsNonWhitespace(passing_sentence)) return error.InvalidRuleSentence;
        var formatted: std.ArrayList(FormattedViolation) = .empty;
        defer {
            for (formatted.items) |*item| item.deinit(allocator);
            formatted.deinit(allocator);
        }
        for (groups) |group| {
            if (!containsNonWhitespace(group.rule_sentence)) return error.InvalidRuleSentence;
            for (group.violations) |violation| {
                var item = try violation_factory.ViolationFactory.fromViolation(
                    allocator,
                    violation,
                    group.rule_sentence,
                );
                formatted.append(allocator, item) catch |failure| {
                    item.deinit(allocator);
                    return failure;
                };
            }
        }
        if (formatted.items.len == 0) return passingResult(allocator, passing_sentence, options.color);
        return failingResult(allocator, formatted.items, options.color);
    }
};

fn failingResult(
    allocator: Allocator,
    formatted: []FormattedViolation,
    color_options: ColorOptions,
) Allocator.Error!TestResult {
    std.mem.sort(FormattedViolation, formatted, {}, formattedLessThan);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var title_buffer: [96]u8 = undefined;
    const noun = if (formatted.len == 1) "violation" else "violations";
    const title = std.fmt.bufPrint(
        &title_buffer,
        "Architecture rule failed with {d} {s}:",
        .{ formatted.len, noun },
    ) catch unreachable;
    color.writeStyled(&output.writer, color_options, .bold_red, title) catch
        return error.OutOfMemory;
    output.writer.writeAll("\n\n") catch return error.OutOfMemory;

    for (formatted, 0..) |item, index| {
        if (index != 0) output.writer.writeAll("\n\n") catch return error.OutOfMemory;
        var heading_buffer: [128]u8 = undefined;
        const heading = std.fmt.bufPrint(
            &heading_buffer,
            "{d}. {s}",
            .{ index + 1, item.heading },
        ) catch unreachable;
        color.writeStyled(&output.writer, color_options, .yellow, heading) catch
            return error.OutOfMemory;
        output.writer.writeAll("\n   ") catch return error.OutOfMemory;
        writeIndented(&output.writer, item.details) catch return error.OutOfMemory;
    }
    return .{ .passed = false, .message = try output.toOwnedSlice() };
}

fn passingResult(
    allocator: Allocator,
    rule_sentence: []const u8,
    color_options: ColorOptions,
) Allocator.Error!TestResult {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    color.writeStyled(&output.writer, color_options, .bold_green, "Architecture rule passed") catch
        return error.OutOfMemory;
    output.writer.print("\nRule: {s}", .{rule_sentence}) catch return error.OutOfMemory;
    return .{ .passed = true, .message = try output.toOwnedSlice() };
}

fn formattedLessThan(_: void, left: FormattedViolation, right: FormattedViolation) bool {
    const key_order = std.mem.order(u8, left.sort_key, right.sort_key);
    if (key_order != .eq) return key_order == .lt;
    const heading_order = std.mem.order(u8, left.heading, right.heading);
    if (heading_order != .eq) return heading_order == .lt;
    return std.mem.order(u8, left.details, right.details) == .lt;
}

fn writeIndented(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    for (value) |byte| {
        try writer.writeByte(byte);
        if (byte == '\n') try writer.writeAll("   ");
    }
}

fn containsNonWhitespace(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n\x0b\x0c").len != 0;
}

fn emptyViolation(allocator: Allocator, rule_id: []const u8) !Violation {
    var payload = try assertion.EmptyTestViolation.init(allocator, rule_id, &.{}, false);
    return assertion.Violation.fromEmptyTestMove(&payload);
}

fn matchingViolation(allocator: Allocator, path: []const u8) !Violation {
    var evidence = try assertion.ScopePattern.init(
        allocator,
        0,
        .{ .glob = "*_service.zig" },
        .filename,
        .exact,
    );
    defer evidence.deinit(allocator);
    const payload = try assertion.MatchingViolation.initFromEvidence(
        allocator,
        path,
        evidence,
        .should,
    );
    return assertion.Violation{ .matching = payload };
}

test "result factory shapes passing rules with an owned message" {
    var result = try ResultFactory.fromViolations(
        std.testing.allocator,
        &.{},
        "project files should have no cycles",
        .{},
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.passed);
    try std.testing.expectEqualStrings(
        "Architecture rule passed\nRule: project files should have no cycles",
        result.message,
    );
    var cloned = try result.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);
    try std.testing.expect(result.eql(cloned));
    try std.testing.expect(result.message.ptr != cloned.message.ptr);
}

test "multiple violations sort before numbering and render one plain golden message" {
    var later = try matchingViolation(std.testing.allocator, "src\\order.zig");
    defer later.deinit(std.testing.allocator);
    var earlier = try emptyViolation(std.testing.allocator, "files.have_name");
    defer earlier.deinit(std.testing.allocator);
    var result = try ResultFactory.fromViolations(
        std.testing.allocator,
        &.{ later, earlier },
        "project files should have name *_service.zig",
        .{ .color = .{ .mode = .never } },
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.passed);
    try std.testing.expectEqualStrings(
        "Architecture rule failed with 2 violations:\n\n" ++
            "1. Empty test violation\n" ++
            "   Rule: project files should have name *_service.zig\n" ++
            "   Rule id: files.have_name\n" ++
            "   Reason: no files matched the rule scope\n" ++
            "   Selectors: unfiltered project scope\n\n" ++
            "2. File pattern violation\n" ++
            "   Rule: project files should have name *_service.zig\n" ++
            "   File: src/order.zig:1:1\n" ++
            "   Reason: filename does not match required glob \"*_service.zig\" (exact)",
        result.message,
    );
}

test "heterogeneous groups retain each producing rule sentence in one result" {
    var matching_value = try matchingViolation(std.testing.allocator, "src/order.zig");
    defer matching_value.deinit(std.testing.allocator);
    var empty_value = try emptyViolation(std.testing.allocator, "files.have_no_cycles");
    defer empty_value.deinit(std.testing.allocator);
    var result = try ResultFactory.fromViolationGroups(
        std.testing.allocator,
        &.{
            .{
                .violations = &.{matching_value},
                .rule_sentence = "service files should have name *_service.zig",
            },
            .{
                .violations = &.{empty_value},
                .rule_sentence = "domain files should have no cycles",
            },
        },
        "all 2 architecture rules",
        .{},
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "Architecture rule failed with 2 violations:\n\n" ++
            "1. Empty test violation\n" ++
            "   Rule: domain files should have no cycles\n" ++
            "   Rule id: files.have_no_cycles\n" ++
            "   Reason: no files matched the rule scope\n" ++
            "   Selectors: unfiltered project scope\n\n" ++
            "2. File pattern violation\n" ++
            "   Rule: service files should have name *_service.zig\n" ++
            "   File: src/order.zig:1:1\n" ++
            "   Reason: filename does not match required glob \"*_service.zig\" (exact)",
        result.message,
    );
}

test "heterogeneous groups validate even empty rule descriptions" {
    try std.testing.expectError(
        error.InvalidRuleSentence,
        ResultFactory.fromViolationGroups(
            std.testing.allocator,
            &.{.{ .violations = &.{}, .rule_sentence = "  " }},
            "all architecture rules",
            .{},
        ),
    );
}

test "colour is exact when forced and auto-disables for inappropriate outputs" {
    var violation = try emptyViolation(std.testing.allocator, "files.have_no_cycles");
    defer violation.deinit(std.testing.allocator);
    var colored = try ResultFactory.fromViolations(
        std.testing.allocator,
        &.{violation},
        "project files should have no cycles",
        .{ .color = .{ .mode = .always } },
    );
    defer colored.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(
        u8,
        colored.message,
        "\x1b[1;31mArchitecture rule failed with 1 violation:\x1b[0m\n\n" ++
            "\x1b[33m1. Empty test violation\x1b[0m",
    ));

    var auto_plain = try ResultFactory.fromViolations(
        std.testing.allocator,
        &.{violation},
        "project files should have no cycles",
        .{ .color = .{ .ansi_terminal = true, .no_color = true } },
    );
    defer auto_plain.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, auto_plain.message, "\x1b[") == null);
}

fn exerciseResultAllocationFailures(allocator: Allocator) !void {
    var matching_value = try matchingViolation(allocator, "src/order.zig");
    defer matching_value.deinit(allocator);
    var empty_value = try emptyViolation(allocator, "files.have_name");
    defer empty_value.deinit(allocator);
    var result = try ResultFactory.fromViolationGroups(
        allocator,
        &.{
            .{
                .violations = &.{matching_value},
                .rule_sentence = "project files should have name *_service.zig",
            },
            .{
                .violations = &.{empty_value},
                .rule_sentence = "project files should have no cycles",
            },
        },
        "all 2 architecture rules",
        .{ .color = .{ .mode = .always } },
    );
    defer result.deinit(allocator);
    var cloned = try result.clone(allocator);
    defer cloned.deinit(allocator);
    try std.testing.expect(result.eql(cloned));
}

test "result shaping and cloning clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseResultAllocationFailures,
        .{},
    );
}
