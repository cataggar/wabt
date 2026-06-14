# wasip2

Hand-written Zig **guest** bindings for the WASI Preview 2 (and bundled
proposal) packages that [`cataggar/wabt`](https://github.com/cataggar/wabt)
embeds, plus runnable Component-Model examples.

Each `wasi:*` interface is exposed as a thin, typed Zig wrapper over
canonical-ABI `extern` host imports — no `wit-bindgen`. A guest links these
for `wasm32-freestanding`, then `wabt component new` wraps the core module
into a component (auto-embedding the WIT and the wasi-preview1 adapter).

## Layout

```
src/
  abi.zig            shared canonical-ABI infra (cabi_realloc, ret-area)
  wasi_io.zig        wasi:io@0.2.6 (error, poll, streams) — foundational
  wasi_cli.zig       wasi:cli@0.2.6
  wasi_http.zig      wasi:http@0.2.6
  wasi_keyvalue.zig  wasi:keyvalue@0.2.0-draft
  ...                (more packages added per the roadmap)
examples/
  hello/             wasi:cli/run command that prints a greeting
```

`abi.zig` owns the single `cabi_realloc` export and the ret-area used to
receive results wider than one core value, so a guest may combine several
`wasi_*` modules without duplicate exports or competing scratch state.

## Coverage

| Module | Package | Status |
|---|---|---|
| `wasi_io` | `wasi:io@0.2.6` | streams (in/out), poll, error |
| `wasi_cli` | `wasi:cli@0.2.6` | seed (run/stdout/exit) |
| `wasi_clocks` | `wasi:clocks@0.2.6` | monotonic + wall clock |
| `wasi_random` | `wasi:random@0.2.6` | random, insecure, insecure-seed |
| `wasi_http` | `wasi:http@0.2.6` | seed (incoming-handler) |
| `wasi_keyvalue` | `wasi:keyvalue@0.2.0-draft` | seed |
| `wasi_filesystem` / `wasi_sockets` | `@0.2.6` | planned |
| `wasi_config` / `wasi_nn` / `wasi_tls` | proposals | planned |

Bindings are demand-driven: functions are added as examples need them.

## Prerequisites

- Zig `0.16.0`.
- The `wabt` CLI (cataggar/wabt) on `PATH` — provides `component new` and
  `module validate`.
- Optional: `wamr` and/or `wasmtime` to run the produced components.

## Build

```sh
zig build examples
```

Builds every example core (`zig build-exe -target wasm32-freestanding`),
wraps it with `wabt component new`, validates it, and installs the result
under `zig-out/examples/`.

The `wasi_*` modules are wasm-only (their `extern` host imports link solely
for `wasm32-freestanding`), so there is no native library artifact and no
native `zig build test`; `zig build examples` is the validation gate.
