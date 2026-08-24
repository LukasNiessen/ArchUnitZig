const std = @import("std");
const builtin = @import("builtin");
const archunit = @import("archunit");
const tracking = @import("tracking_allocator.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const TrackingAllocator = tracking.TrackingAllocator;

const fixture_file_count: usize = 240;
const imports_per_file: usize = 12;
const fixture_depth: usize = 8;
const cached_iterations: usize = 20;
const fixture_root = ".zig-cache/benchmark/extraction-v1-f240-i12-d8";
const fixture_source_dir = fixture_root ++ "/src/level_0/level_1/level_2/level_3/level_4/level_5/level_6/level_7";
const results_path = "zig-out/benchmark/results.json";
const expected_graph_digest = "f0559163589aa672d1e8f68265967864ffcdf2f52665af936efe6cd2947193b5";

const expected_source_files = fixture_file_count + 2;
const expected_zig_files = fixture_file_count + 1;
const expected_internal_import_edges = fixture_file_count * imports_per_file;
const expected_external_import_edges = fixture_file_count + 1;
const expected_graph_edges = expected_zig_files + expected_internal_import_edges + expected_external_import_edges;

const Stage = enum {
    enumeration,
    source_loading,
    tokenize_parse,
    resolution_classification,
    normalization,
    projection,
    first_check,
    cached_checks,
};

const all_stages = [_]Stage{
    .enumeration,
    .source_loading,
    .tokenize_parse,
    .resolution_classification,
    .normalization,
    .projection,
    .first_check,
    .cached_checks,
};

const Evidence = struct {
    status: []const u8,
    runner: []const u8,
    run_url: ?[]const u8,
    observed_commit: ?[]const u8,
    baseline: ?Baseline = null,
};

const BaselineStages = struct {
    enumeration_ns: u64,
    source_loading_ns: u64,
    tokenize_parse_ns: u64,
    resolution_classification_ns: u64,
    normalization_ns: u64,
    projection_ns: u64,
    first_check_ns: u64,
    cached_checks_ns: u64,
    cached_check_per_iteration_ns: u64,
};

const Baseline = struct {
    total_duration_ns: u64,
    peak_live_bytes: usize,
    stages: BaselineStages,
};

const StageBudgets = struct {
    enumeration_ns: u64,
    source_loading_ns: u64,
    tokenize_parse_ns: u64,
    resolution_classification_ns: u64,
    normalization_ns: u64,
    projection_ns: u64,
    first_check_ns: u64,
    cached_check_per_iteration_ns: u64,
};

const Budgets = struct {
    schema_version: u32,
    evidence: Evidence,
    max_total_ns: u64,
    max_peak_live_bytes: usize,
    stages: StageBudgets,
};

const StageMeasurement = struct {
    stage: Stage,
    duration_ns: u64,
    allocation_calls: usize,
    allocated_bytes: usize,
    peak_live_bytes: usize,
};

const BenchmarkResult = struct {
    schema_version: u32 = 1,
    zig_version: []const u8 = builtin.zig_version_string,
    optimize_mode: []const u8 = @tagName(builtin.mode),
    target_os: []const u8 = @tagName(builtin.os.tag),
    target_arch: []const u8 = @tagName(builtin.cpu.arch),
    fixture: struct {
        version: u32 = 1,
        source_files: usize = fixture_file_count,
        imports_per_file: usize = imports_per_file,
        folder_depth: usize = fixture_depth,
        cached_iterations: usize = cached_iterations,
    } = .{},
    enumerated_files: usize,
    zig_files: usize,
    graph_edges: usize,
    projected_edges: usize,
    stable_graph_digest: []u8,
    total_duration_ns: u64,
    overall_peak_live_bytes: usize,
    final_live_bytes: usize,
    measurements: [all_stages.len]StageMeasurement,
    budgets: Budgets,
    budgets_enforced: bool,

    fn deinit(self: *BenchmarkResult, allocator: Allocator) void {
        allocator.free(self.stable_graph_digest);
        self.* = undefined;
    }
};

const LoadedSource = struct {
    path: []const u8,
    contents: ?[:0]u8 = null,

    fn deinit(self: *LoadedSource, allocator: Allocator) void {
        if (self.contents) |contents| allocator.free(contents);
    }
};

const ParsedSource = struct {
    result: ?archunit.ParseResult = null,

    fn deinit(self: *ParsedSource, allocator: Allocator) void {
        if (self.result) |*result| result.deinit(allocator);
    }
};

const ClassifiedSource = struct {
    references: std.ArrayList(archunit.ClassifiedReference) = .empty,

    fn deinit(self: *ClassifiedSource, allocator: Allocator) void {
        for (self.references.items) |*reference| reference.deinit(allocator);
        self.references.deinit(allocator);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var enforce_budgets = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--enforce-budgets")) {
            enforce_budgets = true;
        } else {
            return error.InvalidArgument;
        }
    }

    var parsed_budgets = try std.json.parseFromSlice(Budgets, allocator, @embedFile("budgets.json"), .{});
    defer parsed_budgets.deinit();
    if (parsed_budgets.value.schema_version != 1) return error.UnsupportedBudgetSchema;

    try generateFixture(allocator, io);
    var result = try runBenchmark(allocator, io, parsed_budgets.value, enforce_budgets);
    defer result.deinit(allocator);
    try writeResult(allocator, io, &result);
    try printResult(io, &result);
    if (enforce_budgets) try enforceBudgets(&result);
}

fn runBenchmark(
    child_allocator: Allocator,
    io: Io,
    budgets: Budgets,
    budgets_enforced: bool,
) !BenchmarkResult {
    archunit.clearGraphCache();
    defer archunit.clearGraphCache();

    var tracker = TrackingAllocator{ .child = child_allocator };
    const allocator = tracker.allocator();
    var measurements: [all_stages.len]StageMeasurement = undefined;
    var owned_digest: ?[]u8 = null;
    errdefer if (owned_digest) |digest| child_allocator.free(digest);
    var zig_file_count: usize = 0;

    {
        var diagnostics = archunit.ErrorContext.init(allocator);
        defer diagnostics.deinit();

        var window = tracker.beginWindow();
        var started = benchmarkTime(io);
        var source_files = try archunit.enumerateSourceFiles(
            allocator,
            io,
            fixture_root,
            .{},
            &diagnostics,
        );
        var ended = benchmarkTime(io);
        measurements[@intFromEnum(Stage.enumeration)] = makeMeasurement(
            &tracker,
            .enumeration,
            started,
            ended,
            window,
        );
        defer source_files.deinit(allocator);
        try expectEqual(expected_source_files, source_files.items().len, "enumerated source count");

        const loaded = try allocator.alloc(LoadedSource, source_files.items().len);
        defer {
            for (loaded) |*entry| entry.deinit(allocator);
            allocator.free(loaded);
        }
        for (source_files.items(), loaded) |path, *entry| entry.* = .{ .path = path };

        window = tracker.beginWindow();
        started = benchmarkTime(io);
        for (loaded) |*entry| {
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const absolute_path = try std.fs.path.join(allocator, &.{ fixture_root, entry.path });
            defer allocator.free(absolute_path);
            entry.contents = try Io.Dir.cwd().readFileAllocOptions(
                io,
                absolute_path,
                allocator,
                .limited(std.math.maxInt(usize)),
                .of(u8),
                0,
            );
        }
        ended = benchmarkTime(io);
        measurements[@intFromEnum(Stage.source_loading)] = makeMeasurement(
            &tracker,
            .source_loading,
            started,
            ended,
            window,
        );

        const parsed = try allocator.alloc(ParsedSource, loaded.len);
        defer {
            for (parsed) |*entry| entry.deinit(allocator);
            allocator.free(parsed);
        }
        for (parsed) |*entry| entry.* = .{};

        window = tracker.beginWindow();
        started = benchmarkTime(io);
        for (loaded, parsed) |entry, *parsed_entry| {
            const contents = entry.contents orelse continue;
            parsed_entry.result = try archunit.parseSource(
                allocator,
                entry.path,
                contents,
                .strict,
                &diagnostics,
            );
            zig_file_count += 1;
        }
        ended = benchmarkTime(io);
        measurements[@intFromEnum(Stage.tokenize_parse)] = makeMeasurement(
            &tracker,
            .tokenize_parse,
            started,
            ended,
            window,
        );
        try expectEqual(expected_zig_files, zig_file_count, "parsed Zig source count");

        const classified = try allocator.alloc(ClassifiedSource, loaded.len);
        defer {
            for (classified) |*entry| entry.deinit(allocator);
            allocator.free(classified);
        }
        for (classified) |*entry| entry.* = .{};
        const sources = try allocator.alloc(archunit.SourceReferences, loaded.len);
        defer allocator.free(sources);

        window = tracker.beginWindow();
        started = benchmarkTime(io);
        for (loaded, parsed, classified, sources) |loaded_entry, parsed_entry, *classified_entry, *source| {
            if (parsed_entry.result) |parse_result| {
                try classified_entry.references.ensureTotalCapacity(
                    allocator,
                    parse_result.references.items.len,
                );
                for (parse_result.references.items) |reference| {
                    var classified_reference = switch (reference.kind) {
                        .zig_file, .zon_file, .embedded_file => blk: {
                            var resolution = (try archunit.resolveRelativeReference(
                                allocator,
                                io,
                                fixture_root,
                                loaded_entry.path,
                                reference,
                                &diagnostics,
                            )).?;
                            defer resolution.deinit(allocator);
                            break :blk try archunit.classifyReference(allocator, .{ .file = .{
                                .reference = reference,
                                .resolution = resolution,
                            } });
                        },
                        else => try archunit.classifyReference(allocator, .{ .raw = reference }),
                    };
                    classified_entry.references.append(allocator, classified_reference) catch |failure| {
                        classified_reference.deinit(allocator);
                        return failure;
                    };
                }
            }
            source.* = .{
                .source_path = loaded_entry.path,
                .references = classified_entry.references.items,
            };
        }
        ended = benchmarkTime(io);
        measurements[@intFromEnum(Stage.resolution_classification)] = makeMeasurement(
            &tracker,
            .resolution_classification,
            started,
            ended,
            window,
        );

        window = tracker.beginWindow();
        started = benchmarkTime(io);
        var graph = try archunit.normalizeGraph(allocator, sources);
        ended = benchmarkTime(io);
        measurements[@intFromEnum(Stage.normalization)] = makeMeasurement(
            &tracker,
            .normalization,
            started,
            ended,
            window,
        );
        defer graph.deinit(allocator);
        try expectEqual(expected_graph_edges, graph.len(), "normalized graph edge count");

        const digest = stableGraphDigest(&graph);
        const digest_hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, &digest_hex, expected_graph_digest)) return error.UnexpectedGraphDigest;
        owned_digest = try child_allocator.dupe(u8, &digest_hex);
        var second_graph = try archunit.normalizeGraph(allocator, sources);
        defer second_graph.deinit(allocator);
        const second_digest = stableGraphDigest(&second_graph);
        if (!std.mem.eql(u8, &digest, &second_digest)) return error.NondeterministicGraph;

        window = tracker.beginWindow();
        started = benchmarkTime(io);
        var projected = try archunit.projectEdges(allocator, &graph, archunit.identity());
        ended = benchmarkTime(io);
        measurements[@intFromEnum(Stage.projection)] = makeMeasurement(
            &tracker,
            .projection,
            started,
            ended,
            window,
        );
        defer projected.deinit(allocator);
        try expectEqual(graph.len(), projected.len(), "identity projection edge count");
    }
    try expectEqual(0, tracker.active_bytes, "live bytes after staged extraction");

    {
        var files_scope = try archunit.files(allocator, .{ .locator = fixture_root });
        defer files_scope.deinit();
        var source_scope = try files_scope.inPath(&.{.{ .glob = "src/**" }});
        defer source_scope.deinit();
        var should = try source_scope.should();
        defer should.deinit();
        var rule = try should.haveName(.{ .glob = "*.zig" });
        defer rule.deinit(allocator);

        var options = archunit.CheckOptions.init(allocator, io);
        options.clear_cache = true;
        var window = tracker.beginWindow();
        var started = benchmarkTime(io);
        var first_violations = try rule.check(options);
        var ended = benchmarkTime(io);
        measurements[@intFromEnum(Stage.first_check)] = makeMeasurement(
            &tracker,
            .first_check,
            started,
            ended,
            window,
        );
        const first_check_passed = first_violations.passes();
        first_violations.deinit(allocator);
        if (!first_check_passed) return error.BenchmarkRuleViolation;

        options.clear_cache = false;
        window = tracker.beginWindow();
        started = benchmarkTime(io);
        for (0..cached_iterations) |_| {
            var violations = try rule.check(options);
            const passed = violations.passes();
            violations.deinit(allocator);
            if (!passed) return error.BenchmarkRuleViolation;
        }
        ended = benchmarkTime(io);
        measurements[@intFromEnum(Stage.cached_checks)] = makeMeasurement(
            &tracker,
            .cached_checks,
            started,
            ended,
            window,
        );
    }
    try expectEqual(0, tracker.active_bytes, "live bytes after fluent checks");

    var total_duration_ns: u64 = 0;
    for (measurements) |measurement| total_duration_ns += measurement.duration_ns;
    return .{
        .enumerated_files = expected_source_files,
        .zig_files = zig_file_count,
        .graph_edges = expected_graph_edges,
        .projected_edges = expected_graph_edges,
        .stable_graph_digest = owned_digest.?,
        .total_duration_ns = total_duration_ns,
        .overall_peak_live_bytes = tracker.peak_live_bytes,
        .final_live_bytes = tracker.active_bytes,
        .measurements = measurements,
        .budgets = budgets,
        .budgets_enforced = budgets_enforced,
    };
}

fn generateFixture(allocator: Allocator, io: Io) !void {
    try Io.Dir.cwd().createDirPath(io, fixture_source_dir);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = fixture_root ++ "/build.zig.zon",
        .data =
        \\.{
        \\    .name = .archunit_benchmark_fixture,
        \\    .version = "0.0.0",
        \\    .minimum_zig_version = "0.16.0",
        \\    .fingerprint = 0x8a572a6e6f5a965a,
        \\    .paths = .{ "build.zig", "src" },
        \\}
        \\
        ,
    });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = fixture_root ++ "/build.zig",
        .data =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void { _ = b; }
        \\
        ,
    });

    for (0..fixture_file_count) |file_index| {
        var output: Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try output.writer.writeAll("const std = @import(\"std\");\n");
        for (0..imports_per_file) |import_index| {
            const target_index = (file_index + import_index + 1) % fixture_file_count;
            try output.writer.print(
                "const dep_{d:0>2} = @import(\"file_{d:0>3}.zig\");\n",
                .{ import_index, target_index },
            );
        }
        try output.writer.print("pub const id: usize = {d};\n", .{file_index});
        try output.writer.writeAll("pub fn touch() usize {\n    return @sizeOf(std.mem.Allocator)");
        for (0..imports_per_file) |import_index| {
            try output.writer.print(" + dep_{d:0>2}.id", .{import_index});
        }
        try output.writer.writeAll(";\n}\n");
        const contents = try output.toOwnedSlice();
        defer allocator.free(contents);
        const source_path = try std.fmt.allocPrint(
            allocator,
            fixture_source_dir ++ "/file_{d:0>3}.zig",
            .{file_index},
        );
        defer allocator.free(source_path);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = contents });
    }
}

fn stableGraphDigest(graph: *const archunit.Graph) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (graph.items()) |edge| {
        hashLengthPrefixed(&hash, edge.source);
        hashLengthPrefixed(&hash, edge.target);
        hash.update(&.{@intFromBool(edge.external)});
        inline for (std.meta.fields(archunit.ImportKind)) |field| {
            const value: archunit.ImportKind = @enumFromInt(field.value);
            hash.update(&.{@intFromBool(edge.import_kinds.contains(value))});
        }
        inline for (std.meta.fields(archunit.TargetClass)) |field| {
            const value: archunit.TargetClass = @enumFromInt(field.value);
            hash.update(&.{@intFromBool(edge.target_classes.contains(value))});
        }
        inline for (std.meta.fields(archunit.TargetAvailability)) |field| {
            const value: archunit.TargetAvailability = @enumFromInt(field.value);
            hash.update(&.{@intFromBool(edge.target_availabilities.contains(value))});
        }
        for (edge.locations.items) |location| {
            hashInteger(&hash, location.byte_offset);
            hashInteger(&hash, location.line);
            hashInteger(&hash, location.column);
        }
        hash.update(&.{0xff});
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn hashLengthPrefixed(hash: anytype, value: []const u8) void {
    hashInteger(hash, value.len);
    hash.update(value);
}

fn hashInteger(hash: anytype, value: anytype) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(value), .little);
    hash.update(&encoded);
}

fn benchmarkTime(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn makeMeasurement(
    tracker: *const TrackingAllocator,
    stage: Stage,
    started_at: i96,
    ended_at: i96,
    snapshot: tracking.Snapshot,
) StageMeasurement {
    std.debug.assert(ended_at >= started_at);
    return .{
        .stage = stage,
        .duration_ns = @intCast(ended_at - started_at),
        .allocation_calls = tracker.allocation_calls - snapshot.allocation_calls,
        .allocated_bytes = tracker.allocated_bytes - snapshot.allocated_bytes,
        .peak_live_bytes = tracker.window_peak_live_bytes,
    };
}

fn stageBudget(budgets: StageBudgets, stage: Stage) u64 {
    return switch (stage) {
        .enumeration => budgets.enumeration_ns,
        .source_loading => budgets.source_loading_ns,
        .tokenize_parse => budgets.tokenize_parse_ns,
        .resolution_classification => budgets.resolution_classification_ns,
        .normalization => budgets.normalization_ns,
        .projection => budgets.projection_ns,
        .first_check => budgets.first_check_ns,
        .cached_checks => budgets.cached_check_per_iteration_ns * cached_iterations,
    };
}

fn enforceBudgets(result: *const BenchmarkResult) !void {
    var failed = false;
    for (result.measurements) |measurement| {
        const limit = stageBudget(result.budgets.stages, measurement.stage);
        if (measurement.duration_ns > limit) {
            std.debug.print("budget exceeded: {s} took {d} ns, limit {d} ns\n", .{
                @tagName(measurement.stage),
                measurement.duration_ns,
                limit,
            });
            failed = true;
        }
    }
    if (result.total_duration_ns > result.budgets.max_total_ns) {
        std.debug.print("budget exceeded: total took {d} ns, limit {d} ns\n", .{
            result.total_duration_ns,
            result.budgets.max_total_ns,
        });
        failed = true;
    }
    if (result.overall_peak_live_bytes > result.budgets.max_peak_live_bytes) {
        std.debug.print("budget exceeded: peak live bytes {d}, limit {d}\n", .{
            result.overall_peak_live_bytes,
            result.budgets.max_peak_live_bytes,
        });
        failed = true;
    }
    if (failed) return error.PerformanceBudgetExceeded;
}

fn writeResult(allocator: Allocator, io: Io, result: *const BenchmarkResult) !void {
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{
        .writer = &output.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try json.write(result.*);
    try output.writer.writeByte('\n');
    const contents = try output.toOwnedSlice();
    defer allocator.free(contents);
    if (std.fs.path.dirname(results_path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = results_path, .data = contents });
}

fn printResult(io: Io, result: *const BenchmarkResult) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "ArchUnitZig extraction benchmark: {d} files, {d} graph edges, digest {s}\n",
        .{ result.enumerated_files, result.graph_edges, result.stable_graph_digest },
    );
    for (result.measurements) |measurement| {
        try stdout.print(
            "  {s}: {d:.3} ms, {d} allocations, {d} requested bytes, {d} peak live bytes\n",
            .{
                @tagName(measurement.stage),
                @as(f64, @floatFromInt(measurement.duration_ns)) / std.time.ns_per_ms,
                measurement.allocation_calls,
                measurement.allocated_bytes,
                measurement.peak_live_bytes,
            },
        );
    }
    try stdout.print(
        "  total: {d:.3} ms, overall peak {d} bytes; budgets {s}\n  result: {s}\n",
        .{
            @as(f64, @floatFromInt(result.total_duration_ns)) / std.time.ns_per_ms,
            result.overall_peak_live_bytes,
            if (result.budgets_enforced) "enforced" else "report-only",
            results_path,
        },
    );
    try stdout.flush();
}

fn expectEqual(expected: usize, actual: usize, subject: []const u8) !void {
    if (expected == actual) return;
    std.debug.print("benchmark correctness failure: {s}: expected {d}, found {d}\n", .{
        subject,
        expected,
        actual,
    });
    return error.BenchmarkCorrectnessFailure;
}
