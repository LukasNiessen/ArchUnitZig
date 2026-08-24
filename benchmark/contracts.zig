const std = @import("std");

test {
    _ = @import("tracking_allocator.zig");
}

test "budgets cover every measured stage with positive values" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        @embedFile("budgets.json"),
        .{},
    );
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), root.get("schema_version").?.integer);
    try std.testing.expect(root.get("max_total_ns").?.integer > 0);
    try std.testing.expect(root.get("max_peak_live_bytes").?.integer > 0);
    const stages = root.get("stages").?.object;
    const expected = [_][]const u8{
        "enumeration_ns",
        "source_loading_ns",
        "tokenize_parse_ns",
        "resolution_classification_ns",
        "normalization_ns",
        "projection_ns",
        "first_check_ns",
        "cached_check_per_iteration_ns",
    };
    try std.testing.expectEqual(expected.len, stages.count());
    for (expected) |name| try std.testing.expect(stages.get(name).?.integer > 0);
}
