const model = @import("../domain/model.zig");

pub fn load() usize {
    return model.value;
}
