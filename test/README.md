# Tests

Unit tests live alongside the code; run them with:

```console
$ zig build test
```

Wasm 3.0 spec tests — `wabt` does not execute WebAssembly, so the
[WebAssembly/testsuite](https://github.com/WebAssembly/testsuite)
conformance run lives in
[cataggar/wamr](https://github.com/cataggar/wamr), which uses the
`.wast` helpers from this repository to convert the suite into commands
and then runs them on the WAMR engine. See `zig build spec-testsuite`
there.

To convert a single `.wast` file to JSON + `.wasm` modules:

```console
$ ./zig-out/bin/wabt spec to-json input.wast
```

## Core GC regression corpus

`src/fixtures/gc-regression/corpus.json` is embedded by
`src/gc_regression.zig` and runs under `zig build test`. Its five valid
modules contain each core GC encoding `0xfb00..0xfb1e` exactly once and cross
WAT parse/validate, binary write/read/validate, and print/reparse. The suite
also checks validation with GC disabled. Its invalid side has 12 semantic WAT
cases and 7 malformed binary bodies covering operands/results, indices,
packed/default/mutability rules, nullability, recursive subtyping, and
truncated or malformed immediates.

For the standalone wasm-tools 1.250.0 differential matrix:

```console
$ zig build
$ scripts/gc_regression.py \
    zig-out/bin/wabt \
    /path/to/wasm-tools-1.250.0
```

The runner materializes the shared corpus under
`zig-out/gc-regression-matrix`, compares WAT and binary verdicts, validates
wabt-produced binaries with wasm-tools, checks GC-disabled rejection, and
compares canonical wasm-tools prints across wabt's print/reparse round-trip.
It downloads nothing, is not part of `zig build test`, exits nonzero on any
mismatch, and removes materialized files after a successful run unless
`--keep-work` is passed. The script predates the shared CLI `--features`
selector, so its GC-disabled check remains in the embedded Zig suite; the
external runner checks the wasm-tools `-gc` verdict.

## Wide arithmetic differential matrix

`src/wide_arithmetic_regression.zig` covers the four `0xfc13..0xfc16`
instructions in-process, including exact operands/results, feature gating,
unreachable-stack typing, malformed neighboring encodings, and
WAT/binary/WAT round trips.

The focused wasm-tools 1.250.0 matrix also exercises the CLI's
`--enable-wide-arithmetic` option:

```console
$ zig build
$ scripts/wide_arithmetic_regression.py \
    zig-out/bin/wabt \
    /path/to/wasm-tools-1.250.0
```

It compares enabled and disabled WAT and binary verdicts, malformed binaries,
and validates wabt-produced binary and text output with wasm-tools. Temporary
files stay below `zig-out/wide-arithmetic-matrix` and are removed after a
successful run.

## Custom page-size differential matrix

`src/custom_page_sizes_regression.zig` checks text, binary, validation, and
round-trip behavior for 1-byte and 64-KiB memory pages. Run its standalone
wasm-tools 1.250.0 matrix with:

```console
$ zig build
$ scripts/custom_page_sizes.py \
    zig-out/bin/wabt \
    /path/to/wasm-tools-1.250.0
```

Shared memories remain part of the threads feature. Shared tables are
intentionally rejected at every WABT boundary because they require the
separate shared-everything-threads type system, which WABT does not yet model.
wasm-tools 1.250.0 rejects them with its default features and accepts a
well-typed shared-table binary with `--features all`; WABT will continue to
reject them until a dedicated feature and shared types are implemented.

## Typed select differential matrix

`src/fixtures/typed-select-regression/corpus.json` supplements the inactive
C++-era typed-select goldens with an embedded suite run by
`src/typed_select_regression.zig`. It covers exact numeric and SIMD typing,
abstract and indexed references, recursive and declared subtyping,
nullability and bottom types, polymorphic stacks, feature gates, vector
arity, malformed LEBs, and text/binary round trips.

Run the wasm-tools 1.250.0 differential matrix with:

```console
$ zig build
$ scripts/typed_select_regression.py \
    zig-out/bin/wabt \
    /path/to/wasm-tools-1.250.0
```

Typed select belongs to reference-types even for numeric results; disabling
multi-value does not disable it. Type-specific SIMD, function-reference, GC,
and exception gates are checked through `Validator.Options` in the embedded
suite. The differential runner checks every combination of reference-types,
function-references, GC, and exceptions against wasm-tools: nullable
`func`/`extern` need only reference-types, their non-null forms need
function-references, GC heap types (including `nofunc`/`noextern`) need GC,
exception heap types need exceptions, and concrete function types need
function-references or GC. The consolidated cross-feature corpus below uses
the shared CLI `--features` selector to cover proposal gates outside typed
select.

## Declaration feature-gate oracle

`src/declaration_feature_gate_regression.zig` checks proposal gates across
types, tables, globals, tags, blocks, and element segments. Compare its WAT
and binary expectations with wasm-tools 1.250.0 using:

```console
$ scripts/declaration_feature_gate_regression.py \
    /path/to/wasm-tools-1.250.0
```

## Cross-feature differential corpus

`src/fixtures/cross-feature-regression/corpus.json` freezes expected CLI exit
statuses across function bodies, constant expressions, declarations, raw
dependency combinations, malformed WAT, and malformed or truncated binaries.
Run every case against wabt and wasm-tools 1.250.0 with:

```console
$ zig build
$ scripts/cross_feature_regression.py \
    zig-out/bin/wabt \
    /path/to/wasm-tools-1.250.0
```

The runner checks WAT and binary verdicts under equivalent feature selectors,
validates wabt-produced binaries with wasm-tools, downloads nothing, and
removes its `zig-out/cross-feature-matrix` workspace after a successful run.
The corpus records the one spelling translation needed by the pinned oracle:
wabt's `mutable-globals` is wasm-tools' `mutable-global`.

## Legacy C++-era test corpus

The `parse/`, `regress/`, `spec-new/`, and `typecheck/` directories
hold ~500 golden tests carried over from the original C++ wabt. They
were driven by a Python harness that spawned per-tool wrappers
(`wat2wasm`, `wasm2wat`, …); both the harness and those wrappers were
removed when the CLI was reorganized under subject roots (#137).

The data is preserved as a corpus so a future Zig-native harness can
resurrect the coverage. Until that work happens these `.txt` files are
not exercised by any tooling. Active Zig coverage may duplicate a legacy
golden, but does not replace it; preserving the historical corpus is the
repository policy.
