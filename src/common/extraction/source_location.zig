const std = @import("std");

/// Location of a dependency builtin. Byte offsets are zero-based; lines and columns are one-based.
pub const SourceLocation = struct {
    byte_offset: u32,
    line: usize,
    column: usize,

    pub fn lessThan(left: SourceLocation, right: SourceLocation) bool {
        if (left.byte_offset != right.byte_offset) return left.byte_offset < right.byte_offset;
        if (left.line != right.line) return left.line < right.line;
        return left.column < right.column;
    }
};

test "source locations have deterministic lexical order" {
    const locations = [_]SourceLocation{
        .{ .byte_offset = 20, .line = 2, .column = 4 },
        .{ .byte_offset = 4, .line = 1, .column = 5 },
        .{ .byte_offset = 20, .line = 2, .column = 3 },
    };
    var sorted = locations;
    std.mem.sort(SourceLocation, &sorted, {}, struct {
        fn lessThan(_: void, left: SourceLocation, right: SourceLocation) bool {
            return left.lessThan(right);
        }
    }.lessThan);
    try std.testing.expectEqual(@as(u32, 4), sorted[0].byte_offset);
    try std.testing.expectEqual(@as(usize, 3), sorted[1].column);
}
