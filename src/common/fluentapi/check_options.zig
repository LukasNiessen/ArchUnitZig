const std = @import("std");

const extraction_options = @import("../extraction/extraction_options.zig");
const module_resolver = @import("../extraction/module_resolver.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

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

pub const CompilationUnitOverride = module_resolver.CompilationUnitOverride;
pub const BuildGraphMode = extraction_options.BuildGraphMode;
pub const ExtractionOptions = extraction_options.ExtractionOptions;
pub const ModuleOrigin = module_resolver.ModuleOrigin;
pub const ModuleOverride = module_resolver.ModuleOverride;
pub const ModuleResolutionOverrides = module_resolver.ModuleResolutionOverrides;

/// Per-check configuration. Every slice is borrowed for the duration of `check`; results allocate
/// from `allocator` and must be released with that same allocator.
pub const CheckOptions = struct {
    allocator: Allocator,
    io: Io,
    working_directory: []const u8 = ".",
    allow_empty_tests: bool = false,
    clear_cache: bool = false,
    logging: LoggingOptions = .{},
    extraction: ExtractionOptions = .{},

    pub fn init(allocator: Allocator, io: Io) CheckOptions {
        return .{ .allocator = allocator, .io = io };
    }
};

test "check options have safe deterministic defaults" {
    const options = CheckOptions.init(std.testing.allocator, std.testing.io);

    try std.testing.expectEqualStrings(".", options.working_directory);
    try std.testing.expect(!options.allow_empty_tests);
    try std.testing.expect(!options.clear_cache);
    try std.testing.expectEqual(LogLevel.disabled, options.logging.level);
    try std.testing.expect(options.logging.include_violations);
    try std.testing.expectEqual(@as(usize, 0), options.extraction.exclusions.len);
    try std.testing.expectEqual(@as(usize, 0), options.extraction.module_resolution.compilation_units.len);
    try std.testing.expectEqual(BuildGraphMode.explicit_only, options.extraction.build_graph_mode);
}

test "check options carry borrowed extraction and Zig module context" {
    const exclusions = [_][]const u8{ "zig-cache/**", "generated/**" };
    const modules = [_]ModuleOverride{
        .{ .name = "domain", .source_path = "src/domain/root.zig" },
        .{ .name = "support", .source_path = "../support/root.zig", .origin = .package },
    };
    const compilation_units = [_]CompilationUnitOverride{.{
        .id = "app",
        .root_source_path = "src/main.zig",
        .modules = &modules,
    }};
    const options = CheckOptions{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .working_directory = "fixture",
        .allow_empty_tests = true,
        .clear_cache = true,
        .logging = .{ .level = .debug, .include_violations = false },
        .extraction = .{
            .exclusions = &exclusions,
            .strictness = .permissive,
            .module_resolution = .{
                .compilation_units = &compilation_units,
            },
        },
    };

    try std.testing.expect(options.allow_empty_tests);
    try std.testing.expectEqualStrings("fixture", options.working_directory);
    try std.testing.expect(options.clear_cache);
    try std.testing.expectEqual(LogLevel.debug, options.logging.level);
    try std.testing.expect(!options.logging.include_violations);
    try std.testing.expectEqualStrings("generated/**", options.extraction.exclusions[1]);
    try std.testing.expect(options.extraction.strictness == .permissive);
    try std.testing.expectEqualStrings("app", options.extraction.module_resolution.compilation_units[0].id);
    try std.testing.expectEqualStrings("src/main.zig", options.extraction.module_resolution.compilation_units[0].root_source_path.?);
    try std.testing.expectEqualStrings("domain", options.extraction.module_resolution.compilation_units[0].modules[0].name);
    try std.testing.expectEqual(ModuleOrigin.package, options.extraction.module_resolution.compilation_units[0].modules[1].origin);
}
