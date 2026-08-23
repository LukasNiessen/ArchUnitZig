//! Public package root for ArchUnitZig.
//!
//! The rule-building API will be added incrementally as its contracts are implemented and tested.

const std = @import("std");
const extraction = @import("common/extraction.zig");

pub const Edge = extraction.Edge;
pub const Graph = extraction.Graph;
pub const ImportKind = extraction.ImportKind;
pub const ImportKinds = extraction.ImportKinds;

test {
    _ = std.testing;
    _ = @import("common/extraction.zig");
    _ = @import("common/matching.zig");
}
