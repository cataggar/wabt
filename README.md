# WABT: The WebAssembly Binary Toolkit (Zig)

A fork of [WebAssembly/wabt](https://github.com/WebAssembly/wabt) ported from C++ to Zig and maintained with AI assistance.

**100% WebAssembly 3.0 spec conformance** — 65,011/65,011 tests passing.

## Tools

 - **wat2wasm**: translate from [WebAssembly text format](https://webassembly.github.io/spec/core/text/index.html) to the [WebAssembly binary format](https://webassembly.github.io/spec/core/binary/index.html)
 - **wasm2wat**: the inverse of wat2wasm, translate from the binary format back to the text format (also known as a .wat)
 - **wasm-objdump**: print information about a wasm binary. Similar to objdump.
 - **wasm-interp**: decode and run a WebAssembly binary file using a stack-based interpreter
 - **wasm-decompile**: decompile a wasm binary into readable C-like syntax
 - **wat-desugar**: parse .wat text form and print canonical flat format
 - **wasm2c**: convert a WebAssembly binary file to a C source and header
 - **wasm-strip**: remove sections of a WebAssembly binary file
 - **wasm-validate**: validate a file in the WebAssembly binary format
 - **wast2json**: convert a file in the wasm spec test format to a JSON file and associated wasm binary files
 - **wasm-stats**: output stats for a module
 - **spectest-interp**: run WebAssembly spec tests (.wast files)

## Building

Requires [Zig](https://ziglang.org/) 0.15.x. No other dependencies.

```console
$ git clone --recursive https://github.com/cataggar/wabt
$ cd wabt
$ zig build
```

For release builds:

```console
$ zig build -Doptimize=ReleaseSafe
```

Cross-compilation works out of the box:

```console
$ zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSafe
$ zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe
$ zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
```

## Running tests

Unit tests:

```console
$ zig build test
```

Wasm 3.0 spec tests:

```console
$ zig build -Doptimize=ReleaseSafe
$ ./zig-out/bin/spectest-interp third_party/testsuite/i32.wast
```

## Wasm 3.0 proposals

All ratified Wasm 3.0 proposals are enabled by default:

| Proposal | Status |
| --- | --- |
| [Exception handling](https://github.com/WebAssembly/exception-handling) | ✓ |
| [GC (garbage collection)](https://github.com/WebAssembly/gc) | ✓ |
| [Memory64](https://github.com/WebAssembly/memory64) | ✓ |
| [Multi-memory](https://github.com/WebAssembly/multi-memory) | ✓ |
| [Tail calls](https://github.com/WebAssembly/tail-call) | ✓ |
| [Relaxed SIMD](https://github.com/WebAssembly/relaxed-simd) | ✓ |
| [Extended const](https://github.com/WebAssembly/extended-const) | ✓ |
| [SIMD](https://github.com/WebAssembly/simd) | ✓ |
| [Bulk memory](https://github.com/WebAssembly/bulk-memory-operations) | ✓ |
| [Reference types](https://github.com/WebAssembly/reference-types) | ✓ |
| [Multi-value](https://github.com/WebAssembly/multi-value) | ✓ |
| [Annotations](https://github.com/WebAssembly/annotations) | ✓ |

## License

[Apache 2.0](LICENSE)
