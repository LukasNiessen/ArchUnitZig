const a = @import("a.zig");

pub fn fromB() usize {
    return @intFromBool(@hasDecl(a, "fromA"));
}
