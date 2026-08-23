//! Public package root for ArchUnitZig.
//!
//! The rule-building API will be added incrementally as its contracts are implemented and tested.

const std = @import("std");
const assertion = @import("common/assertion.zig");
const common_error = @import("common/error.zig");
const extraction = @import("common/extraction.zig");
const file_rules = @import("files.zig");
const fluentapi = @import("common/fluentapi.zig");
const matching = @import("common/matching.zig");
const projection = @import("common/projection.zig");
const testing_support = @import("testing.zig");

pub const Edge = extraction.Edge;
pub const BuildGraphMode = extraction.BuildGraphMode;
pub const ClassifiedReference = extraction.ClassifiedReference;
pub const ArchUnitError = common_error.ArchUnitError;
pub const Diagnostic = common_error.Diagnostic;
pub const DiagnosticCode = common_error.DiagnosticCode;
pub const DependencyReference = extraction.DependencyReference;
pub const DiagnosticKind = extraction.DiagnosticKind;
pub const EmptyTestViolation = assertion.EmptyTestViolation;
pub const CycleViolation = assertion.CycleViolation;
pub const EnumerationOptions = extraction.EnumerationOptions;
pub const ErrorCategory = common_error.ErrorCategory;
pub const ErrorContext = common_error.ErrorContext;
pub const FileResolutionStatus = extraction.FileResolutionStatus;
pub const FileResolutionInput = extraction.FileResolutionInput;
pub const FileBuilderError = file_rules.BuilderError;
pub const FilesScope = file_rules.FilesScope;
pub const FilesHaveNoCycles = file_rules.FilesHaveNoCycles;
pub const FilesMatchPattern = file_rules.FilesMatchPattern;
pub const FilesShould = file_rules.FilesShould;
pub const FilesShouldNot = file_rules.FilesShouldNot;
pub const Graph = extraction.Graph;
pub const ImportKind = extraction.ImportKind;
pub const ImportKinds = extraction.ImportKinds;
pub const LocatedProject = extraction.LocatedProject;
pub const Candidate = matching.Candidate;
pub const CheckOptions = fluentapi.CheckOptions;
pub const Checkable = fluentapi.Checkable;
pub const CompilationUnitOverride = extraction.CompilationUnitOverride;
pub const CycleProjectionError = projection.CycleProjectionError;
pub const ExtractionOptions = extraction.ExtractionOptions;
pub const Filter = matching.Filter;
pub const MatchingMode = matching.MatchingMode;
pub const MapFunction = projection.MapFunction;
pub const MappedEdge = projection.MappedEdge;
pub const LogLevel = fluentapi.LogLevel;
pub const LoggingOptions = fluentapi.LoggingOptions;
pub const ModuleOrigin = extraction.ModuleOrigin;
pub const ModuleOverride = extraction.ModuleOverride;
pub const ModuleResolutionOverrides = extraction.ModuleResolutionOverrides;
pub const ModuleResolutionStatus = extraction.ModuleResolutionStatus;
pub const Mood = assertion.Mood;
pub const MatchingViolation = assertion.MatchingViolation;
pub const Pattern = matching.Pattern;
pub const ParseResult = extraction.ParseResult;
pub const NodeProjectionOptions = projection.NodeProjectionOptions;
pub const PatternSyntax = matching.PatternSyntax;
pub const PatternTarget = matching.PatternTarget;
pub const ProjectMarker = extraction.ProjectMarker;
pub const ProjectOptions = file_rules.ProjectOptions;
pub const ProjectedCycle = projection.ProjectedCycle;
pub const ProjectedCycles = projection.ProjectedCycles;
pub const ProjectedEdge = projection.ProjectedEdge;
pub const ProjectedEdges = projection.ProjectedEdges;
pub const ProjectedNode = projection.ProjectedNode;
pub const ProjectedNodes = projection.ProjectedNodes;
pub const ProjectionError = projection.ProjectionError;
pub const TechnicalCode = common_error.TechnicalCode;
pub const TechnicalError = common_error.TechnicalError;
pub const UserCode = common_error.UserCode;
pub const UserError = common_error.UserError;
pub const RegexFactory = matching.RegexFactory;
pub const ResolvedReference = extraction.ResolvedReference;
pub const ResolvedModuleReference = extraction.ResolvedModuleReference;
pub const ResolutionInput = extraction.ResolutionInput;
pub const ScopePattern = assertion.ScopePattern;
pub const FileScopePatterns = file_rules.ScopePatterns;
pub const SourceLocation = extraction.SourceLocation;
pub const SourceReferences = extraction.SourceReferences;
pub const Strictness = extraction.Strictness;
pub const SourceFiles = extraction.SourceFiles;
pub const SelectedFiles = file_rules.SelectedFiles;
pub const SyntaxDiagnostic = extraction.SyntaxDiagnostic;
pub const TargetAvailability = extraction.TargetAvailability;
pub const TargetClass = extraction.TargetClass;
pub const Violation = assertion.Violation;
pub const ViolationList = assertion.ViolationList;
pub const matchesAny = matching.matchesAny;
pub const matchesSelectors = matching.matchesSelectors;
pub const checkAll = fluentapi.checkAll;
pub const categoryOfError = common_error.categoryOf;
pub const classifyReference = extraction.classifyReference;
pub const clearGraphCache = extraction.clearGraphCache;
pub const locateProject = extraction.locateProject;
pub const normalizeGraph = extraction.normalizeGraph;
pub const parseSource = extraction.parseSource;
pub const projectEdges = projection.projectEdges;
pub const projectCycles = projection.projectCycles;
pub const projectInternalCycles = projection.projectInternalCycles;
pub const projectToNodes = projection.projectToNodes;
pub const resolveRelativeReference = extraction.resolveRelativeReference;
pub const resolveModuleReference = extraction.resolveModuleReference;
pub const validateModuleResolutionOverrides = extraction.validateModuleResolutionOverrides;
pub const enumerateSourceFiles = extraction.enumerateSourceFiles;
pub const extractProjectGraph = extraction.extractProjectGraph;
pub const files = file_rules.files;
pub const formatCyclePath = testing_support.formatCyclePath;
pub const gatherMatchingFileViolations = file_rules.gatherMatchingFileViolations;
pub const identity = projection.identity;
pub const perEdge = projection.perEdge;
pub const perExternalEdge = projection.perExternalEdge;
pub const perInternalEdge = projection.perInternalEdge;
pub const projectFiles = file_rules.projectFiles;

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
    _ = @import("common/projection.zig");
    _ = @import("files.zig");
    _ = @import("testing.zig");
}
