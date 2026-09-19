# WABT: The WebAssembly Binary Toolkit

A rewrite of [WebAssembly/wabt](https://github.com/WebAssembly/wabt) in Zig, maintained with AI assistance. It supports the Wasm 3.0 proposals. `wabt` does not execute WebAssembly — its parser, validator and binary writer are exercised against the full [WebAssembly/testsuite](https://github.com/WebAssembly/testsuite) (257 `.wast` files, 65k+ assertions) by [cataggar/wamr](https://github.com/cataggar/wamr), which runs the resulting modules on the WAMR engine.

## Install

Install pre-built binaries from GitHub Releases with [ghr](https://github.com/cataggar/ghr):

```console
$ ghr install cataggar/wabt
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
  oci        OCI WebAssembly artifacts — push, pull, copy, inspect, resolve, list-tags

Global:
  version    Print the wabt version and exit
  help       Print this help; `wabt help <subject>` for details
```

Run `wabt help <subject>` for the verbs in that subject.

## OCI artifacts

WABT can push, resolve, inspect, pull, copy, and list tags for validated
WebAssembly artifacts in OCI registries and image layouts.

The default Wasm-v0 profile is qualified with pinned `wkg`/oci-wasm producers:

```console
$ wabt oci push registry.example/team/echo:v1 component.wasm \
    --format wasm-v0 --created 2026-09-19T14:44:44Z
$ wabt oci pull registry.example/team/echo@sha256:... \
    -o downloaded-component.wasm
```

The explicit generic profile is ORAS-compatible and intentionally not
automatically wkg-compatible:

```console
$ wabt oci push registry.example/team/echo:generic component.wasm \
    --format oci --created 2026-09-19T14:44:44Z
```

See the [OCI user guide](docs/oci.md) and
[authentication policy](docs/oci-authentication.md). OCI commands preserve and
verify transport bytes; WABT does not execute downloaded WebAssembly. ORAS,
wkg, registries, and runtimes used for qualification are external test tools,
not runtime dependencies, and successful transport is not runtime,
signature-verification, or production-readiness evidence.

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

WABT is licensed under [Apache 2.0](LICENSE). See
[Third-Party Notices](THIRD_PARTY_NOTICES.md) for licenses and provenance of
adapted code.
