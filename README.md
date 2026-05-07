# WABT: The WebAssembly Binary Toolkit

A fork of [WebAssembly/wabt](https://github.com/WebAssembly/wabt) ported from C++ to Zig and maintained with AI assistance.

**100% WebAssembly 3.0 spec conformance** — 65,011/65,011 tests passing.

## Install

Pre-built binaries are published to [GitHub Releases](https://github.com/cataggar/wabt/releases) and [PyPI](https://pypi.org/project/wabt-bin/). See [installation details](https://github.com/cataggar/wabt/issues/69).

```console
$ dist install cataggar/wabt
```

```console
$ uv tool install wabt-bin
```

## Tools

All tools are exposed as subcommands of a single `wabt` binary, in the
style of [wasm-tools](https://github.com/bytecodealliance/wasm-tools)
and `zig`:

```console
$ wabt help
wabt - WebAssembly Binary Toolkit

Usage: wabt <subcommand> [args...]

Subcommands:
  parse           Translate WebAssembly text format to binary (was wat2wasm)
  print           Print a wasm binary as WebAssembly text format (was wasm2wat)
  validate        Validate a WebAssembly binary
  objdump         Dump information about a WebAssembly binary
  strip           Strip custom sections from a WebAssembly binary
  json-from-wast  Convert a .wast spec test to JSON + .wasm files (was wast2json)
  decompile       Decompile a wasm binary into readable pseudo-code
  stats           Print module statistics
  desugar         Parse and re-emit WebAssembly text format
  spectest        Run a WebAssembly spec test (.wast)
  version         Print the wabt version and exit
  help            Print this help; `wabt help <subcommand>` for details
```

Run `wabt help <subcommand>` for details on any subcommand.

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
$ ./zig-out/bin/wabt spectest third_party/testsuite/i32.wast
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
