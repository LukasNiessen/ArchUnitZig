//! Public package root for ArchUnitZig.
//!
//! The user-facing API will be added incrementally as its contracts are implemented and tested.

const std = @import("std");

test "the package root compiles" {
    try std.testing.expect(true);
}
