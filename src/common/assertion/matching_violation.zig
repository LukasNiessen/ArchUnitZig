const std = @import("std");

const matching = @import("../matching.zig");
const mood_module = @import("mood.zig");
const scope_pattern = @import("scope_pattern.zig");

const Allocator = std.mem.Allocator;
pub const Mood = mood_module.Mood;
pub const ScopePattern = scope_pattern.ScopePattern;

/// Owned facts for one selected path that disagrees with a pattern predicate. The original
/// expression is retained separately from the compiled filter and no presentation prose is stored.
pub const MatchingViolation = struct {
    subject_path: []const u8,
    expression: []const u8,
    syntax: matching.PatternSyntax,
    target: matching.PatternTarget,
    matching_mode: matching.MatchingMode,
    mood: Mood,

    pub fn initFromEvidence(
        allocator: Allocator,
        subject_path: []const u8,
        predicate: ScopePattern,
        mood: Mood,
    ) Allocator.Error!MatchingViolation {
        const owned_subject = try allocator.dupe(u8, subject_path);
        errdefer allocator.free(owned_subject);
        const owned_expression = try allocator.dupe(u8, predicate.expression);
        return .{
            .subject_path = owned_subject,
            .expression = owned_expression,
            .syntax = predicate.syntax,
            .target = predicate.target,
            .matching_mode = predicate.matching,
            .mood = mood,
        };
    }

    pub fn clone(self: MatchingViolation, allocator: Allocator) Allocator.Error!MatchingViolation {
        const predicate = ScopePattern{
            .selector_index = 0,
            .expression = self.expression,
            .syntax = self.syntax,
            .target = self.target,
            .matching = self.matching_mode,
        };
        return initFromEvidence(allocator, self.subject_path, predicate, self.mood);
    }

    pub fn deinit(self: *MatchingViolation, allocator: Allocator) void {
        allocator.free(self.subject_path);
        allocator.free(self.expression);
        self.* = undefined;
    }

    pub fn eql(self: MatchingViolation, other: MatchingViolation) bool {
        return std.mem.eql(u8, self.subject_path, other.subject_path) and
            std.mem.eql(u8, self.expression, other.expression) and
            self.syntax == other.syntax and
            self.target == other.target and
            self.matching_mode == other.matching_mode and
            self.mood == other.mood;
    }
};

test "matching violations own candidate and predicate facts" {
    var subject = [_]u8{ 's', 'r', 'c', '/', 'o', 'r', 'd', 'e', 'r', '.', 'z', 'i', 'g' };
    var evidence = try ScopePattern.init(
        std.testing.allocator,
        0,
        .{ .glob = "*_service.zig" },
        .filename,
        .exact,
    );
    defer evidence.deinit(std.testing.allocator);
    var violation = try MatchingViolation.initFromEvidence(
        std.testing.allocator,
        &subject,
        evidence,
        .should_not,
    );
    defer violation.deinit(std.testing.allocator);
    @memset(&subject, 'x');
    var cloned = try violation.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("src/order.zig", violation.subject_path);
    try std.testing.expectEqualStrings("*_service.zig", violation.expression);
    try std.testing.expectEqual(matching.PatternTarget.filename, violation.target);
    try std.testing.expectEqual(Mood.should_not, violation.mood);
    try std.testing.expect(violation.eql(cloned));
    try std.testing.expect(violation.subject_path.ptr != cloned.subject_path.ptr);
}
