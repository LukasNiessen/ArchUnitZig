const slice_projection = @import("slices/projection/slice_projection.zig");
const slice_dependency = @import("slices/assertion/slice_dependency.zig");
const slice_fluent = @import("slices/fluentapi/slices.zig");
const plantuml = @import("slices/uml/plantuml.zig");

pub const SliceLabels = slice_projection.SliceLabels;
pub const SliceProjection = slice_projection.SliceProjection;
pub const SliceProjectionError = slice_projection.ProjectionError;
pub const SliceSuffix = slice_projection.SliceSuffix;
pub const projectSliceEdges = slice_projection.projectSliceEdges;
pub const projectSliceLabels = slice_projection.projectSliceLabels;
pub const gatherSliceDependencyViolations = slice_dependency.gatherSliceDependencyViolations;
pub const SliceBuilderError = slice_fluent.BuilderError;
pub const ProjectSliceOptions = slice_fluent.ProjectSliceOptions;
pub const ProjectSlices = slice_fluent.ProjectSlices;
pub const SliceDependencyRule = slice_fluent.SliceDependencyRule;
pub const SlicesShould = slice_fluent.SlicesShould;
pub const SlicesShouldNot = slice_fluent.SlicesShouldNot;
pub const projectSlices = slice_fluent.projectSlices;
pub const slices = slice_fluent.slices;
pub const PlantUmlDependency = plantuml.PlantUmlDependency;
pub const PlantUmlDiagram = plantuml.PlantUmlDiagram;
pub const PlantUmlDiagnostic = plantuml.PlantUmlDiagnostic;
pub const PlantUmlDiagnosticKind = plantuml.PlantUmlDiagnosticKind;
pub const PlantUmlParseResult = plantuml.PlantUmlParseResult;
pub const PlantUmlRenderError = plantuml.RenderError;
pub const PlantUmlExportError = plantuml.ExportError;
pub const parsePlantUml = plantuml.parsePlantUml;
pub const renderPlantUml = plantuml.renderPlantUml;
pub const exportPlantUml = plantuml.exportPlantUml;

test {
    _ = @import("slices/projection/slice_projection.zig");
    _ = @import("slices/assertion/slice_dependency.zig");
    _ = @import("slices/fluentapi/slices.zig");
    _ = @import("slices/uml/plantuml.zig");
}
