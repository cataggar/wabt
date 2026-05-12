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

## Status: full v3 preview1 surface wired

This directory ships:

  * **WAT source** (`src/adapter.wat`) — preview1 surface lowered
    through preview2:
    * `proc_exit` → `wasi:cli/exit.exit-with-code(u8)` (lossless,
      with `exit(result)` fallback for strict-0.2.0 hosts);
    * `fd_write`, `fd_pwrite`, `fd_read` →
      `wasi:filesystem/types.descriptor.{write,read}-via-stream` +
      `wasi:io/streams.[method]{output,input}-stream.blocking-…`;
    * `fd_close` → `[resource-drop]descriptor`;
    * `fd_seek` (user-fd) → adapter-tracked position update;
      stdio → `ESPIPE`;
    * `fd_sync` / `fd_datasync` → `descriptor.{sync, sync-data}`;
    * `fd_filestat_get` / `path_filestat_get` →
      `descriptor.{stat, stat-at}` projected into preview1's
      64-byte `filestat` layout;
    * `fd_filestat_set_size` → `descriptor.set-size`;
    * `fd_filestat_set_times` / `path_filestat_set_times` →
      `descriptor.{set-times, set-times-at}` with preview1
      fstflags bits translated into `new-timestamp` variants;
    * `fd_readdir` → `descriptor.read-directory` +
      `directory-entry-stream.read-directory-entry` packed into
      preview1 `dirent` records;
    * `fd_prestat_get` / `fd_prestat_dir_name` →
      `wasi:filesystem/preopens.get-directories`;
    * `path_open` → `descriptor.open-at`;
    * `path_create_directory`, `path_remove_directory`,
      `path_unlink_file`, `path_symlink`, `path_rename`,
      `path_link` → matching `descriptor.*-at` mutations;
    * `args_get` / `args_sizes_get` / `environ_get` /
      `environ_sizes_get` → `wasi:cli/environment.{get-arguments,
      get-environment}`;
    * `clock_time_get` / `clock_res_get` →
      `wasi:clocks/{wall-clock, monotonic-clock}`;
    * `random_get` → `wasi:random/random.get-random-bytes`;
    * `sched_yield` → trivial success;
    * `proc_raise`, `fd_fdstat_set_flags`, `sock_*` → `ENOSYS=52`
      (no preview2 equivalent in 0.2.6 / deferred to
      cataggar/wabt#168).
  * **WIT world** (`wit/preview1.wit` + `wit/deps/{wasi-cli,
    wasi-clocks, wasi-filesystem, wasi-io, wasi-random}/`) —
    declares the full preview2 surface the adapter consumes.
    Import order matters: any iface whose body has `use other.{T}`
    must follow `other`; the encoder builds `world_alias_map`
    import-by-import.
  * **`zig build adapter`** — runs `tools/build_adapter.zig` to
    parse the WAT, validate it, encode the WIT world via wabt's
    `metadata_encode.encodeWorldFromResolver`, attach the
    `component-type:wabt:wasi-preview1@0.0.0:command:encoded world`
    custom section, and self-check the result through the
    splicer's `adapter/decode.parseFromAdapterCore`. Output:
    `zig-out/adapter/wasi_snapshot_preview1.command.wasm`. The
    artifact is also `@embedFile`d into the `wabt` CLI binary as
    the default `--adapt` source for `wabt component new`.

The `proc_exit` lowering remains the one deliberate divergence
from the wasmtime reference adapter: `proc_exit(code)` traps with
the original numeric `code` end-to-end via
`wasi:cli/exit.exit-with-code(u8)` rather than collapsing to
host-exit-code 1 through `wasi:cli/exit.exit(result<_, _>)`.

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
    * `wasi:cli/exit@0.2.6.exit-with-code` — replaces the lossy
      `exit(result)` that the wasmtime adapter routes through.
      The full preview2 import list (`wasi:cli/{exit, stdout,
      stderr, environment}@0.2.6`, `wasi:io/{streams, error}@0.2.6`,
      `wasi:clocks/{wall-clock, monotonic-clock}@0.2.6`,
      `wasi:random/random@0.2.6`,
      `wasi:filesystem/{preopens, types}@0.2.6`) is enumerated in
      the `import` block of `src/adapter.wat` and surfaced in the
      encoded WIT world.

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
    * preview1 surface (full v3 cut, per [#165 + #166][issue]):
        `proc_exit`, `proc_raise`, `sched_yield`,
        `fd_write`, `fd_pwrite`, `fd_read`,
        `fd_close`, `fd_seek`, `fd_sync`, `fd_datasync`,
        `fd_fdstat_get`, `fd_fdstat_set_flags`,
        `fd_filestat_get`, `fd_filestat_set_size`,
        `fd_filestat_set_times`,
        `fd_prestat_get`, `fd_prestat_dir_name`, `fd_readdir`,
        `path_open`, `path_create_directory`,
        `path_remove_directory`, `path_unlink_file`,
        `path_symlink`, `path_rename`, `path_link`,
        `path_filestat_get`, `path_filestat_set_times`,
        `args_get`, `args_sizes_get`,
        `environ_get`, `environ_sizes_get`,
        `clock_time_get`, `clock_res_get`,
        `random_get`,
        `sock_accept`, `sock_recv`, `sock_send`, `sock_shutdown`
        (sockets are inline `ENOSYS=52` stubs; the preview2
        `wasi:sockets/*` lift is deferred to cataggar/wabt#168).
        wabt's adapter-core-wasm GC pass
        ([`src/component/adapter/gc.zig`](../../src/component/adapter/gc.zig))
        drops any unused exports at splice time.

* **`component-type:…:command:encoded world` custom section**:
  produced by `tools/build_adapter.zig` invoking
  [`metadata_encode.encodeWorldFromResolver`](../../src/component/wit/metadata_encode.zig)
  on `wit/preview1.wit` + `wit/deps/wasi-cli/world.wit`. The splicer
  decodes this in
  [`src/component/adapter/decode.zig`](../../src/component/adapter/decode.zig)
  to drive `types-import.hoist`. Section name used here:
  `component-type:wabt:wasi-preview1@0.0.0:command:encoded world`
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
preview2 types (`list<u8>`, `result<_, e>`, `option<datetime>`,
`new-timestamp` variant, resource handles) has to be hand-coded in
WAT. The adapter's helper bank covers the recurring patterns:
`$descriptor_error_only_result` decodes the 8-byte
`result<_, error-code>` ret-area; `$build_new_timestamp` projects
preview1 fstflags into a flat-ABI `new-timestamp` variant;
`$write_preview1_filestat` projects a 96-byte `descriptor-stat`
record (with three `option<datetime>` slots) into preview1's
64-byte `filestat` layout.

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
