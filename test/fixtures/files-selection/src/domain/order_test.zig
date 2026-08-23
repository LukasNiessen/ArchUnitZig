const std = @import("std");
const Order = @import("order.zig").Order;

test "order is constructible" {
    _ = Order{};
    try std.testing.expect(true);
}
