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

### D020 — Ignore directives are lexical, local, and exact

ArchUnitZig recognizes only an anchored ordinary line-comment grammar: `// archunit: ignore`, with
optional targets separated by commas or ASCII whitespace. Comment starts are discovered in gaps
between Zig AST tokens. This reuses the language tokenizer's knowledge of string, multiline-string,
and documentation-comment boundaries instead of stripping comments with a second parser.

A trailing directive applies to every literal `@import`, `@embedFile`, or in-`@cImport` `@cInclude`
whose token span contains that physical line. A standalone comment applies only to a dependency
builtin beginning on the immediately following line; a blank line breaks the association. Unscoped
directives suppress all applicable references, while scoped targets compare exactly with the decoded
literal. They do not use path-prefix matching because an annotation must not hide future siblings by
surprise.

A comment beginning like an ArchUnit directive but missing the colon, `ignore` keyword, or a target
after a comma returns the user error `InvalidIgnoreDirective`. Its owned diagnostic subject includes
the source path, line, and column. Other comments remain ordinary prose.

Consequence: compatibility exceptions stay visible beside the exact source dependency they waive,
one ignored occurrence cannot erase an unignored occurrence elsewhere, and malformed annotations
cannot silently weaken architecture checks.

### D021 — Projections own evidence and mapper results are borrowed

`MappedEdge` is a borrowed pair of non-empty labels returned by a type-erased `MapFunction`. The hook
borrows an optional typed context and returns null to drop an edge. `projectEdges` clones a successful
mapping before the next hook call, so stateless factories allocate nothing and contextual mappers may
return slices backed by their context or the current raw edge.

`ProjectedEdge` owns its labels and a non-empty collection of deep-cloned raw edges. Equal mapped
label pairs aggregate, then projected pairs and raw evidence are sorted lexically. `ProjectedNode`
also owns cloned incoming/outgoing evidence. Raw self-edges create nodes but are never reported as
dependencies; external target nodes are opt-in without hiding the source's outgoing external edge.
All outputs survive destruction of the input graph.

`ProjectedCycle` owns a non-empty closed sequence of cloned projected edges; discontinuous paths are
rejected. Iterative Tarjan/Johnson discovery produces these values without changing ownership or
violation evidence. Projection performs no filesystem access and uses only the allocator supplied
for that call.

Consequence: file, layer, and slice views can share one projection kernel without dangling graph
pointers or language-specific relabelling state. Deterministic owned results cost additional edge
clones, a deliberate trade-off for safe rule results and diagnostics.

### D022 — Standard edge factories preserve shared externality

`perEdge`, `perInternalEdge`, and `perExternalEdge` are allocation-free, stateless `MapFunction`
factories. All three drop raw self-edges because downstream dependency projections must not turn the
synthetic node-retention mechanism into a dependency. `identity` is the named deliberate exception
and retains every raw edge.

The filtered factories inspect only `Edge.external`; they never infer externality from `ImportKind`
or target spelling. A resolved `root` alias and project-owned `@embedFile` resource can therefore be
internal. An unresolved `root`, missing resource, `std`, `builtin`, package alias, or C header can be
external. Both states keep their Zig-specific import kind in the cumulated raw evidence.

Consequence: files, layers, slices, and reports share identical internal/external semantics across
languages, while Zig-specific selectors can still inspect kinds without changing graph topology.

### D023 — Cycle discovery is iterative, directed, and deterministic

Cycle discovery first normalizes projected dependencies: self-edges are removed, equal label pairs
are collapsed, identical raw evidence is deduplicated, and the remaining labels and evidence are
sorted lexically. Labels then receive dense integer IDs in lexical order. Tarjan identifies strongly
connected components and Johnson enumerates elementary circuits over that normalized adjacency.
Both algorithms, including Johnson's unblock operation, use explicit heap-backed stacks rather than
call-stack recursion so a deep dependency chain or circuit cannot exhaust the process stack.

A directed cycle is canonicalized by rotation to its lexically smallest label and emitted once.
Opposite directions remain different cycles because dependency direction is meaningful. Results are
sorted lexically by their vertex sequence. The public result deep-clones each projected edge and its
raw evidence, so callers may destroy the graph or intermediate projections immediately. The
`projectInternalCycles` convenience entry point deliberately uses `perInternalEdge`; external and
synthetic self-edges therefore cannot create file cycles.

Consequence: enumeration is stable across source and edge insertion order, parallel raw edges retain
their combined violation evidence without multiplying circuits, and graph depth consumes allocator
memory instead of call-stack depth. Elementary-cycle enumeration is inherently exponential in the
number of circuits, so callers should expect output-sensitive runtime for densely cyclic graphs.

### D010 — Fluent scopes are independent allocator-bound values

`projectFiles(allocator, options)` and `files` create an owned `FilesScope` and clone its optional
project locator without accessing the filesystem. Each selector compiles and owns its patterns plus
presentation-neutral evidence. A selector call is one OR group, while calls in the chain are ANDed.
`inFile` records literal/exact syntax rather than pretending a path is a glob or regular expression.

Every narrowing operation deep-clones the preceding locator and selector groups before appending its
own group. A base scope and all branches therefore have independent storage, retain the allocator
that created them, and each require `deinit()`. Plain struct assignment is not an ownership clone;
`clone()` is the explicit operation when a second owner is needed. Later fluent stages use different
types so invalid stage order is absent from the method set instead of represented by a runtime enum.
Builder-stage pattern failures are returned immediately as `InvalidPattern` or `OutOfMemory`.

An arena/context would make chains cheaper but every branch would borrow a less-obvious parent
lifetime. Reference-counted persistent nodes would reduce copies while adding atomic/non-atomic
policy and failure complexity. Independent values deliberately pay O(chain length) copying and regex
compilation per appended selector because architecture rules are short and ownership stays local.

Consequence: stored half-rules can be branched safely, caller pattern/locator buffers can be released
immediately, and allocation failures unwind one owner at a time. `select(graph)` remains pure; only a
future terminal `check` may locate and extract the configured project.

### D024 — Mood is one assertion fact behind two stage types

The assertion kernel defines exactly two `Mood` values, `should` and `should_not`. Its `holds` method
is the sole positive/negative truth inversion: assertion gatherers evaluate a predicate once and
report it when the selected mood does not hold. They do not branch into duplicate positive and
negative implementations.

The fluent surface nevertheless exposes distinct owned `FilesShould` and `FilesShouldNot` types.
Both are thin wrappers over one `FileRuleContext`, containing an independently cloned `FilesScope`
and one `Mood`. This keeps `should`/`shouldNot` off the mood-stage method sets and lets a future
positive-only predicate exist only on `FilesShould`. No synonyms are part of the grammar.
Descriptions are rendered through the shared context from original selector evidence and differ
only in the final mood phrase.

Consequence: one stored scope can safely produce both moods, each with local `deinit()`, and future
predicates receive one data flag instead of two code paths. The extra scope clone preserves D010's
branching and lifetime guarantees at the mood boundary.

### D025 — File cycles use a selected induced graph and retain concrete imports

`projectFiles(...).should().haveNoCycles()` is a positive-only terminal. It selects normalized file
nodes, then keeps an internal non-self edge only when both endpoints occur in that sorted selection.
An unselected intermediate file is not contracted into a synthetic selected-to-selected edge. A
cycle that leaves the selection is therefore outside the rule, while selecting that intermediate
file makes the complete circuit visible. This is the induced-subgraph behavior of the established
sibling APIs and avoids topology that never existed in the source.

The terminal composes project location, enumeration, source parsing, reference resolution,
classification, normalization, and caching through one reusable extractor. `CheckOptions` carries
explicit Zig `std.Io` and a borrowed working directory because Zig 0.16 intentionally has no hidden
global I/O interface. Compilation-unit overrides remain explicit and `build.zig` is not executed.
When exactly one unit exists, every source may use it; with multiple units, only an exact declared
root is assigned because descendant membership cannot be inferred honestly without build-graph
data. Other module imports remain visible as unresolved external references.

Every elementary directed circuit produces one owned `cycle` violation. Its path contains ordered
projected edges, and every projected edge deep-clones the concrete graph edges, import kinds, and
source locations that support it. Empty selections use the shared `empty_test` violation unless the
caller opts into vacuous passes. The assertion stores no final sentence; the testing layer may
format a readable closed path such as `a.zig -> b.zig -> a.zig` from the data.

Consequence: selection boundaries are predictable, external dependencies and normalization
self-edges cannot create false cycles, results survive graph/cache destruction, and future text or
machine reporters can choose their own rendering without re-extracting source evidence.

### D026 — Self-contained file matching is one target-driven assertion

`haveName`, `beInFolder`, and `beInPath` compile one predicate pattern at fluent construction time
and are available in both moods. All six entry points return the same owned terminal type. The
terminal differs only by the target stored in its filter: filename, path without filename, or full
project-relative path. It first applies the independently built subject selectors, enforces the
shared empty-test guard, then delegates to a pure `gatherMatchingFileViolations` function.

The gatherer accepts selected paths, a compiled filter, owned predicate evidence, and one `Mood`.
It normalizes separators through the matching kernel, evaluates each path once, and reports exactly
when `Mood.holds` is false. Glob compilation is anchored and records exact whole-target semantics;
regular expressions record partial semantics, with anchors available when the caller wants an exact
regular expression. A root-level file has `.` as its folder, matching the selector contract.

Every `matching` violation deep-copies the subject path and original predicate expression and stores
the syntax, target, matching mode, and mood. It does not retain a builder, compiled regex, graph, or
rendered sentence. Predicate construction therefore catches malformed patterns before filesystem
work, while returned violations survive terminal, graph, and cache destruction.

Consequence: the three predicates cannot drift into subtly different matching behavior, both moods
share one assertion path, Windows and POSIX spellings agree, and testing/reporting layers receive
enough structured evidence to explain either a required non-match or a forbidden match.

### D027 — File dependencies are direct, target-complete, and grouped by source

`dependOnFiles()` exists on both mood stages and returns a non-checkable object builder. Its first
`withName`, `inFolder`, `inPath`, or `inFile` call creates a terminal. Further object selectors clone
the existing terminal and append an AND condition; alternatives within one call retain OR semantics.
The subject scope and object scope are independent owned values, so either can outlive the builder
from which it was branched.

The rule projects only internal non-self graph edges. In positive mood the selected object set is an
allowlist: every direct dependency from a selected subject must target it. In negative mood it is a
blocklist: no direct dependency from a selected subject may target it. Reachability is deliberately
not traversed. A future transitive modifier must be explicit because silently following imports
changes both performance and the meaning of existing rules.

Subject selection uses normalized Zig self-nodes. Object selection uses the union of those nodes and
all concrete internal edge targets. This distinction is required in Zig because a ZON file or
embedded resource can be a real internal dependency without receiving a synthetic source self-edge.
External targets never enter the candidate set. Explicit module mappings may promote a named alias
to its local Zig root before selection; `build.zig` still is not executed.

Subject and object selections are guarded independently. Stable rule ids ending in `.subject` or
`.object` identify which side matched nothing, and `allow_empty_tests` is the sole opt-in to a
vacuous pass. The pure gatherer groups all disagreeing target edges under one source. Each
`file_dependency` violation owns those projected edges and their concrete raw imports, kinds, and
locations, while storing only the shared mood fact and no rendered prose.

Consequence: direct allowlists and blocklists share one `Mood.holds` decision, ZON/resources remain
selectable objects, multiple bad imports from one source render coherently, and rule results survive
destruction of the graph, selectors, terminal, and cache.

### D028 — External-module policy is category-explicit and metadata-backed

The normalized `Edge` model retains `TargetClass` and `TargetAvailability` sets in addition to its
external bit and import-kind set. Extraction inserts the exact classified values; parallel edges
union them. Compatibility constructors infer deterministic defaults for hand-built graphs. Clone,
equality, projection, caching, and violation ownership all preserve the sets. This is necessary
because target spelling cannot distinguish a resolved package alias from an unresolved alias, and
the external bit cannot distinguish either from `std`, a header, or a missing resource.

`dependOnExternalModules()` enables three categories by default: resolved package modules,
unresolved named aliases, and missing/outside named mappings. These together match the sibling
meaning of an external module while retaining their availability differences in evidence. Compiler
modules (`std`, `builtin`, and an unresolved `root`), C headers, and external/missing embedded
resources are excluded by default. The fluent builder and terminal expose explicit
`includingCompilerModules`, `includingCHeaders`, and `includingResources` opt-ins. A `root` mapped by
its compilation unit and any named module mapped to a project root are internal and never enter the
external projection.

The first `matching` call completes the terminal. Repeated calls and multiple patterns in one call
join one OR group, unlike the AND chaining of file object selectors. Within enabled categories,
positive mood is an allowlist and negative mood a blocklist. Empty subject and object policy is
refined by D030: in particular, absence is meaningful for a negative external blocklist.

The pure gatherer groups disagreeing external projected edges by source. Each
`external_module_dependency` violation owns those edges, including target class/availability sets,
import kinds, and locations, and stores no rendered prose. Category membership is derived from raw
edge evidence, never from names such as `std` or file extensions.

Consequence: policies can be broad by default without conflating fundamentally different Zig
dependency mechanisms, explicit opt-ins remain reviewable in fluent rules, and reporters can explain
whether a violation was a package, unresolved alias, compiler module, header, or resource.

### D029 — Custom file predicates receive one borrowed byte-safe view

`adhereTo(predicate, description)` is available from both file mood stages. The predicate type is a
function pointer taking the per-check allocator and a `FileInfo`, and returning `anyerror!bool`. A
plain boolean is evaluated through `Mood.holds`; any callback error propagates unchanged from
`check` and never becomes architecture disagreement data. Requiring an error-union return keeps one
stable function-pointer type while making the failure capability explicit at every callback.

`FileInfo` is a borrowed view with project-relative path, stem, dot-prefixed extension, directory,
raw source bytes, non-blank byte-line count, import total/counts/kinds, and optional top-level Zig
declaration counts split into functions, variables, tests, and other root declarations. Counts come
from Zig 0.16's AST and dependency parser rather than regular expressions. Invalid syntax and
arbitrary bytes remain observable; their declaration summary is `null` and import summary empty.
ZON files likewise expose bytes and path facts without pretending they have Zig declarations.

The terminal locates and enumerates the project with the normal exclusions, applies subject
selectors, then reads and evaluates one selected file at a time. It intentionally does not require a
dependency graph: graph extraction under strict syntax policy would reject the very binary or legacy
source bytes this escape hatch must be able to inspect. Each callback view is valid only until that
call returns and must not be retained. The check allocator may be used for temporary callback work.

On disagreement, `custom_file` owns the source path, user description, mood, byte and non-blank-line
counts, import summary, and optional declaration summary. It never copies source bytes into the
result. The description is validated as non-blank and copied when the terminal is built. Empty
subject selection uses the shared `EmptyTestViolation` contract before any callback is invoked.

Consequence: project-specific policies remain idiomatic `zig test` code, can safely inspect any file
bytes and allocate temporary state, report stable structured evidence, and cannot accidentally turn
callback failures or vacuous selections into passing architecture checks.

### D030 — One guard enforces terminal non-vacuity with relational exceptions

`guardEmptyTest` is the single assertion primitive for non-vacuity. It accepts a matched count,
`allow_empty_tests`, stable rule id, selector evidence, and `Mood`. A non-zero count returns a
continue signal. Zero returns either one owned `EmptyTestViolation` or, only with the explicit
option, an owned empty result. File terminals share thin scope adapters that collect evidence only
on the zero path; individual conditions no longer construct or bypass empty violations themselves.

Every current file terminal guards its subject selection: `haveNoCycles`, `haveName`,
`beInFolder`, `beInPath`, `dependOnFiles`, `dependOnExternalModules`, and `adhereTo`. Negation never
changes subject non-vacuity. A real-fixture conformance test enumerates all seven entry points using
the same misspelled folder, and pins rule id, mood, selector evidence, default violation, and explicit
opt-out behavior.

Relational objects depend on whether the candidate universe is closed. `dependOnFiles` selects from
the finite internal project graph, so zero object matches are guarded in both moods: the library can
prove that the requested file/folder/path does not exist. External module names are open-ended and
absence is the purpose of a blocklist. Therefore negative `dependOnExternalModules` rules do not
apply an object empty guard; no forbidden match is a pass, even when there are no external edges.
Positive external rules guard only when selected subjects have zero dependencies in the enabled
categories. When external candidates exist but none match the positive allowlist expression, the
normal dependency violations are returned because they explain the disagreement better.

`allow_empty_tests` affects only a guard that actually applies. It never suppresses ordinary
matching, dependency, cycle, or custom-predicate violations. This decision supersedes D028's earlier
choice to treat a negative external pattern with no observed match as an empty object expression.

Consequence: misspelled subject selectors fail uniformly, internal relational typos remain
defensive, external blocklists can state absence without false failures, and future terminals have
one allocation-safe guard contract to adopt.

### D031 — Reports cross one exhaustive owned formatting boundary

`ViolationFactory` is the only formatter for the closed `Violation` union. It returns a fully owned
`FormattedViolation` with separate heading, detail, and plain sort-key fields. The exhaustive switch
deliberately makes a new in-library violation fail compilation until its report representation is
defined. Opaque values supplied by a future adapter or plug-in use the separate `formatUnknown`
entry point, so forward-compatible fallback does not weaken that compile-time check.

`ResultFactory` accepts the rule sentence separately because violations remain data-only and not
every evidence shape retains its originating scope. It formats all violations, sorts by uncoloured
content, and only then assigns numbers and optional ANSI styling. Pass and failure messages are
owned `TestResult` values with clone and deinitialisation support. Paths are normalized to portable
project-relative spelling, and dependency evidence retains its import location, import kind, target
class, and availability in the final message.

Colour is explicit policy: `always` and `never` give stable output, while `auto` emits ANSI only when
the caller reports an ANSI-capable terminal and neither no-colour policy nor a dumb terminal applies.
Allocation-failure tests cover both factories and golden tests pin every current violation variant,
multi-violation ordering, Windows path normalization, colour modes, and unknown-value fallback.

Consequence: native and future testing adapters consume one deterministic report contract, cannot
silently diverge in wording or order, and never need to own violation-specific formatting logic.

### D032 — Native assertions use stderr plus a stable disagreement error

Zig error values cannot carry an owned diagnostic message. `expectPasses` and `assertPasses`
therefore follow the same shape as `std.testing`: on architecture disagreement they emit the shared
`ResultFactory` message and return `error.ArchitectureViolation`. They are ordinary `!void` helpers;
`assertPasses` is a naming alias, not a panic API. Their public edge is inline so the calling test
remains present in the error return trace.

`AssertionOptions` contains `CheckOptions`, result/colour policy, and an optional borrowed failure
writer. The writer replaces stderr and makes custom-runner integration and exact tests deterministic.
Otherwise stderr is locked through the explicit `std.Io`; `auto` colour enables ANSI only for an
escape-code terminal. Diagnostic writes are best effort, as in `std.testing`, and a closed output
stream does not change the semantic assertion error. A failure to analyze the project propagates its
original error unchanged and emits no architecture disagreement.

`Checkable` erasure includes an owned `description(Allocator)` operation. `assertAllPass` checks
handles sequentially, retains every sentence with its owned violations, and calls grouped
`ResultFactory` shaping once. It stops at the first user or technical error, cleans all partial data,
and never deinitializes the caller's handles.

Consequence: a normal Zig `test` block can use `try expectPasses(&rule, options)` without framework
registration, diagnostics stay shared and attributable across heterogeneous rules, and callers keep
explicit control of allocation, I/O, colour, and handle ownership.

### D033 — Layers are ordered ownership over internal file edges

Named layers do not introduce another extraction or graph model. `projectLayers` projects the same
normalized graph to internal non-self file edges and nodes, then assigns each path to the first
matching ordered `LayerDefinition`. Overlap is therefore deliberate precedence rather than multiple
membership. Duplicate layer names are rejected, and empty-policy guards count effective assignments
after precedence so a completely shadowed source cannot pass vacuously.

Definitions use complete-path or directory filters with the shared glob/regex semantics. Fluent
transitions deep-clone the optional locator, compiled filters, definitions, and policies; construction
is I/O-free and previous branches remain independent. Policy sources and targets must already be
declared. An empty allowlist seals a layer, a blocklist must be non-empty, duplicate targets and
duplicate same-kind source policies are errors, and blocklists take precedence over allowlists.

Intra-layer edges always pass. An internal edge with an unassigned endpoint is ignored by default;
the project-level `strict_unassigned_dependencies` option reports it with optional assignment fields
and the `unassigned_endpoint` policy kind. External/package/compiler/resource edges remain outside
layer policy. A resolved named module or `root` mapping is internal and participates with its exact
import kind and location.

Only definitions used as policy sources invoke `guardEmptyTest`; an unused empty definition is
descriptive data rather than a test. `LayerDependencyViolation` owns one complete projected edge,
source and target assignments, and the violated policy kind. The closed union and testing formatter
handle it exhaustively.

Consequence: layers remain a readable convenience over proven file semantics, overlap and strictness
are reviewable choices, module aliases cannot bypass policies, and layer reports retain concrete Zig
import evidence without duplicating extraction logic.

### D034 — Graph reports share one owned deterministic snapshot

Graph rendering begins only after a pure `Graph`-to-`GraphReportSnapshot` pipeline has filtered,
selected, collapsed, aggregated, sorted, and counted the dependency model. Renderers receive no
extractor or query options and issue #31 must make every format consume this same value. Snapshot
titles, node ids and labels, edge labels, and collections are deeply owned and cloneable. Nodes sort
by label and receive `n0`, `n1`, and subsequent stable ids; edges sort by source label then target
label.

External and self dependencies are independently opt-in. Removing self edges never removes isolated
internal files because normalized self edges establish the node universe before report-edge
filtering. Focus is undirected breadth-first traversal with an explicit depth; reachable and
dependent queries are outgoing and incoming transitive closures. Several query modifiers union
their selected node sets, and the absence of modifiers selects every eligible node. All matching
uses normalized project-relative paths and the shared glob/regex semantics.

Selection precedes collapse. Folder collapse retains the first positive number of directory
segments and leaves root files unchanged. Pattern collapse is a compiled global regular-expression
replacement: `$0` through `$9` expand existing captures, unmatched optional captures expand to
empty, and `$$` emits a dollar. Invalid capture references fail before snapshot work. Collapsed
self-edges are omitted unless self dependencies were requested.

The normalized Zig graph already has at most one edge for a `(source, target)` pair, because parallel
imports union evidence during extraction. `raw_edge_count` therefore counts selected normalized
edges before collapse, not source occurrences. An aggregated report edge's `count` records how many
of those normalized edges collapsed onto its pair. Aggregation unions import kinds, target classes,
and target availabilities and preserves whether any contributor was external. This keeps compiler,
resource, C-header, resolution, and import-kind facts available to every future renderer.

`projectGraph` and `dependencyGraph` own their locator and every query string. Each modifier clones
state and returns an independent builder. Construction performs validation but no filesystem I/O;
the terminal `snapshot(CheckOptions)` call performs extraction so working-directory, cache, module,
strictness, resource, and C-header choices retain the existing borrowed per-call lifetime. The
snapshot allocates from the check allocator and remains valid after the builder, graph, and cache
are destroyed.

Consequence: all output formats will agree on graph content and summary counts, graph queries remain
portable and branchable in ordinary Zig tests, collapse cannot erase Zig-specific classification
evidence, and renderer work cannot accidentally rerun or reinterpret extraction.

### D035 — Graph formats are owned views over one metadata-complete snapshot

`GraphReportFormat` is a closed enum covering DOT, Mermaid, D2, CSV, JSON, and HTML. The static
`GraphRenderer` dispatch and every `toX` helper take a completed `GraphReportSnapshot` and return an
owned byte slice from the caller's allocator. Unlike dynamic siblings, Zig needs no runtime format
lookup or snapshot-type check: unsupported formats and wrong input types do not compile. Mermaid is
the one renderer that can report `DanglingEdge` when a manually assembled snapshot edge has no node
id; snapshots produced by the factory satisfy that invariant.

All formats preserve snapshot order and use LF structural line endings. DOT and D2 quote backslash,
quote, and physical line controls. Mermaid uses stable snapshot node ids and HTML-escapes its label
surface. CSV uses RFC 4180 field quoting and carries source, target, aggregate count, externality,
import kinds, target classes, and target availabilities. JSON uses `std.json.Stringify`, emits the
same complete classification data, and is round-trip tested with `std.json`. These are serialization
decisions over existing facts; no renderer sorts, filters, or reconstructs the graph independently.

Visual styling is metadata-backed. External edges are dashed or dotted. Edges whose target-class
set contains `resource` are blue in DOT, Mermaid, and D2 and receive a resource row treatment in
HTML. HTML also marks external rows and exposes all edge metadata. Spelling such as a file extension
or the name `std` never decides presentation category.

The HTML renderer produces one deterministic offline UTF-8 document with embedded CSS. It has no
scripts, imports, remote URLs, fonts, or assets. Summary metrics, node and dependency tables, empty
state, and escaped Mermaid/DOT/D2/JSON source sections are present in the file itself. Every text or
attribute value crosses the HTML escaping boundary, including the portable source blocks.

`exportReport` renders first, validates a non-blank output path, deliberately creates its parent
hierarchy, overwrites the target, and propagates Zig's concrete directory/open/write errors.
Format-specific export helpers delegate to it. The fluent builder's `render`, `exportReport`,
`toX`, and `exportAsX` terminals first produce one owned snapshot using `CheckOptions`, then render;
their returned bytes use the check allocator and their file I/O uses the check `std.Io`.

Consequence: formats cannot disagree about graph membership or lose Zig classification evidence,
hostile labels cannot break their serialization context, HTML remains portable in restricted
environments, and library users retain explicit ownership and I/O failure handling.
