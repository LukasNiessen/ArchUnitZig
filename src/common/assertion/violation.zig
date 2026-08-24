const std = @import("std");

const empty_test = @import("empty_test_violation.zig");
const cycle_violation = @import("cycle_violation.zig");
const custom_file_violation = @import("custom_file_violation.zig");
const custom_metric_violation = @import("custom_metric_violation.zig");
const file_dependency_violation = @import("file_dependency_violation.zig");
const external_dependency_violation = @import("external_module_dependency_violation.zig");
const layer_dependency_violation = @import("layer_dependency_violation.zig");
const matching_violation = @import("matching_violation.zig");
const metric_violation = @import("metric_violation.zig");
const metric_predicate_violation = @import("metric_predicate_violation.zig");
const slice_dependency_violation = @import("slice_dependency_violation.zig");

const Allocator = std.mem.Allocator;
pub const EmptyTestViolation = empty_test.EmptyTestViolation;
pub const CycleViolation = cycle_violation.CycleViolation;
pub const CustomFileViolation = custom_file_violation.CustomFileViolation;
pub const CustomMetricViolation = custom_metric_violation.CustomMetricViolation;
pub const FileDependencyViolation = file_dependency_violation.FileDependencyViolation;
pub const ExternalModuleDependencyViolation = external_dependency_violation.ExternalModuleDependencyViolation;
pub const LayerDependencyViolation = layer_dependency_violation.LayerDependencyViolation;
pub const MatchingViolation = matching_violation.MatchingViolation;
pub const MetricViolation = metric_violation.MetricViolation;
pub const MetricPredicateViolation = metric_predicate_violation.MetricPredicateViolation;
pub const SliceDependencyViolation = slice_dependency_violation.SliceDependencyViolation;

/// Closed, data-only architecture disagreement. Formatters exhaustively switch on this union in
/// the testing layer; rule code never stores its final prose here.
pub const Violation = union(enum) {
    cycle: CycleViolation,
    custom_file: CustomFileViolation,
    custom_metric: CustomMetricViolation,
    empty_test: EmptyTestViolation,
    external_module_dependency: ExternalModuleDependencyViolation,
    file_dependency: FileDependencyViolation,
    layer_dependency: LayerDependencyViolation,
    matching: MatchingViolation,
    metric: MetricViolation,
    metric_predicate: MetricPredicateViolation,
    slice_dependency: SliceDependencyViolation,

    pub const Kind = std.meta.Tag(Violation);
    pub const CloneError = empty_test.InitError || cycle_violation.InitError || file_dependency_violation.InitError || external_dependency_violation.InitError || layer_dependency_violation.InitError || slice_dependency_violation.InitError || custom_file_violation.InitError || custom_metric_violation.InitError || metric_violation.InitError || metric_predicate_violation.InitError;

    pub fn fromCycleMove(payload: *CycleViolation) Violation {
        const result = Violation{ .cycle = payload.* };
        payload.* = undefined;
        return result;
    }

    pub fn fromCustomFileMove(payload: *CustomFileViolation) Violation {
        const result = Violation{ .custom_file = payload.* };
        payload.* = undefined;
        return result;
    }

    pub fn fromCustomMetricMove(payload: *CustomMetricViolation) Violation {
        const result = Violation{ .custom_metric = payload.* };
        payload.* = undefined;
        return result;
    }

    pub fn fromEmptyTestMove(payload: *EmptyTestViolation) Violation {
        const result = Violation{ .empty_test = payload.* };
        payload.* = undefined;
        return result;
    }

    pub fn fromMatchingMove(payload: *MatchingViolation) Violation {
        const result = Violation{ .matching = payload.* };
        payload.* = undefined;
        return result;
    }

    pub fn fromMetricMove(payload: *MetricViolation) Violation {
        const result = Violation{ .metric = payload.* };
        payload.* = undefined;
        return result;
    }

    pub fn fromMetricPredicateMove(payload: *MetricPredicateViolation) Violation {
        const result = Violation{ .metric_predicate = payload.* };
        payload.* = undefined;
        return result;
    }

    pub fn fromFileDependencyMove(payload: *FileDependencyViolation) Violation {
        const result = Violation{ .file_dependency = payload.* };
        payload.* = undefined;
        return result;
    }

    pub fn fromExternalModuleDependencyMove(payload: *ExternalModuleDependencyViolation) Violation {
        const result = Violation{ .external_module_dependency = payload.* };
        payload.* = undefined;
        return result;
    }

    pub fn fromLayerDependencyMove(payload: *LayerDependencyViolation) Violation {
        const result = Violation{ .layer_dependency = payload.* };
        payload.* = undefined;
        return result;
    }

    pub fn fromSliceDependencyMove(payload: *SliceDependencyViolation) Violation {
        const result = Violation{ .slice_dependency = payload.* };
        payload.* = undefined;
        return result;
    }

    pub fn kind(self: Violation) Kind {
        return std.meta.activeTag(self);
    }

    pub fn clone(self: Violation, allocator: Allocator) CloneError!Violation {
        return switch (self) {
            .cycle => |value| .{ .cycle = try value.clone(allocator) },
            .custom_file => |value| .{ .custom_file = try value.clone(allocator) },
            .custom_metric => |value| .{ .custom_metric = try value.clone(allocator) },
            .empty_test => |value| .{ .empty_test = try value.clone(allocator) },
            .external_module_dependency => |value| .{ .external_module_dependency = try value.clone(allocator) },
            .file_dependency => |value| .{ .file_dependency = try value.clone(allocator) },
            .layer_dependency => |value| .{ .layer_dependency = try value.clone(allocator) },
            .matching => |value| .{ .matching = try value.clone(allocator) },
            .metric => |value| .{ .metric = try value.clone(allocator) },
            .metric_predicate => |value| .{ .metric_predicate = try value.clone(allocator) },
            .slice_dependency => |value| .{ .slice_dependency = try value.clone(allocator) },
        };
    }

    pub fn deinit(self: *Violation, allocator: Allocator) void {
        switch (self.*) {
            .cycle => |*value| value.deinit(allocator),
            .custom_file => |*value| value.deinit(allocator),
            .custom_metric => |*value| value.deinit(allocator),
            .empty_test => |*value| value.deinit(allocator),
            .external_module_dependency => |*value| value.deinit(allocator),
            .file_dependency => |*value| value.deinit(allocator),
            .layer_dependency => |*value| value.deinit(allocator),
            .matching => |*value| value.deinit(allocator),
            .metric => |*value| value.deinit(allocator),
            .metric_predicate => |*value| value.deinit(allocator),
            .slice_dependency => |*value| value.deinit(allocator),
        }
        self.* = undefined;
    }

    pub fn eql(self: Violation, other: Violation) bool {
        if (self.kind() != other.kind()) return false;
        return switch (self) {
            .cycle => |left| left.eql(other.cycle),
            .custom_file => |left| left.eql(other.custom_file),
            .custom_metric => |left| left.eql(other.custom_metric),
            .empty_test => |left| left.eql(other.empty_test),
            .external_module_dependency => |left| left.eql(other.external_module_dependency),
            .file_dependency => |left| left.eql(other.file_dependency),
            .layer_dependency => |left| left.eql(other.layer_dependency),
            .matching => |left| left.eql(other.matching),
            .metric => |left| left.eql(other.metric),
            .metric_predicate => |left| left.eql(other.metric_predicate),
            .slice_dependency => |left| left.eql(other.slice_dependency),
        };
    }
};

fn formatterDispatchBoundary(violation: Violation) []const u8 {
    return switch (violation) {
        .cycle => "format-cycle-in-testing-layer",
        .custom_file => "format-custom-file-in-testing-layer",
        .custom_metric => "format-custom-metric-in-testing-layer",
        .empty_test => "format-empty-selection-in-testing-layer",
        .external_module_dependency => "format-external-module-dependency-in-testing-layer",
        .file_dependency => "format-file-dependency-in-testing-layer",
        .layer_dependency => "format-layer-dependency-in-testing-layer",
        .matching => "format-matching-disagreement-in-testing-layer",
        .metric => "format-metric-threshold-in-testing-layer",
        .metric_predicate => "format-metric-predicate-in-testing-layer",
        .slice_dependency => "format-slice-dependency-in-testing-layer",
    };
}

test "tagged union exposes exhaustive presentation dispatch without formatting prose" {
    var payload = try EmptyTestViolation.init(
        std.testing.allocator,
        "files.have_name",
        &.{},
        false,
    );
    var violation = Violation.fromEmptyTestMove(&payload);
    defer violation.deinit(std.testing.allocator);

    try std.testing.expectEqual(Violation.Kind.empty_test, violation.kind());
    try std.testing.expectEqualStrings(
        "format-empty-selection-in-testing-layer",
        formatterDispatchBoundary(violation),
    );
}

test "violation clone owns independent payload storage" {
    var payload = try EmptyTestViolation.init(
        std.testing.allocator,
        "files.have_no_cycles",
        &.{},
        false,
    );
    var original = Violation.fromEmptyTestMove(&payload);
    defer original.deinit(std.testing.allocator);
    var cloned = try original.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expect(original.eql(cloned));
    try std.testing.expect(original.empty_test.rule_id.ptr != cloned.empty_test.rule_id.ptr);
}
