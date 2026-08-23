//! Public package root for ArchUnitZig.
//!
//! The rule-building API will be added incrementally as its contracts are implemented and tested.

const std = @import("std");
const extraction = @import("common/extraction.zig");
const matching = @import("common/matching.zig");

pub const Edge = extraction.Edge;
pub const Graph = extraction.Graph;
pub const ImportKind = extraction.ImportKind;
pub const ImportKinds = extraction.ImportKinds;
pub const Candidate = matching.Candidate;
pub const Filter = matching.Filter;
pub const MatchingMode = matching.MatchingMode;
pub const Pattern = matching.Pattern;
pub const PatternTarget = matching.PatternTarget;
pub const RegexFactory = matching.RegexFactory;
pub const matchesAny = matching.matchesAny;
pub const matchesSelectors = matching.matchesSelectors;

test "public facade builds and runs pattern filters" {
    var filter = try RegexFactory.pathMatcher(
        std.testing.allocator,
        .{ .glob = "src/**/*.zig" },
    );
    defer filter.deinit();

    try std.testing.expect(try filter.matches(
        std.testing.allocator,
        .{ .path = "src\\domain\\model.zig" },
    ));
}

test {
    _ = std.testing;
    _ = @import("common/extraction.zig");
    _ = @import("common/matching.zig");
}
