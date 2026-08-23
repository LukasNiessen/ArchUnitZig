const inside = @import("boundary/inside.zig");

pub fn value() usize {
    return @sizeOf(@TypeOf(inside));
}
