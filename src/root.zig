//! Public package root for ArchUnitZig.
//!
//! The rule-building API will be added incrementally as its contracts are implemented and tested.

const std = @import("std");
const assertion = @import("common/assertion.zig");
const common_error = @import("common/error.zig");
const extraction = @import("common/extraction.zig");
const fluentapi = @import("common/fluentapi.zig");
const matching = @import("common/matching.zig");

pub const Edge = extraction.Edge;
pub const ArchUnitError = common_error.ArchUnitError;
pub const Diagnostic = common_error.Diagnostic;
pub const DiagnosticCode = common_error.DiagnosticCode;
pub const DependencyReference = extraction.DependencyReference;
pub const DiagnosticKind = extraction.DiagnosticKind;
pub const EmptyTestViolation = assertion.EmptyTestViolation;
pub const EnumerationOptions = extraction.EnumerationOptions;
pub const ErrorCategory = common_error.ErrorCategory;
pub const ErrorContext = common_error.ErrorContext;
pub const FileResolutionStatus = extraction.FileResolutionStatus;
pub const Graph = extraction.Graph;
pub const ImportKind = extraction.ImportKind;
pub const ImportKinds = extraction.ImportKinds;
pub const LocatedProject = extraction.LocatedProject;
pub const Candidate = matching.Candidate;
pub const CheckOptions = fluentapi.CheckOptions;
pub const Checkable = fluentapi.Checkable;
pub const Filter = matching.Filter;
pub const MatchingMode = matching.MatchingMode;
pub const LogLevel = fluentapi.LogLevel;
pub const LoggingOptions = fluentapi.LoggingOptions;
pub const ModuleOverride = fluentapi.ModuleOverride;
pub const ModuleResolutionOverrides = fluentapi.ModuleResolutionOverrides;
pub const Pattern = matching.Pattern;
pub const ParseResult = extraction.ParseResult;
pub const PatternSyntax = matching.PatternSyntax;
pub const PatternTarget = matching.PatternTarget;
pub const ProjectMarker = extraction.ProjectMarker;
pub const TechnicalCode = common_error.TechnicalCode;
pub const TechnicalError = common_error.TechnicalError;
pub const UserCode = common_error.UserCode;
pub const UserError = common_error.UserError;
pub const RegexFactory = matching.RegexFactory;
pub const ResolvedReference = extraction.ResolvedReference;
pub const ScopePattern = assertion.ScopePattern;
pub const SourceLocation = extraction.SourceLocation;
pub const Strictness = extraction.Strictness;
pub const SourceFiles = extraction.SourceFiles;
pub const SyntaxDiagnostic = extraction.SyntaxDiagnostic;
pub const Violation = assertion.Violation;
pub const ViolationList = assertion.ViolationList;
pub const matchesAny = matching.matchesAny;
pub const matchesSelectors = matching.matchesSelectors;
pub const checkAll = fluentapi.checkAll;
pub const categoryOfError = common_error.categoryOf;
pub const locateProject = extraction.locateProject;
pub const parseSource = extraction.parseSource;
pub const resolveRelativeReference = extraction.resolveRelativeReference;
pub const enumerateSourceFiles = extraction.enumerateSourceFiles;

test "public facade builds and runs pattern filters" {
    var filter = try RegexFactory.pathMatcher(
        std.testing.allocator,
        .{ .glob = "src/**/*.zig" },
    );
    defer filter.deinit();

    try std.testing.expect(try filter.matches(
        std.testing.allocator,
        .{ .path = "src\\domain\\model.zig" },
    ));
}

test {
    _ = std.testing;
    _ = @import("common/assertion.zig");
    _ = @import("common/error.zig");
    _ = @import("common/extraction.zig");
    _ = @import("common/fluentapi.zig");
    _ = @import("common/matching.zig");
}
