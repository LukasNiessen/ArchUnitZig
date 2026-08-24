const std = @import("std");
const domain = @import("domain");

pub fn value() usize {
    return domain.value() + 1;
}

test "application delegates to domain" {
    try std.testing.expectEqual(@as(usize, 11), value());
}
