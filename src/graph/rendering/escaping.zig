const std = @import("std");

const Writer = std.Io.Writer;

/// Writes one DOT/D2-compatible double-quoted value without raw line controls.
pub fn writeQuoted(writer: *Writer, value: []const u8) Writer.Error!void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x08 => try writer.writeAll("\\b"),
        0x0c => try writer.writeAll("\\f"),
        else => try writer.writeByte(byte),
    };
    try writer.writeByte('"');
}

/// Writes an HTML-safe label for a quoted Mermaid node, converting physical lines to `<br/>`.
pub fn writeMermaidLabel(writer: *Writer, value: []const u8) Writer.Error!void {
    var index: usize = 0;
    while (index < value.len) : (index += 1) switch (value[index]) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&#39;"),
        '\r' => {
            if (index + 1 < value.len and value[index + 1] == '\n') index += 1;
            try writer.writeAll("<br/>");
        },
        '\n' => try writer.writeAll("<br/>"),
        else => try writer.writeByte(value[index]),
    };
}

pub fn writeHtml(writer: *Writer, value: []const u8) Writer.Error!void {
    for (value) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&#39;"),
        else => try writer.writeByte(byte),
    };
}

/// Writes comment-safe text on one physical line.
pub fn writeSingleLine(writer: *Writer, value: []const u8) Writer.Error!void {
    var index: usize = 0;
    while (index < value.len) : (index += 1) switch (value[index]) {
        '\r' => {
            if (index + 1 < value.len and value[index + 1] == '\n') index += 1;
            try writer.writeByte(' ');
        },
        '\n' => try writer.writeByte(' '),
        else => try writer.writeByte(value[index]),
    };
}

/// Writes one RFC 4180 field, quoting only when required.
pub fn writeCsvField(writer: *Writer, value: []const u8) Writer.Error!void {
    if (std.mem.indexOfAny(u8, value, ",\"\r\n") == null) return writer.writeAll(value);
    try writer.writeByte('"');
    for (value) |byte| {
        if (byte == '"') try writer.writeByte('"');
        try writer.writeByte(byte);
    }
    try writer.writeByte('"');
}

test "quoted escaping handles hostile quotes backslashes and line controls" {
    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeQuoted(&output.writer, "a\\\"b\r\nc\td");
    try std.testing.expectEqualStrings("\"a\\\\\\\"b\\r\\nc\\td\"", output.written());
}

test "Mermaid and HTML escaping prevent markup injection" {
    var mermaid: Writer.Allocating = .init(std.testing.allocator);
    defer mermaid.deinit();
    try writeMermaidLabel(&mermaid.writer, "</script> & \"x\"\r\ny");
    try std.testing.expectEqualStrings(
        "&lt;/script&gt; &amp; &quot;x&quot;<br/>y",
        mermaid.written(),
    );
    var html: Writer.Allocating = .init(std.testing.allocator);
    defer html.deinit();
    try writeHtml(&html.writer, "<&>\"'");
    try std.testing.expectEqualStrings("&lt;&amp;&gt;&quot;&#39;", html.written());
}

test "single-line and CSV escaping normalize comments and quote records" {
    var line: Writer.Allocating = .init(std.testing.allocator);
    defer line.deinit();
    try writeSingleLine(&line.writer, "one\r\ntwo\nthree");
    try std.testing.expectEqualStrings("one two three", line.written());
    var csv: Writer.Allocating = .init(std.testing.allocator);
    defer csv.deinit();
    try writeCsvField(&csv.writer, "a,\"b\"\n");
    try std.testing.expectEqualStrings("\"a,\"\"b\"\"\n\"", csv.written());
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
    var output: Writer.Allocating = .init(allocator);
    defer output.deinit();
    writeQuoted(&output.writer, "a\\\"b\r\nc\td") catch return error.OutOfMemory;
    writeMermaidLabel(&output.writer, "</script> & \"x\"\r\ny") catch return error.OutOfMemory;
    writeHtml(&output.writer, "<&>\"'") catch return error.OutOfMemory;
    writeCsvField(&output.writer, "a,\"b\"\n") catch return error.OutOfMemory;
}

test "escaping helpers clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
