# `wasi:cli@0.2.x` preview1 → preview2 adapter

A wabt-native, Zig-authored replacement for the
[wasmtime `wasi_snapshot_preview1.command.wasm` adapter][wm-adapter].
Built as part of `zig build adapter`, embedded as `@embedFile` into
the `wabt` CLI, and used as the default `--adapt` source for
`wabt component new` when the embed declares preview1 imports.

[wm-adapter]: https://github.com/bytecodealliance/wasmtime/blob/main/crates/wasi-preview1-component-adapter/README.md

Tracks [cataggar/wamr#453][issue]. The motivation (drop the lossy
`wasi:cli/exit.exit(result)` round-trip, drop the
`exit_code_sink` workaround, ship a reviewable in-tree adapter)
is documented in that issue.

[issue]: https://github.com/cataggar/wamr/issues/453

## Status: in-progress, not yet wired into `wabt component new`

This directory ships the **scaffolding** for the adapter — a WAT
source with the correct import / export shape and stubbed function
bodies, plus a Zig build tool that drives the wabt library to parse
and emit the artifact. Subsequent commits fill in:

  1. the `wit/preview1.wit` world declaration and a
     `metadata_encode.encodeWorldFromSource` call from
     `tools/build_adapter.zig` that appends the
     `component-type:…:command:encoded world` custom section to the
     emitted wasm (today the artifact is *shape only* — it parses,
     validates and has the right imports/exports, but the splicer
     in `src/component/adapter/decode.zig` rejects it with
     `MissingEncodedWorld` because the world section is absent;
     gated on `metadata_encode.zig` gaining support for resource
     handles — the real `wasi:io/streams` interface uses
     `[method]output-stream.blocking-write-and-flush(borrow<…>,
     …)`),
  2. real preview1 → preview2 semantics in `src/adapter.wat`
     replacing the current ENOSYS stubs (`fd_write` iterates the
     iovec list and calls `output-stream.blocking-write-and-flush`,
     `args_get` lowers `wasi:cli/environment.get-arguments`, etc.),
  3. embedding the artifact into the wabt CLI via `@embedFile` and
     wiring it as the default `--adapt` source in
     `src/tools/component_new.zig` when the embed declares
     preview1 imports and `--adapt` is not passed.

The `proc_exit` lowering is the one piece that's fully wired
end-to-end already, because it's just a single canon-lower of `u8`
through `wasi:cli/exit.exit-with-code` — see the body of `$proc_exit`
in `src/adapter.wat`. That's the key win over the wasmtime
adapter, which routes through the lossy `exit(result<_,_>)` and
collapses every non-zero `proc_exit(code)` to host exit code 1.

## Layout

```
adapters/wasi-preview1/
├── README.md            (this file)
├── src/
│   └── adapter.wat      WAT source — imports preview2, exports preview1
├── wit/
│   └── preview1.wit     `world preview1-command`: imports the
│                        preview2 instances we use, exports
│                        `wasi:cli/run`
└── tools/
    └── build_adapter.zig
                         small Zig program invoked from build.zig
                         to: parse WAT → wasm bytes, encode WIT
                         world → encoded-world bytes, append the
                         encoded-world as a `component-type:…`
                         custom section, write the final
                         `wasi_snapshot_preview1.command.wasm`.
```

## Adapter shape (command shape, per `detectShape` at
[`src/component/adapter/adapter.zig:828`](../../src/component/adapter/adapter.zig))

* **Core wasm imports** (matched against the embed at splice time):
    * `env.memory` — the embed's linear memory; the adapter reads
      iovec lists and writes errno return values into it.
    * `__main_module__._start` — invoked from the adapter's
      `wasi:cli/run.run` body.
    * `__main_module__.cabi_realloc` (best-effort) — used for any
      canon-lift'd preview2 return values that need a return area in
      embed memory. Absent embeds get a `buildMainModuleFallback`
      stub from the splicer.
    * One preview2 instance import per WASI namespace the adapter
      lowers into. Initial scope:
        * `wasi:cli/exit@0.2.6.exit-with-code` — replaces the lossy
          `exit(result)` that the wasmtime adapter routes through.
        * `wasi:cli/stdout@0.2.6.get-stdout`,
          `wasi:cli/stderr@0.2.6.get-stderr`,
          `wasi:cli/stdin@0.2.6.get-stdin`.
        * `wasi:io/streams@0.2.6.[method]output-stream.blocking-
          write-and-flush`,
          `[method]output-stream.blocking-flush`,
          `[method]input-stream.blocking-read`,
          `[resource-drop]output-stream`,
          `[resource-drop]input-stream`.
        * `wasi:cli/environment@0.2.6.get-arguments`,
          `get-environment`.
        * `wasi:clocks/wall-clock@0.2.6.now`,
          `wasi:clocks/monotonic-clock@0.2.6.now`.
        * `wasi:random/random@0.2.6.get-random-bytes`.

* **Core wasm exports** (flat names, no
  `wasi_snapshot_preview1.` prefix — the splicer maps them to
  whatever adapter `name` the user specified):
    * `wasi:cli/run@0.2.6#run` — `(func (result i32))`. Calls
      `__main_module__._start` then returns `0` (ok). On
      `proc_exit(code)` the trap unwinds out of `_start`; the
      wrapping `wasi:cli/exit.exit-with-code` host call has already
      landed the code at this point.
    * `cabi_import_realloc` — `(func (param i32 i32 i32 i32)
      (result i32))`. Canon-lower realloc helper. For the initial
      scope we either delegate to `__main_module__.cabi_realloc`
      or trap (none of our supported preview1 imports actually
      route a list / string back through realloc — `fd_write` etc.
      pass `(ptr, len)` slices directly out of embed memory).
    * preview1 surface (initial cut, per [#453][issue] scope cut):
        `proc_exit`, `proc_raise`, `sched_yield`,
        `fd_write`, `fd_read`, `fd_close`, `fd_seek`,
        `fd_fdstat_get`, `fd_fdstat_set_flags`,
        `fd_prestat_get`, `fd_prestat_dir_name`,
        `args_get`, `args_sizes_get`,
        `environ_get`, `environ_sizes_get`,
        `clock_time_get`, `clock_res_get`,
        `random_get`.
        All other preview1 imports trap with `errno=ENOSYS`. wabt's
        adapter-core-wasm GC pass
        ([`src/component/adapter/gc.zig`](../../src/component/adapter/gc.zig))
        drops the unused ones at splice time.

* **`component-type:…:command:encoded world` custom section**:
  produced by `wabt component embed` (or directly by
  [`metadata_encode.encodeWorldFromSource`](../../src/component/wit/metadata_encode.zig))
  from `wit/preview1.wit`. The splicer decodes this in
  [`src/component/adapter/decode.zig`](../../src/component/adapter/decode.zig)
  to drive `types-import.hoist`. Section name format used here:
  `component-type:wabt:0.0.0:wasi:cli@0.2.6:command:encoded world`
  (any `component-type:*` prefix is accepted by `decode.zig`).

## Why hand-authored WAT instead of compiled Zig?

The wasmtime adapter is Rust-source compiled through `wit-bindgen`,
which generates ~190 KiB of canon-lower binding glue per release.
We have no Zig-side `wit-bindgen` equivalent. Hand-authored WAT
keeps the adapter:

* **Small** — only the preview1 surface we actually need, no
  long-tail of unused wit-bindgen scaffolding.
* **Reviewable** — every byte of the adapter is in this directory
  in source-readable form; updates land via normal PRs against the
  WAT and WIT files.
* **Pinned to wabt's existing infrastructure** — the build pipeline
  is just `wabt.text.Parser.parseModule` + `metadata_encode.encodeWorldFromSource`
  + custom-section append. No new dependency.

The downside is that the canonical-ABI lowering of compound
preview2 types (`list<u8>`, `result<_, e>`, resource handles) has
to be hand-coded in WAT. That's tractable for our initial scope —
the preview2 calls we make either take primitive `(handle, ptr,
len)` triples (`blocking-write-and-flush`) or single `u8` /
`u64` scalars (`exit-with-code`, `clock.now`); none require
canon-lower'd realloc.

## Building locally

```console
$ zig build adapter
$ ls zig-out/adapter/
wasi_snapshot_preview1.command.wasm
```

The artifact is also embedded into the `wabt` CLI binary so that
`wabt component new` uses it by default when the embed declares
`wasi_snapshot_preview1.*` imports and `--adapt` is not passed.
Override the builtin with `--adapt
wasi_snapshot_preview1=<file.wasm>` (existing flag, unchanged).
