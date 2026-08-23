const std = @import("std");

const extraction = @import("../../common/extraction.zig");
const report = @import("../projection/report.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
pub const GraphReportSnapshot = report.GraphReportSnapshot;

pub fn toJson(allocator: Allocator, snapshot: *const GraphReportSnapshot) Allocator.Error![]u8 {
    var output: Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    writeSnapshot(&output.writer, snapshot) catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

fn writeSnapshot(writer: *Writer, snapshot: *const GraphReportSnapshot) Writer.Error!void {
    var json: std.json.Stringify = .{
        .writer = writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try json.beginObject();
    try json.objectField("title");
    try json.write(snapshot.title);
    try json.objectField("nodes");
    try json.beginArray();
    for (snapshot.nodes) |node| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(node.id);
        try json.objectField("label");
        try json.write(node.label);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("edges");
    try json.beginArray();
    for (snapshot.edges) |edge| {
        try json.beginObject();
        try json.objectField("source");
        try json.write(edge.source);
        try json.objectField("target");
        try json.write(edge.target);
        try json.objectField("count");
        try json.write(edge.count);
        try json.objectField("external");
        try json.write(edge.external);
        try json.objectField("import_kinds");
        try writeEnumSet(&json, extraction.ImportKind, edge.import_kinds);
        try json.objectField("target_classes");
        try writeEnumSet(&json, extraction.TargetClass, edge.target_classes);
        try json.objectField("target_availabilities");
        try writeEnumSet(&json, extraction.TargetAvailability, edge.target_availabilities);
        try json.endObject();
    }
    try json.endArray();
    try json.objectField("summary");
    try json.beginObject();
    try json.objectField("node_count");
    try json.write(snapshot.summary.node_count);
    try json.objectField("edge_count");
    try json.write(snapshot.summary.edge_count);
    try json.objectField("raw_edge_count");
    try json.write(snapshot.summary.raw_edge_count);
    try json.objectField("external_edge_count");
    try json.write(snapshot.summary.external_edge_count);
    try json.endObject();
    try json.endObject();
}

fn writeEnumSet(json: *std.json.Stringify, comptime E: type, set: std.EnumSet(E)) Writer.Error!void {
    try json.beginArray();
    inline for (std.meta.fields(E)) |field| {
        const value: E = @enumFromInt(field.value);
        if (set.contains(value)) try json.write(field.name);
    }
    try json.endArray();
}

test "JSON renderer emits the complete stable snapshot and round trips hostile strings" {
    var snapshot = try @import("test_snapshot.zig").make(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);
    const rendered = try toJson(std.testing.allocator, &snapshot);
    defer std.testing.allocator.free(rendered);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(snapshot.title, root.get("title").?.string);
    try std.testing.expectEqual(@as(usize, 4), root.get("nodes").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 3), root.get("edges").?.array.items.len);
    const resource = root.get("edges").?.array.items[1].object;
    try std.testing.expectEqualStrings("resource", resource.get("target_classes").?.array.items[0].string);
    try std.testing.expectEqual(@as(i64, 4), root.get("summary").?.object.get("raw_edge_count").?.integer);

    const expected_prefix =
        \\{
        \\  "title": "Architecture <Main>\r\n\"quoted\"",
        \\  "nodes": [
        \\    {
        \\      "id": "n0",
        \\      "label": "app/\"api\"\n.zig"
        \\    },
    ;
    try std.testing.expect(std.mem.startsWith(u8, rendered, expected_prefix));
    try std.testing.expect(std.mem.endsWith(
        u8,
        rendered,
        "    \"raw_edge_count\": 4,\n    \"external_edge_count\": 1\n  }\n}",
    ));
}

test "empty JSON snapshot has parseable empty collections" {
    const empty_nodes = try std.testing.allocator.alloc(report.GraphReportNode, 0);
    const empty_edges = try std.testing.allocator.alloc(report.GraphReportEdge, 0);
    var snapshot = report.GraphReportSnapshot{
        .title = try std.testing.allocator.dupe(u8, "Empty"),
        .nodes = empty_nodes,
        .edges = empty_edges,
        .summary = .{ .node_count = 0, .edge_count = 0, .raw_edge_count = 0, .external_edge_count = 0 },
    };
    defer snapshot.deinit(std.testing.allocator);
    const rendered = try toJson(std.testing.allocator, &snapshot);
    defer std.testing.allocator.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("nodes").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("edges").?.array.items.len);
}

fn exerciseAllocationFailures(allocator: Allocator, snapshot: *const GraphReportSnapshot) Allocator.Error!void {
    const rendered = try toJson(allocator, snapshot);
    defer allocator.free(rendered);
}

test "JSON rendering cleans up every allocation failure" {
    var snapshot = try @import("test_snapshot.zig").make(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{&snapshot},
    );
}
