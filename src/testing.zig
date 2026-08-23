pub const formatCyclePath = @import("testing/cycle_path.zig").formatCyclePath;
pub const ColorMode = @import("testing/color.zig").ColorMode;
pub const ColorOptions = @import("testing/color.zig").ColorOptions;
pub const FormattedViolation = @import("testing/violation_factory.zig").FormattedViolation;
pub const ViolationFactory = @import("testing/violation_factory.zig").ViolationFactory;
pub const ResultFactory = @import("testing/result_factory.zig").ResultFactory;
pub const ResultOptions = @import("testing/result_factory.zig").ResultOptions;
pub const TestResult = @import("testing/result_factory.zig").TestResult;
pub const ViolationGroup = @import("testing/result_factory.zig").ViolationGroup;
pub const ArchitectureAssertionError = @import("testing/native.zig").ArchitectureAssertionError;
pub const AssertionOptions = @import("testing/native.zig").AssertionOptions;
pub const assertAllPass = @import("testing/native.zig").assertAllPass;
pub const assertPasses = @import("testing/native.zig").assertPasses;
pub const expectPasses = @import("testing/native.zig").expectPasses;

test {
    _ = @import("testing/color.zig");
    _ = @import("testing/cycle_path.zig");
    _ = @import("testing/violation_factory.zig");
    _ = @import("testing/result_factory.zig");
    _ = @import("testing/native.zig");
}
