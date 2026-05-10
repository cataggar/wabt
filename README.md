# WABT: The WebAssembly Binary Toolkit

A fork of [WebAssembly/wabt](https://github.com/WebAssembly/wabt) ported from C++ to Zig and maintained with AI assistance. It supports the Wasm 3.0 proposals and passes the [WebAssembly/testsuite](https://github.com/WebAssembly/testsuite) at 65k+ assertions.

## Install

Install pre-built binaries from GitHub Releases with [ghr](https://github.com/cataggar/ghr):

```console
$ ghr install cataggar/wabt@v3.0.0-dev.4
```

See [INSTALL.md](INSTALL.md) for alternative installation methods (uv, pip) and detailed instructions.

## Tools

All tools are exposed as subcommands of a single `wabt` binary, in the
style of [wasm-tools](https://github.com/bytecodealliance/wasm-tools)
and `zig`, organized by conceptual subject:

```console
$ wabt help
wabt - WebAssembly Binary Toolkit

Usage: wabt <subject> <verb> [args...]

Subjects:
  text       Text format (.wat) work — parse, print, desugar
  module     Core wasm (.wasm) work — validate, objdump, strip, stats, decompile, shrink
  component  Component-model work — new, embed, compose
  spec       Spec testing (.wast) work — run, to-json

Global:
  version    Print the wabt version and exit
  help       Print this help; `wabt help <subject>` for details
```

Run `wabt help <subject>` for the verbs in that subject.

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

## License

[Apache 2.0](LICENSE)
