const std = @import("std");

const escaping = @import("escaping.zig");
const report = @import("../projection/report.zig");
const support = @import("support.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
pub const GraphReportSnapshot = report.GraphReportSnapshot;
pub const RenderError = Allocator.Error || error{DanglingEdge};

pub fn toDot(allocator: Allocator, snapshot: *const GraphReportSnapshot) Allocator.Error![]u8 {
    var output: Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    writer.writeAll("digraph dependencies {\n  rankdir=LR;\n  label=") catch return error.OutOfMemory;
    escaping.writeQuoted(writer, snapshot.title) catch return error.OutOfMemory;
    writer.writeAll(";\n  labelloc=t;") catch return error.OutOfMemory;
    for (snapshot.nodes) |node| {
        writer.writeAll("\n  ") catch return error.OutOfMemory;
        escaping.writeQuoted(writer, node.label) catch return error.OutOfMemory;
        writer.writeByte(';') catch return error.OutOfMemory;
    }
    for (snapshot.edges) |edge| {
        writer.writeAll("\n  ") catch return error.OutOfMemory;
        escaping.writeQuoted(writer, edge.source) catch return error.OutOfMemory;
        writer.writeAll(" -> ") catch return error.OutOfMemory;
        escaping.writeQuoted(writer, edge.target) catch return error.OutOfMemory;
        writeDotAttributes(writer, edge) catch return error.OutOfMemory;
        writer.writeByte(';') catch return error.OutOfMemory;
    }
    writer.writeAll("\n}") catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

fn writeDotAttributes(writer: *Writer, edge: report.GraphReportEdge) Writer.Error!void {
    const has_resource_style = support.edgeIsResource(edge.target_classes);
    const has_attributes = edge.count > 1 or edge.external or has_resource_style or edge.import_kinds.count() > 0;
    if (!has_attributes) return;
    try writer.writeAll(" [");
    var wrote = false;
    if (edge.count > 1) {
        try writer.print("label=\"{d}\"", .{edge.count});
        wrote = true;
    }
    if (edge.external) try writeAttributeSeparator(writer, &wrote, "style=dashed");
    if (has_resource_style) try writeAttributeSeparator(writer, &wrote, "color=\"#2563eb\"");
    if (edge.import_kinds.count() > 0) {
        if (wrote) try writer.writeAll(", ");
        try writer.writeAll("tooltip=\"");
        try support.writeImportKinds(writer, edge.import_kinds, ", ");
        try writer.writeByte('"');
    }
    try writer.writeByte(']');
}

fn writeAttributeSeparator(writer: *Writer, wrote: *bool, value: []const u8) Writer.Error!void {
    if (wrote.*) try writer.writeAll(", ");
    try writer.writeAll(value);
    wrote.* = true;
}

pub fn toMermaid(allocator: Allocator, snapshot: *const GraphReportSnapshot) RenderError![]u8 {
    var output: Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    writer.writeAll("%% ") catch return error.OutOfMemory;
    escaping.writeSingleLine(writer, snapshot.title) catch return error.OutOfMemory;
    writer.writeAll("\nflowchart LR") catch return error.OutOfMemory;
    for (snapshot.nodes) |node| {
        writer.print("\n  {s}[\"", .{node.id}) catch return error.OutOfMemory;
        escaping.writeMermaidLabel(writer, node.label) catch return error.OutOfMemory;
        writer.writeAll("\"]") catch return error.OutOfMemory;
    }
    for (snapshot.edges) |edge| {
        const source_id = nodeId(snapshot, edge.source) orelse return error.DanglingEdge;
        const target_id = nodeId(snapshot, edge.target) orelse return error.DanglingEdge;
        writer.print("\n  {s} {s}", .{ source_id, if (edge.external) "-.->" else "-->" }) catch
            return error.OutOfMemory;
        if (edge.count > 1) writer.print("|{d}|", .{edge.count}) catch return error.OutOfMemory;
        writer.print(" {s}", .{target_id}) catch return error.OutOfMemory;
    }
    for (snapshot.edges, 0..) |edge, index| {
        if (!support.edgeIsResource(edge.target_classes)) continue;
        writer.print("\n  linkStyle {d} stroke:#2563eb,stroke-width:2px", .{index}) catch
            return error.OutOfMemory;
    }
    return output.toOwnedSlice();
}

fn nodeId(snapshot: *const GraphReportSnapshot, label: []const u8) ?[]const u8 {
    for (snapshot.nodes) |node| {
        if (std.mem.eql(u8, node.label, label)) return node.id;
    }
    return null;
}

pub fn toD2(allocator: Allocator, snapshot: *const GraphReportSnapshot) Allocator.Error![]u8 {
    var output: Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    writer.writeAll("# ") catch return error.OutOfMemory;
    escaping.writeSingleLine(writer, snapshot.title) catch return error.OutOfMemory;
    for (snapshot.nodes) |node| {
        writer.writeByte('\n') catch return error.OutOfMemory;
        escaping.writeQuoted(writer, node.label) catch return error.OutOfMemory;
    }
    for (snapshot.edges) |edge| {
        writer.writeByte('\n') catch return error.OutOfMemory;
        escaping.writeQuoted(writer, edge.source) catch return error.OutOfMemory;
        writer.writeAll(" -> ") catch return error.OutOfMemory;
        escaping.writeQuoted(writer, edge.target) catch return error.OutOfMemory;
        if (edge.count > 1) writer.print(": \"{d}\"", .{edge.count}) catch return error.OutOfMemory;
        try writeD2Style(writer, edge);
    }
    return output.toOwnedSlice();
}

fn writeD2Style(writer: *Writer, edge: report.GraphReportEdge) Allocator.Error!void {
    const resource = support.edgeIsResource(edge.target_classes);
    if (!edge.external and !resource) return;
    writer.writeAll(" { ") catch return error.OutOfMemory;
    if (edge.external) writer.writeAll("style.stroke-dash: 4") catch return error.OutOfMemory;
    if (edge.external and resource) writer.writeAll("; ") catch return error.OutOfMemory;
    if (resource) writer.writeAll("style.stroke: \"#2563eb\"") catch return error.OutOfMemory;
    writer.writeAll(" }") catch return error.OutOfMemory;
}

pub fn toCsv(allocator: Allocator, snapshot: *const GraphReportSnapshot) Allocator.Error![]u8 {
    var output: Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    writer.writeAll(
        "source,target,count,external,import_kinds,target_classes,target_availabilities",
    ) catch return error.OutOfMemory;
    for (snapshot.edges) |edge| {
        writer.writeByte('\n') catch return error.OutOfMemory;
        escaping.writeCsvField(writer, edge.source) catch return error.OutOfMemory;
        writer.writeByte(',') catch return error.OutOfMemory;
        escaping.writeCsvField(writer, edge.target) catch return error.OutOfMemory;
        writer.print(",{d},{s},\"", .{ edge.count, if (edge.external) "true" else "false" }) catch
            return error.OutOfMemory;
        support.writeImportKinds(writer, edge.import_kinds, "|") catch return error.OutOfMemory;
        writer.writeAll("\",\"") catch return error.OutOfMemory;
        support.writeTargetClasses(writer, edge.target_classes, "|") catch return error.OutOfMemory;
        writer.writeAll("\",\"") catch return error.OutOfMemory;
        support.writeTargetAvailabilities(writer, edge.target_availabilities, "|") catch
            return error.OutOfMemory;
        writer.writeByte('"') catch return error.OutOfMemory;
    }
    return output.toOwnedSlice();
}

test "DOT renderer has stable golden output with aggregate external and resource styles" {
    var snapshot = try @import("test_snapshot.zig").make(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);
    const rendered = try toDot(std.testing.allocator, &snapshot);
    defer std.testing.allocator.free(rendered);
    const expected =
        \\digraph dependencies {
        \\  rankdir=LR;
        \\  label="Architecture <Main>\r\n\"quoted\"";
        \\  labelloc=t;
        \\  "app/\"api\"\n.zig";
        \\  "assets/config,<x>.json";
        \\  "domain<&>.zig";
        \\  "std";
        \\  "app/\"api\"\n.zig" -> "assets/config,<x>.json" [color="#2563eb", tooltip="embedded_file"];
        \\  "app/\"api\"\n.zig" -> "domain<&>.zig" [label="2", tooltip="zig_file, root_module"];
        \\  "app/\"api\"\n.zig" -> "std" [style=dashed, tooltip="standard_library"];
        \\}
    ;
    try std.testing.expectEqualStrings(expected, rendered);
}

test "Mermaid renderer uses node ids escaped labels and resource link styling" {
    var snapshot = try @import("test_snapshot.zig").make(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);
    const rendered = try toMermaid(std.testing.allocator, &snapshot);
    defer std.testing.allocator.free(rendered);
    const expected =
        \\%% Architecture <Main> "quoted"
        \\flowchart LR
        \\  n0["app/&quot;api&quot;<br/>.zig"]
        \\  n1["assets/config,&lt;x&gt;.json"]
        \\  n2["domain&lt;&amp;&gt;.zig"]
        \\  n3["std"]
        \\  n0 --> n1
        \\  n0 -->|2| n2
        \\  n0 -.-> n3
        \\  linkStyle 0 stroke:#2563eb,stroke-width:2px
    ;
    try std.testing.expectEqualStrings(expected, rendered);
}

test "Mermaid rejects an edge whose label has no snapshot node" {
    var snapshot = try @import("test_snapshot.zig").make(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);
    std.testing.allocator.free(snapshot.edges[0].target);
    snapshot.edges[0].target = try std.testing.allocator.dupe(u8, "missing.zig");
    try std.testing.expectError(error.DanglingEdge, toMermaid(std.testing.allocator, &snapshot));
}

test "D2 renderer has stable quoted output and edge styles" {
    var snapshot = try @import("test_snapshot.zig").make(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);
    const rendered = try toD2(std.testing.allocator, &snapshot);
    defer std.testing.allocator.free(rendered);
    const expected =
        \\# Architecture <Main> "quoted"
        \\"app/\"api\"\n.zig"
        \\"assets/config,<x>.json"
        \\"domain<&>.zig"
        \\"std"
        \\"app/\"api\"\n.zig" -> "assets/config,<x>.json" { style.stroke: "#2563eb" }
        \\"app/\"api\"\n.zig" -> "domain<&>.zig": "2"
        \\"app/\"api\"\n.zig" -> "std" { style.stroke-dash: 4 }
    ;
    try std.testing.expectEqualStrings(expected, rendered);
}

test "CSV renderer quotes hostile fields and includes every classification set" {
    var snapshot = try @import("test_snapshot.zig").make(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);
    const rendered = try toCsv(std.testing.allocator, &snapshot);
    defer std.testing.allocator.free(rendered);
    const expected =
        "source,target,count,external,import_kinds,target_classes,target_availabilities\n" ++
        "\"app/\"\"api\"\"\n.zig\",\"assets/config,<x>.json\",1,false,\"embedded_file\",\"resource\",\"resolved\"\n" ++
        "\"app/\"\"api\"\"\n.zig\",domain<&>.zig,2,false,\"zig_file|root_module\",\"internal\",\"resolved\"\n" ++
        "\"app/\"\"api\"\"\n.zig\",std,1,true,\"standard_library\",\"compiler\",\"unresolved\"";
    try std.testing.expectEqualStrings(expected, rendered);
}

fn exerciseAllocationFailures(allocator: Allocator, snapshot: *const GraphReportSnapshot) RenderError!void {
    const dot = try toDot(allocator, snapshot);
    defer allocator.free(dot);
    const mermaid = try toMermaid(allocator, snapshot);
    defer allocator.free(mermaid);
    const d2 = try toD2(allocator, snapshot);
    defer allocator.free(d2);
    const csv = try toCsv(allocator, snapshot);
    defer allocator.free(csv);
}

test "text renderers clean up every allocation failure" {
    var snapshot = try @import("test_snapshot.zig").make(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{&snapshot},
    );
}
