pub const Captures = @import("matching/regex.zig").Captures;
pub const MatchRange = @import("matching/regex.zig").MatchRange;
pub const Pattern = @import("matching/pattern.zig").Pattern;
pub const Regex = @import("matching/regex.zig").Regex;
pub const MatchingMode = @import("matching/pattern_target.zig").MatchingMode;
pub const PatternTarget = @import("matching/pattern_target.zig").PatternTarget;
pub const RegexMatcher = @import("matching/regex_factory.zig").RegexMatcher;

test {
    _ = @import("matching/pattern.zig");
    _ = @import("matching/pattern_target.zig");
    _ = @import("matching/regex.zig");
    _ = @import("matching/regex_factory.zig");
}
