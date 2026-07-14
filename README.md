# wasip3

Zig **guest** bindings for **WASI 0.3** (Component-Model
**async**). Sibling to the [`wasip2`](https://github.com/cataggar/wabt/tree/wasip2)
branch (from which this one is forked), retargeted to the 0.3 async ABI.

## What changed from 0.2

WASI 0.3 rebases WASI onto the Component Model's native async primitives:

- **No `wasi:io`.** `pollable` / `input-stream` / `output-stream` are gone;
  their roles are now the canonical-ABI types `future<T>` / `stream<T>` and
  the `async` lift/lower convention. These live in **`cm_async`** here, not a
  `wasi:io` wrapper.
- **`async func`.** Functions like `wasi:cli/run@0.3.0#run`
  (`async func() -> result`) are async; the guest reports results via
  `task.return`.
- **Streams as values.** Stdout is `wasi:cli/stdout@0.3.0.write-via-stream(data:
  stream<u8>) -> future<...>` — you create a `stream<u8>`, hand the readable end
  to the host, and write to the writable end.

## The guest ⇄ wrapper async ABI contract

`cm_async` declares the **async built-in intrinsics** the guest core imports;
the component wrapper (`wabt component new`, once it grows P3 generation —
[cataggar/wabt#263](https://github.com/cataggar/wabt/issues/263)) supplies them
via `canon` defs (`canon stream.write`, `canon task.return`, …). A compiled
`wasi:cli` guest imports exactly:

```
[stream]stream<u8>            { new, write, read, drop-readable, drop-writable }
[error-context]              { new, debug-message, drop }
[waitable-set] / [waitable]  { new, wait, drop, join }
[task-return]<export>        { task-return }
wasi:cli/stdout@0.3.0        { write-via-stream }
```

The import **module** names the built-in family + operand type (so the wrapper
picks the right component type index); the **field** is the bare op. This naming
is **provisional** — to be finalized with wabt's P3 generation and reconciled
with `wit-bindgen`'s convention for cross-toolchain interop.

## Layout

```
src/
  cm_async.zig         WASI 0.3 async primitives (future/stream/error-context/waitable-set/subtask)
  wasi_cli_bindings.zig  `wabt component bindgen`-generated wasi:cli@0.3.0 import client wrappers
  wasi_cli.zig         ergonomic wasi:cli@0.3.0 layer (run export, stdout/stderr/stdin, args/env, exit, terminal)
  wasi_clocks_bindings.zig  `wabt component bindgen`-generated wasi:clocks@0.3.0 import client wrappers
  wasi_clocks.zig      ergonomic wasi:clocks@0.3.0 layer (monotonic now/resolution/sleep, system now/resolution)
  wasi_random_bindings.zig  `wabt component bindgen`-generated wasi:random@0.3.0 import client wrappers
  wasi_random.zig      ergonomic wasi:random@0.3.0 layer (secure/insecure bytes + u64, insecure-seed)
  wasi_filesystem_bindings.zig  `wabt component bindgen`-generated wasi:filesystem@0.3.0 import client wrappers
  wasi_filesystem.zig  ergonomic wasi:filesystem@0.3.0 layer (preopens, open, read/writeAll via stream<u8>, stat/get-type)
  wasi_sockets_bindings.zig  `wabt component bindgen`-generated wasi:sockets@0.3.0 import client wrappers
  wasi_sockets.zig     ergonomic wasi:sockets@0.3.0 layer (TCP connect/send/recv + listen/accept, UDP connect/send/recv, ip-name-lookup resolveAddresses, address builders)
  wasi_http_bindings.zig  `wabt component bindgen`-generated wasi:http/types@0.3.0 import client wrappers
  wasi_http.zig        ergonomic wasi:http@0.3.0 service handler layer (handler + Request/Responder, over the generated body stream/trailers future)
  root.zig             `wasip3` re-export index
```

All of `wasi:cli` / `wasi:clocks` / `wasi:random` / `wasi:filesystem` / `wasi:sockets`
are now **generated** with `wabt component bindgen`
(see [cataggar/wabt#280](https://github.com/cataggar/wabt/issues/280)) + thin
ergonomic wrappers, the pattern `wasi_cli` established.

## Status

**Runnable.** P3 canonical-ABI generation in `wabt component new` landed
([#263](https://github.com/cataggar/wabt/issues/263)), and `component bindgen`
now generates the full client surface — including non-primitive `future`/`stream`
elements, async imports, and streaming exports
([#284](https://github.com/cataggar/wabt/issues/284) /
[#289](https://github.com/cataggar/wabt/issues/289)). The `wasi:cli@0.3.0`,
`wasi:clocks@0.3.0`, `wasi:random@0.3.0`, `wasi:filesystem@0.3.0`, and
`wasi:sockets@0.3.0` bindings here are **generated + wrapped**, build to a
`wasm32-freestanding` command, wrap via `wabt component new`, and **run on
wasmtime 46** end to end: `run` + stdout/stderr + `get-arguments`; monotonic/system
clocks incl. the async `wait-for`/`wait-until`; secure/insecure random +
insecure-seed; filesystem preopens + async `descriptor.stat`/`get-type` + `stream<u8>`
file read/write; `sockets` `ip-name-lookup.resolve-addresses`. Validate with
`-S p3 -W component-model-async -W component-model-async-stackful
-W component-model-more-async-builtins -W component-model-error-context` (filesystem
adds `--dir`, sockets adds `-S allow-ip-name-lookup`).

## Prerequisites

- Zig `0.16.0`.
- (Later, for end-to-end) a `wabt` with P3 generation, and wasmtime 46.

## Build

```sh
zig build test     # native + bindgen unit tests and semantic codegen checks
```

The `wasi_*` / `cm_async` wrappers are wasm-only (their `extern` host imports
link only for `wasm32-freestanding`), so they are type-checked by compiling a
guest, not by native tests.

`zig build test` is hermetic with respect to external CLI tools. The optional
component-wrapping integration check requires a separately installed
[`wasm-tools`](https://github.com/bytecodealliance/wasm-tools) on `PATH`:

```sh
zig build root-import-component-test
```
