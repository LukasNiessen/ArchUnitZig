const std = @import("std");

const Worker = struct {
    value: u8,

    pub fn run(self: Worker) u8 {
        return self.value;
    }
};

pub fn main() void {
    _ = std;
}

test "worker" {
    try std.testing.expectEqual(@as(u8, 1), (Worker{ .value = 1 }).run());
}
