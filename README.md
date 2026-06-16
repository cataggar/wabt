# wasip2

Zig **guest** bindings for the WASI Preview 2 (and bundled
proposal) packages that [`cataggar/wabt`](https://github.com/cataggar/wabt)
embeds.

Each `wasi:*` interface is exposed as a thin, typed Zig wrapper over
canonical-ABI `extern` host imports — no `wit-bindgen`. A guest links these
for `wasm32-freestanding`, then `wabt component new` wraps the core module
into a component (auto-embedding the WIT and the wasi-preview1 adapter).

## Layout

```
src/
  root.zig           `wasip2` index re-exporting every module
  abi.zig            shared canonical-ABI infra (cabi_realloc, ret-area)
  wasi_io.zig        wasi:io@0.2.6 (error, poll, streams) — foundational
  wasi_cli.zig       wasi:cli@0.2.6        wasi_clocks.zig   wasi:clocks@0.2.6
  wasi_random.zig    wasi:random@0.2.6     wasi_filesystem.zig  wasi:filesystem@0.2.6
  wasi_sockets.zig   wasi:sockets@0.2.6    wasi_config.zig   wasi:config@0.2.0-rc.1
  wasi_http.zig      wasi:http@0.2.6       wasi_keyvalue.zig wasi:keyvalue@0.2.0-draft
  wasi_nn.zig        wasi:nn@…             wasi_tls.zig      wasi:tls@0.2.0-draft
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
| `wasi_keyvalue` | `wasi:keyvalue@0.2.0-draft` | seed (bucket get/set/delete/exists) |
| `wasi_filesystem` | `wasi:filesystem@0.2.6` | preopens (get-directories) |
| `wasi_sockets` | `wasi:sockets@0.2.6` | ip-name-lookup (resolve) |
| `wasi_config` | `wasi:config@0.2.0-rc.1` | store (get / get-all) |
| `wasi_nn` | `wasi:nn@0.2.0-rc-2024-10-28` | tensor |
| `wasi_tls` | `wasi:tls@0.2.0-draft` | types (handshake handles) |

Every P2 package that wabt bundles now has a guest binding module.

## Prerequisites

- Zig `0.16.0`.
- The `wabt` CLI (cataggar/wabt) on `PATH` — provides `component new` and
  `module validate`.

## Test

```sh
zig build test
```

Runs native unit tests for the host-import-free canonical-ABI core in
`abi.zig` (the `cabi_realloc` bump arena, alignment, and ret-area decoders).

The `wasi_*` wrappers are wasm-only: their public functions call `extern`
host imports that resolve solely under `wasm32-freestanding`, so they have
no native artifact and can't be unit-tested natively.
