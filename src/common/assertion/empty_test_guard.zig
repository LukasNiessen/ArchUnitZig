const std = @import("std");

const empty_test = @import("empty_test_violation.zig");
const mood_module = @import("mood.zig");
const scope_pattern = @import("scope_pattern.zig");
const violation_module = @import("violation.zig");
const violation_list = @import("violation_list.zig");

const Allocator = std.mem.Allocator;
pub const Mood = mood_module.Mood;
pub const ScopePattern = scope_pattern.ScopePattern;
pub const ViolationList = violation_list.ViolationList;

/// Applies the shared non-vacuity policy. `null` means analysis should continue. A non-null list is
/// the complete early result: empty when the caller explicitly allowed emptiness, otherwise one
/// owned `EmptyTestViolation`.
pub fn guardEmptyTest(
    allocator: Allocator,
    matched_count: usize,
    allow_empty_tests: bool,
    rule_id: []const u8,
    scope: []const ScopePattern,
    mood: Mood,
) empty_test.InitError!?ViolationList {
    if (matched_count != 0) return null;
    if (allow_empty_tests) return ViolationList{};

    var payload = try empty_test.EmptyTestViolation.init(
        allocator,
        rule_id,
        scope,
        mood.isNegated(),
    );
    var violation = violation_module.Violation.fromEmptyTestMove(&payload);
    var result = ViolationList{};
    result.appendMove(allocator, &violation) catch |failure| {
        violation.deinit(allocator);
        return failure;
    };
    return result;
}

test "shared empty guard distinguishes continue violation and explicit opt out" {
    try std.testing.expectEqual(
        @as(?ViolationList, null),
        try guardEmptyTest(
            std.testing.allocator,
            1,
            false,
            "files.have_name",
            &.{},
            .should,
        ),
    );

    var rejected = (try guardEmptyTest(
        std.testing.allocator,
        0,
        false,
        "files.have_name",
        &.{},
        .should_not,
    )).?;
    defer rejected.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), rejected.items().len);
    try std.testing.expectEqualStrings("files.have_name", rejected.items()[0].empty_test.rule_id);
    try std.testing.expect(rejected.items()[0].empty_test.is_negated);

    var allowed = (try guardEmptyTest(
        std.testing.allocator,
        0,
        true,
        "files.have_name",
        &.{},
        .should,
    )).?;
    defer allowed.deinit(std.testing.allocator);
    try std.testing.expect(allowed.passes());
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var result = (try guardEmptyTest(
        allocator,
        0,
        false,
        "files.adhere_to",
        &.{},
        .should,
    )).?;
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.items().len);
}

test "shared empty guard cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
