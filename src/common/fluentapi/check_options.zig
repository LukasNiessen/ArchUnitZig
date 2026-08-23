const std = @import("std");

const Allocator = std.mem.Allocator;

pub const LogLevel = enum {
    disabled,
    errors,
    info,
    debug,
};

/// Logging configuration is per check. Issue #40 will add sinks and event formatting without
/// changing the core option boundary.
pub const LoggingOptions = struct {
    level: LogLevel = .disabled,
    include_violations: bool = true,
};

/// One named import supplied by the caller's Zig compilation context.
pub const ModuleOverride = struct {
    name: []const u8,
    source_path: []const u8,
};

/// Static resolution context used instead of executing an analyzed project's `build.zig`.
pub const ModuleResolutionOverrides = struct {
    root_source_path: ?[]const u8 = null,
    modules: []const ModuleOverride = &.{},
};

/// Per-check configuration. Every slice is borrowed for the duration of `check`; results allocate
/// from `allocator` and must be released with that same allocator.
pub const CheckOptions = struct {
    allocator: Allocator,
    allow_empty_tests: bool = false,
    clear_cache: bool = false,
    logging: LoggingOptions = .{},
    extraction_exclusions: []const []const u8 = &.{},
    module_resolution: ModuleResolutionOverrides = .{},

    pub fn init(allocator: Allocator) CheckOptions {
        return .{ .allocator = allocator };
    }
};

test "check options have safe deterministic defaults" {
    const options = CheckOptions.init(std.testing.allocator);

    try std.testing.expect(!options.allow_empty_tests);
    try std.testing.expect(!options.clear_cache);
    try std.testing.expectEqual(LogLevel.disabled, options.logging.level);
    try std.testing.expect(options.logging.include_violations);
    try std.testing.expectEqual(@as(usize, 0), options.extraction_exclusions.len);
    try std.testing.expectEqual(@as(?[]const u8, null), options.module_resolution.root_source_path);
    try std.testing.expectEqual(@as(usize, 0), options.module_resolution.modules.len);
}

test "check options carry borrowed extraction and Zig module context" {
    const exclusions = [_][]const u8{ "zig-cache/**", "generated/**" };
    const modules = [_]ModuleOverride{
        .{ .name = "domain", .source_path = "src/domain/root.zig" },
        .{ .name = "support", .source_path = "test/support.zig" },
    };
    const options = CheckOptions{
        .allocator = std.testing.allocator,
        .allow_empty_tests = true,
        .clear_cache = true,
        .logging = .{ .level = .debug, .include_violations = false },
        .extraction_exclusions = &exclusions,
        .module_resolution = .{
            .root_source_path = "src/main.zig",
            .modules = &modules,
        },
    };

    try std.testing.expect(options.allow_empty_tests);
    try std.testing.expect(options.clear_cache);
    try std.testing.expectEqual(LogLevel.debug, options.logging.level);
    try std.testing.expect(!options.logging.include_violations);
    try std.testing.expectEqualStrings("generated/**", options.extraction_exclusions[1]);
    try std.testing.expectEqualStrings("src/main.zig", options.module_resolution.root_source_path.?);
    try std.testing.expectEqualStrings("domain", options.module_resolution.modules[0].name);
}
