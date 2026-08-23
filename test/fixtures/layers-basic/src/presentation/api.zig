const service = @import("../application/service.zig");

pub fn handle() usize {
    return service.execute();
}
