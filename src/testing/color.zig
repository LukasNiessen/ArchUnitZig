const std = @import("std");

const Allocator = std.mem.Allocator;

pub const ColorMode = enum { auto, always, never };

/// Result messages do not yet know their eventual output stream. Auto colour therefore requires a
/// caller-declared ANSI-capable terminal and still respects the conventional suppression signals.
pub const ColorOptions = struct {
    mode: ColorMode = .auto,
    ansi_terminal: bool = false,
    no_color: bool = false,
    term_is_dumb: bool = false,

    pub fn enabled(self: ColorOptions) bool {
        if (self.no_color or self.term_is_dumb) return false;
        return switch (self.mode) {
            .always => true,
            .never => false,
            .auto => self.ansi_terminal,
        };
    }
};

pub const Style = enum {
    bold_red,
    bold_green,
    yellow,
    cyan,
    blue,
    dim,
};

pub fn writeStyled(
    writer: *std.Io.Writer,
    options: ColorOptions,
    style: Style,
    value: []const u8,
) std.Io.Writer.Error!void {
    if (!options.enabled()) return writer.writeAll(value);
    try writer.writeAll(code(style));
    try writer.writeAll(value);
    try writer.writeAll("\x1b[0m");
}

pub fn styleAlloc(
    allocator: Allocator,
    options: ColorOptions,
    style: Style,
    value: []const u8,
) Allocator.Error![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    writeStyled(&output.writer, options, style, value) catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

fn code(style: Style) []const u8 {
    return switch (style) {
        .bold_red => "\x1b[1;31m",
        .bold_green => "\x1b[1;32m",
        .yellow => "\x1b[33m",
        .cyan => "\x1b[36m",
        .blue => "\x1b[34m",
        .dim => "\x1b[2m",
    };
}

test "colour modes respect terminal capability and automatic suppression" {
    try std.testing.expect(!(ColorOptions{}).enabled());
    try std.testing.expect((ColorOptions{ .ansi_terminal = true }).enabled());
    try std.testing.expect((ColorOptions{ .mode = .always }).enabled());
    try std.testing.expect(!(ColorOptions{ .mode = .always, .no_color = true }).enabled());
    try std.testing.expect(!(ColorOptions{ .mode = .always, .term_is_dumb = true }).enabled());
    try std.testing.expect(!(ColorOptions{ .mode = .never, .ansi_terminal = true }).enabled());
}

test "styled output has deterministic ANSI and plain forms" {
    const colored = try styleAlloc(
        std.testing.allocator,
        .{ .mode = .always },
        .bold_red,
        "Architecture rule failed",
    );
    defer std.testing.allocator.free(colored);
    try std.testing.expectEqualStrings(
        "\x1b[1;31mArchitecture rule failed\x1b[0m",
        colored,
    );

    const plain = try styleAlloc(
        std.testing.allocator,
        .{ .mode = .never },
        .bold_red,
        "Architecture rule failed",
    );
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("Architecture rule failed", plain);
}
