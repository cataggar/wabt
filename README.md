# WABT: The WebAssembly Binary Toolkit

A fork of [WebAssembly/wabt](https://github.com/WebAssembly/wabt) ported from C++ to Zig and maintained with AI assistance. It supports the Wasm 3.0 proposals and passes the [WebAssembly/testsuite](https://github.com/WebAssembly/testsuite) at 65k+ assertions.

## Install

Install pre-built binaries from GitHub Releases with [ghr](https://github.com/cataggar/ghr):

```console
$ ghr install cataggar/wabt@v3.0.0-dev.1
```

See [INSTALL.md](INSTALL.md) for alternative installation methods (uv, pip) and detailed instructions.

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
  shrink          Minimize a wasm binary while preserving a property
  component       Component-model subcommands (embed)
  version         Print the wabt version and exit
  help            Print this help; `wabt help <subcommand>` for details
```

Run `wabt help <subcommand>` for details on any subcommand.

## Building

Requires [Zig](https://ziglang.org/) 0.16. No other dependencies.

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

Wasm 3.0 spec tests — run the full [WebAssembly/testsuite](https://github.com/WebAssembly/testsuite) (257 `.wast` files, 65k+ assertions) and compare against the pinned baseline at [`test/spec-baseline.tsv`](test/spec-baseline.tsv):

```console
$ zig build -Doptimize=ReleaseSafe
$ python3 scripts/check_spec_baseline.py
```

To run a single file:

```console
$ ./zig-out/bin/wabt spectest third_party/testsuite/i32.wast
```

## License

[Apache 2.0](LICENSE)
