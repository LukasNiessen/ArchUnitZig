const std = @import("std");

const errors = @import("errors.zig");

const Allocator = std.mem.Allocator;
pub const ArchUnitError = errors.ArchUnitError;
pub const ErrorCategory = errors.ErrorCategory;
pub const TechnicalCode = errors.TechnicalCode;
pub const UserCode = errors.UserCode;

pub const DiagnosticCode = union(ErrorCategory) {
    user: UserCode,
    technical: TechnicalCode,
};

/// Owned context paired with an error-union tag. `operation` is a stable identifier such as
/// `zig.parse_source`; `subject` is usually a path, module, layer, or user expression.
pub const Diagnostic = struct {
    code: DiagnosticCode,
    operation: []const u8,
    subject: ?[]const u8,
    cause: ?anyerror,

    pub fn init(
        allocator: Allocator,
        code: DiagnosticCode,
        operation: []const u8,
        subject: ?[]const u8,
        cause: ?anyerror,
    ) Allocator.Error!Diagnostic {
        const owned_operation = try allocator.dupe(u8, operation);
        errdefer allocator.free(owned_operation);
        const owned_subject = if (subject) |value| try allocator.dupe(u8, value) else null;

        return .{
            .code = code,
            .operation = owned_operation,
            .subject = owned_subject,
            .cause = cause,
        };
    }

    pub fn clone(self: Diagnostic, allocator: Allocator) Allocator.Error!Diagnostic {
        return init(allocator, self.code, self.operation, self.subject, self.cause);
    }

    pub fn deinit(self: *Diagnostic, allocator: Allocator) void {
        allocator.free(self.operation);
        if (self.subject) |value| allocator.free(value);
        self.* = undefined;
    }

    pub fn category(self: Diagnostic) ErrorCategory {
        return std.meta.activeTag(self.code);
    }

    pub fn errorValue(self: Diagnostic) ArchUnitError {
        return switch (self.code) {
            .user => |code| code.toError(),
            .technical => |code| code.toError(),
        };
    }
};

/// Optional owned context for one failing operation. Reusing it replaces and frees the prior
/// diagnostic. If recording itself runs out of memory, the returned tag is technical OutOfMemory.
pub const ErrorContext = struct {
    allocator: Allocator,
    diagnostic: ?Diagnostic = null,

    pub fn init(allocator: Allocator) ErrorContext {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ErrorContext) void {
        self.clear();
        self.* = undefined;
    }

    pub fn clear(self: *ErrorContext) void {
        if (self.diagnostic) |*value| value.deinit(self.allocator);
        self.diagnostic = null;
    }

    pub fn failUser(
        self: *ErrorContext,
        code: UserCode,
        operation: []const u8,
        subject: ?[]const u8,
        cause: ?anyerror,
    ) ArchUnitError {
        return self.record(.{ .user = code }, operation, subject, cause);
    }

    pub fn failTechnical(
        self: *ErrorContext,
        code: TechnicalCode,
        operation: []const u8,
        subject: ?[]const u8,
        cause: ?anyerror,
    ) ArchUnitError {
        return self.record(.{ .technical = code }, operation, subject, cause);
    }

    fn record(
        self: *ErrorContext,
        code: DiagnosticCode,
        operation: []const u8,
        subject: ?[]const u8,
        cause: ?anyerror,
    ) ArchUnitError {
        const next = Diagnostic.init(self.allocator, code, operation, subject, cause) catch {
            self.clear();
            return error.OutOfMemory;
        };
        self.clear();
        self.diagnostic = next;
        return self.diagnostic.?.errorValue();
    }
};

test "user diagnostic retains invalid-pattern context" {
    var context = ErrorContext.init(std.testing.allocator);
    defer context.deinit();
    const failure = context.failUser(
        .invalid_pattern,
        "pattern.compile",
        "(",
        error.MissingParen,
    );

    try std.testing.expectEqual(error.InvalidPattern, failure);
    const diagnostic = context.diagnostic.?;
    try std.testing.expectEqual(ErrorCategory.user, diagnostic.category());
    try std.testing.expectEqualStrings("pattern.compile", diagnostic.operation);
    try std.testing.expectEqualStrings("(", diagnostic.subject.?);
    try std.testing.expectEqual(error.MissingParen, diagnostic.cause.?);
}

test "technical diagnostic retains filesystem context and replaces prior data" {
    var context = ErrorContext.init(std.testing.allocator);
    defer context.deinit();
    try std.testing.expectEqual(
        error.InvalidOptions,
        context.failUser(.invalid_options, "options.validate", null, null),
    );
    const failure = context.failTechnical(
        .file_system,
        "project.enumerate",
        "missing/src",
        error.FileNotFound,
    );

    try std.testing.expectEqual(error.FileSystemFailure, failure);
    const diagnostic = context.diagnostic.?;
    try std.testing.expectEqual(ErrorCategory.technical, diagnostic.category());
    try std.testing.expectEqualStrings("project.enumerate", diagnostic.operation);
    try std.testing.expectEqual(error.FileNotFound, diagnostic.cause.?);
}

test "malformed user regex maps to UserError with parser cause" {
    const Pattern = @import("../matching.zig").Pattern;
    var context = ErrorContext.init(std.testing.allocator);
    defer context.deinit();

    const Compile = struct {
        fn run(diagnostics: *ErrorContext) ArchUnitError!void {
            var compiled = (Pattern{ .regex = "(" }).compile(std.testing.allocator) catch |cause| {
                if (cause == error.OutOfMemory) {
                    return diagnostics.failTechnical(
                        .out_of_memory,
                        "pattern.compile",
                        "(",
                        cause,
                    );
                }
                return diagnostics.failUser(.invalid_pattern, "pattern.compile", "(", cause);
            };
            defer compiled.deinit();
        }
    };

    try std.testing.expectError(error.InvalidPattern, Compile.run(&context));
    try std.testing.expectEqual(ErrorCategory.user, context.diagnostic.?.category());
    try std.testing.expectEqual(error.MissingParen, context.diagnostic.?.cause.?);
}

test "technical failures are errors while architecture disagreement is violation data" {
    const assertion = @import("../assertion.zig");
    var context = ErrorContext.init(std.testing.allocator);
    defer context.deinit();

    const Simulated = struct {
        fn parse(diagnostics: *ErrorContext) ArchUnitError!void {
            return diagnostics.failTechnical(
                .parser_failure,
                "zig.parse_source",
                "src/broken.zig",
                error.UnexpectedToken,
            );
        }

        fn mismatch(allocator: Allocator) !assertion.ViolationList {
            var payload = try assertion.EmptyTestViolation.init(
                allocator,
                "files.have_name",
                &.{},
                false,
            );
            var violation = assertion.Violation.fromEmptyTestMove(&payload);
            var result = assertion.ViolationList{};
            result.appendMove(allocator, &violation) catch |failure| {
                violation.deinit(allocator);
                return failure;
            };
            return result;
        }
    };

    try std.testing.expectError(error.ParserFailure, Simulated.parse(&context));
    try std.testing.expectEqual(ErrorCategory.technical, context.diagnostic.?.category());

    var violations = try Simulated.mismatch(std.testing.allocator);
    defer violations.deinit(std.testing.allocator);
    try std.testing.expect(!violations.passes());
    try std.testing.expectEqual(@as(usize, 1), violations.items().len);
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var context = ErrorContext.init(allocator);
    defer context.deinit();
    const failure = context.failUser(
        .invalid_module_override,
        "module_map.validate",
        "domain",
        null,
    );
    if (failure == error.OutOfMemory) return error.OutOfMemory;

    var cloned = try context.diagnostic.?.clone(allocator);
    defer cloned.deinit(allocator);
    try std.testing.expectEqual(error.InvalidModuleOverride, cloned.errorValue());
}

test "diagnostic recording and cloning clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
