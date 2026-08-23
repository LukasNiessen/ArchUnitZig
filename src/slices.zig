const slice_projection = @import("slices/projection/slice_projection.zig");
const slice_dependency = @import("slices/assertion/slice_dependency.zig");

pub const SliceLabels = slice_projection.SliceLabels;
pub const SliceProjection = slice_projection.SliceProjection;
pub const SliceProjectionError = slice_projection.ProjectionError;
pub const SliceSuffix = slice_projection.SliceSuffix;
pub const projectSliceEdges = slice_projection.projectSliceEdges;
pub const projectSliceLabels = slice_projection.projectSliceLabels;
pub const gatherSliceDependencyViolations = slice_dependency.gatherSliceDependencyViolations;

test {
    _ = @import("slices/projection/slice_projection.zig");
    _ = @import("slices/assertion/slice_dependency.zig");
}
