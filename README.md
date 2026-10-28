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
  module     Core wasm (.wasm) work — validate, objdump, strip, stats, decompile, shrink, optimize
  component  Component-model work — new, embed, compose
  spec       Spec testing (.wast) work — run, to-json
  oci        OCI WebAssembly artifacts — push, pull, copy, inspect, resolve, list-tags

Global:
  version    Print the wabt version and exit
  help       Print this help; `wabt help <subject>` for details
```

Run `wabt help <subject>` for the verbs in that subject.

## Module optimization

`wabt module optimize` runs a fixed, deterministic sequence of behavior-preserving optimization passes on a core WebAssembly module and validates both the input and output binaries:

```console
$ wabt module optimize input.wasm -o optimized.wasm
$ wabt module validate optimized.wasm
```

Passes execute in a fixed deterministic order (repeating intra-procedural passes to a bounded fixed point before dead-function removal):

1. **Constant folding** — folds `i32`/`i64` constant arithmetic, bitwise, shift/rotate, and comparison operations when trap-free (preserving division/remainder by zero and signed `INT_MIN / -1` overflow traps).
2. **Control-flow simplification** — removes `nop`, simplifies `if` and `br_if` with constant conditions, and eliminates trivial empty or unused `block` wrappers with branch-depth adjustment.
3. **Dead-code elimination** — removes unreachable instructions following unconditional control transfers (`unreachable`, `return`, `br`, `br_table`) up to the matching block boundary.
4. **Dead-function removal** — computes reachability from exports, `start`, globals, tables, and element segments, removes unreachable defined functions, and remaps all surviving function indices across the module.

Scope and safety policy:

- **Supported subset (fail-closed):** operates on validated core WebAssembly modules using standard MVP/sign-extension/bulk-memory/reference-type instructions and rejects unsupported proposals (SIMD, atomics/threads, GC, exception handling, tail calls, typed function references, multi-memory, memory64, custom page sizes, wide arithmetic) and Component Model binaries rather than emitting unverified code.
- **Custom sections:** rejected by default because code transformations and function index remapping invalidate custom section offsets and indices (`name`, DWARF, `producers`, etc.). Pass `--strip-custom` to discard custom sections explicitly before optimizing.
- **Distinct from `shrink` and Binaryen `wasm-opt`:** unlike `wabt module shrink` (which minimizes a binary against an external predicate and may alter semantics), `wabt module optimize` is strictly semantics-preserving. It does not expose `-O` / `-O2` / `-Os` flags or claim equivalence to Binaryen's optimization pipeline; for full whole-program Binaryen optimization passes, pair `wabt` with `wasm-opt` (`ghr install WebAssembly/binaryen`).

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

Requires [Zig](https://ziglang.org/) 0.17. No other dependencies.

```console
$ git clone --recursive https://github.com/cataggar/wabt
$ cd wabt
$ zig build
```

For release builds:

```console
$ zig build -Doptimize=safe
```

Cross-compilation works out of the box:

```console
$ zig build -Dtarget=aarch64-linux -Doptimize=safe
$ zig build -Dtarget=aarch64-macos -Doptimize=safe
$ zig build -Dtarget=x86_64-windows -Doptimize=safe
```

## License

WABT is licensed under [Apache 2.0](LICENSE). See
[Third-Party Notices](THIRD_PARTY_NOTICES.md) for licenses and provenance of
adapted code.
