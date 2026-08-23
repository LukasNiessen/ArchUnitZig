const module_resolver = @import("module_resolver.zig");
const source_parser = @import("source_parser.zig");

pub const BuildGraphMode = enum {
    disabled,
    explicit_only,
};

/// Every option here changes extraction output and therefore belongs in `buildGraphCacheKey`.
pub const ExtractionOptions = struct {
    exclusions: []const []const u8 = &.{},
    strictness: source_parser.Strictness = .strict,
    include_resources: bool = true,
    include_c_imports: bool = true,
    module_resolution: module_resolver.ModuleResolutionOverrides = .{},
    build_graph_mode: BuildGraphMode = .explicit_only,
};
