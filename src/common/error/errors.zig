pub const UserError = error{
    InvalidPattern,
    UnknownLayer,
    InvalidOptions,
    InvalidFluentStage,
    InvalidProjectPath,
    InvalidModuleOverride,
    InvalidIgnoreDirective,
};

pub const TechnicalError = error{
    FileSystemFailure,
    OutOfMemory,
    MalformedProjectMetadata,
    UnsupportedBuildOutput,
    ParserFailure,
    InternalInvariant,
};

pub const ArchUnitError = UserError || TechnicalError;

pub const ErrorCategory = enum { user, technical };

pub const UserCode = enum {
    invalid_pattern,
    unknown_layer,
    invalid_options,
    invalid_fluent_stage,
    invalid_project_path,
    invalid_module_override,
    invalid_ignore_directive,

    pub fn toError(self: UserCode) UserError {
        return switch (self) {
            .invalid_pattern => error.InvalidPattern,
            .unknown_layer => error.UnknownLayer,
            .invalid_options => error.InvalidOptions,
            .invalid_fluent_stage => error.InvalidFluentStage,
            .invalid_project_path => error.InvalidProjectPath,
            .invalid_module_override => error.InvalidModuleOverride,
            .invalid_ignore_directive => error.InvalidIgnoreDirective,
        };
    }
};

pub const TechnicalCode = enum {
    file_system,
    out_of_memory,
    malformed_project_metadata,
    unsupported_build_output,
    parser_failure,
    internal_invariant,

    pub fn toError(self: TechnicalCode) TechnicalError {
        return switch (self) {
            .file_system => error.FileSystemFailure,
            .out_of_memory => error.OutOfMemory,
            .malformed_project_metadata => error.MalformedProjectMetadata,
            .unsupported_build_output => error.UnsupportedBuildOutput,
            .parser_failure => error.ParserFailure,
            .internal_invariant => error.InternalInvariant,
        };
    }
};

pub fn categoryOf(failure: anyerror) ?ErrorCategory {
    return switch (failure) {
        error.InvalidPattern,
        error.UnknownLayer,
        error.InvalidOptions,
        error.InvalidFluentStage,
        error.InvalidProjectPath,
        error.InvalidModuleOverride,
        error.InvalidIgnoreDirective,
        => .user,
        error.FileSystemFailure,
        error.OutOfMemory,
        error.MalformedProjectMetadata,
        error.UnsupportedBuildOutput,
        error.ParserFailure,
        error.InternalInvariant,
        => .technical,
        else => null,
    };
}

test "user and technical error sets are distinguishable" {
    const std = @import("std");

    try std.testing.expectEqual(ErrorCategory.user, categoryOf(error.InvalidPattern).?);
    try std.testing.expectEqual(ErrorCategory.user, categoryOf(error.UnknownLayer).?);
    try std.testing.expectEqual(ErrorCategory.technical, categoryOf(error.FileSystemFailure).?);
    try std.testing.expectEqual(ErrorCategory.technical, categoryOf(error.ParserFailure).?);
    try std.testing.expectEqual(@as(?ErrorCategory, null), categoryOf(error.AccessDenied));
}
