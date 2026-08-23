# Zig-specific decisions

This log captures choices that should not be rediscovered in each implementation ticket. A decision
may be amended by a pull request that updates its rationale, consequences, tests, and affected issue.

## Accepted

### D001 — Target Zig 0.16.0 first

Zig changes quickly before 1.0. ArchUnitZig starts on the current stable 0.16.0 toolchain and records
that minimum in `build.zig.zon`. Compatibility with another release is a tested change, not an
unverified version range.

Consequence: CI and examples pin 0.16.x; public use of `std.zig.Ast`, `std.Io`, and `std.Build` is
reviewed on every Zig upgrade.

### D002 — Project-relative forward-slash identifiers

All internal identifiers are relative to the analyzed project/package root and use `/` separators.

Consequence: results are portable and readable, while workspace support must preserve a package
identity so two packages cannot collapse equal relative paths.

### D003 — Explicit allocation and ownership

Public work that allocates caller-owned data receives a caller-supplied allocator. Owned results
expose an explicit cleanup path; borrowed views document their lifetime. A process-wide internal
cache may use a documented library allocator only when it stores clones, exposes invalidation, and
never transfers that allocator's storage to callers (D019).

Consequence: fluent-builder ergonomics require a prototype before being repeated. Convenience never
justifies leaks, dangling AST/source slices, or undocumented transfer of ownership.

### D004 — Data-only tagged-union violations

Zig has no open base class. The planned representation is an owned tagged union whose variants carry
facts. The testing layer exhaustively formats them.

Consequence: adding a fundamentally new violation shape updates the union and formatter. This is a
deliberate Zig trade-off for exhaustive cleanup and safe value semantics. Owned transfers use named
move functions that invalidate the source; cloning allocates independent payload storage. A
`ViolationList` with zero items is the only pass representation.

### D005 — Safe build analysis by default

Analyzing a project does not execute its `build.zig`. Build scripts are arbitrary code and may have
side effects or network behavior.

Consequence: explicit compilation-root/module maps land first. Unresolved aliases remain visible.
Any build execution mode must be opt-in and clearly separated from static analysis.

### D006 — Preserve Zig dependency kinds

Relative `.zig`, `.zon`, named module, `std`, `builtin`, `root`, `@embedFile`, and C-header references
remain distinguishable even when the shared graph also exposes a simple `external` flag.

Consequence: file rules, external-module rules, graph styling, and diagnostics can state what they
actually include instead of conflating compiler, package, code, and resource dependencies.

### D007 — `std.testing` helpers are the native adapter

Zig has no custom matcher registration layer. A small `expectPasses`/`assertPasses` helper is the
idiomatic integration with ordinary `test` blocks.

Consequence: no framework detection or import-time registration. Formatting remains shared so a
future adapter does not duplicate messages.

### D008 — No invented class metrics

Metrics use Zig files, declarations, containers, functions, and dependency graphs. LCOM,
class/interface counts, abstractness, and main-sequence distance are omitted unless a separately
reviewed Zig definition preserves their meaning.

Consequence: initial metrics cover structural counts, afferent/efferent coupling, instability,
coupling factor, and custom callbacks.

### D009 — Use zoptia0regex behind an ArchUnitZig adapter

Zig 0.16 has no standard-library regex engine. ArchUnitZig pins
[`zoptia0regex` 0.4.0](https://github.com/zoptia/zoptia0regex/tree/v0.4.0) by immutable package hash
and exposes it only through an allocator-aware adapter. The engine ports Go's RE2-style semantics,
supports numbered and named captures, avoids exponential backtracking, cross-compiles as Zig source,
and uses an Apache-2.0 license with a BSD-derived notice.

The alternatives evaluated for [issue #4](https://github.com/LukasNiessen/ArchUnitZig/issues/4) were:

| Candidate | Result | Reason |
| --- | --- | --- |
| `zoptia0regex` 0.4.0 | Selected | Zig 0.16, capture groups, linear-time design, explicit allocator API |
| `mnemnion/mvzr` 0.3.12 | Rejected | No capture groups and documents backtracking behavior |
| `zig-utils/zig-regex` 0.2.1 | Rejected | Current package requires a Zig 0.17 development toolchain |
| In-repository engine | Deferred | Duplicates a substantial parser/VM without improving the current contract |

Before selection, the dependency passed all 51 upstream unit tests and all 14,934 committed
differential/fuzz cases on Zig 0.16.0. ArchUnitZig additionally tests invalid expressions, captures,
allocation failures, exact/partial behavior, and a nested-repetition adversarial input.

Consequence: public code does not expose backend types. Backend replacement remains possible, while
the adapter owns compilation state and callers supply temporary match allocations. The exact URL,
version, hash, and notices are recorded in `build.zig.zon` and `THIRD_PARTY_LICENSES.md`. Regex and
glob wildcards follow the engine's Unicode-scalar semantics; identifiers otherwise remain UTF-8 byte
slices. This is tested and documented rather than silently treating one byte as one character.

### D011 — Owned type-erased checkables

Concrete terminal rules expose `check(CheckOptions)` directly, preserving their precise error sets.
For heterogeneous collections, `Checkable.fromMove` allocates an owned box, moves the rule into it,
and invalidates the source. The erased vtable broadens errors to `anyerror` only at this collection
boundary and destroys both the concrete rule and box through its original owner allocator.

This was selected over a borrowed handle because Zig cannot encode the backing value's lifetime in
the handle type. An owned box makes it impossible for a collection to outlive stack-backed rule
storage. `checkAll` evaluates in order and moves each owned `ViolationList` into one result, cleaning
partial results on the first error.

Consequence: erasing a rule performs one allocation and requires an explicit `deinit`; callers that
check one concrete rule pay neither cost. `CheckOptions.allocator` owns returned violation data,
while borrowed exclusions and module overrides need only live through the check call.

### D012 — Error tags plus optional owned diagnostic context

`UserError` and `TechnicalError` are disjoint Zig error sets. User errors identify invalid API/rule
input; technical errors identify analysis that could not be performed. Functions use those tags in
ordinary error unions. When the tag alone is insufficient, a caller-owned `ErrorContext` records an
owned diagnostic code, stable operation identifier, optional subject, and optional underlying Zig or
OS error.

Consequence: normal error propagation remains idiomatic and allocation-free unless context is
requested. Recording context can itself fail only as `OutOfMemory`. A rule disagreement never enters
either error set; it remains a `Violation` in the returned list.

### D013 — Marked project and filesystem traversal boundaries

Automatic project discovery walks upward from a canonical working directory. The nearest directory
with `build.zig.zon` wins, falling back to `build.zig`; no marker is a user error, while an explicit
directory may intentionally be unmarked. Enumeration never follows symlinks or reparse points and
does not enter a nested directory containing either Zig project marker unless the caller explicitly
disables that boundary.

Default directory exclusions cover VCS data, Zig caches/output/package caches, vendored dependencies,
coverage/distribution output, and documentation/generated trees. Caller patterns are additive and
retain root-anchored versus basename semantics. Results include lowercase `.zig` and, by default,
`.zon` files as sorted project-relative `/` paths.

Consequence: one analysis cannot accidentally absorb a sibling package, dependency cache, or link
cycle. Workspace/nested-package analysis must opt in and preserve package identity in issue #48.

### D014 — AST-validated, token-based dependency discovery

Source extraction parses the complete file with Zig 0.16's `std.zig.Ast`, then recognizes builtin
tokens for literal `@import`, `@embedFile`, and `@cInclude` calls inside deprecated `@cImport`.
Targets are decoded with `std.zig.string_literal.parseAlloc` before import-kind classification.
This combines syntax validation with a small dependency-specific token pass and avoids coupling the
library to unstable declaration-node shapes it does not need.

Strict mode maps malformed files, non-literal operands, and invalid literals to the technical
`ParserFailure` error with owned `ErrorContext`. Permissive mode returns owned syntax diagnostics;
an AST-invalid file contributes no partial references. Locations use a zero-based byte offset and
one-based line/column, anchored at the dependency builtin. C headers are observable only while
`@cImport` remains in Zig 0.16, and an `@cInclude` outside that lexical call is ignored.

Consequence: comments and string contents cannot create dependencies, escaped targets are handled
according to Zig semantics, callers can choose fail-fast versus editor-friendly analysis, and no
project code or build script executes. A Zig upgrade must review both AST and token APIs under D001.

### D015 — Relative file resolution is explicit and root-bounded

Zig 0.16 defines a file-form `@import` target as relative to the file containing the call. The same
basis applies to `@embedFile`. ArchUnitZig resolves `.zig`, `.zon`, and embedded-resource targets by
combining decoded strings with the importing file's project-relative directory, normalising both
separator forms plus `.`/`..`, and then canonicalising an existing target against the canonical
project root.

Resolution returns an owned target with its original import kind and source location plus one of
`resolved`, `missing`, or `outside_project`. A lexical root escape is reported without probing it;
canonical comparison prevents filesystem indirection from silently making an external file
internal. Absolute targets are outside because the language contract requires relative file paths.
Named/compiler imports return no path-resolution result and are never guessed by appending `.zig`.

Consequence: missing and outside targets remain diagnosable, ZON and resource files owned by the
project can become internal graph nodes, and build-defined aliases remain visible for issue #11.
Final external/compiler/resource classification remains the responsibility of issue #12.

### D016 — Module resolution is scoped to explicit compilation units

A Zig repository does not have one global import table. Each library, executable, test, or other
compilation root may bind the same module name differently. Resolution therefore accepts an
explicit compilation unit with a stable id, optional root source path, and exact alias mappings.
Mappings declare `project` or `package` origin. `root` uses the selected unit; `std` and `builtin`
remain compiler-provided; unknown aliases remain owned unresolved results.

Project mappings reuse the root-bounded file resolver. Package roots are existence-checked but keep
their stable raw alias as the graph-facing target and remain package-provided even when stored under
the repository. Duplicate aliases inside one unit, duplicate unit ids, empty mappings, and attempts
to override `std`, `builtin`, or `root` are user errors. Identical aliases in different units are
valid and resolve independently.

ArchUnitZig does not read or execute `build.zig` for this path. Build scripts are arbitrary Zig
programs and may derive roots/imports through options, control flow, helper functions, dependencies,
environment, or I/O. Static matching of a few `std.Build` call shapes would be safe to execute but
dishonest about completeness, so it is deferred until a mode can publish a precise supported-form
contract and surface everything else as unresolved.

Consequence: resolution is deterministic and context-correct without running untrusted code. Users
or build integrations must supply the compilation contexts they actually test; issue #12 can then
classify the explicit statuses without reconstructing build semantics.

### D017 — Target class, availability, and externality are orthogonal

One enum cannot honestly describe every Zig dependency. A project-owned `@embedFile` target is both
internal and a resource; a missing one is still a resource but has no internal concrete file. A
resolved `root` alias targets a project file while remaining identifiable as `root_module`.
ArchUnitZig therefore records target class (`internal`, `external`, `compiler`, `resource`, or
`c_header`), availability (`resolved`, `unresolved`, `missing`, or `outside_project`), the shared
`external` boolean, and `ImportKind` independently.

The owned classified result retains raw target text, graph-facing target, optional mapped source
path, and source location. Resolved project module aliases promote the graph target to their
project-relative source path. Package and unresolved modules keep their stable raw names, avoiding
machine-specific package-cache paths in shared graphs. Missing/outside mappings keep diagnostic
paths without becoming internal.

Consequence: the sibling-compatible graph can continue to consume `external` and import-kind sets,
while Zig diagnostics and future selectors can distinguish compiler aliases, resources, headers,
missing paths, and explicit module promotion without reverse engineering a flattened target.

### D018 — Normalized graphs own sorted edges and source locations

The graph invariant is one edge per normalized `(source, target)` pair. Normalization emits one
internal self-edge for every enumerated lowercase `.zig` source, including import-free files, then
adds its classified references. Synthetic self-edges begin with no import kinds because they do not
represent a source expression; a real self-import merges its kind and location normally.

Parallel edges must agree on the compatibility `external` flag. Their `ImportKinds` sets are
unioned, and owned source locations are sorted by byte offset, line, then column and deduplicated.
Edges themselves are sorted by normalized source and target after construction. ZON enumeration
entries do not become synthetic Zig nodes, and equal external names from different sources remain
distinct because source is part of the key.

Consequence: downstream traversal and rendering are deterministic across enumeration order and host
separators. Empty files remain observable, diagnostics can point to every distinct import site, and
callers may release all parser/classifier buffers immediately after normalization.

### D019 — Graph cache identity is complete and cached values never alias callers

Graph cache identity is a versioned, length-delimited byte encoding of the canonical project root
and every field in `ExtractionOptions`: exclusions, strictness, resource and C-header toggles,
compilation-unit/root/module mappings, and build-graph mode. Wyhash accelerates lookup, but equality
always compares the complete encoding. A reflection test requires each current and future extraction
or nested module-mapping field to be listed by the key schema. `CheckOptions.clear_cache` controls an
operation and therefore does not alter graph identity.

An instance `GraphCache` uses its explicit allocator and is not synchronized. It clones both keys and
graphs on insertion and clones graphs again on lookup; callers may deinitialise source inputs or clear
the cache without invalidating a result. The process-wide cache uses `page_allocator` behind an atomic
mutex because a zero-argument `clearGraphCache` must be callable across threads. The lock covers clone
allocation as well as lookup so invalidation cannot race an in-flight read.

Consequence: equal inputs can reuse extraction without mutable aliases, every invalidation releases
cache-owned memory, and option growth fails tests until cache identity is consciously updated. An
instance cache must be externally synchronized when shared; the global helpers provide that boundary.

## Open decisions

### D010 — Fluent builder storage ([issue #19](https://github.com/LukasNiessen/ArchUnitZig/issues/19))

Sibling builders are immutable values. Zig needs safe storage for a runtime number of patterns while
keeping an English-like chain and explicit allocation failure. Prototype arena/context-backed stage
views, owned persistent nodes, and a deliberately mutable state machine before choosing.
