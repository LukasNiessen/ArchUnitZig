const service = @import("../service/root.zig");

pub fn handle() usize {
    return service.execute();
}
