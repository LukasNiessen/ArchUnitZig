const a = @import("a.zig");

pub fn value() usize {
    return @sizeOf(@TypeOf(a));
}
