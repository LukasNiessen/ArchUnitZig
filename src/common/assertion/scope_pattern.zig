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

    pub fn clone(self: ScopePattern, allocator: Allocator) Allocator.Error!ScopePattern {
        return .{
            .selector_index = self.selector_index,
            .expression = try allocator.dupe(u8, self.expression),
            .syntax = self.syntax,
            .target = self.target,
            .matching = self.matching,
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
            self.matching == other.matching;
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
