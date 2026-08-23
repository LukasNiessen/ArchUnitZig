pub const Captures = @import("matching/regex.zig").Captures;
pub const Candidate = @import("matching/filter.zig").Candidate;
pub const Filter = @import("matching/filter.zig").Filter;
pub const MatchRange = @import("matching/regex.zig").MatchRange;
pub const Pattern = @import("matching/pattern.zig").Pattern;
pub const PatternSyntax = @import("matching/pattern.zig").PatternSyntax;
pub const Regex = @import("matching/regex.zig").Regex;
pub const MatchingMode = @import("matching/pattern_target.zig").MatchingMode;
pub const PatternTarget = @import("matching/pattern_target.zig").PatternTarget;
pub const RegexMatcher = @import("matching/regex_factory.zig").RegexMatcher;
pub const RegexFactory = @import("matching/filter_factory.zig");
pub const matchesAny = @import("matching/filter.zig").matchesAny;
pub const matchesSelectors = @import("matching/filter.zig").matchesSelectors;

test {
    _ = @import("matching/filter.zig");
    _ = @import("matching/filter_factory.zig");
    _ = @import("matching/pattern.zig");
    _ = @import("matching/pattern_target.zig");
    _ = @import("matching/regex.zig");
    _ = @import("matching/regex_factory.zig");
}
