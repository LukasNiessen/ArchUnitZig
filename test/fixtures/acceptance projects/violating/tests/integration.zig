const std = @import("std");
const builtin = @import("builtin");
const root_module = @import("root");
const app = @import("app");
const vendor_package = @import("vendor_pkg");

test "second compilation root sees local and package modules" {
    _ = builtin;
    _ = root_module;
    try std.testing.expect(app.score() > vendor_package.value);
}
