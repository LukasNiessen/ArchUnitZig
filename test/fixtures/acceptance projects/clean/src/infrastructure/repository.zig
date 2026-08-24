const std = @import("std");
const domain = @import("domain");

pub fn load() usize {
    return domain.value();
}

test "repository loads a domain value" {
    try std.testing.expectEqual(@as(usize, 10), load());
}
