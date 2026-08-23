const std = @import("std");

/// The one positive/negative fact shared by architecture assertions.
pub const Mood = enum {
    should,
    should_not,

    pub fn isNegated(self: Mood) bool {
        return self == .should_not;
    }

    /// Whether one predicate result satisfies this mood. Assertion gatherers report a violation
    /// exactly when this returns false; they do not implement separate positive/negative paths.
    pub fn holds(self: Mood, predicate_result: bool) bool {
        return switch (self) {
            .should => predicate_result,
            .should_not => !predicate_result,
        };
    }

    pub fn phrase(self: Mood) []const u8 {
        return switch (self) {
            .should => "should",
            .should_not => "should not",
        };
    }

    pub fn format(self: Mood, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return writer.writeAll(self.phrase());
    }
};

test "moods are complementary over the same predicate result" {
    for ([_]bool{ false, true }) |predicate_result| {
        try std.testing.expect(Mood.should.holds(predicate_result) != Mood.should_not.holds(predicate_result));
    }
    try std.testing.expect(Mood.should.holds(true));
    try std.testing.expect(Mood.should_not.holds(false));
    try std.testing.expect(!Mood.should.isNegated());
    try std.testing.expect(Mood.should_not.isNegated());
}

test "moods render as the only two grammar phrases" {
    try std.testing.expectFmt("should", "{f}", .{Mood.should});
    try std.testing.expectFmt("should not", "{f}", .{Mood.should_not});
}
