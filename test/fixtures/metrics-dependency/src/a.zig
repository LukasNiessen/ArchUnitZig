const std = @import("std");
const b = @import("b.zig");
const c = @import("c.zig");

test "a" {
    try std.testing.expectEqual(@as(u8, 4), b.value + c.value);
}
