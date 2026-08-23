const slice_projection = @import("slices/projection/slice_projection.zig");

pub const SliceLabels = slice_projection.SliceLabels;
pub const SliceProjection = slice_projection.SliceProjection;
pub const SliceProjectionError = slice_projection.ProjectionError;
pub const SliceSuffix = slice_projection.SliceSuffix;
pub const projectSliceEdges = slice_projection.projectSliceEdges;
pub const projectSliceLabels = slice_projection.projectSliceLabels;

test {
    _ = @import("slices/projection/slice_projection.zig");
}
