# Architecture

## Status

This is the working architecture for the Zig port. The language-agnostic direction comes from the
ArchUnitEverything kickoff artifacts and the implemented TypeScript, Go, .NET, and Ruby siblings.
Where Zig changes a decision, `decisions.md` records the reason and its consequences.

## Pipeline

```text
Zig project -> extract dependency graph -> project vocabulary -> assert policy -> report
```

The extractor is the language boundary. Projection, assertions, cycle detection, layer policy, slice
policy, and graph rendering operate on the shared data model and should remain pure apart from
caller-supplied allocation.

## Dependency model

The shared atom is an edge from a stable source identifier to a stable target identifier, plus an
external flag and a set of import kinds. ArchUnitZig adds enough import-kind detail to keep these Zig
concepts distinct:

- relative Zig file imports;
- relative ZON data imports;
- named build modules and package modules;
- compiler-provided `std`, `builtin`, and context-dependent `root` modules;
- embedded resource files;
- deprecated `@cImport` / C-header references while Zig 0.16 still supports them.

Every discovered Zig source file receives a self-edge. Edges with the same `(source, target)` are
merged and union their kinds. Public identifiers are project-relative and separator-normalised to
`/`, which keeps patterns, diagnostics, cache keys, and golden output portable.

## Module boundaries

```text
root.zig
  -> files | layers | slices | metrics | graph | testing
                  \       |       /
                         common
```

- `common` contains extraction, projection, matching, violation data, errors, check contracts, and
  logging.
- Domain modules depend on `common` but not on one another.
- `testing` formats common/domain violation data and exposes `std.testing` helpers.
- `root.zig` is a facade. Internal code never imports it.

The repository will enforce these rules against itself after the files API lands.

## Extraction strategy

ArchUnitZig uses Zig's tokenizer/AST for source syntax. Literal `@import`, `@embedFile`, and C-import
references are found without executing the source.

Relative `.zig`, `.zon`, and embedded-file paths resolve from the importing file. Named module
imports cannot be resolved from the string alone: `build.zig` supplies aliases and a repository may
have several roots with different import tables. The safe initial design accepts explicit
compilation-root/module maps and preserves unresolved aliases as visible targets. Static discovery
for common build declarations may be added when it can report its limits honestly. Running an
arbitrary project's `build.zig` is never the default because build files are executable code.

## Rules and reports

The first user-facing release prioritises file rules, named layers, and graph reports. Slices follow
once pattern/regex capture is stable. Metrics focus on Zig declarations and dependency coupling.
Class-oriented parity is not a goal when the underlying concept is absent.

Every rule is lazy and returns violations as values. User/technical errors use Zig error unions and
diagnostic context. The testing edge turns non-empty violations into a normal `zig test` failure.

## Verification strategy

1. Pure algorithms use hand-built graph fixtures and exhaustive unit tests.
2. Extraction uses focused syntax/path fixtures, including malformed and multi-root projects.
3. Every terminal has a public-API integration test against a real Zig project.
4. End-to-end fixtures include clean and intentionally violating twins.
5. `std.testing.allocator` detects leaks on owned paths, AST-derived data, violations, and reports.
6. Golden diagnostics/renderers are deterministic and tested with hostile escaping input.
7. Dogfood rules protect this repository's module boundaries and include negative proof tests.
