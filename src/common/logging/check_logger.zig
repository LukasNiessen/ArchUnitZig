const std = @import("std");

const assertion = @import("../assertion.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const max_message_bytes = 512;

pub const LogClock = types.LogClock;
pub const LogEvent = types.LogEvent;
pub const LogFileMode = types.LogFileMode;
pub const LogFileOptions = types.LogFileOptions;
pub const LogLevel = types.LogLevel;
pub const LogRecord = types.LogRecord;
pub const LogSink = types.LogSink;
pub const LoggingOptions = types.LoggingOptions;

pub const InitError = Allocator.Error || error{
    InvalidLogDirectory,
    InvalidLogNamePrefix,
    MissingLogSink,
};

/// Runtime state owned by exactly one operation. Configuration and custom sinks remain borrowed.
pub const CheckLogger = struct {
    allocator: Allocator,
    io: Io,
    options: LoggingOptions,
    file: ?Io.File = null,
    file_offset: u64 = 0,
    owned_log_path: ?[]u8 = null,

    pub fn init(allocator: Allocator, io: Io, options: LoggingOptions) InitError!CheckLogger {
        if (options.writer == null and options.logger == null and options.file == null) {
            return error.MissingLogSink;
        }
        if (options.file) |file_options| {
            if (!containsNonWhitespace(file_options.output_directory)) return error.InvalidLogDirectory;
            if (!validNamePrefix(file_options.name_prefix)) return error.InvalidLogNamePrefix;
        }
        return .{ .allocator = allocator, .io = io, .options = options };
    }

    pub fn deinit(self: *CheckLogger) void {
        if (self.file) |file| file.close(self.io);
        if (self.owned_log_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    pub fn logPath(self: *const CheckLogger) ?[]const u8 {
        return self.owned_log_path;
    }

    pub fn startCheck(self: *CheckLogger, check_name: []const u8) anyerror!void {
        return self.emit(.info, .start_check, "rule={s}", .{check_name});
    }

    pub fn endCheck(self: *CheckLogger, check_name: []const u8, violation_count: usize) anyerror!void {
        return self.emit(.info, .end_check, "rule={s} violations={d}", .{ check_name, violation_count });
    }

    pub fn endCheckError(self: *CheckLogger, check_name: []const u8, failure: anyerror) anyerror!void {
        return self.emit(.@"error", .end_check, "rule={s} error={s}", .{ check_name, @errorName(failure) });
    }

    pub fn logExtraction(self: *CheckLogger, message: []const u8) anyerror!void {
        if (!self.options.include_progress) return;
        return self.emit(.info, .extraction, "{s}", .{message});
    }

    pub fn logCache(self: *CheckLogger, message: []const u8) anyerror!void {
        if (!self.options.include_progress) return;
        return self.emit(.debug, .cache, "{s}", .{message});
    }

    pub fn logViolation(self: *CheckLogger, violation: assertion.Violation) anyerror!void {
        if (!self.options.include_violations) return;
        try self.emit(.warn, .violation, "kind={s}", .{@tagName(violation.kind())});
        if (!self.options.include_metrics) return;
        switch (violation) {
            .custom_metric => |value| try self.logMetric(value.metric_name, value.measured, value.target_identifier),
            .metric => |value| try self.logMetric(value.metric_name, value.measured, value.target_identifier),
            .metric_predicate => |value| try self.logMetric(value.metric_name, value.measured, value.target_identifier),
            else => {},
        }
    }

    pub fn logViolations(self: *CheckLogger, violations: []const assertion.Violation) anyerror!void {
        for (violations) |violation| try self.logViolation(violation);
    }

    pub fn logMetric(
        self: *CheckLogger,
        name: []const u8,
        value: assertion.MetricValue,
        subject: []const u8,
    ) anyerror!void {
        if (!self.options.include_metrics) return;
        const safe_subject = safeSubject(subject);
        return switch (value) {
            .signed => |number| self.emit(.debug, .metric, "name={s} value={d} subject={s}", .{ name, number, safe_subject }),
            .unsigned => |number| self.emit(.debug, .metric, "name={s} value={d} subject={s}", .{ name, number, safe_subject }),
            .floating => |number| self.emit(.debug, .metric, "name={s} value={d} subject={s}", .{ name, number, safe_subject }),
        };
    }

    pub fn logExport(self: *CheckLogger, format: []const u8, output_path: []const u8) anyerror!void {
        return self.emit(
            .info,
            .@"export",
            "format={s} file={s}",
            .{ format, std.fs.path.basename(output_path) },
        );
    }

    pub fn log(self: *CheckLogger, level: LogLevel, message: []const u8) anyerror!void {
        return self.emit(level, .message, "{s}", .{message});
    }

    fn emit(
        self: *CheckLogger,
        level: LogLevel,
        event: LogEvent,
        comptime format: []const u8,
        args: anytype,
    ) anyerror!void {
        if (level.priority() < self.options.level.priority()) return;
        var raw_output: Io.Writer.Allocating = .init(self.allocator);
        defer raw_output.deinit();
        raw_output.writer.print(format, args) catch return error.OutOfMemory;
        const raw_message = try raw_output.toOwnedSlice();
        defer self.allocator.free(raw_message);
        const safe_message = try sanitize(self.allocator, raw_message);
        defer self.allocator.free(safe_message);
        const timestamp = self.options.clock.now(self.io);
        var line_output: Io.Writer.Allocating = .init(self.allocator);
        defer line_output.deinit();
        try writeTimestamp(&line_output.writer, timestamp, false);
        line_output.writer.print(
            " [{s}] [{s}] {s}\n",
            .{ upperLevel(level), @tagName(event), safe_message },
        ) catch return error.OutOfMemory;
        const line = try line_output.toOwnedSlice();
        defer self.allocator.free(line);

        const record = LogRecord{
            .timestamp = timestamp,
            .level = level,
            .event = event,
            .message = safe_message,
        };
        if (self.options.logger) |sink| try sink.write(record);
        if (self.options.writer) |writer| try writer.writeAll(line);
        if (self.options.file != null) try self.writeFile(timestamp, line);
    }

    fn writeFile(self: *CheckLogger, timestamp: Io.Timestamp, line: []const u8) anyerror!void {
        if (self.file == null) try self.openFile(timestamp);
        try self.file.?.writePositionalAll(self.io, line, self.file_offset);
        self.file_offset += line.len;
    }

    fn openFile(self: *CheckLogger, timestamp: Io.Timestamp) anyerror!void {
        const options = self.options.file.?;
        try Io.Dir.cwd().createDirPath(self.io, options.output_directory);
        var name_output: Io.Writer.Allocating = .init(self.allocator);
        defer name_output.deinit();
        name_output.writer.print("{s}-", .{options.name_prefix}) catch return error.OutOfMemory;
        try writeTimestamp(&name_output.writer, timestamp, true);
        name_output.writer.writeAll(".log") catch return error.OutOfMemory;
        const file_name = try name_output.toOwnedSlice();
        defer self.allocator.free(file_name);
        const path = try std.fs.path.join(
            self.allocator,
            &.{ options.output_directory, file_name },
        );
        errdefer self.allocator.free(path);
        const file = try Io.Dir.cwd().createFile(self.io, path, .{
            .read = options.mode == .append,
            .truncate = options.mode == .overwrite,
        });
        errdefer file.close(self.io);
        self.file_offset = if (options.mode == .append) (try file.stat(self.io)).size else 0;
        self.owned_log_path = path;
        self.file = file;
    }
};

/// Stack-owned activation helper. It never allocates or reads the clock when logging is absent.
pub const LogSession = struct {
    logger: ?CheckLogger = null,

    pub fn activate(self: *LogSession, options: anytype) anyerror!void {
        if (options.logger != null or options.logging == null) return;
        self.logger = try CheckLogger.init(options.allocator, options.io, options.logging.?);
        options.logger = &self.logger.?;
    }

    pub fn deinit(self: *LogSession) void {
        if (self.logger) |*logger| logger.deinit();
        self.* = undefined;
    }
};

/// Shared lifecycle wrapper used by every concrete terminal. If the underlying check fails, its
/// error wins over a secondary failure while writing the final error event.
pub fn runLoggedCheck(
    context: anytype,
    options: anytype,
    check_name: []const u8,
    comptime perform: anytype,
) anyerror!assertion.ViolationList {
    var logged_options = options;
    var session = LogSession{};
    defer session.deinit();
    try session.activate(&logged_options);
    const logger = logged_options.logger;
    if (logger) |active| try active.startCheck(check_name);
    var result = perform(context, logged_options) catch |failure| {
        if (logger) |active| active.endCheckError(check_name, failure) catch {};
        return failure;
    };
    errdefer result.deinit(logged_options.allocator);
    if (logger) |active| {
        try active.logViolations(result.items());
        try active.endCheck(check_name, result.items().len);
    }
    return result;
}

fn sanitize(allocator: Allocator, value: []const u8) Allocator.Error![]u8 {
    const limit = @min(value.len, max_message_bytes);
    const suffix = if (value.len > limit) "..." else "";
    const result = try allocator.alloc(u8, limit + suffix.len);
    for (value[0..limit], 0..) |byte, index| {
        result[index] = if (byte < 0x20 or byte == 0x7f) '?' else byte;
    }
    @memcpy(result[limit..], suffix);
    return result;
}

fn safeSubject(value: []const u8) []const u8 {
    return if (std.fs.path.isAbsolute(value)) std.fs.path.basename(value) else value;
}

fn writeTimestamp(writer: *Io.Writer, timestamp: Io.Timestamp, filename: bool) Allocator.Error!void {
    const nanoseconds = timestamp.toNanoseconds();
    const seconds = @divFloor(nanoseconds, std.time.ns_per_s);
    const fractional: u32 = @intCast(@mod(nanoseconds, std.time.ns_per_s));
    if (seconds < 0 or seconds > std.math.maxInt(i64)) {
        if (filename) {
            writer.print("unix-{d}-{d:0>9}", .{ seconds, fractional }) catch return error.OutOfMemory;
        } else {
            writer.print("[unix={d}.{d:0>9}]", .{ seconds, fractional }) catch return error.OutOfMemory;
        }
        return;
    }
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const fields = .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
        fractional,
    };
    if (filename) {
        writer.print(
            "{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}-{d:0>2}-{d:0>2}-{d:0>9}",
            fields,
        ) catch return error.OutOfMemory;
    } else {
        writer.print(
            "[{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}Z]",
            fields,
        ) catch return error.OutOfMemory;
    }
}

fn upperLevel(level: LogLevel) []const u8 {
    return switch (level) {
        .debug => "DEBUG",
        .info => "INFO",
        .warn => "WARN",
        .@"error" => "ERROR",
    };
}

fn containsNonWhitespace(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n\x0b\x0c").len != 0;
}

fn validNamePrefix(value: []const u8) bool {
    if (!containsNonWhitespace(value) or
        std.mem.eql(u8, value, ".") or
        std.mem.eql(u8, value, "..")) return false;
    return std.mem.indexOfAny(u8, value, "/\\") == null;
}

const fixed_timestamp = Io.Timestamp.fromNanoseconds(
    1_786_443_072 * std.time.ns_per_s + 123_456_789,
);

fn fixedNow(_: Io) Io.Timestamp {
    return fixed_timestamp;
}

test "disabled sessions do not initialize a logger or read a clock" {
    const Options = struct {
        allocator: Allocator,
        io: Io,
        logging: ?LoggingOptions = null,
        logger: ?*CheckLogger = null,
    };
    var options = Options{ .allocator = std.testing.allocator, .io = std.testing.io };
    var session = LogSession{};
    defer session.deinit();
    try session.activate(&options);
    try std.testing.expect(options.logger == null);
}

test "fixed vocabulary level filtering and custom records use safe in-memory output" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var records: usize = 0;
    const Sink = struct {
        fn write(count: *usize, record: LogRecord) !void {
            try std.testing.expect(std.mem.indexOfScalar(u8, record.message, '\n') == null);
            count.* += 1;
        }
    };
    var logger = try CheckLogger.init(std.testing.allocator, std.testing.io, .{
        .level = .info,
        .writer = &output.writer,
        .logger = LogSink.fromContext(usize, &records, Sink.write),
        .clock = LogClock.fromStateless(fixedNow),
    });
    defer logger.deinit();
    try logger.log(.debug, "hidden");
    try logger.startCheck("files.rule\ninjected");
    try logger.logCache("hidden cache");
    try logger.logExtraction("graph ready");
    try logger.endCheck("files.rule", 0);
    const text = output.written();
    try std.testing.expectEqual(@as(usize, 3), records);
    try std.testing.expect(std.mem.indexOf(u8, text, "[INFO] [start_check] rule=files.rule?injected") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[INFO] [extraction] graph ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "hidden") == null);
}

test "file output creates timestamped directories and honors overwrite then append" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const directory = try std.fs.path.join(std.testing.allocator, &.{ root, "nested", "logs" });
    defer std.testing.allocator.free(directory);
    const file_options = LogFileOptions{ .output_directory = directory };
    var first = try CheckLogger.init(std.testing.allocator, std.testing.io, .{
        .file = file_options,
        .clock = LogClock.fromStateless(fixedNow),
    });
    try first.logExtraction("first");
    const path = try std.testing.allocator.dupe(u8, first.logPath().?);
    defer std.testing.allocator.free(path);
    first.deinit();
    try std.testing.expectEqualStrings(
        "archunit-2026-08-11_10-11-12-123456789.log",
        std.fs.path.basename(path),
    );

    var second = try CheckLogger.init(std.testing.allocator, std.testing.io, .{
        .file = file_options,
        .clock = LogClock.fromStateless(fixedNow),
    });
    try second.logExtraction("second");
    second.deinit();
    var appended = try CheckLogger.init(std.testing.allocator, std.testing.io, .{
        .file = .{ .output_directory = directory, .mode = .append },
        .clock = LogClock.fromStateless(fixedNow),
    });
    try appended.logExtraction("third");
    appended.deinit();

    const contents = try Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        std.testing.allocator,
        .unlimited,
        .of(u8),
        0,
    );
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "first") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "second") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "third") != null);
}

test "custom logger failures propagate and absolute subjects expose only their basename" {
    const Failing = struct {
        fn write(_: LogRecord) !void {
            return error.MockLogSinkFailure;
        }
    };
    var failing = try CheckLogger.init(std.testing.allocator, std.testing.io, .{
        .logger = LogSink.fromStateless(Failing.write),
        .clock = LogClock.fromStateless(fixedNow),
    });
    defer failing.deinit();
    try std.testing.expectError(error.MockLogSinkFailure, failing.startCheck("rule"));

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var safe = try CheckLogger.init(std.testing.allocator, std.testing.io, .{
        .level = .debug,
        .writer = &output.writer,
        .clock = LogClock.fromStateless(fixedNow),
    });
    defer safe.deinit();
    try safe.logMetric("count\nforged", .{ .unsigned = 1 }, "C:\\private\\token\\secret.zig");
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "C:\\private") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "secret.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "count?forged") != null);
}

test "concurrent logger contexts keep independent sinks and lifecycle records" {
    const ThreadContext = struct {
        output: *Io.Writer,
        rule_name: []const u8,
        failed: bool = false,

        fn run(self: *@This()) void {
            var logger = CheckLogger.init(std.heap.smp_allocator, std.testing.io, .{
                .writer = self.output,
                .clock = LogClock.fromStateless(fixedNow),
            }) catch {
                self.failed = true;
                return;
            };
            defer logger.deinit();
            logger.startCheck(self.rule_name) catch {
                self.failed = true;
                return;
            };
            logger.endCheck(self.rule_name, 0) catch {
                self.failed = true;
            };
        }
    };
    var first_buffer: [512]u8 = undefined;
    var second_buffer: [512]u8 = undefined;
    var first_writer: Io.Writer = .fixed(&first_buffer);
    var second_writer: Io.Writer = .fixed(&second_buffer);
    var first = ThreadContext{ .output = &first_writer, .rule_name = "first.rule" };
    var second = ThreadContext{ .output = &second_writer, .rule_name = "second.rule" };
    const first_thread = try std.Thread.spawn(.{}, ThreadContext.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, ThreadContext.run, .{&second});
    first_thread.join();
    second_thread.join();

    try std.testing.expect(!first.failed);
    try std.testing.expect(!second.failed);
    try std.testing.expect(std.mem.indexOf(u8, first_writer.buffered(), "first.rule") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_writer.buffered(), "second.rule") == null);
    try std.testing.expect(std.mem.indexOf(u8, second_writer.buffered(), "second.rule") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_writer.buffered(), "first.rule") == null);
}

fn exerciseAllocationFailures(allocator: Allocator) !void {
    var output_buffer: [256]u8 = undefined;
    var output: Io.Writer = .fixed(&output_buffer);
    var logger = try CheckLogger.init(allocator, std.testing.io, .{
        .writer = &output,
        .clock = LogClock.fromStateless(fixedNow),
    });
    defer logger.deinit();
    try logger.startCheck("allocation-safe");
}

test "logger rendering cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
