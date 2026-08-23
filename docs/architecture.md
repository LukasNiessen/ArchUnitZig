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

## Pattern matching

`Pattern` distinguishes default glob syntax from the explicit regular-expression escape hatch.
Globs are anchored: `*` stays in one path segment, `**` crosses segments, `?` matches one character,
and `[...]` defines a character class. Both user patterns and candidates normalise `\\` separators
to `/`; matching remains case-sensitive.

The selected regex engine operates on Unicode scalar values. Consequently, glob `?` and character
classes match one Unicode scalar, which may occupy several UTF-8 bytes. Identifiers remain ordinary
UTF-8 byte slices for storage, equality, and graph operations; this documented matching behavior
avoids splitting a valid multi-byte character.

A compiled `Filter` owns its regex program and records one target: filename, full path, path without
filename, or Zig declaration/type name. Patterns supplied in one selector call are alternatives
(OR); repeated selector calls are cumulative (AND). Empty alternatives match nothing and zero
selector calls match everything.

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

ArchUnitZig first validates each source with Zig's own AST parser, then scans the resulting token
stream. Literal `@import`, `@embedFile`, and `@cInclude` calls nested inside deprecated `@cImport`
are found without executing the source. String literals are decoded with Zig's standard literal
parser before targets are classified, so escaped module names and file extensions retain their
semantic import kind. Comments, ordinary string contents, and multiline-string contents cannot
become false dependencies because they are not builtin tokens.

Each reference owns its decoded target and records a zero-based byte offset plus one-based line and
column for the builtin. Strict extraction maps malformed syntax, invalid literals, and non-literal
dependency operands to the technical `ParserFailure` tag with `ErrorContext`. Permissive extraction
returns owned syntax diagnostics instead; a file rejected by the AST contributes no partial edges.
This policy preserves deterministic whole-file analysis while allowing callers such as editors to
continue across broken files.

Relative `.zig`, `.zon`, and embedded-file paths resolve from the importing file. The resolver
collapses `.` and `..` segments using project-relative `/` identifiers before filesystem access.
Existing targets are canonicalised against the canonical project root, which also catches paths
that leave the root through filesystem indirection. Results explicitly distinguish `resolved`,
`missing`, and `outside_project`; resolved ZON and embedded resources stay internal while retaining
their original import kind and source location. Absolute targets are outside because Zig documents
file imports as relative.

Named module imports cannot be resolved from the string alone: `build.zig` supplies aliases and a
repository may have several roots with different import tables. The path resolver returns no result
for those kinds and never probes by appending `.zig`. The safe initial design accepts explicit
compilation-root/module maps and preserves unresolved aliases as visible targets. Static discovery
for common build declarations may be added when it can report its limits honestly. Running an
arbitrary project's `build.zig` is never the default because build files are executable code.

Project discovery canonicalises an explicit directory/marker or searches upward for the nearest
`build.zig.zon`, then `build.zig`. Source enumeration uses Zig 0.16's selective directory walker so
excluded directories are never opened recursively. Symlink/reparse entries are not followed, and a
nested marked Zig project is a traversal boundary by default. The owned result contains sorted,
project-relative `/` paths for lowercase `.zig` and `.zon` files; custom exclusion globs are additive
to the documented cache, VCS, output, documentation, and dependency defaults.

## Rules and reports

The first user-facing release prioritises file rules, named layers, and graph reports. Slices follow
once pattern/regex capture is stable. Metrics focus on Zig declarations and dependency coupling.
Class-oriented parity is not a goal when the underlying concept is absent.

Every rule is lazy and returns violations as values. User/technical errors use Zig error unions and
diagnostic context. The testing edge turns non-empty violations into a normal `zig test` failure.

`Violation` is an owned, closed tagged union of structured facts. Each domain rule adds an evidence
shape only when it lands, and the testing formatter must then handle the new tag exhaustively. The
kernel does not render final prose. `ViolationList` is the owned check result: zero items means pass,
while `appendMove` makes ownership transfer explicit and clone/deinitialisation cover every payload.

The first tag is `empty_test`. It records a stable machine `rule_id`, negation, and scope-pattern
facts (selector group, glob/regex syntax, target, and exact/partial mode). This preserves OR patterns
within one selector and AND across selector calls, so the testing layer can explain a vacuous rule
without retaining builders or compiled regular expressions.

Every terminal rule is directly checkable through `check(CheckOptions)`. Options carry the result
allocator, empty-test/cache flags, per-check logging configuration, extraction exclusions, and an
explicit Zig root/module map. These slices are borrowed only for the call; every returned
`ViolationList` is owned by the supplied allocator.

Heterogeneous rule collections use owned `Checkable` boxes. `fromMove` makes the transfer explicit
and prevents a stored handle from dangling after a stack rule leaves scope. `checkAll` runs boxes in
order, moves their violations into one result, and discards partial results when a later rule returns
a user or technical error.

Errors have two disjoint sets. `UserError` covers malformed patterns, unknown layers, impossible
options, invalid paths/module overrides, and invalid fluent stages. `TechnicalError` covers I/O,
allocation, malformed project metadata, unsupported build output, parser failure, and internal
invariants. Native causes are mapped at the boundary rather than leaked as an unstable public set.
An optional owned `ErrorContext` retains the stable operation, subject, and underlying cause for the
testing/reporting layer. Architecture disagreement stays outside both sets as violation data.

## Verification strategy

1. Pure algorithms use hand-built graph fixtures and exhaustive unit tests.
2. Extraction uses focused syntax/path fixtures, including malformed and multi-root projects.
3. Every terminal has a public-API integration test against a real Zig project.
4. End-to-end fixtures include clean and intentionally violating twins.
5. `std.testing.allocator` detects leaks on owned paths, AST-derived data, violations, and reports.
6. Golden diagnostics/renderers are deterministic and tested with hostile escaping input.
7. Dogfood rules protect this repository's module boundaries and include negative proof tests.
