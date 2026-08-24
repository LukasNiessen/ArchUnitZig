const std = @import("std");
const builtin = @import("builtin");
const root_module = @import("root");
const application = @import("application");
const vendor_package = @import("vendor_pkg");
const forbidden_repository = @import("infrastructure");
const app_config = @import("data/app.zon");
const banner = @embedFile("assets/banner.txt");
const c = @cImport({
    @cInclude("acceptance.h");
});

comptime {
    _ = @import("test_support.zig");
}

pub fn score() usize {
    _ = builtin;
    _ = root_module;
    return application.value() + vendor_package.value + forbidden_repository.load() + app_config.weight + banner.len + c.ACCEPTANCE_VALUE;
}

test "reachable violating twin still builds offline" {
    const support = @import("test_support.zig");
    try std.testing.expect(support.enabled);
    try std.testing.expect(score() > 0);
}
