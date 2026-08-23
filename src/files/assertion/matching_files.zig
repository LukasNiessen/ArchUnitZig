const std = @import("std");

const assertion = @import("../../common/assertion.zig");
const matching = @import("../../common/matching.zig");

const Allocator = std.mem.Allocator;

/// Pure assertion over already-selected file paths. Extraction, empty-test guarding, and final
/// prose remain outside this gatherer.
pub fn gatherMatchingFileViolations(
    allocator: Allocator,
    selected_paths: []const []const u8,
    filter: *const matching.Filter,
    predicate: assertion.ScopePattern,
    mood: assertion.Mood,
) Allocator.Error!assertion.ViolationList {
    std.debug.assert(filter.target() != .declaration_name);
    var result = assertion.ViolationList{};
    errdefer result.deinit(allocator);
    for (selected_paths) |path| {
        const matches = filter.matches(allocator, .{ .path = path }) catch |failure| switch (failure) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MissingDeclarationName => unreachable,
        };
        if (mood.holds(matches)) continue;
        var payload = try assertion.MatchingViolation.initFromEvidence(
            allocator,
            path,
            predicate,
            mood,
        );
        var violation = assertion.Violation.fromMatchingMove(&payload);
        result.appendMove(allocator, &violation) catch |failure| {
            violation.deinit(allocator);
            return failure;
        };
    }
    return result;
}

fn evidence(
    allocator: Allocator,
    pattern: matching.Pattern,
    target: matching.PatternTarget,
) !assertion.ScopePattern {
    return assertion.ScopePattern.init(
        allocator,
        0,
        pattern,
        target,
        switch (pattern) {
            .glob => .exact,
            .regex => .partial,
        },
    );
}

test "gatherer reports positive disagreements and negated matches through one mood path" {
    var filter = try matching.Filter.init(
        std.testing.allocator,
        .{ .glob = "*_service.zig" },
        .filename,
        .exact,
    );
    defer filter.deinit();
    var predicate = try evidence(std.testing.allocator, .{ .glob = "*_service.zig" }, .filename);
    defer predicate.deinit(std.testing.allocator);
    const paths = [_][]const u8{ "src/order_repository.zig", "src/order_service.zig" };

    var positive = try gatherMatchingFileViolations(
        std.testing.allocator,
        &paths,
        &filter,
        predicate,
        .should,
    );
    defer positive.deinit(std.testing.allocator);
    var negated = try gatherMatchingFileViolations(
        std.testing.allocator,
        &paths,
        &filter,
        predicate,
        .should_not,
    );
    defer negated.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), positive.items().len);
    try std.testing.expectEqualStrings("src/order_repository.zig", positive.items()[0].matching.subject_path);
    try std.testing.expectEqual(assertion.Mood.should, positive.items()[0].matching.mood);
    try std.testing.expectEqual(@as(usize, 1), negated.items().len);
    try std.testing.expectEqualStrings("src/order_service.zig", negated.items()[0].matching.subject_path);
    try std.testing.expectEqual(assertion.Mood.should_not, negated.items()[0].matching.mood);
}

test "filters normalize separators and select filename folder and path facts" {
    const Case = struct {
        pattern: matching.Pattern,
        target: matching.PatternTarget,
        expected_violations: usize,
    };
    const cases = [_]Case{
        .{ .pattern = .{ .glob = "order.zig" }, .target = .filename, .expected_violations = 0 },
        .{ .pattern = .{ .glob = "src/domain" }, .target = .path_without_filename, .expected_violations = 0 },
        .{ .pattern = .{ .glob = "src/domain/order.zig" }, .target = .path, .expected_violations = 0 },
        .{ .pattern = .{ .glob = "." }, .target = .path_without_filename, .expected_violations = 1 },
    };
    for (cases) |case| {
        var filter = try matching.Filter.init(std.testing.allocator, case.pattern, case.target, .exact);
        defer filter.deinit();
        var predicate = try evidence(std.testing.allocator, case.pattern, case.target);
        defer predicate.deinit(std.testing.allocator);
        var result = try gatherMatchingFileViolations(
            std.testing.allocator,
            &.{"src\\domain\\order.zig"},
            &filter,
            predicate,
            .should,
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected_violations, result.items().len);
    }
}

test "glob matching is whole-target while regular expressions are partial or explicitly anchored" {
    const cases = [_]struct {
        pattern: matching.Pattern,
        matching_mode: matching.MatchingMode,
        expected_violations: usize,
    }{
        .{ .pattern = .{ .glob = "order" }, .matching_mode = .exact, .expected_violations = 1 },
        .{ .pattern = .{ .regex = "order" }, .matching_mode = .partial, .expected_violations = 0 },
        .{ .pattern = .{ .regex = "^order$" }, .matching_mode = .partial, .expected_violations = 1 },
    };
    for (cases) |case| {
        var filter = try matching.Filter.init(
            std.testing.allocator,
            case.pattern,
            .filename,
            case.matching_mode,
        );
        defer filter.deinit();
        var predicate = try evidence(std.testing.allocator, case.pattern, .filename);
        defer predicate.deinit(std.testing.allocator);
        var result = try gatherMatchingFileViolations(
            std.testing.allocator,
            &.{"src/order_service.zig"},
            &filter,
            predicate,
            .should,
        );
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected_violations, result.items().len);
    }
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var filter = try matching.Filter.init(allocator, .{ .regex = "service" }, .filename, .partial);
    defer filter.deinit();
    var predicate = try evidence(allocator, .{ .regex = "service" }, .filename);
    defer predicate.deinit(allocator);
    var result = try gatherMatchingFileViolations(
        allocator,
        &.{ "src/order_service.zig", "src/order_repository.zig" },
        &filter,
        predicate,
        .should,
    );
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.items().len);
}

test "matching gatherer cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
