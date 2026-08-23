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
    _ = @import("common/extraction/edge.zig");
    _ = @import("common/extraction/graph.zig");
    _ = @import("common/extraction/identifier.zig");
    _ = @import("common/extraction/import_kind.zig");
}
