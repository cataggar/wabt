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
`--keep-work` is passed. Since the wabt CLI has no feature-selection option,
its GC-disabled check remains in the embedded Zig suite; the external runner
checks the wasm-tools `-gc` verdict.

## Legacy C++-era test corpus

The `parse/`, `regress/`, `spec-new/`, and `typecheck/` directories
hold ~500 golden tests carried over from the original C++ wabt. They
were driven by a Python harness that spawned per-tool wrappers
(`wat2wasm`, `wasm2wat`, …); both the harness and those wrappers were
removed when the CLI was reorganized under subject roots (#137).

The data is preserved as a corpus so a future Zig-native harness can
resurrect the coverage. Until that work happens these `.txt` files are
not exercised by any tooling.
