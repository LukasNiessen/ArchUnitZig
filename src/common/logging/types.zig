const std = @import("std");

const Io = std.Io;

pub const LogLevel = enum {
    debug,
    info,
    warn,
    @"error",

    pub fn priority(self: LogLevel) u2 {
        return switch (self) {
            .debug => 0,
            .info => 1,
            .warn => 2,
            .@"error" => 3,
        };
    }
};

pub const LogEvent = enum {
    start_check,
    end_check,
    extraction,
    cache,
    violation,
    metric,
    @"export",
    message,
};

/// One borrowed structured record. `message` is already control-safe and lives only through the
/// sink call; a sink which retains it must clone it.
pub const LogRecord = struct {
    timestamp: Io.Timestamp,
    level: LogLevel,
    event: LogEvent,
    message: []const u8,
};

/// Borrowed type-erased custom logger. Errors deliberately propagate through the active operation.
pub const LogSink = struct {
    context: ?*anyopaque,
    write_fn: *const fn (context: ?*anyopaque, record: LogRecord) anyerror!void,

    pub fn init(
        context: ?*anyopaque,
        write_fn: *const fn (context: ?*anyopaque, record: LogRecord) anyerror!void,
    ) LogSink {
        return .{ .context = context, .write_fn = write_fn };
    }

    pub fn fromStateless(
        comptime write_fn: *const fn (record: LogRecord) anyerror!void,
    ) LogSink {
        return .{
            .context = null,
            .write_fn = struct {
                fn write(_: ?*anyopaque, record: LogRecord) anyerror!void {
                    return write_fn(record);
                }
            }.write,
        };
    }

    pub fn fromContext(
        comptime Context: type,
        context: *Context,
        comptime write_fn: *const fn (context: *Context, record: LogRecord) anyerror!void,
    ) LogSink {
        return .{
            .context = context,
            .write_fn = struct {
                fn write(raw_context: ?*anyopaque, record: LogRecord) anyerror!void {
                    const typed: *Context = @ptrCast(@alignCast(raw_context.?));
                    return write_fn(typed, record);
                }
            }.write,
        };
    }

    pub fn write(self: LogSink, record: LogRecord) anyerror!void {
        return self.write_fn(self.context, record);
    }
};

/// Borrowed clock hook. The system clock is the default; tests and deterministic tools can inject
/// a fixed source without changing process-wide time.
pub const LogClock = struct {
    context: ?*const anyopaque = null,
    now_fn: *const fn (context: ?*const anyopaque, io: Io) Io.Timestamp = systemNow,

    pub fn system() LogClock {
        return .{};
    }

    pub fn fromStateless(
        comptime now_fn: *const fn (io: Io) Io.Timestamp,
    ) LogClock {
        return .{
            .now_fn = struct {
                fn now(_: ?*const anyopaque, io: Io) Io.Timestamp {
                    return now_fn(io);
                }
            }.now,
        };
    }

    pub fn fromContext(
        comptime Context: type,
        context: *const Context,
        comptime now_fn: *const fn (context: *const Context, io: Io) Io.Timestamp,
    ) LogClock {
        return .{
            .context = context,
            .now_fn = struct {
                fn now(raw_context: ?*const anyopaque, io: Io) Io.Timestamp {
                    const typed: *const Context = @ptrCast(@alignCast(raw_context.?));
                    return now_fn(typed, io);
                }
            }.now,
        };
    }

    pub fn now(self: LogClock, io: Io) Io.Timestamp {
        return self.now_fn(self.context, io);
    }

    fn systemNow(_: ?*const anyopaque, io: Io) Io.Timestamp {
        return Io.Clock.real.now(io);
    }
};

pub const LogFileMode = enum { overwrite, append };

pub const LogFileOptions = struct {
    output_directory: []const u8 = "logs",
    mode: LogFileMode = .overwrite,
    name_prefix: []const u8 = "archunit",
};

/// Borrowed, immutable per-operation logging configuration. At least one writer, custom logger, or
/// file sink is required when this value is present in `CheckOptions`.
pub const LoggingOptions = struct {
    level: LogLevel = .info,
    writer: ?*Io.Writer = null,
    logger: ?LogSink = null,
    file: ?LogFileOptions = null,
    clock: LogClock = .{},
    include_progress: bool = true,
    include_violations: bool = true,
    include_metrics: bool = true,
};

test "log sink and clock adapters retain only borrowed typed contexts" {
    const Context = struct {
        writes: usize = 0,
        timestamp: Io.Timestamp = .fromNanoseconds(42),

        fn write(self: *@This(), record: LogRecord) !void {
            try std.testing.expectEqual(LogEvent.cache, record.event);
            self.writes += 1;
        }

        fn now(self: *const @This(), _: Io) Io.Timestamp {
            return self.timestamp;
        }
    };
    var context = Context{};
    const sink = LogSink.fromContext(Context, &context, Context.write);
    const clock = LogClock.fromContext(Context, &context, Context.now);
    try sink.write(.{
        .timestamp = clock.now(std.testing.io),
        .level = .debug,
        .event = .cache,
        .message = "hit",
    });
    try std.testing.expectEqual(@as(usize, 1), context.writes);
    try std.testing.expectEqual(@as(i96, 42), clock.now(std.testing.io).toNanoseconds());
}
