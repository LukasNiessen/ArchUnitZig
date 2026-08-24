const std = @import("std");
const builtin = @import("builtin");
const root_module = @import("root");

pub fn value() usize {
    _ = builtin;
    _ = root_module;
    return 10;
}

test "domain value is stable" {
    try std.testing.expectEqual(@as(usize, 10), value());
}
