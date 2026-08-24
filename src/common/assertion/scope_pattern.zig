const std = @import("std");

const matching = @import("../matching.zig");

const Allocator = std.mem.Allocator;

/// Owned, presentation-neutral evidence describing one pattern in an empty selector scope.
/// Patterns sharing `selector_index` are alternatives; different indices are cumulative selectors.
pub const ScopePattern = struct {
    selector_index: usize,
    expression: []const u8,
    syntax: matching.PatternSyntax,
    target: matching.PatternTarget,
    matching: matching.MatchingMode,
    is_exclusion: bool = false,

    pub fn init(
        allocator: Allocator,
        selector_index: usize,
        pattern: matching.Pattern,
        target: matching.PatternTarget,
        matching_mode: matching.MatchingMode,
    ) Allocator.Error!ScopePattern {
        return .{
            .selector_index = selector_index,
            .expression = try allocator.dupe(u8, pattern.source()),
            .syntax = pattern.syntax(),
            .target = target,
            .matching = matching_mode,
        };
    }

    pub fn initLiteral(
        allocator: Allocator,
        selector_index: usize,
        expression: []const u8,
        target: matching.PatternTarget,
    ) Allocator.Error!ScopePattern {
        return .{
            .selector_index = selector_index,
            .expression = try allocator.dupe(u8, expression),
            .syntax = .literal,
            .target = target,
            .matching = .exact,
        };
    }

    pub fn initExclusion(
        allocator: Allocator,
        selector_index: usize,
        pattern: matching.Pattern,
        target: matching.PatternTarget,
        matching_mode: matching.MatchingMode,
    ) Allocator.Error!ScopePattern {
        var result = try init(allocator, selector_index, pattern, target, matching_mode);
        result.is_exclusion = true;
        return result;
    }

    pub fn initLiteralExclusion(
        allocator: Allocator,
        selector_index: usize,
        expression: []const u8,
        target: matching.PatternTarget,
    ) Allocator.Error!ScopePattern {
        var result = try initLiteral(allocator, selector_index, expression, target);
        result.is_exclusion = true;
        return result;
    }

    pub fn clone(self: ScopePattern, allocator: Allocator) Allocator.Error!ScopePattern {
        return .{
            .selector_index = self.selector_index,
            .expression = try allocator.dupe(u8, self.expression),
            .syntax = self.syntax,
            .target = self.target,
            .matching = self.matching,
            .is_exclusion = self.is_exclusion,
        };
    }

    pub fn deinit(self: *ScopePattern, allocator: Allocator) void {
        allocator.free(self.expression);
        self.* = undefined;
    }

    pub fn eql(self: ScopePattern, other: ScopePattern) bool {
        return self.selector_index == other.selector_index and
            std.mem.eql(u8, self.expression, other.expression) and
            self.syntax == other.syntax and
            self.target == other.target and
            self.matching == other.matching and
            self.is_exclusion == other.is_exclusion;
    }
};

test "scope pattern owns structured selector evidence" {
    var source = [_]u8{ '*', '.', 'z', 'i', 'g' };
    var scope = try ScopePattern.init(
        std.testing.allocator,
        2,
        .{ .glob = &source },
        .filename,
        .partial,
    );
    defer scope.deinit(std.testing.allocator);
    @memset(&source, 'x');

    try std.testing.expectEqual(@as(usize, 2), scope.selector_index);
    try std.testing.expectEqualStrings("*.zig", scope.expression);
    try std.testing.expectEqual(matching.PatternSyntax.glob, scope.syntax);
    try std.testing.expectEqual(matching.PatternTarget.filename, scope.target);
}

test "scope pattern describes exact literals without calling them globs or regexes" {
    var source = [_]u8{ 's', 'r', 'c', '/', 'o', 'r', 'd', 'e', 'r', '.', 'z', 'i', 'g' };
    var scope = try ScopePattern.initLiteral(std.testing.allocator, 1, &source, .path);
    defer scope.deinit(std.testing.allocator);
    @memset(&source, 'x');

    try std.testing.expectEqualStrings("src/order.zig", scope.expression);
    try std.testing.expectEqual(matching.PatternSyntax.literal, scope.syntax);
    try std.testing.expectEqual(matching.MatchingMode.exact, scope.matching);
}

test "scope pattern retains exclusion evidence through cloning" {
    var exclusion = try ScopePattern.initExclusion(
        std.testing.allocator,
        1,
        .{ .regex = "generated" },
        .path,
        .partial,
    );
    defer exclusion.deinit(std.testing.allocator);
    var cloned = try exclusion.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);
    try std.testing.expect(cloned.is_exclusion);
    try std.testing.expect(exclusion.eql(cloned));
}
