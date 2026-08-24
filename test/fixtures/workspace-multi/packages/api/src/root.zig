const helper = @import("helper.zig");
const shared = @import("shared");

pub fn run() void {
    helper.touch();
    shared.touch();
}
