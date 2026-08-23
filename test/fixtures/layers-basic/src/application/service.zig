const model = @import("../domain/model.zig");
const logger = @import("../support/logger.zig");

pub fn execute() usize {
    logger.record();
    return model.value;
}
