pub const formatCyclePath = @import("testing/cycle_path.zig").formatCyclePath;
pub const ColorMode = @import("testing/color.zig").ColorMode;
pub const ColorOptions = @import("testing/color.zig").ColorOptions;

test {
    _ = @import("testing/color.zig");
    _ = @import("testing/cycle_path.zig");
}
