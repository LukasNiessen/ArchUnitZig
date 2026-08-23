const matching = @import("../../common/matching.zig");

pub const Pattern = matching.Pattern;

pub const FocusQuery = struct {
    pattern: Pattern,
    depth: usize,
};

pub const PatternCollapse = struct {
    expression: []const u8,
    replacement: []const u8,
};

pub const CollapseQuery = union(enum) {
    folder_depth: usize,
    pattern: PatternCollapse,
};

/// Borrowed options for one pure graph-to-snapshot transformation.
///
/// Callers may freely copy and branch this value. Any pattern, replacement, and title text must
/// remain alive only for the duration of snapshot creation; the resulting snapshot owns its data.
pub const GraphQueryOptions = struct {
    include_external_dependencies: bool = false,
    include_self_dependencies: bool = false,
    focus: ?FocusQuery = null,
    reachable_from: ?Pattern = null,
    dependents_of: ?Pattern = null,
    collapse: ?CollapseQuery = null,
    title: []const u8 = "Project dependency graph",
};

test "query options are copyable branchable values" {
    const baseline: GraphQueryOptions = .{};
    var focused = baseline;
    focused.focus = .{ .pattern = .{ .glob = "src/**" }, .depth = 2 };
    var external = baseline;
    external.include_external_dependencies = true;

    try @import("std").testing.expect(baseline.focus == null);
    try @import("std").testing.expect(!baseline.include_external_dependencies);
    try @import("std").testing.expect(focused.focus != null);
    try @import("std").testing.expect(external.include_external_dependencies);
}
