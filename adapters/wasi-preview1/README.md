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

  * **WAT source** (`src/fragments/`, concatenated by
    `tools/build_adapter.zig`) — preview1 surface lowered
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
    * `fd_fdstat_get` → stdio probes
      `wasi:cli/terminal-{stdin,stdout,stderr}.get-terminal-<n>`
      (cached per-fd) to report `CHARACTER_DEVICE` for tty stdio
      vs `UNKNOWN` for redirected stdio; user-fd branch lifts
      `descriptor.{get-type, get-flags}` and synthesises
      `fs_rights_*` from the resolved preview1 filetype
      (cataggar/wabt#179);
    * `random_get` → `wasi:random/random.get-random-bytes`;
    * `sched_yield` → trivial success;
    * `proc_raise` → `ENOSYS=52` (advisory; no preview2 equivalent);
    * `fd_fdstat_set_flags` → `ENOSYS=52` permanently: preview2
      0.2.6 has no descriptor-flags mutator and re-opening would
      lose fd identity (cataggar/wabt#179, closed);
    * `sock_*` → `ENOSYS=52` permanently: preview1 v3 has no
      socket-creation primitives so the lift would be moot
      (cataggar/wabt#178, closed as won't-implement).
  * **WIT world** (`wit/preview1.wit` + `wit/deps/{wasi-cli,
    wasi-clocks, wasi-filesystem, wasi-io, wasi-random}/`) —
    declares the full preview2 surface the adapter consumes.
    Import order matters: any iface whose body has `use other.{T}`
    must follow `other`; the encoder builds `world_alias_map`
    import-by-import.

    The same `wit/preview1.wit` file also declares `world reactor`
    — same preview2 import list as `command`, but with no
    `export wasi:cli/run@0.2.6;` decl. See "Reactor variant" below.
  * **`zig build adapter`** — builds **both** shapes
    (`wasi_snapshot_preview1.{command,reactor}.wasm`).
    `tools/build_adapter.zig` concatenates the per-shape WAT
    fragments from `src/fragments/` (single source of truth for
    the preview1→preview2 lowering bodies — see
    `src/fragments/README.md` for the cut rationale), parses +
    validates the result, encodes the named WIT world via
    `metadata_encode.encodeWorldFromResolver`, attaches the
    `component-type:wabt:wasi-preview1@0.0.0:<world>:encoded world`
    custom section, and self-checks via the splicer's
    `adapter/decode.parseFromAdapterCore`. Outputs land under
    `zig-out/adapter/`. Both artifacts are also `@embedFile`d
    into the `wabt` CLI binary; `wabt component new` auto-picks
    between them based on whether the embed core exports
    `_start` (see `src/tools/component_new.zig:pickBuiltinAdapter`).
    Per-shape steps `zig build adapter-command` /
    `zig build adapter-reactor` build a single variant.

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
│   └── fragments/       Per-shape and shared WAT fragments;
│                        concatenated by `tools/build_adapter.zig`
│                        into the command-shape and reactor-shape
│                        artifacts. See `fragments/README.md` for
│                        the concatenation order and the cut
│                        points.
├── wit/
│   └── preview1.wit     Declares `world command` (exports
│                        `wasi:cli/run`) AND `world reactor`
│                        (same imports, no `wasi:cli/run` export).
│                        Both worlds share the trimmed
│                        `wit/deps/{wasi-cli, wasi-clocks,
│                        wasi-filesystem, wasi-io, wasi-random}/`
│                        slices that declare the preview2 surface.
└── tools/
    └── build_adapter.zig
                         Small Zig program invoked from `build.zig`
                         to: concatenate the per-shape WAT
                         fragments → parse → wasm bytes; encode
                         the named WIT world → encoded-world
                         bytes; append the encoded-world as a
                         `component-type:…` custom section; write
                         the final
                         `wasi_snapshot_preview1.<shape>.wasm`.
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
      the shared body fragment (`src/fragments/body.wat`) and
      surfaced in the encoded WIT world.

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
        `wasi:sockets/*` lift is deferred to cataggar/wabt#178).
        wabt's adapter-core-wasm GC pass
        ([`src/component/adapter/gc.zig`](../../src/component/adapter/gc.zig))
        drops any unused exports at splice time.

* **`component-type:…:<world>:encoded world` custom section**:
  produced by `tools/build_adapter.zig` invoking
  [`metadata_encode.encodeWorldFromResolver`](../../src/component/wit/metadata_encode.zig)
  on `wit/preview1.wit` (`world command` or `world reactor`) +
  `wit/deps/wasi-cli/world.wit`. The splicer decodes this in
  [`src/component/adapter/decode.zig`](../../src/component/adapter/decode.zig)
  to drive `types-import.hoist`. Section name used here:
  `component-type:wabt:wasi-preview1@0.0.0:<world>:encoded world`
  (any `component-type:*` prefix is accepted by `decode.zig`).

## Reactor variant

A reactor-shape variant of the adapter ships alongside the
command-shape artifact, tracked under
[cataggar/wabt#167](https://github.com/cataggar/wabt/issues/167).
Both artifacts are built by `zig build adapter` and embedded into
the `wabt` CLI binary; `wabt component new` picks the right one
automatically.

Differences from the command shape:

* **No `wasi:cli/run@0.2.6#run` export**. The wrapping component
  lifts the embed's own exports (e.g.
  `wasi:http/incoming-handler.handle`) directly instead of
  routing through a `run` entry. The reactor adapter is a
  passive preview1 → preview2 bridge with no entry point of its
  own.
* **No `__main_module__.*` imports**. The splicer's reactor
  branch (`src/component/adapter/adapter.zig:1226`) explicitly
  rejects any such import for reactor shape. The shared body
  still references `$main_start` / `$main_cabi_realloc` — both
  are supplied as **trap-stub local funcs** by
  `src/fragments/reactor-impl.wat` so the body parses without
  dangling references and links into a valid wasm binary.
* **`world reactor` instead of `world command`** in the encoded
  WIT custom section — same preview2 import surface, no
  `wasi:cli/run` export decl. Lives in the same
  `wit/preview1.wit` file as the command world.

### Auto-selection rule

`wabt component new` (in `src/tools/component_new.zig`) inspects
the embed core wasm's exports via
`core_imports.extract(...).interface.findExport("_start")`:

* `_start` exported as a function ⇒ pick
  `wasi_preview1_command_wasm` (command-shape adapter; `$run`
  calls `__main_module__._start`).
* `_start` absent (cleanly-parsing core) ⇒ pick
  `wasi_preview1_reactor_wasm` (reactor-shape adapter; the
  wrapping component lifts the embed's own exports directly).
* Malformed core ⇒ fall back to the command-shape adapter for
  backwards compatibility with the pre-#167 default.

`--adapt wasi_snapshot_preview1=<file>` and
`--no-builtin-adapter` continue to override this auto-selection
exactly as before.

### Functional caveat (deferred)

Until a real reactor fixture motivates the design, the reactor
adapter has **no source of preview2 scratch memory**: the shared
`$ensure_ret_area` helper calls `$main_cabi_realloc`, which the
reactor variant defines as a trap-stub. Every preview1 entry that
materialises a result through the ret-area scratch page
(essentially every `fd_*`, `path_*`, `clock_*`, `args_*`,
`environ_*`) traps deterministically inside `$ensure_ret_area`.

Composing a reactor embed that never calls a preview1 import from
its lifted entry points still works (no preview1 call ⇒ no ret-
area allocation ⇒ no trap). Real validation requires a
`wasi:http/incoming-handler` fixture (or equivalent) — see
[cataggar/wamr#453][issue]'s "Reactor-shape adapter — deferred"
open question.

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
wasi_snapshot_preview1.reactor.wasm
```

Per-shape build steps:

```console
$ zig build adapter-command    # only the command-shape artifact
$ zig build adapter-reactor    # only the reactor-shape artifact
```

Both artifacts are also embedded into the `wabt` CLI binary so
that `wabt component new` uses them by default when the embed
declares `wasi_snapshot_preview1.*` imports and `--adapt` is not
passed.  `wabt component new` picks command vs reactor based on
whether the embed core exports `_start` (see "Reactor variant"
above). Override the builtin with `--adapt
wasi_snapshot_preview1=<file.wasm>` (existing flag, unchanged) or
disable the auto-attach entirely with `--no-builtin-adapter`.
