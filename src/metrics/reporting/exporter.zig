const std = @import("std");

const fluent_metrics = @import("../fluentapi/metrics.zig");
const export_support = @import("export_support.zig");
const report_data = @import("report_data.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const CheckOptions = fluent_metrics.CheckOptions;
pub const MetricsExportOptions = export_support.MetricsExportOptions;
pub const MetricsReportData = report_data.MetricsReportData;
pub const MetricsScope = fluent_metrics.MetricsScope;

/// Public facade for programmatic comprehensive gathering, pure rendering, and explicit export.
pub const MetricsExporter = struct {
    pub fn gatherComprehensive(
        scope: *const MetricsScope,
        options: CheckOptions,
    ) anyerror!MetricsReportData {
        var result = MetricsReportData{};
        errdefer result.deinit(options.allocator);

        var count = try scope.count();
        defer count.deinit();
        var count_data = try count.gatherReportData(options);
        defer count_data.deinit(options.allocator);
        try result.appendDataMove(options.allocator, &count_data);

        if (scope.targetLevel() == .file) {
            var dependency = try scope.dependency();
            defer dependency.deinit();
            var dependency_data = try dependency.gatherReportData(options);
            defer dependency_data.deinit(options.allocator);
            try result.appendDataMove(options.allocator, &dependency_data);
        }
        result.sort();
        return result;
    }

    pub fn toHtml(
        allocator: Allocator,
        io: Io,
        data: *const MetricsReportData,
        options: MetricsExportOptions,
    ) export_support.ExportError![]u8 {
        return export_support.toHtml(allocator, io, data, options);
    }

    pub fn exportAsHtml(
        allocator: Allocator,
        io: Io,
        data: *const MetricsReportData,
        output_path: []const u8,
        options: MetricsExportOptions,
    ) export_support.ExportError!void {
        return export_support.exportAsHtml(allocator, io, data, output_path, options);
    }
};

fn findEntry(
    data: *const MetricsReportData,
    kind: report_data.MetricsReportSectionKind,
    label: []const u8,
) ?*const report_data.MetricsReportEntry {
    for (data.items()) |section| {
        if (section.kind != kind) continue;
        for (section.items()) |*entry| if (std.mem.eql(u8, entry.label, label)) return entry;
    }
    return null;
}

fn metricText(allocator: Allocator, value: report_data.MetricValue) ![]u8 {
    return switch (value) {
        .signed => |number| std.fmt.allocPrint(allocator, "{d}", .{number}),
        .unsigned => |number| std.fmt.allocPrint(allocator, "{d}", .{number}),
        .floating => |number| std.fmt.allocPrint(allocator, "{d}", .{number}),
    };
}

test "comprehensive gathering contains exact supported fixture summaries" {
    var scope = try fluent_metrics.metrics(
        std.testing.allocator,
        .{ .locator = "test/fixtures/metrics-dependency" },
    );
    defer scope.deinit();
    const options = CheckOptions.init(std.testing.allocator, std.testing.io);
    var data = try MetricsExporter.gatherComprehensive(&scope, options);
    defer data.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), data.items().len);
    try std.testing.expectEqual(report_data.MetricsReportSectionKind.count, data.items()[0].kind);
    try std.testing.expectEqual(report_data.MetricsReportSectionKind.dependency, data.items()[1].kind);
    try std.testing.expectEqual(@as(u64, 5), findEntry(&data, .count, "subject_count").?.value.unsigned);
    try std.testing.expectEqual(@as(u64, 3), findEntry(&data, .dependency, "total_afferent_coupling").?.value.unsigned);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.3),
        findEntry(&data, .dependency, "average_instability").?.value.floating,
        0.000_001,
    );
}

test "every structured value is rendered and unsupported metric families stay absent" {
    var scope = try fluent_metrics.metrics(
        std.testing.allocator,
        .{ .locator = "test/fixtures/metrics-dependency" },
    );
    defer scope.deinit();
    var data = try MetricsExporter.gatherComprehensive(
        &scope,
        CheckOptions.init(std.testing.allocator, std.testing.io),
    );
    defer data.deinit(std.testing.allocator);
    const html = try MetricsExporter.toHtml(
        std.testing.allocator,
        std.testing.io,
        &data,
        .{ .title = "Comprehensive", .include_timestamp = false },
    );
    defer std.testing.allocator.free(html);

    for (data.items()) |section| {
        try std.testing.expect(std.mem.indexOf(u8, html, section.title) != null);
        for (section.items()) |entry| {
            const value = try metricText(std.testing.allocator, entry.value);
            defer std.testing.allocator.free(value);
            const row = try std.fmt.allocPrint(
                std.testing.allocator,
                "<tr><td>{s}</td><td class=\"value\" data-value-kind=\"{s}\">{s}</td></tr>",
                .{ entry.label, @tagName(std.meta.activeTag(entry.value)), value },
            );
            defer std.testing.allocator.free(row);
            try std.testing.expect(std.mem.indexOf(u8, html, row) != null);
        }
    }
    for ([_][]const u8{
        "Classes",
        "Interfaces",
        "LCOM",
        "Abstractness",
        "Distance from Main Sequence",
        "Zone of Pain",
        "Zone of Uselessness",
    }) |unsupported| try std.testing.expect(std.mem.indexOf(u8, html, unsupported) == null);
}

test "non-file comprehensive scopes omit dependency sections instead of placeholders" {
    var root = try fluent_metrics.metrics(
        std.testing.allocator,
        .{ .locator = "test/fixtures/metrics-structural" },
    );
    defer root.deinit();
    var containers = try root.forContainersMatching(&.{.{ .glob = "Worker" }});
    defer containers.deinit();
    var data = try MetricsExporter.gatherComprehensive(
        &containers,
        CheckOptions.init(std.testing.allocator, std.testing.io),
    );
    defer data.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), data.items().len);
    try std.testing.expectEqual(report_data.MetricsReportSectionKind.count, data.items()[0].kind);
}
