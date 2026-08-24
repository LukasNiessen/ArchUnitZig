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

Before graph normalization, every resolver result becomes an owned classified reference. Target
class (`internal`, `external`, `compiler`, `resource`, or `c_header`) is separate from availability
(`resolved`, `unresolved`, `missing`, or `outside_project`) and from the compatibility `external`
boolean. This is intentional: a resolved embedded resource is project-owned but still a resource,
while a missing resource remains a resource but is not an internal concrete target. `ImportKind`
retains the finest Zig identity in every case.

Classified results keep the raw import name, graph-facing target, optional mapped source path,
source location, and all three classification facts. Normalized edges retain sets of target classes
and availabilities alongside import kinds, so parallel references can union classification evidence
without flattening it back to one external bit. An explicitly mapped project module changes
the graph target from its raw alias to the resolved project-relative root and becomes internal.
Package and unresolved aliases keep stable raw graph targets. A resolved `root` alias can be
internal while its `root_module` kind remains observable; `std` and `builtin` remain compiler class.

Every discovered Zig source file receives a self-edge. Edges with the same `(source, target)` are
merged and union their kinds. Public identifiers are project-relative and separator-normalised to
`/`, which keeps patterns, diagnostics, cache keys, and golden output portable.

Graph normalization consumes borrowed per-source classified references and returns a fully owned
graph sorted by normalized source, then target. Every enumerated lowercase `.zig` file receives
exactly one internal self-edge, including import-free files; enumerated ZON data does not receive a
synthetic Zig node. Synthetic self-edges start with an empty import-kind set because no source
expression created them.

Parallel `(source, target)` references must agree on externality. They merge into one edge, union
their import-kind sets, and retain unique source locations sorted by zero-based byte offset, then
line and column. Repeated source entries and repeated imports cannot duplicate an edge or location.
Equal external target names from different sources remain separate pairs. Edge and graph clones own
independent path and location storage.

## Pattern matching

`Pattern` distinguishes default glob syntax from the explicit regular-expression escape hatch.
Globs are anchored: `*` stays in one path segment, `**` crosses segments, `?` matches one character,
and `[...]` defines a character class. Both user patterns and candidates normalise `\\` separators
to `/`; matching remains case-sensitive. Glob filters therefore record exact whole-target matching,
while explicit regular expressions use partial matching and can opt into whole-target behavior with
their own anchors.

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

An ordinary line comment may suppress intentional dependency occurrences with `// archunit: ignore`.
A trailing directive applies to literal dependency calls spanning that line; a standalone directive
applies only to a builtin beginning on the immediately following physical line. Optional targets are
comma/whitespace separated and compare exactly after Zig string-literal decoding. Directive comments
are found only in tokenizer gaps, so doc comments, strings, and multiline strings are not annotations.
Malformed intended directives are located user errors rather than silently changing graph output.

Relative `.zig`, `.zon`, and embedded-file paths resolve from the importing file. The resolver
collapses `.` and `..` segments using project-relative `/` identifiers before filesystem access.
Existing targets are canonicalised against the canonical project root, which also catches paths
that leave the root through filesystem indirection. Results explicitly distinguish `resolved`,
`missing`, and `outside_project`; resolved ZON and embedded resources stay internal while retaining
their original import kind and source location. Absolute targets are outside because Zig documents
file imports as relative.

Named module imports cannot be resolved from the string alone: `build.zig` supplies aliases and a
repository may have several roots with different import tables. The path resolver returns no result
for those kinds and never probes by appending `.zig`. Callers instead provide explicit compilation
units for each library, executable, test, or other root. Every unit has a stable id, optional root
source path, and its own exact alias table; therefore the same alias can resolve differently in two
units without a false global winner.

Module results retain the raw import name, concrete source path when known, import kind, location,
and one of `resolved_project`, `resolved_package`, `compiler_provided`, `unresolved`, `missing`, or
`outside_project`. Project mappings pass through the root-bounded file resolver. Package mappings
must be explicitly marked and remain external even if their checked root file is physically stored
under the project. `std` and `builtin` are compiler-provided; `root` resolves only from the selected
unit. Unknown aliases stay visible rather than disappearing.

ArchUnitZig does not read or execute `build.zig` in the default resolver. Zig build files are
arbitrary programs whose module tables can depend on options, targets, environment, I/O, and control
flow. A recognizer for a few call spellings would imply completeness it cannot provide, so static
discovery is deferred until it can expose a precise supported-form contract and diagnostics.

Project discovery canonicalises an explicit directory/marker or searches upward for the nearest
`build.zig.zon`, then `build.zig`. Source enumeration uses Zig 0.16's selective directory walker so
excluded directories are never opened recursively. Symlink/reparse entries are not followed, and a
nested marked Zig project is a traversal boundary by default. The owned result contains sorted,
project-relative `/` paths for lowercase `.zig` and `.zon` files; custom exclusion globs are additive
to the documented cache, VCS, output, documentation, and dependency defaults.

Extraction settings live in one `ExtractionOptions` value: exclusions, parser strictness,
resource/C-header toggles, explicit compilation-unit mappings, and build-graph mode. Graph-cache
keys use the canonical project root plus a length-delimited encoding of every field. A schema test
reflects over the options and nested module-mapping structs, so adding a field without acknowledging
it in key construction fails the suite. Slice order is significant; this may conservatively miss an
equivalent hit but cannot return a graph produced for different input.

`GraphCache` instances own cloned keys and graphs and are deliberately not synchronized. Reads also
return clones, so clearing or destroying a cache never invalidates a caller's graph. The process-wide
cache wraps the same implementation in an atomic mutex, owns storage with `page_allocator`, and is
invalidated by thread-safe `clearGraphCache`. `CheckOptions.clear_cache` is an operation control, not
an extraction input, so it does not participate in cache identity.

Projection is a pure allocator-backed layer over `Graph`. A `MapFunction` borrows an optional typed
context and returns borrowed `MappedEdge` labels or null to drop a raw edge. `projectEdges` immediately
clones valid non-empty labels and raw `Edge` evidence, aggregates equal label pairs, and sorts pairs
and evidence. The resulting values remain valid after the source graph and mapper context are gone.

`projectToNodes` deep-clones its evidence as well. Raw self-edges retain isolated nodes but do not
appear as incoming or outgoing dependencies. External targets are omitted by default, while their
source's outgoing evidence stays visible; opting in creates the external target node and incoming
evidence. Owned `ProjectedCycle` values require a closed ordered edge path. Iterative Tarjan/Johnson
cycle discovery produces deterministic directed cycles over these values.

The standard `perEdge`, `perInternalEdge`, and `perExternalEdge` mapping factories drop raw self-edges;
`identity` retains them deliberately. Internal/external factories inspect only the graph's canonical
`external` fact. Zig import kinds remain orthogonal evidence: resolved `root` and embedded resources
may be internal, while unresolved `root`, missing resources, compiler modules, packages, and C headers
may be external without changing the shared projection vocabulary.

## Rules and reports

The first user-facing release prioritises file rules, named layers, and graph reports. Slices follow
once pattern/regex capture is stable. Metrics focus on Zig declarations and dependency coupling.
Class-oriented parity is not a goal when the underlying concept is absent.

Every rule is lazy and returns violations as values. User/technical errors use Zig error unions and
diagnostic context. The testing edge turns non-empty violations into a normal `zig test` failure.

File scopes are allocator-bound owned values. `projectFiles` and `files` clone an optional locator;
each `withName`, `inFolder`, `inPath`, or `inFile` call returns a deep independent scope. Every scope
must be deinitialized, and `clone` is required instead of shallow struct assignment when another
owner is wanted. This makes branching safe without an arena parent lifetime. Selector construction
compiles patterns but performs no I/O. Its pure `select(graph)` boundary consumes a normalized graph;
terminal `check` remains the only fluent operation that may locate and extract a project.

`should` and `shouldNot` return different owned stage types over one shared rule context. The context
carries the scope plus a two-value `Mood`; `Mood.holds(predicate_result)` is the only assertion-level
negation operation. Mood stages expose neither another mood nor scope selectors, and the grammar has
no synonyms. Rule descriptions reuse one renderer and append only `should` or `should not`.

`Violation` is an owned, closed tagged union of structured facts. Each domain rule adds an evidence
shape only when it lands, and the testing formatter must then handle the new tag exhaustively. The
kernel does not render final prose. `ViolationList` is the owned check result: zero items means pass,
while `appendMove` makes ownership transfer explicit and clone/deinitialisation cover every payload.

The shared report boundary has two owned stages. `ViolationFactory` exhaustively turns each
`Violation` variant into a `FormattedViolation` containing a heading, details, and an uncoloured
sort key. It normalizes project-relative paths to `/`, includes concrete import kinds and source
locations, and provides a separate `formatUnknown` fallback for opaque adapter or plug-in values.
`ResultFactory` combines those values with the rule sentence, sorts before numbering, and returns a
pass/fail `TestResult` with one owned message. Adapters must delegate to these factories rather than
invent their own prose.

Colour is applied only while assembling the final result, after ordering has been decided. `always`
and `never` are deterministic testable choices; `auto` requires the caller to declare an ANSI-capable
terminal and is suppressed by no-colour policy or a dumb terminal. Plain text therefore remains the
safe default for redirected output and tools that cannot establish terminal capabilities.

`expectPasses` and `assertPasses` are the native `zig test` edge. They accept a concrete terminal,
run its `check`, obtain its owned description, delegate to `ResultFactory`, emit a failed result once,
and return `error.ArchitectureViolation`. `AssertionOptions` carries the normal `CheckOptions`, result
policy, and an optional borrowed failure writer. Without that writer, the helper locks stderr through
the caller's `std.Io`; automatic ANSI is enabled only when stderr reports escape-code support. User
and technical check errors propagate unchanged and produce no architecture-failure message.

`assertAllPass` applies the same contract to owned heterogeneous `Checkable` handles. The erased
vtable preserves an owned-description operation as well as `check`, so violations from different
rules retain the correct sentence in one sorted report. Handles remain caller-owned, checks run in
order, and the first analysis error discards all partial violation and description storage.

Structural metrics cross a second Zig AST boundary because the dependency graph deliberately does
not retain declaration trees or source spans. `MetricProjectInfo` owns sorted file facts and named
declaration facts. File counts describe immediate root members; declaration-bound container counts
describe immediate members; line, token, import, anonymous-container, and block-statement facts
describe the complete lexical subject span. `MetricAnalysis` owns the extracted project and exposes
a deterministic borrowed view selected at file, declaration, or container level.

`metrics` scopes are lazy allocator-bound values using the shared path and declaration-name pattern
semantics. Count selections produce owned measurements, summaries aggregate the selected structural
facts, and threshold terminals emit the shared structured `metric` violation. Numeric evidence keeps
signed integers, unsigned integers, and floating-point values tagged rather than routing counts
through `f64`. Class/interface vocabulary and class-level LCOM do not exist in this model.

Dependency metrics consume a projected internal label universe and projected edge evidence. They
count distinct directed neighbor labels rather than imports, so file, collapsed-module, and slice
views share one calculation. The fluent facade builds the file projection from normalized Zig
self-nodes and internal file-to-file edges, then applies path selectors only to the returned subjects;
the full topology remains the normalization denominator. Resources and ZON dependency objects are
not silently promoted to Zig source subjects. Abstractness and main-sequence distance have no Zig
metric because visibility and opaque syntax do not establish abstract contracts.

Custom metrics sit on a scalar-only callback boundary above structural and projected dependency
analysis. Metric definitions own their name and description, while calculation/predicate contexts
are explicitly borrowed. A callback sees stable identity slices for that invocation plus copied
structural facts, copied dependency facts, and a contributing-file count; it never receives an AST,
tokenizer buffer, or source buffer. File, declaration, and container builders reuse `MetricsScope`.
Module and slice builders reuse the public edge mapper and require mapped internal self-edges to
declare the complete projected subject universe. Measurements and violations clone all evidence
that survives the callback.

Metric selection terminals share one assertion layer. Five threshold verbs route tagged values to
one comparator and produce `MetricViolation` data with measured value, comparison, and threshold.
The sixth verb, `shouldSatisfy`, routes the value and scalar subject view to a borrowed predicate.
Built-in predicate failures use `MetricPredicateViolation`; custom failures retain their described
custom evidence. Predicate rules never manufacture a comparison or threshold that did not exist.

Metric reports cross an owned renderer-independent boundary. Count, dependency, and custom builders
gather their real summaries or measurements into sorted typed sections before rendering. The
comprehensive facade composes count and file-dependency sections; scopes without a file dependency
topology omit that section. The offline HTML renderer works only from this data, escapes titles and
labels, preserves numeric tags, embeds CSS, and optionally adds a UTC timestamp. Export resolves an
HTML filename, creates parent directories, and writes through caller-supplied `std.Io`.

Graph reports cross a separate renderer-independent snapshot boundary. `projectGraph` keeps project
identity and owned query state lazy until `snapshot(CheckOptions)` extracts the normalized graph.
Focus, reachability, and dependent selection produce a node set; collapse then maps those nodes and
their selected edges; equal mapped pairs aggregate counts plus import-kind, target-class, and
availability sets. The final snapshot owns a title, sorted stable-id nodes, sorted label-based edges,
and summary counts. `GraphRenderer` turns only that value into owned DOT, Mermaid, D2, CSV, JSON, or
offline HTML bytes. Format escaping and metadata-backed external/resource styling stay inside the
rendering module. Export creates parent directories deliberately and writes through caller-supplied
`std.Io`; fluent render/export terminals may perform extraction once but a renderer never does.

The `empty_test` tag records a stable machine `rule_id`, negation, and scope-pattern
facts (selector group, glob/regex/literal syntax, target, and exact/partial mode). This preserves OR
patterns within one selector and AND across selector calls, so the testing layer can explain a
vacuous rule without retaining builders or compiled regular expressions.

`projectFiles(...).should().haveNoCycles()` is positive-only and checks the induced internal graph
of selected files. Both endpoints of an edge must be selected; the rule never contracts a path
through an unselected file. External and synthetic self-edges cannot form file cycles. Each
elementary cycle is one `cycle` violation whose ordered path owns projected edges and underlying raw
imports, including locations. Cycle-path prose belongs to `testing`, not the assertion payload.

`haveName`, `beInFolder`, and `beInPath` are self-contained predicates in both moods. They share one
terminal and one pure gatherer; only the filter target changes between filename, directory portion,
and complete project-relative path. A `matching` violation owns the selected path, original pattern
expression and syntax, target, exact/partial mode, and mood. Subject selectors remain separate and
continue to use OR within one call and AND across calls.

`dependOnFiles()` exists in both moods and begins a separate object-selector stage. The first object
selector completes a terminal; later object selectors remain chainable and use AND, while patterns
within one selector use OR. The rule evaluates only direct internal non-self edges. Positive mood is
an allowlist for every direct dependency of a selected subject; negative mood is a blocklist.
Subjects are Zig nodes, while object candidates also include internal edge targets such as ZON and
embedded files. A `file_dependency` violation groups owned projected target edges by source and
therefore retains every concrete import kind and location.

`dependOnExternalModules().matching(...)` is also available in both moods. By default it governs
external named modules: resolved packages, unresolved aliases, and unavailable named mappings.
Compiler modules, C headers, and missing/outside embedded resources are distinct opt-in categories.
Repeated `matching` calls add OR alternatives. Positive mood is an allowlist and negative mood a
blocklist within the enabled categories. A local module mapping is internal and cannot be mistaken
for an external-module violation. External violations group owned projected edges by source and keep
target class, availability, import kind, and source locations.

`adhereTo(predicate, description)` is the Zig escape hatch in both moods. Its callback signature is
`fn (std.mem.Allocator, FileInfo) anyerror!bool`: returning a boolean participates in the same
`Mood.holds` logic as built-in predicates, while returning an error aborts the check unchanged as an
analysis failure. `FileInfo` exposes project-relative path, stem, dot-prefixed extension, directory,
raw source bytes, non-blank byte-line count, per-kind import counts/set, and optional AST-derived
root declaration counts. Source bytes need not be UTF-8.

The terminal reads one selected source at a time. Every slice in `FileInfo` is borrowed and valid
only until that predicate call returns; callbacks must not retain it. The supplied allocator is the
check allocator and may be used for temporary work under normal Zig ownership rules. A custom-file
violation owns the path, policy description, mood, and scalar summaries, but deliberately does not
duplicate the source buffer. Unlike graph-dependent rules, this terminal enumerates the selected
files directly so malformed or binary `.zig` bytes can still be governed. Valid Zig syntax supplies
AST facts; malformed bytes and ZON files expose `null` declaration facts rather than invented data.

`projectLayers`/`layers` builds one lazy named-layer policy over the normalized internal file graph.
`layer(name).definedBy(...)` selects complete paths and `definedByFolder(...)` selects directories;
glob matching is exact and regex matching partial. Layer names are unique. When definitions overlap,
the first declaration owns the file deterministically, including for empty-source checks. Every
transition deep-clones owned definitions, compiled filters, policies, and the optional locator, so
builders are branchable and construction performs no extraction.

`whereLayer(name).mayOnlyDependOnLayers(...)` creates an allowlist; an empty list seals the source
layer. `mayNotDependOnLayers(...)` creates a non-empty blocklist, and blocklists are evaluated before
allowlists so one edge produces at most one violation. Intra-layer edges always pass. Unassigned
internal endpoints are ignored by default or become structured `unassigned_endpoint` disagreements
under `strict_unassigned_dependencies`; external edges never participate. Resolved Zig module aliases
and `root` mappings are ordinary internal edges and retain their import kinds and locations.

Only a layer used as a policy source invokes the shared empty-test guard. The guard counts effective
first-precedence assignments rather than raw selector matches. A layer dependency violation owns its
projected edge, optional source/target assignments, and policy kind; rendering remains exclusively in
the testing layer.

`projectSlices`/`slices` projects normalized paths to one component label. `definedBy` requires one
literal `(**)` marker and captures one non-empty path segment; `definedByRegex` uses capture group 1.
Pure identity and file-stem suffix projections are also public. A path has at most one label,
unmatched paths are orphans, and duplicate labels deliberately collapse files and aggregate their
raw dependency evidence. Matched isolated files remain labels through normalized self edges.

Internal intra-slice edges are removed. External targets remain exact external graph identifiers
when their source maps, including when the identifier equals the source slice label. In both moods,
`containDependency(source, target)` governs one direct projected edge: positive mood reports an
absent required edge without fabricated import evidence, while negative mood reports the concrete
forbidden edge and its locations. A projection matching no internal labels uses the universal empty
guard; a non-empty projection does not require every label named by a negative absence rule to exist.

PlantUML is a small owned boundary over that same slice graph. The parser recognizes component
declarations, optional aliases, two directed arrows, comments, and one start/end block. Every other
statement produces a structured one-based line/column diagnostic. Successful parsing resolves
aliases to sorted canonical names and pairs. Diagram rules compare both relationship sets: extra
actual edges retain projected import evidence, while missing actual edges carry only the expected
source and target.

Positive diagram stages can independently ignore actual edges involving undeclared diagram nodes or
purely external slice targets. Mixed internal/external evidence stays governed. Inline bytes and file
paths are owned during construction but consumed only by terminal checks, after non-vacuity is
established. Reverse generation uses projected labels as components and projected edges as arrows,
including isolated internal labels and external targets, so parsing the generated UTF-8 and applying
strict validation returns no disagreement.

Every terminal applies one shared empty-test guard to its subject selection. Zero subjects produce
one `empty_test` violation by default, including under negation; `allow_empty_tests` returns an empty
result instead. Direct file-dependency rules also guard a zero-match object scope in both moods,
because their possible objects are the finite internal project files and a misspelling is
detectable. External module names form an open universe: a positive rule with no enabled external
candidates guards its object expression, while a negative rule with no forbidden match passes by
definition. A positive expression missing existing external candidates reports ordinary dependency
violations instead of hiding them behind an empty-test result.

Every terminal rule is directly checkable through `check(CheckOptions)`. Options carry explicit
`std.Io`, the working directory, result allocator, empty-test/cache controls, per-check logging
configuration, and the centralized extraction options. Their slices are borrowed only for the call;
every returned `ViolationList` is owned by the supplied allocator.

Heterogeneous rule collections use owned `Checkable` boxes. `fromMove` makes the transfer explicit
and prevents a stored handle from dangling after a stack rule leaves scope. `checkAll` runs boxes in
order, moves their violations into one result, and discards partial results when a later rule returns
a user or technical error.

Errors have two disjoint sets. `UserError` covers malformed patterns/directives, unknown layers,
impossible options, invalid paths/module overrides, and invalid fluent stages. `TechnicalError` covers I/O,
allocation, malformed project metadata, unsupported build output, parser failure, and internal
invariants. Native causes are mapped at the boundary rather than leaked as an unstable public set.
An optional owned `ErrorContext` retains the stable operation, subject, and underlying cause for the
testing/reporting layer. Architecture disagreement stays outside both sets as violation data.

## Verification strategy

1. Pure algorithms use hand-built graph fixtures and exhaustive unit tests.
2. Extraction uses focused syntax/path fixtures, including malformed and multi-root projects.
3. Every terminal has a public-API integration test against a real Zig project.
4. End-to-end fixtures include clean and intentionally violating twins plus explicit module-alias
   and non-Zig dependency targets.
5. `std.testing.allocator` detects leaks on owned paths, AST-derived data, violations, and reports.
6. Golden diagnostics/renderers are deterministic and tested with hostile escaping input.
7. Dogfood rules protect this repository's module boundaries and include negative proof tests.
