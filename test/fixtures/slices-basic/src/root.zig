const std = @import("std");
const entry = @import("features/api/entry.zig");

test "fixture remains a valid Zig project" {
    try std.testing.expectEqual(@as(usize, 5), entry.handle("ok"));
}
