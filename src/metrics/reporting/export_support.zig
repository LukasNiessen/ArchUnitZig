const std = @import("std");

const html_renderer = @import("html_renderer.zig");
const report_data = @import("report_data.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const MetricsExportOptions = html_renderer.MetricsExportOptions;
pub const MetricsReportData = report_data.MetricsReportData;
pub const ExportError = html_renderer.RenderError || std.Io.Dir.CreateDirPathError || std.Io.Dir.WriteFileError || error{
    InvalidOutputPath,
};

pub fn toHtml(
    allocator: Allocator,
    io: Io,
    data: *const MetricsReportData,
    options: MetricsExportOptions,
) html_renderer.RenderError![]u8 {
    return html_renderer.toHtml(allocator, io, data, options);
}

/// Writes an offline report, appending `.html` when the supplied file name has another or no
/// extension. Parent directories are created before the file is opened.
pub fn exportAsHtml(
    allocator: Allocator,
    io: Io,
    data: *const MetricsReportData,
    output_path: []const u8,
    options: MetricsExportOptions,
) ExportError!void {
    const resolved = try resolveHtmlPath(allocator, output_path);
    defer allocator.free(resolved);
    const html = try html_renderer.toHtml(allocator, io, data, options);
    defer allocator.free(html);
    if (std.fs.path.dirname(resolved)) |parent| {
        if (parent.len != 0 and !std.mem.eql(u8, parent, ".")) {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        }
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = resolved, .data = html });
}

pub fn resolveHtmlPath(allocator: Allocator, output_path: []const u8) (Allocator.Error || error{InvalidOutputPath})![]u8 {
    const trimmed = std.mem.trim(u8, output_path, " \t\r\n\x0b\x0c");
    if (trimmed.len == 0 or
        std.mem.endsWith(u8, trimmed, "/") or
        std.mem.endsWith(u8, trimmed, "\\")) return error.InvalidOutputPath;
    const basename = std.fs.path.basename(trimmed);
    if (basename.len == 0 or std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..")) {
        return error.InvalidOutputPath;
    }
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(basename), ".html")) {
        return allocator.dupe(u8, trimmed);
    }
    return std.fmt.allocPrint(allocator, "{s}.html", .{trimmed});
}

test "export creates nested directories appends extension and writes rendered bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const requested = try std.fs.path.join(std.testing.allocator, &.{ root, "nested", "quality-report" });
    defer std.testing.allocator.free(requested);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}.html", .{requested});
    defer std.testing.allocator.free(expected);
    var section = try report_data.countSection(std.testing.allocator, "Count", 1, 0, .{ .functions = 2 });
    var section_owned = true;
    errdefer if (section_owned) section.deinit(std.testing.allocator);
    var data = MetricsReportData{};
    defer data.deinit(std.testing.allocator);
    try data.appendSectionMove(std.testing.allocator, &section);
    section_owned = false;

    try exportAsHtml(
        std.testing.allocator,
        std.testing.io,
        &data,
        requested,
        .{ .title = "Quality", .include_timestamp = false },
    );
    const written = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        expected,
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(written);
    const rendered = try toHtml(
        std.testing.allocator,
        std.testing.io,
        &data,
        .{ .title = "Quality", .include_timestamp = false },
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(rendered, written);
}

test "output path resolution is explicit and case-insensitive for HTML" {
    const already = try resolveHtmlPath(std.testing.allocator, "reports/quality.HTML");
    defer std.testing.allocator.free(already);
    try std.testing.expectEqualStrings("reports/quality.HTML", already);
    const appended = try resolveHtmlPath(std.testing.allocator, "reports/quality.json");
    defer std.testing.allocator.free(appended);
    try std.testing.expectEqualStrings("reports/quality.json.html", appended);
    for ([_][]const u8{ "", " \t", ".", "..", "reports/", "reports\\" }) |invalid| {
        try std.testing.expectError(error.InvalidOutputPath, resolveHtmlPath(std.testing.allocator, invalid));
    }
}

test "directory and write failures propagate instead of disappearing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blocker", .data = "not a directory" });
    const blocked = try std.fs.path.join(std.testing.allocator, &.{ root, "blocker", "report.html" });
    defer std.testing.allocator.free(blocked);
    var data = MetricsReportData{};
    defer data.deinit(std.testing.allocator);
    var failed = false;
    exportAsHtml(
        std.testing.allocator,
        std.testing.io,
        &data,
        blocked,
        .{ .include_timestamp = false },
    ) catch {
        failed = true;
    };
    try std.testing.expect(failed);

    try tmp.dir.createDir(std.testing.io, "directory.html", .default_dir);
    const directory_output = try std.fs.path.join(std.testing.allocator, &.{ root, "directory.html" });
    defer std.testing.allocator.free(directory_output);
    failed = false;
    exportAsHtml(
        std.testing.allocator,
        std.testing.io,
        &data,
        directory_output,
        .{ .include_timestamp = false },
    ) catch {
        failed = true;
    };
    try std.testing.expect(failed);
}
