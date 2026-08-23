const std = @import("std");

const extraction = @import("../../common/extraction.zig");

const Writer = std.Io.Writer;

pub fn writeImportKinds(writer: *Writer, kinds: extraction.ImportKinds, separator: []const u8) Writer.Error!void {
    return writeEnumSet(writer, extraction.ImportKind, kinds, separator);
}

pub fn writeTargetClasses(writer: *Writer, classes: extraction.TargetClasses, separator: []const u8) Writer.Error!void {
    return writeEnumSet(writer, extraction.TargetClass, classes, separator);
}

pub fn writeTargetAvailabilities(
    writer: *Writer,
    availabilities: extraction.TargetAvailabilities,
    separator: []const u8,
) Writer.Error!void {
    return writeEnumSet(writer, extraction.TargetAvailability, availabilities, separator);
}

fn writeEnumSet(writer: *Writer, comptime E: type, set: std.EnumSet(E), separator: []const u8) Writer.Error!void {
    var wrote = false;
    inline for (std.meta.fields(E)) |field| {
        const value: E = @enumFromInt(field.value);
        if (set.contains(value)) {
            if (wrote) try writer.writeAll(separator);
            try writer.writeAll(field.name);
            wrote = true;
        }
    }
}

pub fn edgeIsResource(classes: extraction.TargetClasses) bool {
    return classes.contains(.resource);
}

test "classification sets render in stable enum declaration order" {
    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeImportKinds(
        &output.writer,
        extraction.ImportKinds.initMany(&.{ .embedded_file, .zig_file, .root_module }),
        "|",
    );
    try std.testing.expectEqualStrings("zig_file|root_module|embedded_file", output.written());
}
