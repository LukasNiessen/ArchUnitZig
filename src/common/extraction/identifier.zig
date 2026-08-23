const std = @import("std");

const Allocator = std.mem.Allocator;

/// Returns an owned identifier with platform separators normalised to `/` and repeated separators
/// collapsed. Extraction is responsible for making internal identifiers project-relative before
/// they enter the graph; this function intentionally leaves other bytes, including `..`, alone so
/// unresolved external targets remain diagnosable.
pub fn normalize(allocator: Allocator, identifier: []const u8) Allocator.Error![]u8 {
    var output_length = identifier.len;
    var previous_was_separator = false;

    for (identifier) |byte| {
        const is_separator = byte == '/' or byte == '\\';
        if (is_separator and previous_was_separator) output_length -= 1;
        previous_was_separator = is_separator;
    }

    const output = try allocator.alloc(u8, output_length);
    var output_index: usize = 0;
    previous_was_separator = false;

    for (identifier) |byte| {
        const is_separator = byte == '/' or byte == '\\';
        if (is_separator and previous_was_separator) continue;

        output[output_index] = if (is_separator) '/' else byte;
        output_index += 1;
        previous_was_separator = is_separator;
    }

    return output;
}

test "normalise Windows and repeated separators" {
    const actual = try normalize(std.testing.allocator, "src\\\\api//handler.zig");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings("src/api/handler.zig", actual);
}

test "normalisation leaves module names and UTF-8 bytes intact" {
    const actual = try normalize(std.testing.allocator, "módules/example");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings("módules/example", actual);
}

test "normalisation supports an empty identifier" {
    const actual = try normalize(std.testing.allocator, "");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqual(@as(usize, 0), actual.len);
}
