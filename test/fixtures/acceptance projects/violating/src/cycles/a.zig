const b = @import("b.zig");

pub fn fromA() usize {
    return b.fromB();
}
