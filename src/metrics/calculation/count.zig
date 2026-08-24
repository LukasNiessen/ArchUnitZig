const std = @import("std");

const structural = @import("../extraction/structural.zig");

pub const StructuralMetrics = structural.StructuralMetrics;

/// Zig-native structural count vocabulary. Class, interface, method, and LCOM terminology is
/// intentionally absent.
pub const CountMetric = enum {
    declarations,
    functions,
    tests,
    constants,
    variables,
    fields,
    structs,
    unions,
    enums,
    opaque_types,
    error_sets,
    other_declarations,
    anonymous_containers,
    imports,
    statements,
    tokens,
    source_lines,
    non_blank_lines,

    pub fn name(self: CountMetric) []const u8 {
        return @tagName(self);
    }

    pub fn measure(self: CountMetric, metrics: StructuralMetrics) usize {
        return switch (self) {
            inline else => |metric| @field(metrics, @tagName(metric)),
        };
    }
};

test "every count metric maps exactly to its structural fact" {
    var values = StructuralMetrics{};
    inline for (std.meta.fields(CountMetric), 1..) |field, expected| {
        @field(values, field.name) = expected;
    }
    inline for (std.meta.fields(CountMetric), 1..) |field, expected| {
        const metric: CountMetric = @enumFromInt(field.value);
        try std.testing.expectEqual(@as(usize, expected), metric.measure(values));
        try std.testing.expectEqualStrings(field.name, metric.name());
    }
}
