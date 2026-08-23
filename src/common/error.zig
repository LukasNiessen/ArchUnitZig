pub const ArchUnitError = @import("error/errors.zig").ArchUnitError;
pub const Diagnostic = @import("error/diagnostic.zig").Diagnostic;
pub const DiagnosticCode = @import("error/diagnostic.zig").DiagnosticCode;
pub const ErrorCategory = @import("error/errors.zig").ErrorCategory;
pub const ErrorContext = @import("error/diagnostic.zig").ErrorContext;
pub const TechnicalCode = @import("error/errors.zig").TechnicalCode;
pub const TechnicalError = @import("error/errors.zig").TechnicalError;
pub const UserCode = @import("error/errors.zig").UserCode;
pub const UserError = @import("error/errors.zig").UserError;
pub const categoryOf = @import("error/errors.zig").categoryOf;

test {
    _ = @import("error/diagnostic.zig");
    _ = @import("error/errors.zig");
}
