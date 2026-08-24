pub const ContainerKind = @import("metrics/extraction/structural.zig").ContainerKind;
pub const DeclarationInfo = @import("metrics/extraction/structural.zig").DeclarationInfo;
pub const DeclarationKind = @import("metrics/extraction/structural.zig").DeclarationKind;
pub const FileInfo = @import("metrics/extraction/structural.zig").FileInfo;
pub const ProjectInfo = @import("metrics/extraction/structural.zig").ProjectInfo;
pub const StructuralMetrics = @import("metrics/extraction/structural.zig").StructuralMetrics;
pub const extractProjectInfo = @import("metrics/extraction/structural.zig").extractProjectInfo;
pub const inspectSource = @import("metrics/extraction/structural.zig").inspectSource;
pub const ComparisonError = @import("metrics/assertion/threshold.zig").ComparisonError;
pub const passesThreshold = @import("metrics/assertion/threshold.zig").passes;

test {
    _ = @import("metrics/assertion/threshold.zig");
    _ = @import("metrics/extraction/structural.zig");
}
