const module_resolver = @import("module_resolver.zig");
const source_parser = @import("source_parser.zig");
const workspace_options = @import("workspace_options.zig");

pub const BuildGraphMode = enum {
    disabled,
    explicit_only,
};

pub const WorkspaceMode = workspace_options.WorkspaceMode;
pub const WorkspaceOptions = workspace_options.WorkspaceOptions;
pub const WorkspacePackage = workspace_options.WorkspacePackage;

/// Every option here changes extraction output and therefore belongs in `buildGraphCacheKey`.
/// All slices and nested module mappings are borrowed for the duration of extraction/key creation.
pub const ExtractionOptions = struct {
    /// Additional project-relative globs beyond the enumerator defaults.
    exclusions: []const []const u8 = &.{},
    /// One located package by default, or an explicit/discovered manifest workspace.
    workspace: WorkspaceOptions = .{},
    /// Whether invalid source aborts extraction or becomes owned diagnostics.
    strictness: source_parser.Strictness = .strict,
    /// Whether `@embedFile` targets participate in the graph.
    include_resources: bool = true,
    /// Whether headers named by `@cInclude` participate in the graph.
    include_c_imports: bool = true,
    /// Whether imports lexically contained by Zig `test` declarations participate in the graph.
    /// Enabled by default because tests are architecture consumers; production-only policies can
    /// disable it without suppressing imports from ordinary `comptime` blocks.
    include_test_imports: bool = true,
    /// Explicit compilation-root and named-module bindings; build scripts are never executed.
    module_resolution: module_resolver.ModuleResolutionOverrides = .{},
    /// Selects the build-graph source without implying unsupported build-script interpretation.
    build_graph_mode: BuildGraphMode = .explicit_only,
};
