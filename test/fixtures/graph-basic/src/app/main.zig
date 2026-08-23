const std = @import("std");
const service = @import("../domain/service.zig");
const settings = @embedFile("../../assets/settings.json");

pub fn main() void {
    std.debug.print("{s}: {d}\n", .{ settings, service.value() });
}
