const std = @import("std");

const assertion = @import("../../common/assertion.zig");
const custom_calculation = @import("../calculation/custom.zig");
const structural = @import("../extraction/structural.zig");

const Allocator = std.mem.Allocator;
pub const MetricValue = assertion.MetricValue;
pub const StructuralMetrics = structural.StructuralMetrics;

pub const MetricsReportSectionKind = enum {
    count,
    dependency,
    custom,
};

pub const MetricsReportEntry = struct {
    label: []u8,
    value: MetricValue,

    pub fn init(allocator: Allocator, label: []const u8, value: MetricValue) !MetricsReportEntry {
        if (!hasText(label)) return error.EmptyMetricLabel;
        return .{ .label = try allocator.dupe(u8, label), .value = value };
    }

    pub fn clone(self: MetricsReportEntry, allocator: Allocator) !MetricsReportEntry {
        return init(allocator, self.label, self.value);
    }

    pub fn deinit(self: *MetricsReportEntry, allocator: Allocator) void {
        allocator.free(self.label);
        self.* = undefined;
    }

    pub fn eql(self: MetricsReportEntry, other: MetricsReportEntry) bool {
        return std.mem.eql(u8, self.label, other.label) and self.value.eql(other.value);
    }
};

pub const MetricsReportSection = struct {
    kind: MetricsReportSectionKind,
    title: []u8,
    entries: std.ArrayList(MetricsReportEntry) = .empty,

    pub fn init(
        allocator: Allocator,
        kind: MetricsReportSectionKind,
        title: []const u8,
    ) !MetricsReportSection {
        if (!hasText(title)) return error.EmptySectionTitle;
        return .{ .kind = kind, .title = try allocator.dupe(u8, title) };
    }

    pub fn clone(self: MetricsReportSection, allocator: Allocator) !MetricsReportSection {
        var result = try init(allocator, self.kind, self.title);
        errdefer result.deinit(allocator);
        try result.entries.ensureTotalCapacity(allocator, self.entries.items.len);
        for (self.entries.items) |entry| result.entries.appendAssumeCapacity(try entry.clone(allocator));
        return result;
    }

    pub fn deinit(self: *MetricsReportSection, allocator: Allocator) void {
        allocator.free(self.title);
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
        self.* = undefined;
    }

    pub fn append(
        self: *MetricsReportSection,
        allocator: Allocator,
        label: []const u8,
        value: MetricValue,
    ) !void {
        var entry = try MetricsReportEntry.init(allocator, label, value);
        self.entries.append(allocator, entry) catch |failure| {
            entry.deinit(allocator);
            return failure;
        };
    }

    pub fn items(self: *const MetricsReportSection) []const MetricsReportEntry {
        return self.entries.items;
    }

    pub fn sort(self: *MetricsReportSection) void {
        std.mem.sort(MetricsReportEntry, self.entries.items, {}, struct {
            fn lessThan(_: void, left: MetricsReportEntry, right: MetricsReportEntry) bool {
                return std.mem.order(u8, left.label, right.label) == .lt;
            }
        }.lessThan);
    }

    pub fn eql(self: MetricsReportSection, other: MetricsReportSection) bool {
        if (self.kind != other.kind or
            !std.mem.eql(u8, self.title, other.title) or
            self.entries.items.len != other.entries.items.len) return false;
        for (self.entries.items, other.entries.items) |left, right| {
            if (!left.eql(right)) return false;
        }
        return true;
    }
};

/// Owned, renderer-independent metrics report. Data gathering sorts this value before returning it;
/// callers composing sections directly may call `sort` before deterministic serialization.
pub const MetricsReportData = struct {
    sections: std.ArrayList(MetricsReportSection) = .empty,

    pub fn deinit(self: *MetricsReportData, allocator: Allocator) void {
        for (self.sections.items) |*section| section.deinit(allocator);
        self.sections.deinit(allocator);
        self.* = undefined;
    }

    pub fn clone(self: MetricsReportData, allocator: Allocator) !MetricsReportData {
        var result = MetricsReportData{};
        errdefer result.deinit(allocator);
        try result.sections.ensureTotalCapacity(allocator, self.sections.items.len);
        for (self.sections.items) |section| {
            result.sections.appendAssumeCapacity(try section.clone(allocator));
        }
        return result;
    }

    pub fn appendSectionMove(
        self: *MetricsReportData,
        allocator: Allocator,
        section: *MetricsReportSection,
    ) !void {
        try self.sections.append(allocator, section.*);
        section.* = undefined;
    }

    pub fn appendDataMove(
        self: *MetricsReportData,
        allocator: Allocator,
        other: *MetricsReportData,
    ) !void {
        try self.sections.ensureUnusedCapacity(allocator, other.sections.items.len);
        for (other.sections.items) |section| self.sections.appendAssumeCapacity(section);
        other.sections.clearRetainingCapacity();
    }

    pub fn items(self: *const MetricsReportData) []const MetricsReportSection {
        return self.sections.items;
    }

    pub fn sort(self: *MetricsReportData) void {
        for (self.sections.items) |*section| section.sort();
        std.mem.sort(MetricsReportSection, self.sections.items, {}, struct {
            fn lessThan(_: void, left: MetricsReportSection, right: MetricsReportSection) bool {
                const left_kind = @intFromEnum(left.kind);
                const right_kind = @intFromEnum(right.kind);
                if (left_kind != right_kind) return left_kind < right_kind;
                return std.mem.order(u8, left.title, right.title) == .lt;
            }
        }.lessThan);
    }

    pub fn eql(self: MetricsReportData, other: MetricsReportData) bool {
        if (self.sections.items.len != other.sections.items.len) return false;
        for (self.sections.items, other.sections.items) |left, right| {
            if (!left.eql(right)) return false;
        }
        return true;
    }
};

pub fn countSection(
    allocator: Allocator,
    title: []const u8,
    subject_count: usize,
    invalid_syntax_subjects: usize,
    totals: StructuralMetrics,
) !MetricsReportSection {
    var section = try MetricsReportSection.init(allocator, .count, title);
    errdefer section.deinit(allocator);
    try section.append(allocator, "invalid_syntax_subjects", unsignedValue(invalid_syntax_subjects));
    try section.append(allocator, "subject_count", unsignedValue(subject_count));
    inline for (std.meta.fields(StructuralMetrics)) |field| {
        try section.append(allocator, field.name, unsignedValue(@field(totals, field.name)));
    }
    section.sort();
    return section;
}

pub fn dependencySection(
    allocator: Allocator,
    title: []const u8,
    projected_subject_count: usize,
    selected_subject_count: usize,
    total_afferent_coupling: usize,
    total_efferent_coupling: usize,
    average_instability: f64,
    average_coupling_factor: f64,
) !MetricsReportSection {
    var section = try MetricsReportSection.init(allocator, .dependency, title);
    errdefer section.deinit(allocator);
    try section.append(allocator, "average_coupling_factor", .{ .floating = average_coupling_factor });
    try section.append(allocator, "average_instability", .{ .floating = average_instability });
    try section.append(allocator, "projected_subject_count", unsignedValue(projected_subject_count));
    try section.append(allocator, "selected_subject_count", unsignedValue(selected_subject_count));
    try section.append(allocator, "total_afferent_coupling", unsignedValue(total_afferent_coupling));
    try section.append(allocator, "total_efferent_coupling", unsignedValue(total_efferent_coupling));
    section.sort();
    return section;
}

pub fn customSection(
    allocator: Allocator,
    title: []const u8,
    measurements: *const custom_calculation.CustomMetricMeasurements,
) !MetricsReportSection {
    var section = try MetricsReportSection.init(allocator, .custom, title);
    errdefer section.deinit(allocator);
    try section.entries.ensureTotalCapacity(allocator, measurements.items().len);
    for (measurements.items()) |measurement| {
        section.entries.appendAssumeCapacity(try MetricsReportEntry.init(
            allocator,
            measurement.target_identifier,
            measurement.value,
        ));
    }
    section.sort();
    return section;
}

fn unsignedValue(value: usize) MetricValue {
    return .{ .unsigned = @intCast(value) };
}

fn hasText(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n\x0b\x0c").len != 0;
}

test "count and dependency sections contain only supported Zig summary facts" {
    var count = try countSection(
        std.testing.allocator,
        "Count <metrics>",
        2,
        1,
        .{ .functions = 3, .fields = 4, .non_blank_lines = 20 },
    );
    defer count.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 20), count.items().len);
    try std.testing.expectEqualStrings("anonymous_containers", count.items()[0].label);
    try std.testing.expectEqualStrings("variables", count.items()[count.items().len - 1].label);

    var dependency = try dependencySection(
        std.testing.allocator,
        "Dependency metrics",
        4,
        2,
        3,
        3,
        0.5,
        0.25,
    );
    defer dependency.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 6), dependency.items().len);
    for ([_][]const u8{ "class", "interface", "lcom", "abstractness", "distance", "zone" }) |unsupported| {
        for (count.items()) |entry| try std.testing.expect(std.mem.indexOf(u8, entry.label, unsupported) == null);
        for (dependency.items()) |entry| try std.testing.expect(std.mem.indexOf(u8, entry.label, unsupported) == null);
    }
}

test "report data owns caller strings and sorts sections and entries canonically" {
    var later_title = [_]u8{ 'Z', 'e', 't', 'a' };
    var custom_later = try MetricsReportSection.init(std.testing.allocator, .custom, &later_title);
    errdefer custom_later.deinit(std.testing.allocator);
    try custom_later.append(std.testing.allocator, "z", .{ .signed = -1 });
    try custom_later.append(std.testing.allocator, "a", .{ .floating = 0.5 });
    var custom_first = try MetricsReportSection.init(std.testing.allocator, .custom, "Alpha");
    errdefer custom_first.deinit(std.testing.allocator);
    try custom_first.append(std.testing.allocator, "only", .{ .unsigned = 1 });
    var count = try countSection(std.testing.allocator, "Count", 0, 0, .{});
    errdefer count.deinit(std.testing.allocator);

    var data = MetricsReportData{};
    defer data.deinit(std.testing.allocator);
    try data.appendSectionMove(std.testing.allocator, &custom_later);
    try data.appendSectionMove(std.testing.allocator, &custom_first);
    try data.appendSectionMove(std.testing.allocator, &count);
    @memset(&later_title, 'x');
    data.sort();

    try std.testing.expectEqual(MetricsReportSectionKind.count, data.items()[0].kind);
    try std.testing.expectEqualStrings("Alpha", data.items()[1].title);
    try std.testing.expectEqualStrings("Zeta", data.items()[2].title);
    try std.testing.expectEqualStrings("a", data.items()[2].items()[0].label);
    var cloned = try data.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);
    try std.testing.expect(data.eql(cloned));
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var first = try countSection(allocator, "Count", 2, 0, .{ .functions = 3 });
    var first_owned = true;
    errdefer if (first_owned) first.deinit(allocator);
    var second = try dependencySection(allocator, "Dependency", 2, 2, 1, 1, 0.5, 0.5);
    var second_owned = true;
    errdefer if (second_owned) second.deinit(allocator);
    var data = MetricsReportData{};
    defer data.deinit(allocator);
    try data.appendSectionMove(allocator, &second);
    second_owned = false;
    try data.appendSectionMove(allocator, &first);
    first_owned = false;
    data.sort();
    var cloned = try data.clone(allocator);
    defer cloned.deinit(allocator);
}

test "report data construction cloning and move composition release allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
