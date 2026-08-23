pub const CycleViolation = @import("assertion/cycle_violation.zig").CycleViolation;
pub const EmptyTestViolation = @import("assertion/empty_test_violation.zig").EmptyTestViolation;
pub const FileDependencyViolation = @import("assertion/file_dependency_violation.zig").FileDependencyViolation;
pub const ExternalModuleDependencyViolation = @import("assertion/external_module_dependency_violation.zig").ExternalModuleDependencyViolation;
pub const Mood = @import("assertion/mood.zig").Mood;
pub const MatchingViolation = @import("assertion/matching_violation.zig").MatchingViolation;
pub const ScopePattern = @import("assertion/scope_pattern.zig").ScopePattern;
pub const Violation = @import("assertion/violation.zig").Violation;
pub const ViolationList = @import("assertion/violation_list.zig").ViolationList;

test {
    _ = @import("assertion/cycle_violation.zig");
    _ = @import("assertion/empty_test_violation.zig");
    _ = @import("assertion/file_dependency_violation.zig");
    _ = @import("assertion/external_module_dependency_violation.zig");
    _ = @import("assertion/mood.zig");
    _ = @import("assertion/matching_violation.zig");
    _ = @import("assertion/scope_pattern.zig");
    _ = @import("assertion/violation.zig");
    _ = @import("assertion/violation_list.zig");
}
