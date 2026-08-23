const bridge = @import("../bridge.zig");

pub fn value() usize {
    return @sizeOf(@TypeOf(bridge));
}
