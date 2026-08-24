# Extraction benchmark

`zig build benchmark` generates a deterministic Zig project under `.zig-cache/benchmark`, runs the
public extraction pipeline stage by stage in `ReleaseSafe`, exercises one cold and twenty cached
fluent checks, and writes machine-readable evidence to `zig-out/benchmark/results.json`.

The fixture has 240 source files in eight nested folders. Every file imports twelve peers and the
standard library, producing a dense but deterministic graph. Generation is deliberately outside
the measurements. The benchmark times enumeration, source loading, tokenize/parse,
resolution/classification, normalization, projection, the first rule check, and cached rule checks
separately. A tracking allocator records allocation calls, bytes requested, and peak live bytes for
each stage. Graph counts, a stable digest, projection cardinality, rule results, cache behavior, and
zero live tracked bytes are correctness gates even in report-only mode.

`zig build benchmark-check` additionally enforces `budgets.json`. Budgets are intentionally broad
hosted-CI regression tripwires, not microbenchmark promises or laptop-derived product guarantees.
The evidence block records the hosted run used to choose them. Update it only from an uncached
`ubuntu-latest` quality run, retaining enough headroom for normal shared-runner variance.

The current runtime ceilings are rounded above 25 times the recorded green Linux baseline, with
100–200 ms floors for filesystem stages too small for a useful ratio. The total ceiling is 20
seconds. The 64 MiB caller-allocator ceiling is more than eleven times the recorded peak. These are
coarse order-of-magnitude regression guards; changing fixture scale requires a new evidence run and
budget review rather than silently widening them.

The generated fixture is versioned in its directory name. Change that version whenever its shape or
contents change, so stale files cannot silently influence a new benchmark definition.
