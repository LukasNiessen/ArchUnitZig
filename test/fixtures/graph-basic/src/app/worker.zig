const service = @import("../domain/service.zig");

pub fn run() usize {
    return service.value();
}
