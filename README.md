# ArchUnitZig

[![CI](https://github.com/LukasNiessen/ArchUnitZig/actions/workflows/ci.yml/badge.svg)](https://github.com/LukasNiessen/ArchUnitZig/actions/workflows/ci.yml)

ArchUnitZig turns a Zig project into a dependency graph and lets you enforce architecture as
ordinary `zig test` tests. Rules are lazy values: constructing a fluent chain performs no I/O;
checking it returns structured violations or integrates with Zig's test runner.

The current package targets Zig 0.16.0 and is pre-release. Its public surface ships file rules,
named layers, slices and PlantUML diagrams, Zig-native metrics, graph reports, native test helpers,
explicit per-check logging, and low-level extraction/projection data.

## Install

Until the first tagged release, Zig's package manager can track `main`. For a reproducible build,
replace `main` with a reviewed commit hash; after releases begin, prefer a release tag.

<!-- readme-test:install -->
```console
zig fetch --save=archunit git+https://github.com/LukasNiessen/ArchUnitZig.git#main
```

The explicit `--save=archunit` name is the key used by `b.dependency` below. Add an architecture
test module to `build.zig` and expose only ArchUnitZig's public module to it:

<!-- readme-test:build-wiring -->
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const archunit = b.dependency("archunit", .{ .target = target, .optimize = optimize });

    const architecture = b.createModule(.{
        .root_source_file = b.path("test/architecture.zig"),
        .target = target,
        .optimize = optimize,
    });
    architecture.addImport("archunit", archunit.module("archunit"));
    const architecture_tests = b.addTest(.{ .root_module = architecture });
    const run_architecture_tests = b.addRunArtifact(architecture_tests);
    run_architecture_tests.setCwd(b.path("."));

    const format = b.addFmt(.{ .paths = &.{ "build.zig", "build.zig.zon", "src", "test" }, .check = true });
    const test_step = b.step("test", "Run formatting and architecture tests");
    test_step.dependOn(&format.step);
    test_step.dependOn(&run_architecture_tests.step);
}
```

Now create `test/architecture.zig`. The body of this first rule is roughly ten lines because every
owned builder stage is released explicitly:

<!-- readme-test:first-test -->
```zig
const std = @import("std");
const archunit = @import("archunit");

test "production files have no cycles" {
    var files = try archunit.files(std.testing.allocator, .{});
    defer files.deinit();
    var production = try files.inPath(&.{ .{ .glob = "src/*.zig" }, .{ .glob = "src/**/*.zig" } });
    defer production.deinit();
    var should = try production.should();
    defer should.deinit();
    var rule = try should.haveNoCycles();
    defer rule.deinit(std.testing.allocator);
    try archunit.expectPasses(&rule, .init(.init(std.testing.allocator, std.testing.io)));
}
```

Run it with `zig build test`. This exact setup is also the repository's offline README-consumer
fixture, so the dependency wiring and first test compile on every ArchUnitZig test run.

## Fluent grammar and ownership

Read a chain left to right: source → scope → mood → predicate → optional dependency object →
terminal. For example, `project files, in path "src/api/**", should depend on files, in path
"src/service/**"`. Patterns in one selector call are OR alternatives; repeated selector calls are
AND clauses. `except` qualifies the immediately preceding selector. A subject selector matching no
files fails with `EmptyTestViolation` unless `CheckOptions.allow_empty_tests` is explicitly enabled.

Builders own copied locators, pattern programs, names, and policy data. The examples use
`std.testing.allocator`; applications may supply any allocator. Call `deinit()` on scopes and mood
stages, and `deinit(allocator)` on terminal rules, violation lists, snapshots, rendered buffers, and
test results whose API accepts the check allocator. Inputs such as `CheckOptions` slices, callbacks,
logging sinks, and callback contexts are borrowed only for the documented operation or builder
lifetime. Do not shallow-copy an owned builder; use its `clone` or another fluent method.

`expectPasses` distinguishes architecture disagreement from analysis failure. A rule disagreement
becomes `error.ArchitectureViolation`; parser, filesystem, allocation, and invalid-option errors keep
their own error identities and diagnostic context.

## Shipped modules

Each example below is a complete source file compiled and executed against the README consumer
fixture. They import only `archunit`, never repository internals.

### Files

File rules select concrete project-relative paths. Dependency predicates are direct unless a
projection API explicitly says otherwise.

<!-- readme-test:files-example -->
```zig
const std = @import("std");
const archunit = @import("archunit");

test "API files depend on service files" {
    var files = try archunit.files(std.testing.allocator, .{});
    defer files.deinit();
    var api = try files.inPath(&.{.{ .glob = "src/api/**" }});
    defer api.deinit();
    var should = try api.should();
    defer should.deinit();
    var dependency = try should.dependOnFiles();
    defer dependency.deinit();
    var rule = try dependency.inPath(&.{.{ .glob = "src/service/**" }});
    defer rule.deinit(std.testing.allocator);
    try archunit.expectPasses(&rule, .init(.init(std.testing.allocator, std.testing.io)));
}
```

Other shipped file terminals cover forbidden dependencies, external-module allow/block lists,
filename/folder/path matching, elementary cycles, and allocator-aware custom file predicates.

### Layers

Layer definitions have ordered ownership when patterns overlap. Same-layer dependencies are
implicit; allowlists name the other layers a source may read. Enable
`strict_unassigned_dependencies` when every connected graph endpoint must belong to a layer.

<!-- readme-test:layers-example -->
```zig
const std = @import("std");
const archunit = @import("archunit");

test "service may depend only on domain" {
    var architecture = try archunit.projectLayers(std.testing.allocator, .{});
    defer architecture.deinit(std.testing.allocator);
    var domain_stage = try architecture.layer("domain");
    defer domain_stage.deinit();
    var with_domain = try domain_stage.definedBy(.{ .glob = "src/domain/**" });
    defer with_domain.deinit(std.testing.allocator);
    var service_stage = try with_domain.layer("service");
    defer service_stage.deinit();
    var with_service = try service_stage.definedBy(.{ .glob = "src/service/**" });
    defer with_service.deinit(std.testing.allocator);
    var policy_stage = try with_service.whereLayer("service");
    defer policy_stage.deinit();
    var rule = try policy_stage.mayOnlyDependOnLayers(&.{"domain"});
    defer rule.deinit(std.testing.allocator);
    try archunit.expectPasses(&rule, .init(.init(std.testing.allocator, std.testing.io)));
}
```

`mayNotDependOnLayers` is the blocklist form. Every named source layer needs a policy to be checked.

### Slices

A slice is one label projected from a path capture, an explicit regex capture group, deterministic
file suffixes, or identity. Rules compare direct projected dependencies; PlantUML adherence and
export use the same projection.

<!-- readme-test:slices-example -->
```zig
const std = @import("std");
const archunit = @import("archunit");

test "API does not bypass service" {
    var project = try archunit.projectSlices(std.testing.allocator, .{});
    defer project.deinit();
    var slices = try project.definedByRegex("^src/([^/]+)/");
    defer slices.deinit();
    var should_not = try slices.shouldNot();
    defer should_not.deinit();
    var rule = try should_not.containDependency("api", "domain");
    defer rule.deinit(std.testing.allocator);
    try archunit.expectPasses(&rule, .init(.init(std.testing.allocator, std.testing.io)));
}
```

The shipped diagram API is `adhereToDiagram`, `adhereToDiagramInFile`, `toPlantUml`, and
`exportAsPlantUml`, with explicit orphan/external-slice options.

### Metrics

Metrics describe Zig files, declarations, and containers. They do not rename object-oriented class
metrics. Thresholds preserve integer types and reject non-finite floating values.

<!-- readme-test:metrics-example -->
```zig
const std = @import("std");
const archunit = @import("archunit");

test "source files stay small" {
    var project = try archunit.metrics(std.testing.allocator, .{});
    defer project.deinit();
    var source = try project.inPath(&.{.{ .glob = "src/**/*.zig" }});
    defer source.deinit();
    var counts = try source.count();
    defer counts.deinit();
    var functions = try counts.functions();
    defer functions.deinit();
    var rule = try functions.shouldBeBelowOrEqual(2);
    defer rule.deinit(std.testing.allocator);
    try archunit.expectPasses(&rule, .init(.init(std.testing.allocator, std.testing.io)));
}
```

Count selections include Zig declarations, tests, functions, variables, constants, fields,
containers, imports, statements, tokens, and source lines. File scopes also ship afferent/efferent
coupling, instability, coupling factor, custom scalar metrics, owned report data, and offline HTML
export.

### Graph reports

Graph builders can focus, traverse dependencies/dependents, collapse labels, include external or
self dependencies, return owned snapshots, and render DOT, Mermaid, D2, CSV, JSON, or offline HTML.

<!-- readme-test:graph-example -->
```zig
const std = @import("std");
const archunit = @import("archunit");

test "render the project graph as Mermaid" {
    var graph = try archunit.projectGraph(std.testing.allocator, .{});
    defer graph.deinit();
    const mermaid = try graph.toMermaid(.init(std.testing.allocator, std.testing.io));
    defer std.testing.allocator.free(mermaid);
    try std.testing.expect(std.mem.indexOf(u8, mermaid, "src/api/root.zig") != null);
}
```

Rendering allocates a buffer owned by the check allocator; export methods write only to the explicit
path and `std.Io` supplied by the caller.

### Testing and result formatting

Use `expectPasses` for ordinary tests. Use `rule.check`, `ViolationFactory`, and `ResultFactory` when
an adapter or custom runner needs structured facts and deterministic presentation.

<!-- readme-test:testing-example -->
```zig
const std = @import("std");
const archunit = @import("archunit");

pub fn renderedFailure() !archunit.TestResult {
    var files = try archunit.files(std.testing.allocator, .{});
    defer files.deinit();
    var service = try files.inFile(&.{"src/service/root.zig"});
    defer service.deinit();
    var should_not = try service.shouldNot();
    defer should_not.deinit();
    var dependency = try should_not.dependOnFiles();
    defer dependency.deinit();
    var rule = try dependency.inFile(&.{"src/domain/root.zig"});
    defer rule.deinit(std.testing.allocator);
    var violations = try rule.check(.init(std.testing.allocator, std.testing.io));
    defer violations.deinit(std.testing.allocator);
    const sentence = try rule.description(std.testing.allocator);
    defer std.testing.allocator.free(sentence);
    return archunit.ResultFactory.fromViolations(
        std.testing.allocator,
        violations.items(),
        sentence,
        .{ .color = .{ .mode = .never } },
    );
}

test "testing support renders a concrete failure" {
    var result = try renderedFailure();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.passed);
    try std.testing.expect(std.mem.indexOf(u8, result.message, "src/service/root.zig:1:16") != null);
}
```

That deliberate disagreement renders this plain-text result:

<!-- readme-test:failure-output -->
```text
Architecture rule failed with 1 violation:

1. File dependency violation
   Rule: project files, in file "src/service/root.zig", should not depend on files, in file "src/domain/root.zig"
   File: src/service/root.zig
   Reason: depends on forbidden internal files
   Imports:
     - src/service/root.zig:1:16 -> src/domain/root.zig [zig_file]
```

Colour is applied only at result assembly. `.never` is deterministic; `.auto` requires a declared
ANSI-capable terminal. `assertAllPass` combines heterogeneous owned `Checkable` rules without losing
the rule sentence associated with each violation.

## Zig dependency classification

ArchUnitZig parses valid Zig with Zig's AST, extracts literal dependency builtins, resolves what can
be resolved without executing `build.zig`, and retains target class, availability, import kind, and
source locations as separate facts.

| Zig reference | Graph treatment |
| --- | --- |
| Relative `@import("x.zig")` | Resolved project file is internal; missing and outside-project targets remain visible with their availability. |
| Relative `@import("x.zon")` | Project-owned data dependency; no synthetic Zig self-node is invented for the ZON file. |
| Named `@import("domain")` | Internal only when the selected `CompilationUnitOverride` maps it to a project root; package mappings and unresolved aliases remain external. |
| `@import("std")`, `@import("builtin")` | Compiler-class external modules with distinct import kinds. |
| `@import("root")` | Resolves to the selected compilation unit's root; without that context it remains an unresolved compiler alias. |
| `@embedFile("asset")` | Resource-class dependency; a resolved in-project asset remains project-owned. |
| `@cImport` / `@cInclude` | C-header-class evidence while Zig 0.16 still supports the deprecated form. |
| Import inside `test` | Included by default as a real test consumer; set `include_test_imports = false` for a production-only graph. |
| Import inside `comptime` | An ordinary `comptime` outside a `test` declaration remains production compile-time coupling. |

`CompilationUnitOverride` values model each library, executable, test, or other root and its exact
module alias table. Multiple roots may map the same alias differently. Unknown aliases do not
silently disappear. Strict parsing rejects malformed source and non-literal operands; permissive
parsing returns owned syntax diagnostics and no partial edges from a rejected file.

### Project-level `.archignore`

An optional `.archignore` at the located project root adds exclusions to every architecture scan.
It uses the same case-sensitive ArchUnit glob syntax as `ExtractionOptions.exclusions`: `*` stays
within one path segment, `**` crosses segments, `/pattern` is rooted, a pattern without a separator
matches a basename at any depth, and `\` is accepted as a path separator. Blank lines and full-line
`#` comments are ignored. Inline comments and gitignore negation are not supported; a line beginning
with `!` fails with `InvalidPattern` instead of silently behaving like a different language.

Only the root file is read. Nested `.archignore` files have no effect, and all three exclusion
sources are additive: the file cannot re-include a built-in cache/vendor/output directory or a path
excluded explicitly through `CheckOptions`. The cache identity includes the normalized root-file
path, its presence, and a SHA-256 fingerprint of its exact bytes, so edits invalidate cached graphs.

## Limitations

| Area | Current contract |
| --- | --- |
| Zig version | Exactly Zig 0.16.x APIs are targeted; other Zig versions are not supported until explicitly tested. |
| Releases | The package is pre-release and has no stable compatibility guarantee yet; pin a commit rather than mutable `main` in production. |
| Build discovery | ArchUnitZig does not execute or claim to understand arbitrary `build.zig`; named modules need explicit compilation-unit mappings. |
| Dynamic dependencies | Only literal `@import`, `@embedFile`, and `@cInclude` operands are dependency facts. Non-literal operands are parser diagnostics, not guessed names. |
| Package internals | Package-origin modules remain external. ArchUnitZig does not recursively analyze fetched dependency source as part of the current project. |
| Language model | There are no class/interface rules, LCOM, abstractness, main-sequence distance, or class-oriented zone metrics. |
| Visibility | Zig declaration visibility is not treated as abstractness or an architecture layer. |
| Slice vocabulary | Only the projection, dependency, PlantUML, and export methods documented above are shipped; sibling-only slice methods are not implied. |
| Filesystem traversal | Symlinks/reparse points are not followed, nested marked Zig projects are boundaries, cache/VCS/output/docs/dependency trees are excluded by default, and only the project-root `.archignore` is loaded. |
| Concurrency | Graph cache instances are unsynchronized; the process-wide cache is mutex-protected, but caller-owned writers and sinks need their own coordination if shared. |

## Configuration and diagnostics

`CheckOptions` carries the allocator, `std.Io`, working directory, empty-test policy, cache control,
logging, and one `ExtractionOptions` value. Extraction options cover exclusions, strictness,
resource/C-header inclusion, test-import inclusion, compilation-unit mappings, and the currently
explicit-only build-graph mode. Every field that changes a graph participates in its cache key.

Logging is disabled by default. A check can borrow an ordinary writer, structured `LogSink`, and/or
file sink with explicit output directory and prefix. Levels are `debug`, `info`, `warn`, and
`.@"error"`; logging failures propagate, and no process-global stdout/stderr logger is configured.

Architecture disagreements are data-only `Violation` values. Invalid selectors/options are user
errors, while parsing, allocation, I/O, and violated internal invariants are technical errors with
an owned `ErrorContext` diagnostic. Paths are normalized to project-relative `/` identifiers in
public graph and report data.

## More documentation

- [Documentation site](https://lukasniessen.github.io/ArchUnitZig/)
- [Compiler-generated API reference](https://lukasniessen.github.io/ArchUnitZig/api/)
- [Architecture and executable dogfood rules](docs/architecture.md)
- [Zig-specific design decisions](docs/decisions.md)
- [Ordered roadmap](docs/roadmap.md)
- [Contribution and quality workflow](CONTRIBUTING.md)

For repository development, run `zig fmt --check build.zig build.zig.zon src` and `zig build test`.
The test build compiles the standalone README consumer and every fenced example without requiring
Python. Run `zig build docs` after guide, example, public API, or theme changes; it first runs that
consumer chain, then builds and validates the guide and compiler API docs.

## License

[MIT](LICENSE)
