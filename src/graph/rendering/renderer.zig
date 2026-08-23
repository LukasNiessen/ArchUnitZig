const std = @import("std");

const html_renderer = @import("html_renderer.zig");
const json_renderer = @import("json_renderer.zig");
const report = @import("../projection/report.zig");
const text_renderers = @import("text_renderers.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const GraphReportSnapshot = report.GraphReportSnapshot;
pub const RenderError = text_renderers.RenderError;
pub const ExportError = RenderError || std.Io.Dir.CreateDirPathError || std.Io.Dir.WriteFileError || error{
    InvalidOutputPath,
};

pub const GraphReportFormat = enum {
    dot,
    mermaid,
    d2,
    csv,
    json,
    html,

    pub fn extension(self: GraphReportFormat) []const u8 {
        return @tagName(self);
    }
};

pub const GraphRenderer = struct {
    pub fn render(
        allocator: Allocator,
        snapshot: *const GraphReportSnapshot,
        format: GraphReportFormat,
    ) RenderError![]u8 {
        return switch (format) {
            .dot => text_renderers.toDot(allocator, snapshot),
            .mermaid => text_renderers.toMermaid(allocator, snapshot),
            .d2 => text_renderers.toD2(allocator, snapshot),
            .csv => text_renderers.toCsv(allocator, snapshot),
            .json => json_renderer.toJson(allocator, snapshot),
            .html => html_renderer.toHtml(allocator, snapshot),
        };
    }

    pub fn exportReport(
        allocator: Allocator,
        io: Io,
        snapshot: *const GraphReportSnapshot,
        format: GraphReportFormat,
        output_path: []const u8,
    ) ExportError!void {
        if (std.mem.trim(u8, output_path, " \t\r\n\x0b\x0c").len == 0) {
            return error.InvalidOutputPath;
        }
        const rendered = try render(allocator, snapshot, format);
        defer allocator.free(rendered);
        if (std.fs.path.dirname(output_path)) |parent| {
            if (parent.len > 0 and !std.mem.eql(u8, parent, ".")) {
                try std.Io.Dir.cwd().createDirPath(io, parent);
            }
        }
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = rendered });
    }

    pub fn toDot(allocator: Allocator, snapshot: *const GraphReportSnapshot) Allocator.Error![]u8 {
        return text_renderers.toDot(allocator, snapshot);
    }

    pub fn toMermaid(allocator: Allocator, snapshot: *const GraphReportSnapshot) RenderError![]u8 {
        return text_renderers.toMermaid(allocator, snapshot);
    }

    pub fn toD2(allocator: Allocator, snapshot: *const GraphReportSnapshot) Allocator.Error![]u8 {
        return text_renderers.toD2(allocator, snapshot);
    }

    pub fn toCsv(allocator: Allocator, snapshot: *const GraphReportSnapshot) Allocator.Error![]u8 {
        return text_renderers.toCsv(allocator, snapshot);
    }

    pub fn toJson(allocator: Allocator, snapshot: *const GraphReportSnapshot) Allocator.Error![]u8 {
        return json_renderer.toJson(allocator, snapshot);
    }

    pub fn toHtml(allocator: Allocator, snapshot: *const GraphReportSnapshot) RenderError![]u8 {
        return html_renderer.toHtml(allocator, snapshot);
    }

    pub fn exportAsDot(allocator: Allocator, io: Io, snapshot: *const GraphReportSnapshot, path: []const u8) ExportError!void {
        return exportReport(allocator, io, snapshot, .dot, path);
    }

    pub fn exportAsMermaid(allocator: Allocator, io: Io, snapshot: *const GraphReportSnapshot, path: []const u8) ExportError!void {
        return exportReport(allocator, io, snapshot, .mermaid, path);
    }

    pub fn exportAsD2(allocator: Allocator, io: Io, snapshot: *const GraphReportSnapshot, path: []const u8) ExportError!void {
        return exportReport(allocator, io, snapshot, .d2, path);
    }

    pub fn exportAsCsv(allocator: Allocator, io: Io, snapshot: *const GraphReportSnapshot, path: []const u8) ExportError!void {
        return exportReport(allocator, io, snapshot, .csv, path);
    }

    pub fn exportAsJson(allocator: Allocator, io: Io, snapshot: *const GraphReportSnapshot, path: []const u8) ExportError!void {
        return exportReport(allocator, io, snapshot, .json, path);
    }

    pub fn exportAsHtml(allocator: Allocator, io: Io, snapshot: *const GraphReportSnapshot, path: []const u8) ExportError!void {
        return exportReport(allocator, io, snapshot, .html, path);
    }
};

test "closed format dispatch matches every owned specific renderer" {
    var snapshot = try @import("test_snapshot.zig").make(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);
    inline for (std.meta.fields(GraphReportFormat)) |field| {
        const format: GraphReportFormat = @enumFromInt(field.value);
        const dispatched = try GraphRenderer.render(std.testing.allocator, &snapshot, format);
        defer std.testing.allocator.free(dispatched);
        const specific = switch (format) {
            .dot => try GraphRenderer.toDot(std.testing.allocator, &snapshot),
            .mermaid => try GraphRenderer.toMermaid(std.testing.allocator, &snapshot),
            .d2 => try GraphRenderer.toD2(std.testing.allocator, &snapshot),
            .csv => try GraphRenderer.toCsv(std.testing.allocator, &snapshot),
            .json => try GraphRenderer.toJson(std.testing.allocator, &snapshot),
            .html => try GraphRenderer.toHtml(std.testing.allocator, &snapshot),
        };
        defer std.testing.allocator.free(specific);
        try std.testing.expectEqualStrings(specific, dispatched);
        try std.testing.expectEqualStrings(field.name, format.extension());
    }
}

test "every format renders an empty snapshot" {
    var snapshot = try GraphReportSnapshot.init(
        std.testing.allocator,
        "Empty graph",
        &.{},
        &.{},
        .{ .node_count = 0, .edge_count = 0, .raw_edge_count = 0, .external_edge_count = 0 },
    );
    defer snapshot.deinit(std.testing.allocator);
    inline for (std.meta.fields(GraphReportFormat)) |field| {
        const rendered = try GraphRenderer.render(
            std.testing.allocator,
            &snapshot,
            @enumFromInt(field.value),
        );
        defer std.testing.allocator.free(rendered);
        try std.testing.expect(rendered.len > 0);
    }
}

test "every format exports identical UTF-8 bytes into newly created parents" {
    var snapshot = try @import("test_snapshot.zig").make(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    inline for (std.meta.fields(GraphReportFormat)) |field| {
        const format: GraphReportFormat = @enumFromInt(field.value);
        const filename = try std.fmt.allocPrint(std.testing.allocator, "report.{s}", .{field.name});
        defer std.testing.allocator.free(filename);
        const absolute = try std.fs.path.join(std.testing.allocator, &.{ root, "nested", field.name, filename });
        defer std.testing.allocator.free(absolute);
        try GraphRenderer.exportReport(
            std.testing.allocator,
            std.testing.io,
            &snapshot,
            format,
            absolute,
        );
        const actual = try std.Io.Dir.cwd().readFileAllocOptions(
            std.testing.io,
            absolute,
            std.testing.allocator,
            .limited(std.math.maxInt(usize)),
            .of(u8),
            0,
        );
        defer std.testing.allocator.free(actual);
        const expected = try GraphRenderer.render(std.testing.allocator, &snapshot, format);
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "export rejects blank paths and propagates parent creation failures" {
    var snapshot = try @import("test_snapshot.zig").make(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidOutputPath,
        GraphRenderer.exportReport(
            std.testing.allocator,
            std.testing.io,
            &snapshot,
            .json,
            " \t",
        ),
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blocker", .data = "file" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const blocked = try std.fs.path.join(std.testing.allocator, &.{ root, "blocker", "report.json" });
    defer std.testing.allocator.free(blocked);
    if (GraphRenderer.exportReport(
        std.testing.allocator,
        std.testing.io,
        &snapshot,
        .json,
        blocked,
    )) {
        return error.TestExpectedError;
    } else |failure| {
        try std.testing.expect(failure != error.InvalidOutputPath);
    }
}

fn exerciseAllocationFailures(allocator: Allocator, snapshot: *const GraphReportSnapshot) RenderError!void {
    inline for (std.meta.fields(GraphReportFormat)) |field| {
        const rendered = try GraphRenderer.render(allocator, snapshot, @enumFromInt(field.value));
        defer allocator.free(rendered);
    }
}

test "format dispatch cleans up every allocation failure" {
    var snapshot = try @import("test_snapshot.zig").make(std.testing.allocator);
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{&snapshot},
    );
}
