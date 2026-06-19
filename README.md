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
  abi.zig              shared canonical-ABI core (cabi_realloc, ret-area)
  canon.zig            comptime canonical-ABI value marshaller (records/strings/options/lists/variants/futures/streams)
  cm_async.zig         WASI 0.3 async primitives (future/stream/error-context/waitable-set/subtask)
  wasi_cli_bindings.zig  `wabt component bindgen`-generated wasi:cli@0.3.0 import client wrappers
  wasi_cli.zig         ergonomic wasi:cli@0.3.0 layer (run export, stdout/stderr/stdin, args/env, exit, terminal)
  wasi_clocks_bindings.zig  `wabt component bindgen`-generated wasi:clocks@0.3.0 import client wrappers
  wasi_clocks.zig      ergonomic wasi:clocks@0.3.0 layer (monotonic now/resolution/sleep, system now/resolution)
  wasi_random_bindings.zig  `wabt component bindgen`-generated wasi:random@0.3.0 import client wrappers
  wasi_random.zig      ergonomic wasi:random@0.3.0 layer (secure/insecure bytes + u64, insecure-seed)
  wasi_http.zig        wasi:http@0.3.0 service handler helper
  root.zig             `wasip3` re-export index
```

The remaining 0.2 interfaces (`filesystem`/`sockets`) are being re-added as 0.3
bindings by **generating** them with `wabt component bindgen`
(see [cataggar/wabt#280](https://github.com/cataggar/wabt/issues/280)) + thin
ergonomic wrappers, the pattern `wasi_cli` / `wasi_clocks` / `wasi_random` use.

## Status

**Runnable.** P3 canonical-ABI generation in `wabt component new` landed
([#263](https://github.com/cataggar/wabt/issues/263)), and `component bindgen`
now generates the full client surface — including non-primitive `future`/`stream`
elements, async imports, and streaming exports
([#284](https://github.com/cataggar/wabt/issues/284) /
[#289](https://github.com/cataggar/wabt/issues/289)). The `wasi:cli@0.3.0`,
`wasi:clocks@0.3.0`, and `wasi:random@0.3.0` bindings here are
**generated + wrapped**, build to a `wasm32-freestanding` command, wrap via
`wabt component new`, and **run on wasmtime 46** end to end (`run` +
stdout/stderr + `get-arguments`, monotonic/system clocks incl. the async
`wait-for`/`wait-until`, secure/insecure random + insecure-seed). Validate with
`-S p3 -W component-model-async -W component-model-async-stackful
-W component-model-more-async-builtins -W component-model-error-context`.

## Prerequisites

- Zig `0.16.0`.
- (Later, for end-to-end) a `wabt` with P3 generation, and wasmtime 46.

## Build

```sh
zig build test     # native unit tests for abi.zig (cabi_realloc + ret-area)
```

The `wasi_*` / `cm_async` wrappers are wasm-only (their `extern` host imports
link only for `wasm32-freestanding`), so they are type-checked by compiling a
guest, not by native tests.
