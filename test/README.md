# Tests

Unit tests live alongside the code; run them with:

```console
$ zig build test
```

Wasm 3.0 spec tests — run the full [WebAssembly/testsuite](https://github.com/WebAssembly/testsuite) (257 `.wast` files, 65k+ assertions) and compare against the pinned baseline at [`spec-baseline.tsv`](spec-baseline.tsv):

```console
$ zig build -Doptimize=ReleaseSafe
$ python3 scripts/check_spec_baseline.py
```

To run a single file:

```console
$ ./zig-out/bin/wabt spec run third_party/testsuite/i32.wast
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
