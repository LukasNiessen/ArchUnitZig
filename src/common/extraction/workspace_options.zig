const std = @import("std");

pub const WorkspaceMode = enum {
    single_package,
    explicit_packages,
    discover_packages,
};

/// One borrowed package selection relative to the located workspace root.
pub const WorkspacePackage = struct {
    id: []const u8,
    path: []const u8,
};

/// Workspace scope is opt-in so existing package-relative graph identifiers remain compatible.
pub const WorkspaceOptions = struct {
    mode: WorkspaceMode = .single_package,
    packages: []const WorkspacePackage = &.{},
};

test "workspace options retain compatible single-package defaults" {
    const options = WorkspaceOptions{};
    try std.testing.expectEqual(WorkspaceMode.single_package, options.mode);
    try std.testing.expectEqual(@as(usize, 0), options.packages.len);
}
