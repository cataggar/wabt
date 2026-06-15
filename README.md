# wasip3

Hand-written Zig **guest** bindings for **WASI 0.3** (Component-Model
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
  abi.zig        shared canonical-ABI core (cabi_realloc, ret-area) — unchanged from 0.2
  cm_async.zig   WASI 0.3 async primitives contract (future/stream/error-context/waitable-set)
  wasi_cli.zig   wasi:cli@0.3.0 (async run + stdout via write-via-stream(stream<u8>))
  root.zig       `wasip3` re-export index
```

The other 0.2 modules (`wasi_clocks`/`random`/`filesystem`/`sockets`/`http` and
the proposals) were removed; they will be re-added as 0.3 bindings as the
generation work lands.

## Status

**Design-stage.** The bindings **type-check** and compile to a
`wasm32-freestanding` core module exporting `wasi:cli/run@0.3.0#run` with the
intrinsic imports above — i.e. the contract is concrete. They do **not** yet
wrap into a runnable component: that needs wabt's P3 generation to emit the
matching `canon` glue. The validation target is the local **wasmtime 46** build
(`-S p3 -W component-model-async -W component-model-error-context`).

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
