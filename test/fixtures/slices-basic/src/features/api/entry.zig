const std = @import("std");
const helper = @import("helper.zig");
const worker = @import("../services/worker.zig");
const repository = @import("../retrieval/repository.zig");

pub fn handle(input: []const u8) usize {
    return std.mem.trim(u8, input, " ").len + helper.value() + worker.run() + repository.fetch();
}
