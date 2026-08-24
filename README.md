# ArchUnitZig

Architecture tests for Zig projects.

This repository is being bootstrapped as the Zig member of the
[ArchUnitTS](https://github.com/LukasNiessen/ArchUnitTS) family. The first usable release will turn a
Zig project into a dependency graph and let users express file, module, layer, slice, and graph rules
as ordinary `zig test` tests.

The public API is not ready yet. The implementation is tracked in the
[ordered roadmap](docs/roadmap.md), while [architecture](docs/architecture.md) and
[Zig-specific decisions](docs/decisions.md) explain how and why this port differs from its siblings.

## Pattern exclusions

Every selector can exclude generated or otherwise exceptional subjects without duplicating the
surrounding rule. `except` inherits the target of the immediately preceding selector;
`exceptTargeted` can instead inspect a filename, folder, full path, or declaration/container name:

```zig
var project = try archunit.files(std.testing.allocator, .{});
defer project.deinit();
var source = try project.inPath(&.{.{ .glob = "src/**/*.zig" }});
defer source.deinit();
var handwritten = try source.except(&.{.{ .glob = "src/**/generated/**" }});
defer handwritten.deinit();
var public_sources = try handwritten.exceptTargeted(
    &.{.{ .regex = "^internal_" }},
    .filename,
);
defer public_sources.deinit();
```

Alternatives inside a selector remain OR, while its exclusions are OR-ed together and negated:
`(positive A OR positive B) AND NOT (excluded X OR excluded Y)`. The qualifier applies only to the
selector immediately before it; calling either exclusion method before a selector is an error.
The same vocabulary is available for subject and dependency-object file selectors, external
modules, layers, slices, metrics, and graph-query seeds. Slice exclusions run before path-to-slice
projection, and graph exclusions remove seeds before traversal. See
[D043](docs/decisions.md#d043--exclusions-are-owned-qualifiers-on-one-selector).

## Slice example

The pre-release slice API turns one captured path segment into a component and checks direct
component dependencies inside an ordinary Zig test:

```zig
const std = @import("std");
const archunit = @import("archunit");

test "API does not reach into retrieval" {
    var project = try archunit.projectSlices(std.testing.allocator, .{});
    defer project.deinit();
    var features = try project.definedBy("src/features/(**)/");
    defer features.deinit();
    var mood = try features.shouldNot();
    defer mood.deinit();
    var rule = try mood.containDependency("api", "retrieval");
    defer rule.deinit(std.testing.allocator);

    try archunit.expectPasses(
        &rule,
        archunit.AssertionOptions.init(
            archunit.CheckOptions.init(std.testing.allocator, std.testing.io),
        ),
    );
}
```

Use `should().containDependency(...)` for a required edge. Explicit regex capture, file-suffix,
and identity projections are also available; their ownership and orphan/external semantics are
recorded in [D036](docs/decisions.md#d036--slices-are-single-label-projections-with-explicit-orphan-and-external-semantics).

A checked-in component diagram can be a strict architecture contract:

```zig
const diagram =
    "@startuml\n" ++
    "component [api] as A\n" ++
    "component [services] as S\n" ++
    "A --> S\n" ++
    "@enduml\n";

var positive = try features.should();
defer positive.deinit();
var internal_only = try positive.ignoringExternalSlices();
defer internal_only.deinit();
var diagram_rule = try internal_only.adhereToDiagram(diagram);
defer diagram_rule.deinit(std.testing.allocator);
```

`adhereToDiagramInFile(path)` reads only when checked. `features.toPlantUml(options)` and
`features.exportAsPlantUml(options, path)` generate the reverse diagram deterministically. The
supported subset and strict missing/extra relationship behavior are recorded in
[D037](docs/decisions.md#d037--plantuml-validation-is-a-strict-diagnosable-component-subset).

## Structural metrics example

Zig metrics describe files and declarations instead of pretending containers are classes. This
rule limits immediate function declarations in every declaration-bound container under `src`:

```zig
var project = try archunit.metrics(std.testing.allocator, .{});
defer project.deinit();
var source = try project.inPath(&.{.{ .glob = "src/**/*.zig" }});
defer source.deinit();
var containers = try source.forContainersMatching(&.{.{ .glob = "*" }});
defer containers.deinit();
var counts = try containers.count();
defer counts.deinit();
var functions = try counts.functions();
defer functions.deinit();
var rule = try functions.shouldBeBelowOrEqual(12);
defer rule.deinit(std.testing.allocator);

try archunit.expectPasses(
    &rule,
    archunit.AssertionOptions.init(
        archunit.CheckOptions.init(std.testing.allocator, std.testing.io),
    ),
);
```

The same count builder exposes declarations, tests, constants, variables, fields, each named Zig
container kind, anonymous container syntax, imports, statements, tokens, source lines, and
non-blank lines. File, declaration, and container measurements can also be consumed directly with
`measure`, `summary`, and `analyze`. The precise AST and identity contract is recorded in
[D038](docs/decisions.md#d038--structural-metrics-use-declaration-bound-container-identities).

File scopes also expose directed dependency metrics:

```zig
var dependencies = try source.dependency();
defer dependencies.deinit();
var instability = try dependencies.instability();
defer instability.deinit();
var stability_rule = try instability.shouldBeBelowOrEqual(0.75);
defer stability_rule.deinit(std.testing.allocator);
```

Available facts are afferent coupling, efferent coupling, instability, and coupling factor. The pure
`calculateDependencyMetrics` API accepts any internal projected label universe and projected edges,
so module and slice projections use the exact same math. Zig abstractness, main-sequence distance,
and class-oriented zone rules are deliberately absent; [D039](docs/decisions.md#d039--dependency-metrics-count-distinct-projected-internal-neighbors)
records the formulas and why visibility is not treated as abstractness.

Project-specific metrics use an explicitly typed callback boundary:

```zig
fn risk(
    _: std.mem.Allocator,
    info: archunit.CustomMetricInfo,
) !archunit.MetricValue {
    const facts = info.structural orelse return error.MissingStructuralFacts;
    return .{ .unsigned = @intCast(facts.tokens + facts.imports) };
}

var custom = try source.customMetric(
    "token_import_risk",
    "tokens plus direct imports",
    archunit.CustomMetricCalculation.fromStateless(risk),
);
defer custom.deinit();
var rule = try custom.shouldBeBelow(.{ .unsigned = 500 });
defer rule.deinit(std.testing.allocator);
```

The same builder supports `shouldSatisfy`, whose callback receives the measured value and the same
subject view. Context-backed calculations and predicates are available, but their context is
borrowed and must outlive the builder and any derived rule. File, declaration, and container views
come from the structural scope. `customMetricForProjection` accepts a caller-defined `MapFunction`
for module or slice subjects; mapped internal self-edges define the complete label universe. See
[D040](docs/decisions.md#d040--custom-metrics-cross-a-scalar-only-borrowed-callback-boundary) for
the lifetime, projection, and numeric contracts.

Every metric selection exposes exactly six assertion terminals: `shouldBeBelow`, `shouldBeAbove`,
`shouldBe`, `shouldBeBelowOrEqual`, `shouldBeAboveOrEqual`, and `shouldSatisfy`. Built-in predicates
receive the measured `MetricValue` and the same allocator-safe subject context as custom predicates.
Integer thresholds retain signed/unsigned precision, floating thresholds must be finite, and mixed
integer/floating comparisons are rejected instead of coerced. [D041](docs/decisions.md#d041--metric-selections-have-five-threshold-verbs-and-one-predicate-verb)
records the evidence and vocabulary contract.

Metrics can also be gathered as owned structured data or written as a self-contained HTML report:

```zig
const check_options = archunit.CheckOptions.init(allocator, io);
var source = try archunit.metrics(allocator, .{ .locator = "." });
defer source.deinit();

var report = try archunit.MetricsExporter.gatherComprehensive(&source, check_options);
defer report.deinit(allocator);
try archunit.MetricsExporter.exportAsHtml(
    allocator,
    io,
    &report,
    "zig-out/architecture/metrics",
    .{ .title = "Architecture metrics", .include_timestamp = false },
);
```

The exporter appends `.html`, creates parent directories, and embeds all styling without network
resources. `CountMetrics`, `DependencyMetrics`, and `CustomMetricSelection` also expose
`gatherReportData`, `toHtml`, and `exportAsHtml` for focused reports. Disable the timestamp for
golden output. Reports include only metrics ArchUnitZig actually calculates; absent class-oriented
concepts are not rendered as zero-valued placeholders. See
[D042](docs/decisions.md#d042--metrics-reports-serialize-owned-zig-native-data).

## Explicit per-check logging

Logging is disabled unless the caller supplies at least one sink through `CheckOptions.logging`.
An ordinary Zig writer is enough for captured test output:

```zig
var log_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
defer log_output.deinit();

var check_options = archunit.CheckOptions.init(std.testing.allocator, std.testing.io);
check_options.logging = .{
    .level = .debug,
    .writer = &log_output.writer,
};
var violations = try rule.check(check_options);
defer violations.deinit(std.testing.allocator);
```

Levels are `debug`, `info`, `warn`, and `.@"error"` (escaped because `error` is a Zig keyword).
The default `info` level reports check lifecycle, extraction, and export events; `warn` reports
violations, while cache and metric details are `debug`. Progress, violation, and metric event
families can also be disabled independently.

For structured integrations, use a borrowed `LogSink`; for files, configure only the explicit I/O
context and destination:

```zig
check_options.logging = .{
    .file = .{
        .output_directory = "zig-out/architecture/logs",
        .name_prefix = "architecture",
        .mode = .append,
    },
};
```

File sinks create the directory and use UTC nanosecond names such as
`architecture-2026-08-11_10-11-12-123456789.log`. Writer, structured, and file sinks may be
combined; prefixes use portable ASCII letters, digits, `.`, `_`, and `-`. Their configuration is
borrowed for one operation, logging errors propagate, and no process-global logger or implicit
stdout/stderr writer exists. See
[D044](docs/decisions.md#d044--logging-is-explicit-borrowed-and-operation-local).

## Development

ArchUnitZig currently targets Zig 0.16.0.

```console
zig build test
zig fmt --check build.zig build.zig.zon src
```

The test build uses Zig's leak-detecting testing allocator as implementation work lands. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the branch, commit, pull-request, and quality workflow.

## License

[MIT](LICENSE)
