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

## Legacy C++-era test corpus

The `parse/`, `regress/`, `spec-new/`, and `typecheck/` directories
hold ~500 golden tests carried over from the original C++ wabt. They
were driven by a Python harness that spawned per-tool wrappers
(`wat2wasm`, `wasm2wat`, …); both the harness and those wrappers were
removed when the CLI was reorganized under subject roots (#137).

The data is preserved as a corpus so a future Zig-native harness can
resurrect the coverage. Until that work happens these `.txt` files are
not exercised by any tooling.
