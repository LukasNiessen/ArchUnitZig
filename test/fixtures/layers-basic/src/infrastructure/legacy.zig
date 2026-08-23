const api = @import("../presentation/api.zig");

pub fn callLegacy() usize {
    return api.handle();
}
