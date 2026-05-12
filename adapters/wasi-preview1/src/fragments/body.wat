  ;; preview2 instance imports actually consumed by the v1 adapter.
  ;;
  ;; `wasi:cli/exit@0.2.6.exit-with-code(u8)` is the lossless,
  ;; `@unstable(feature = cli-exit-with-code)` extension that
  ;; preserves the numeric proc_exit code end-to-end. Wamr today
  ;; implements it on its host side (see
  ;; `cataggar/wamr:src/component/wasi_cli_adapter.zig:cliExitWithCode`).
  ;; Wasmtime v44 also implements it but gates the linker binding
  ;; behind `-S cli-exit-with-code` (off by default).
  ;;
  ;; `wasi:cli/exit@0.2.6.exit(result<_, _>)` is the stable
  ;; `@since(version = 0.2.0)` form that every runtime targeting
  ;; the wasi-cli interface supplies. It collapses any non-zero
  ;; numeric code to a single error bit. The adapter routes
  ;; through here as a fallback inside `$proc_exit` when
  ;; `exit-with-code` returns (which it won't on a host that
  ;; honored the canon contract); the import itself is mostly
  ;; defensive for any strict-0.2.0 host that wires only `exit`.
  ;;
  ;; Both imports declared together mirrors the canonical
  ;; wasi-cli@0.2.6 interface body — the encoded component-type
  ;; surface stays identical to wit-component's reference output.
  (import "wasi:cli/exit@0.2.6" "exit"
    (func $exit (type $i32_void)))
  (import "wasi:cli/exit@0.2.6" "exit-with-code"
    (func $exit_with_code (type $i32_void)))

  ;; Owned-handle factories for stdout / stderr. Each call yields a
  ;; fresh `own<output-stream>` we *should* drop on teardown — in
  ;; practice we cache one per process (Phase 1.c.3c) and let the
  ;; instance teardown reclaim the table slot.
  (import "wasi:cli/stdout@0.2.6" "get-stdout"
    (func $get_stdout (type $get_stream_sig)))
  (import "wasi:cli/stderr@0.2.6" "get-stderr"
    (func $get_stderr (type $get_stream_sig)))

  ;; The single hot-path output-stream method we'll lower against
  ;; in fd_write. `blocking-` is the right choice for the preview1
  ;; `fd_write` contract (caller expects all bytes drained or a
  ;; non-zero errno).
  (import "wasi:io/streams@0.2.6" "[method]output-stream.blocking-write-and-flush"
    (func $blocking_write_and_flush (type $blocking_write_sig)))

  ;; `[resource-drop]output-stream` — the splicer detects this
  ;; import name and synthesizes the canon `resource.drop` call
  ;; for us (see `src/component/adapter/adapter.zig:706`). Even
  ;; though we never call it directly today (cached handles are
  ;; not dropped), declaring it now keeps the resource-handle
  ;; type surface symmetrical and exercises the encoder's
  ;; `[resource-drop]` import path.
  (import "wasi:io/streams@0.2.6" "[resource-drop]output-stream"
    (func $output_stream_drop (type $i32_void)))

  ;; `wasi:random/random.get-random-bytes(len: u64) -> list<u8>`
  ;;   canon-lower'd to `(func (param i64 i32))` — params are
  ;;   `(len, ret_area_ptr)`. After the call the host has written
  ;;   `(buf_ptr: i32, buf_len: i32)` at `ret_area_ptr`, with
  ;;   `buf_ptr` pointing at the backing buffer the host allocated
  ;;   via our `cabi_import_realloc`. `$random_get` installs a
  ;;   one-shot override so that backing buffer is the caller's
  ;;   preview1 `buf` — zero copy.
  (import "wasi:random/random@0.2.6" "get-random-bytes"
    (func $get_random_bytes (type $get_random_bytes_sig)))

  ;; `wasi:clocks/wall-clock.{now, resolution}() -> datetime` backing
  ;; the preview1 `clock_time_get(REALTIME, …)` /
  ;; `clock_res_get(REALTIME, …)` paths. Each call writes a
  ;; `datetime` record (16 bytes) into the ret_area; the adapter
  ;; then collapses `seconds * 1e9 + nanoseconds` into a u64 ns
  ;; value via `$datetime_to_ns` and stores it at the caller's
  ;; `time_ptr` / `res_ptr`.
  (import "wasi:clocks/wall-clock@0.2.6" "now"
    (func $wall_now (type $wall_clock_sig)))
  (import "wasi:clocks/wall-clock@0.2.6" "resolution"
    (func $wall_resolution (type $wall_clock_sig)))

  ;; `wasi:clocks/monotonic-clock.{now, resolution}() -> u64` backing
  ;; the preview1 `clock_time_get(MONOTONIC, …)` /
  ;; `clock_res_get(MONOTONIC, …)` paths. Returns a u64 nanosecond
  ;; count directly, so the adapter just stores it at the caller's
  ;; output pointer — no ret_area, no conversion.
  (import "wasi:clocks/monotonic-clock@0.2.6" "now"
    (func $monotonic_now (type $monotonic_clock_sig)))
  (import "wasi:clocks/monotonic-clock@0.2.6" "resolution"
    (func $monotonic_resolution (type $monotonic_clock_sig)))

  ;; `wasi:cli/environment.get-arguments() -> list<string>` and
  ;;   `get-environment() -> list<tuple<string,string>>` backing the
  ;;   preview1 `args_*` / `environ_*` quartet. Both return a list
  ;;   that exceeds max-flat-results=1, so the lowered shape is
  ;;   `(func (param i32))` — the i32 is a caller-provided ret_area
  ;;   pointer where the host writes `(list_ptr, list_len)`. The
  ;;   list backing + each string are each separate
  ;;   `cabi_import_realloc` invocations; the adapter routes them
  ;;   through a `count` / `separate` state machine so the host
  ;;   writes strings directly into the caller's preview1 buffer.
  (import "wasi:cli/environment@0.2.6" "get-arguments"
    (func $get_arguments (type $get_arguments_sig)))
  (import "wasi:cli/environment@0.2.6" "get-environment"
    (func $get_environment (type $get_environment_sig)))

  ;; `wasi:filesystem/preopens.get-directories() ->
  ;; list<tuple<descriptor, string>>` backing the preview1
  ;; `fd_prestat_get` / `fd_prestat_dir_name` imports. Lifted on
  ;; each preview1 call via mode 2 (count) of the import-alloc
  ;; state machine — the canon list backing + each name lands in
  ;; the bump arena and gets reset after the call.
  (import "wasi:filesystem/preopens@0.2.6" "get-directories"
    (func $get_directories (type $get_directories_sig)))

  ;; `wasi:filesystem/types.[method]descriptor.open-at` backing the
  ;; preview1 `path_open` import. Returns a new
  ;; `own<descriptor>` via the ret_area; the adapter allocates a
  ;; preview1 fd slot for the handle in `$descriptor_table`.
  (import "wasi:filesystem/types@0.2.6"
    "[method]descriptor.open-at"
    (func $descriptor_open_at (type $descriptor_open_at_sig)))

  ;; `[resource-drop]descriptor` — the splicer detects this import
  ;; name and synthesises the canon `resource.drop` call (see
  ;; `src/component/adapter/adapter.zig:706`). Invoked by
  ;; `$fd_close` for user-opened fds; preopens and stdio fds are
  ;; never dropped (their resource ownership lives with the host).
  (import "wasi:filesystem/types@0.2.6"
    "[resource-drop]descriptor"
    (func $descriptor_drop (type $i32_void)))

  ;; `wasi:filesystem/types.[method]descriptor.read-via-stream`
  ;; backing the preview1 `fd_read` import for regular files.
  ;; Returns an `own<input-stream>` reading from the requested
  ;; byte offset; the adapter drops the stream at the end of each
  ;; `fd_read` call and advances its per-fd position by the bytes
  ;; consumed.
  (import "wasi:filesystem/types@0.2.6"
    "[method]descriptor.read-via-stream"
    (func $descriptor_read_via_stream (type $read_via_stream_sig)))

  ;; `[method]descriptor.write-via-stream(self, offset: u64) ->
  ;; result<own<output-stream>, error-code>` backing preview1
  ;; `fd_write` (fd ≥ 3) and `fd_pwrite`. Same flat shape as
  ;; `read-via-stream`; the adapter opens one stream per call,
  ;; iterates iovecs through `output-stream.blocking-write-and-flush`,
  ;; drops the stream, and (for `fd_write` only) advances the
  ;; per-fd tracked position.
  (import "wasi:filesystem/types@0.2.6"
    "[method]descriptor.write-via-stream"
    (func $descriptor_write_via_stream (type $read_via_stream_sig)))

  ;; `[method]descriptor.append-via-stream(self) ->
  ;; result<own<output-stream>, error-code>`. Declared for completeness
  ;; (the encoded WIT world advertises it) but the current adapter
  ;; routes all writes through `write-via-stream`; preview1
  ;; `FDFLAGS_APPEND` semantics are deferred — wasi-libc emulates
  ;; them by tracking offset on the guest side anyway.
  (import "wasi:filesystem/types@0.2.6"
    "[method]descriptor.append-via-stream"
    (func $descriptor_append_via_stream (type $descriptor_void_sig)))

  ;; `[method]descriptor.set-size(self, size: u64) ->
  ;; result<_, error-code>` backing preview1 `fd_filestat_set_size`.
  ;; Same flat shape as `read-via-stream` (i32, i64, i32) — the
  ;; result payload word is unused on tag=0 and holds the
  ;; `error-code` ordinal on tag=1.
  (import "wasi:filesystem/types@0.2.6"
    "[method]descriptor.set-size"
    (func $descriptor_set_size (type $read_via_stream_sig)))

  ;; `[method]descriptor.set-times(self, atime: new-timestamp,
  ;; mtime: new-timestamp) -> result<_, error-code>` backing preview1
  ;; `fd_filestat_set_times`. Each `new-timestamp` flat-lowers to
  ;; (tag i32, seconds i64, nanoseconds i32); the adapter assembles
  ;; both from the preview1 fstflags bits + raw u64 ns inputs.
  (import "wasi:filesystem/types@0.2.6"
    "[method]descriptor.set-times"
    (func $descriptor_set_times (type $descriptor_set_times_sig)))

  ;; `[method]descriptor.set-times-at(self, path-flags: u8,
  ;; path: string, atime: new-timestamp, mtime: new-timestamp) ->
  ;; result<_, error-code>` backing preview1
  ;; `path_filestat_set_times`.
  (import "wasi:filesystem/types@0.2.6"
    "[method]descriptor.set-times-at"
    (func $descriptor_set_times_at (type $descriptor_set_times_at_sig)))

  ;; `[method]descriptor.stat(self) -> result<descriptor-stat,
  ;; error-code>` backing preview1 `fd_filestat_get`. The 104-byte
  ;; ret-area is the variant `{ tag: u8 (+7 pad), payload: ... }`
  ;; where payload is either a `descriptor-stat` record (96B,
  ;; align 8) or a single `error-code` byte. Decoded by
  ;; `$write_preview1_filestat`.
  (import "wasi:filesystem/types@0.2.6"
    "[method]descriptor.stat"
    (func $descriptor_stat (type $descriptor_void_sig)))

  ;; `[method]descriptor.stat-at(self, path-flags: u8, path: string)
  ;; -> result<descriptor-stat, error-code>` backing preview1
  ;; `path_filestat_get`. Same payload layout as `stat`.
  (import "wasi:filesystem/types@0.2.6"
    "[method]descriptor.stat-at"
    (func $descriptor_stat_at (type $descriptor_stat_at_sig)))

  ;; `[method]descriptor.create-directory-at(self, path: string)`
  ;; backing preview1 `path_create_directory`.
  (import "wasi:filesystem/types@0.2.6"
    "[method]descriptor.create-directory-at"
    (func $descriptor_create_directory_at (type $descriptor_path_only_sig)))

  ;; `[method]descriptor.remove-directory-at(self, path: string)`
  ;; backing preview1 `path_remove_directory`.
  (import "wasi:filesystem/types@0.2.6"
    "[method]descriptor.remove-directory-at"
    (func $descriptor_remove_directory_at (type $descriptor_path_only_sig)))

  ;; `[method]descriptor.unlink-file-at(self, path: string)`
  ;; backing preview1 `path_unlink_file`.
  (import "wasi:filesystem/types@0.2.6"
    "[method]descriptor.unlink-file-at"
    (func $descriptor_unlink_file_at (type $descriptor_path_only_sig)))

  ;; `[method]descriptor.symlink-at(self, old-path: string,
  ;; new-path: string)` backing preview1 `path_symlink`.
  (import "wasi:filesystem/types@0.2.6"
    "[method]descriptor.symlink-at"
    (func $descriptor_symlink_at (type $descriptor_symlink_at_sig)))

  ;; `[method]descriptor.rename-at(self, old-path: string,
  ;; new-descriptor: borrow<descriptor>, new-path: string)` backing
  ;; preview1 `path_rename`. The borrow handle is the same i32 the
  ;; adapter stores in its fd table (the host's resource borrow
  ;; check accepts it because the adapter still owns the underlying
  ;; resource).
  (import "wasi:filesystem/types@0.2.6"
    "[method]descriptor.rename-at"
    (func $descriptor_rename_at (type $descriptor_rename_at_sig)))

  ;; `[method]descriptor.link-at(self, old-path-flags: u8,
  ;; old-path: string, new-descriptor: borrow<descriptor>,
  ;; new-path: string)` backing preview1 `path_link`.
  (import "wasi:filesystem/types@0.2.6"
    "[method]descriptor.link-at"
    (func $descriptor_link_at (type $descriptor_link_at_sig)))

  ;; `[method]descriptor.sync(self)` backing preview1 `fd_sync`
  ;; (file-integrity sync — flushes data + metadata).
  (import "wasi:filesystem/types@0.2.6"
    "[method]descriptor.sync"
    (func $descriptor_sync (type $descriptor_void_sig)))

  ;; `[method]descriptor.sync-data(self)` backing preview1
  ;; `fd_datasync` (data-integrity sync — flushes data only).
  (import "wasi:filesystem/types@0.2.6"
    "[method]descriptor.sync-data"
    (func $descriptor_sync_data (type $descriptor_void_sig)))

  ;; `[method]descriptor.read-directory(self) ->
  ;; result<own<directory-entry-stream>, error-code>` backing
  ;; preview1 `fd_readdir`. Returns a fresh stream cursor on each
  ;; call; adapter ignores the preview1 `cookie` arg and
  ;; re-iterates from the start (matches the wasmtime reference
  ;; adapter's behaviour for non-resumable preview2 streams).
  (import "wasi:filesystem/types@0.2.6"
    "[method]descriptor.read-directory"
    (func $descriptor_read_directory (type $descriptor_void_sig)))

  ;; `[method]directory-entry-stream.read-directory-entry(self) ->
  ;; result<option<directory-entry>, error-code>`. Called by
  ;; `$fd_readdir` in a loop until the option flips to `none` or
  ;; the caller's preview1 buffer fills.
  (import "wasi:filesystem/types@0.2.6"
    "[method]directory-entry-stream.read-directory-entry"
    (func $directory_entry_stream_read (type $descriptor_void_sig)))

  ;; `[resource-drop]directory-entry-stream` — splicer auto-bound,
  ;; same pattern as `[resource-drop]descriptor`. Called at the end
  ;; of every `$fd_readdir` to release the per-call stream.
  (import "wasi:filesystem/types@0.2.6"
    "[resource-drop]directory-entry-stream"
    (func $directory_entry_stream_drop (type $i32_void)))

  ;; `wasi:io/streams.[method]output-stream.blocking-write-and-flush`
  ;; is already declared above for the stdio write path; reused
  ;; verbatim by the user-fd write path on top of
  ;; `descriptor.write-via-stream`.

  ;; `wasi:io/streams.[method]input-stream.blocking-read` — the
  ;; single hot-path read method called by `$fd_read`. Returns
  ;; the bytes read via a canon-lifted `list<u8>`; the adapter
  ;; routes the backing allocation into the caller's preview1
  ;; iov buffer via the one-shot import-alloc override (mode 1).
  (import "wasi:io/streams@0.2.6"
    "[method]input-stream.blocking-read"
    (func $input_stream_blocking_read (type $input_stream_read_sig)))

  ;; `[resource-drop]input-stream` — auto-bound by the splicer
  ;; (same pattern as `[resource-drop]output-stream`). Called at
  ;; the end of every `$fd_read` to release the per-call stream.
  (import "wasi:io/streams@0.2.6"
    "[resource-drop]input-stream"
    (func $input_stream_drop (type $i32_void)))

  ;; ── adapter state ────────────────────────────────────────────
  ;;
  ;; Lazy handle cache for stdout / stderr. Initialised to -1
  ;; (sentinel for "uncached"); populated on first access via
  ;; `wasi:cli/{stdout,stderr}.get-{stdout,stderr}`. wasi-preview1
  ;; is single-threaded (no atomics, no shared memory) so a plain
  ;; mut i32 is safe. We never drop these handles — preview1
  ;; doesn't surface `fd_close` for fd 1 / 2 — so the
  ;; `[resource-drop]output-stream` import is declared for the
  ;; splicer's GC anchor but never invoked from here.
  (global $stdout_handle (mut i32) (i32.const -1))
  (global $stderr_handle (mut i32) (i32.const -1))

  ;; Scratch return-area for canon-lower'd preview2 calls whose
  ;; result type doesn't fit in flat parameters. Reused for:
  ;;
  ;;   * `blocking-write-and-flush` (8-byte `result<_, stream-error>`)
  ;;   * `get-random-bytes` / `get-arguments` / `get-environment`
  ;;     / `get-directories` (8-byte `(list_ptr, list_len)` tuple)
  ;;   * `wall-clock.{now, resolution}` (16-byte `datetime` record)
  ;;   * `descriptor.open-at` (8-byte `result<own<descriptor>,
  ;;     error-code>` discriminated payload)
  ;;
  ;; Page layout (64 KiB):
  ;;
  ;;   0..32       short-lived ret-slot (above).
  ;;   32..2080    `$descriptor_table` — 128 × 16-byte slots for
  ;;               user-opened fds. Each slot is:
  ;;                 offset 0  i32 descriptor handle (-1 = free)
  ;;                 offset 4  pad
  ;;                 offset 8  u64 file position (advanced by
  ;;                           `fd_read` / set by `fd_seek`)
  ;;               Mapped to preview1 fd = `3 + n_preopens + slot`.
  ;;   2080..65536  Bump arena for `$arena_alloc` (used by mode 2 /
  ;;               mode 3 of `$cabi_import_realloc`). Cursor resets
  ;;               to 0 at the end of every preview1 body that
  ;;               touches the import-alloc state machine.
  ;;
  ;; The area is allocated lazily on first preview2 call via the
  ;; embed's `cabi_realloc`; we never free it (the embed instance
  ;; teardown reclaims it).
  ;;
  ;; We request a full page (65536 bytes) rather than the 32 bytes
  ;; we strictly need for ret-area use because when the embed
  ;; itself doesn't export `cabi_realloc`, the component-new
  ;; splicer replaces the `__main_module__::cabi_realloc` import
  ;; with a `realloc_via_memory_grow` body that traps on any
  ;; allocation request smaller than one page (see
  ;; `src/component/adapter/adapter.zig:buildMainModuleFallback`).
  ;; Matches `wit-component`'s upstream
  ;; `allocate_stack_via_realloc` strategy.
  (global $ret_area (mut i32) (i32.const 0))

  ;; ── import-alloc state machine ───────────────────────────────
  ;;
  ;; `$cabi_import_realloc` is invoked by the host for every
  ;; canon-lift'd allocation made during a preview2 import call.
  ;; The behaviour switches on `$import_alloc_mode`:
  ;;
  ;;   mode 0 — default. Delegate to `$main_cabi_realloc` (the
  ;;             embed's heap). Used by callers that don't return
  ;;             allocated data (everything we wired before #163).
  ;;
  ;;   mode 1 — one-shot. The next call returns `$oneshot_ptr`
  ;;             once, then clears the slot and resets mode to 0.
  ;;             Used by `$random_get` to redirect the single
  ;;             `list<u8>` backing alloc into the caller's
  ;;             preview1 `buf` (zero copy).
  ;;
  ;;   mode 2 — count. Used by `args_sizes_get` /
  ;;             `environ_sizes_get` / `fd_prestat_*`. Every
  ;;             allocation is served from the bump arena starting
  ;;             at `$ret_area + 2080` (`$arena_alloc`); `align == 1`
  ;;             allocs additionally accumulate their size into
  ;;             `$strings_sz` so the caller can compute
  ;;             `argv_buf_size` / `env_buf_size` without
  ;;             second-guessing the host. The arena cursor resets
  ;;             to 0 at the start of every preview1 body that
  ;;             enters mode 2 or 3, so the same physical bytes
  ;;             are reused across calls — no main-heap allocation
  ;;             ever happens for args/environ/preopens.
  ;;
  ;;   mode 3 — separate. Used by `args_get` / `environ_get`.
  ;;             `align == 1` allocs go to `$strings_dst +
  ;;             $strings_cur` (the caller's preview1 buffer), with
  ;;             `$strings_cur` advancing by `size + 1` per alloc
  ;;             so that the gap byte after each string can hold a
  ;;             `\0` (args) or `=` / `\0` (environ) terminator
  ;;             written after the host call returns. Non-`align=1`
  ;;             allocs (the list backing) still come from the bump
  ;;             arena.
  ;;
  ;; Single-threaded preview1 → plain mut globals are safe; we
  ;; reset every slot back to 0 at the end of each preview1 body
  ;; so leftover state can't bleed into the next call.
  (global $import_alloc_mode (mut i32) (i32.const 0))
  (global $oneshot_ptr       (mut i32) (i32.const 0))
  (global $arena_cur         (mut i32) (i32.const 0))
  (global $strings_dst       (mut i32) (i32.const 0))
  (global $strings_cur       (mut i32) (i32.const 0))
  (global $strings_sz        (mut i32) (i32.const 0))

  ;; ── descriptor table state ───────────────────────────────────
  ;;
  ;; `$descriptor_table` lives at `$ret_area + 32 .. $ret_area + 2080`
  ;; — 128 × 16-byte slots indexed by `slot = fd - 3 - n_preopens`
  ;; for user-opened fds. Each slot:
  ;;
  ;;   offset 0  i32  descriptor handle (or `-1` = free)
  ;;   offset 4  i32  pad
  ;;   offset 8  u64  file position (advanced by `fd_read`,
  ;;                  written by `fd_seek`; preview2 has no
  ;;                  `seek` method on descriptor, so the position
  ;;                  is purely adapter-side state)
  ;;
  ;; Slots are initialised lazily — the `cabi_realloc` allocation
  ;; that backs `$ret_area` returns uninitialised memory, so a
  ;; fresh write pass is required to install `-1` sentinels in the
  ;; handle slot of every entry. `$descriptor_table_inited` is the
  ;; gate for that pass. Position bytes are not pre-cleared; they
  ;; only matter after a successful `$alloc_fd_slot`, and
  ;; `$path_open` zeroes them right after allocation.
  (global $descriptor_table_inited (mut i32) (i32.const 0))

  ;; ── preview1 errno constants ─────────────────────────────────
  ;; Mirrors wasi-libc `<wasi/api.h>`:
  ;;   EBADF  = 8   bad file descriptor
  ;;   EIO    = 29  I/O error (used for stream-error mapping)
  ;;   ENOSYS = 52  unsupported preview1 function

  ;; ── preview1 surface ─────────────────────────────────────────
  ;;
  ;; proc_exit(code: i32) -> ! :  preview1 declares no return, but
  ;; the canon-lift'd signature in core wasm is `(i32) -> ()`.
  ;;
  ;; Two-step dispatch:
  ;;
  ;;   1. Call `wasi:cli/exit.exit-with-code(u8)`. On runtimes that
  ;;      have bound the `@unstable(cli-exit-with-code)` extension
  ;;      (wamr today) this traps with the original numeric code
  ;;      stashed on the host — the rest of this body never runs.
  ;;
  ;;   2. If `exit-with-code` returned (i.e. the runtime stubs it
  ;;      out), fall through to `wasi:cli/exit.exit(result)` —
  ;;      the stable `@since(version = 0.2.0)` form that every
  ;;      wasi-cli host implements. `result.err = 1`, `result.ok = 0`.
  ;;      Encode `code != 0` → 1, `code == 0` → 0.
  ;;
  ;; The final `unreachable` is defensive — both host calls trap
  ;; on their canonical shapes, but a runtime that ignores both
  ;; would deadlock without it.
  (func $proc_exit (type $proc_exit_sig)
    (local $code_u8 i32)
    ;; clamp to u8 (preview1 proc_exit code is i32; preview2
    ;; exit-with-code expects u8). Use the low 8 bits, matching
    ;; the wasmtime adapter's `code as u8` truncation.
    local.get 0
    i32.const 0xff
    i32.and
    local.set $code_u8
    local.get $code_u8
    call $exit_with_code
    ;; Fallback to stable exit(result). `result` discriminant: 0=ok, 1=err.
    ;; Map non-zero code → err, zero → ok.
    local.get 0
    i32.const 0
    i32.ne
    call $exit
    unreachable)

  ;; proc_raise(sig: i32) -> errno
  (func $proc_raise (type $proc_raise_sig)
    ;; ENOSYS=52
    i32.const 52)

  ;; sched_yield() -> errno
  (func $sched_yield (type $sched_yield_sig)
    ;; Trivially succeed; no preview2 equivalent and yield is
    ;; advisory.
    i32.const 0)

  ;; ── fd_* (mostly ENOSYS stubs until subsequent commits) ──────

  ;; Helper: return cached stdout handle, populating it on first
  ;; call via `wasi:cli/stdout.get-stdout`.
  (func $get_stdout_cached (result i32)
    global.get $stdout_handle
    i32.const -1
    i32.ne
    if (result i32)
      global.get $stdout_handle
    else
      call $get_stdout
      global.set $stdout_handle
      global.get $stdout_handle
    end)

  ;; Helper: return cached stderr handle, populating it on first
  ;; call via `wasi:cli/stderr.get-stderr`.
  (func $get_stderr_cached (result i32)
    global.get $stderr_handle
    i32.const -1
    i32.ne
    if (result i32)
      global.get $stderr_handle
    else
      call $get_stderr
      global.set $stderr_handle
      global.get $stderr_handle
    end)

  ;; Helper: ensure `$ret_area` points at the 64 KiB scratch page
  ;; described above and return that pointer. Allocates once via
  ;; the embed's `cabi_realloc`; subsequent calls are pure reads.
  ;; See the `$ret_area` declaration for the page layout (0..32 =
  ;; short-lived ret slot, 32..65536 = import-alloc bump arena).
  (func $ensure_ret_area (result i32)
    global.get $ret_area
    i32.eqz
    if
      i32.const 0     ;; old_ptr
      i32.const 0     ;; old_size
      i32.const 65536 ;; align (page)
      i32.const 65536 ;; new_size (one page)
      call $main_cabi_realloc
      global.set $ret_area
    end
    global.get $ret_area)

  ;; Helper: bump-allocate `size` bytes from the arena at
  ;; `$ret_area + 2080`, aligned up to `align` (which must be a power
  ;; of two). Used by `$cabi_import_realloc` modes 2 / 3 to serve
  ;; the list-backing allocation (and, in mode 2, the string
  ;; allocations too) without touching the embed's heap.
  ;;
  ;; Offset 2080 = 32 (short-lived ret-slot) + 2048
  ;; (`$descriptor_table`, 128 × 16-byte slots). See the `$ret_area`
  ;; doc for the full page layout.
  ;;
  ;; The arena is not bounds-checked: a host that returns
  ;; pathologically many or pathologically long strings could
  ;; overrun the 63456-byte capacity. For realistic preview1 use
  ;; (n_args + n_envvars ≪ 4096, total bytes ≪ 64 KiB), this is
  ;; comfortably safe; the failure mode if violated is corruption
  ;; of the next adjacent page in env.memory, not a wasm trap.
  ;; A future fixture pushing those limits should grow the arena.
  (func $arena_alloc (param $align i32) (param $size i32) (result i32)
    (local $cur i32) (local $ret i32)
    ;; aligned = (arena_cur + align - 1) & ~(align - 1)
    global.get $arena_cur
    local.get $align
    i32.const 1
    i32.sub
    i32.add
    local.get $align
    i32.const 1
    i32.sub
    i32.const -1
    i32.xor
    i32.and
    local.tee $cur
    ;; ret = $ret_area + 2080 + aligned
    call $ensure_ret_area
    i32.const 2080
    i32.add
    i32.add
    local.set $ret
    ;; arena_cur = aligned + size
    local.get $cur
    local.get $size
    i32.add
    global.set $arena_cur
    local.get $ret)

  ;; Helper: return the base of the `$descriptor_table`, initialising
  ;; the handle slot (offset 0) of every entry to `-1` on first
  ;; call. The position slot (offset 8) is left uninitialised; it
  ;; only matters after a successful `$alloc_fd_slot`, and
  ;; `$path_open` zeroes it right after allocation.
  (func $ensure_descriptor_table (result i32)
    (local $base i32) (local $i i32)
    call $ensure_ret_area
    i32.const 32
    i32.add
    local.set $base
    global.get $descriptor_table_inited
    i32.eqz
    if
      i32.const 0
      local.set $i
      block $done
        loop $next
          local.get $i
          i32.const 128
          i32.ge_u
          br_if $done
          local.get $base
          local.get $i
          i32.const 4              ;; slot stride 16 = 1 << 4
          i32.shl
          i32.add
          i32.const -1
          i32.store offset=0       ;; handle ← -1; position bytes left as-is
          local.get $i
          i32.const 1
          i32.add
          local.set $i
          br $next
        end
      end
      i32.const 1
      global.set $descriptor_table_inited
    end
    local.get $base)

  ;; Helper: find the first free slot in `$descriptor_table`, write
  ;; `handle` into its handle field, and return the slot index.
  ;; Returns `-1` if the table is full (caller maps to `ENFILE=41`
  ;; after dropping the handle). The position field is left
  ;; untouched; callers (`$path_open`) zero it explicitly after a
  ;; successful allocation.
  (func $alloc_fd_slot (param $handle i32) (result i32)
    (local $base i32) (local $i i32) (local $entry i32)
    call $ensure_descriptor_table
    local.set $base
    i32.const 0
    local.set $i
    block $done
      loop $next
        local.get $i
        i32.const 128
        i32.ge_u
        br_if $done
        local.get $base
        local.get $i
        i32.const 4              ;; slot stride 16 = 1 << 4
        i32.shl
        i32.add
        local.tee $entry
        i32.load offset=0
        i32.const -1
        i32.eq
        if
          local.get $entry
          local.get $handle
          i32.store offset=0
          local.get $i
          return
        end
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $next
      end
    end
    i32.const -1)

  ;; Helper: map `wasi:filesystem/types.error-code` ordinals (0..36)
  ;; to preview1 errno values (`<wasi/api.h>`). Ordinals follow the
  ;; declaration order in `wit/deps/wasi-filesystem/types.wit`'s
  ;; `error-code` enum. Cherry-picked from the wasmtime reference
  ;; adapter's `From<filesystem::ErrorCode> for Errno`.
  (func $errno_from_error_code (param $ec i32) (result i32)
    local.get $ec  i32.eqz                      if i32.const  2 return end ;; access → EACCES
    local.get $ec  i32.const  1  i32.eq         if i32.const  6 return end ;; would-block → EAGAIN
    local.get $ec  i32.const  2  i32.eq         if i32.const  7 return end ;; already
    local.get $ec  i32.const  3  i32.eq         if i32.const  8 return end ;; bad-descriptor → EBADF
    local.get $ec  i32.const  4  i32.eq         if i32.const 10 return end ;; busy
    local.get $ec  i32.const  5  i32.eq         if i32.const 16 return end ;; deadlock
    local.get $ec  i32.const  6  i32.eq         if i32.const 19 return end ;; quota → EDQUOT
    local.get $ec  i32.const  7  i32.eq         if i32.const 20 return end ;; exist
    local.get $ec  i32.const  8  i32.eq         if i32.const 22 return end ;; file-too-large → EFBIG
    local.get $ec  i32.const  9  i32.eq         if i32.const 25 return end ;; illegal-byte-sequence → EILSEQ
    local.get $ec  i32.const 10  i32.eq         if i32.const 26 return end ;; in-progress
    local.get $ec  i32.const 11  i32.eq         if i32.const 27 return end ;; interrupted → EINTR
    local.get $ec  i32.const 12  i32.eq         if i32.const 28 return end ;; invalid → EINVAL
    local.get $ec  i32.const 13  i32.eq         if i32.const 29 return end ;; io → EIO
    local.get $ec  i32.const 14  i32.eq         if i32.const 31 return end ;; is-directory → EISDIR
    local.get $ec  i32.const 15  i32.eq         if i32.const 32 return end ;; loop → ELOOP
    local.get $ec  i32.const 16  i32.eq         if i32.const 34 return end ;; too-many-links → EMLINK
    local.get $ec  i32.const 17  i32.eq         if i32.const 35 return end ;; message-size → EMSGSIZE
    local.get $ec  i32.const 18  i32.eq         if i32.const 37 return end ;; name-too-long → ENAMETOOLONG
    local.get $ec  i32.const 19  i32.eq         if i32.const 43 return end ;; no-device → ENODEV
    local.get $ec  i32.const 20  i32.eq         if i32.const 44 return end ;; no-entry → ENOENT
    local.get $ec  i32.const 21  i32.eq         if i32.const 46 return end ;; no-lock → ENOLCK
    local.get $ec  i32.const 22  i32.eq         if i32.const 48 return end ;; insufficient-memory → ENOMEM
    local.get $ec  i32.const 23  i32.eq         if i32.const 51 return end ;; insufficient-space → ENOSPC
    local.get $ec  i32.const 24  i32.eq         if i32.const 54 return end ;; not-directory → ENOTDIR
    local.get $ec  i32.const 25  i32.eq         if i32.const 55 return end ;; not-empty → ENOTEMPTY
    local.get $ec  i32.const 26  i32.eq         if i32.const 56 return end ;; not-recoverable
    local.get $ec  i32.const 27  i32.eq         if i32.const 58 return end ;; unsupported → ENOTSUP
    local.get $ec  i32.const 28  i32.eq         if i32.const 59 return end ;; no-tty → ENOTTY
    local.get $ec  i32.const 29  i32.eq         if i32.const 60 return end ;; no-such-device → ENXIO
    local.get $ec  i32.const 30  i32.eq         if i32.const 61 return end ;; overflow → EOVERFLOW
    local.get $ec  i32.const 31  i32.eq         if i32.const 63 return end ;; not-permitted → EPERM
    local.get $ec  i32.const 32  i32.eq         if i32.const 64 return end ;; pipe → EPIPE
    local.get $ec  i32.const 33  i32.eq         if i32.const 69 return end ;; read-only → EROFS
    local.get $ec  i32.const 34  i32.eq         if i32.const 70 return end ;; invalid-seek → ESPIPE
    local.get $ec  i32.const 35  i32.eq         if i32.const 74 return end ;; text-file-busy → ETXTBSY
    local.get $ec  i32.const 36  i32.eq         if i32.const 75 return end ;; cross-device → EXDEV
    i32.const 29) ;; default → EIO

  ;; Helper: resolve a preview1 `fd` to a preview2 descriptor handle.
  ;; Writes the handle at `*out_handle_ptr` and the lifted preopen
  ;; count at `*out_n_preopens_ptr` (used by callers that then need
  ;; to compose the returned-fd number). Returns 0 on success, the
  ;; preview1 errno on failure (in which case `*out_handle_ptr` is
  ;; untouched).
  ;;
  ;; Multi-output via out-pointers because wabt's validator
  ;; currently rejects multi-result function signatures (see the
  ;; memory note from the #171 clocks work).
  ;;
  ;; Lifts preopens via mode 2 of the import-alloc state machine;
  ;; the arena is reset before returning so the caller can re-use
  ;; the bump arena for any follow-up host call (e.g. `open-at`).
  ;; Helper: resolve a preview1 `fd` to a preview2 descriptor handle.
  ;; Writes the handle at `*out_handle_ptr`, the lifted preopen
  ;; count at `*out_n_preopens_ptr`, and (for user-opened fds) the
  ;; address of the 16-byte `$descriptor_table` slot at
  ;; `*out_slot_addr_ptr`. For preopens we write `0` to
  ;; `*out_slot_addr_ptr` (no slot — preopens are not seekable and
  ;; have no adapter-tracked position). Returns 0 on success, the
  ;; preview1 errno on failure (in which case the out-pointers are
  ;; untouched).
  ;;
  ;; Multi-output via out-pointers because wabt's validator
  ;; currently rejects multi-result function signatures (see the
  ;; memory note from the #171 clocks work).
  ;;
  ;; Lifts preopens via mode 2 of the import-alloc state machine;
  ;; the arena is reset before returning so the caller can re-use
  ;; the bump arena for any follow-up host call (e.g. `open-at`,
  ;; `read-via-stream`).
  (func $resolve_fd
    (param $fd i32)
    (param $out_handle_ptr i32)
    (param $out_n_preopens_ptr i32)
    (param $out_slot_addr_ptr i32)
    (result i32)
    (local $ra i32) (local $idx i32) (local $list_ptr i32)
    (local $list_len i32) (local $entry i32) (local $handle i32)
    (local $tbl i32) (local $slot i32) (local $slot_addr i32)
    local.get $fd
    i32.const 3
    i32.sub
    local.set $idx
    local.get $idx
    i32.const 0
    i32.lt_s
    if
      i32.const 8                       ;; EBADF for stdio
      return
    end
    ;; Lift preopens.
    i32.const 0  global.set $arena_cur
    i32.const 0  global.set $strings_sz
    i32.const 2  global.set $import_alloc_mode
    call $ensure_ret_area
    local.tee $ra
    call $get_directories
    i32.const 0  global.set $import_alloc_mode
    local.get $ra
    i32.load offset=0
    local.set $list_ptr
    local.get $ra
    i32.load offset=4
    local.set $list_len
    ;; Publish n_preopens to the caller.
    local.get $out_n_preopens_ptr
    local.get $list_len
    i32.store
    local.get $idx
    local.get $list_len
    i32.lt_u
    if
      ;; preopen: handle = list_ptr[idx * 12 + 0]; slot_addr = 0
      local.get $list_ptr
      local.get $idx
      i32.const 12
      i32.mul
      i32.add
      i32.load offset=0
      local.set $handle
      i32.const 0  global.set $arena_cur
      i32.const 0  global.set $strings_sz
      local.get $out_handle_ptr
      local.get $handle
      i32.store
      local.get $out_slot_addr_ptr
      i32.const 0
      i32.store
      i32.const 0
      return
    end
    ;; user fd: slot = idx - list_len; bounds check; table lookup.
    local.get $idx
    local.get $list_len
    i32.sub
    local.tee $slot
    i32.const 128
    i32.ge_u
    if
      i32.const 0  global.set $arena_cur
      i32.const 0  global.set $strings_sz
      i32.const 8                       ;; EBADF — past max user fds
      return
    end
    call $ensure_descriptor_table
    local.get $slot
    i32.const 4                          ;; slot stride 16 = 1 << 4
    i32.shl
    i32.add
    local.tee $slot_addr
    i32.load offset=0
    local.tee $handle
    i32.const -1
    i32.eq
    if
      i32.const 0  global.set $arena_cur
      i32.const 0  global.set $strings_sz
      i32.const 8                       ;; EBADF — free slot
      return
    end
    i32.const 0  global.set $arena_cur
    i32.const 0  global.set $strings_sz
    local.get $out_handle_ptr
    local.get $handle
    i32.store
    local.get $out_slot_addr_ptr
    local.get $slot_addr
    i32.store
    i32.const 0)

  ;; Helper: decode the ret-area produced by a canon-lower'd
  ;; `result<_, error-code>` call into a preview1 errno. The
  ;; canonical layout is 8 bytes:
  ;;   offset 0: u8 outer tag (0 = ok, 1 = err) + 3 pad bytes
  ;;   offset 4: i32 payload — unused on tag=0, holds the
  ;;             `error-code` ordinal on tag=1
  ;; ok → 0, err → `$errno_from_error_code(<ordinal>)`.
  ;;
  ;; Used by every wired filesystem mutation that returns a bare
  ;; `result<_, error-code>` (sync, sync-data, set-size,
  ;; set-times, set-times-at, create-directory-at,
  ;; remove-directory-at, unlink-file-at, symlink-at, rename-at,
  ;; link-at). The caller must have already initialised $ra via
  ;; `$ensure_ret_area` and invoked the host method.
  (func $descriptor_error_only_result (param $ra i32) (result i32)
    local.get $ra
    i32.load8_u
    if (result i32)
      local.get $ra
      i32.load offset=4
      call $errno_from_error_code
    else
      i32.const 0
    end)

  ;; Helper: write `buf[0..len]` to `handle` via
  ;; `blocking-write-and-flush`. Maps `stream-error` to EIO; an
  ;; ok result returns 0. Skips zero-length writes (the canon
  ;; ABI accepts them, but preview2 hosts may surface a spurious
  ;; `closed` for an empty contents list).
  (func $write_one
    (param $handle i32) (param $buf i32) (param $len i32)
    (result i32)
    (local $ra i32)
    local.get $len
    i32.eqz
    if
      i32.const 0
      return
    end
    call $ensure_ret_area
    local.set $ra
    local.get $handle
    local.get $buf
    local.get $len
    local.get $ra
    call $blocking_write_and_flush
    ;; result outer discriminant is one byte at offset 0:
    ;;   0 = ok, 1 = err(stream-error)
    local.get $ra
    i32.load8_u
    if (result i32)
      i32.const 29 ;; EIO
    else
      i32.const 0
    end)

  ;; Helper: stream every iovec in `iovs[0..iovs_len]` through
  ;; `$write_one(handle, …)`, accumulating the byte count at
  ;; `*nwritten_ptr`. Bails on the first non-zero errno but
  ;; still publishes the partial count so wasi-libc can resume.
  ;;
  ;; iovec layout (preview1):
  ;;   struct iovec_t { uint8_t *buf; size_t buf_len; }
  ;; canon-lowered to 8 bytes per record in env.memory
  ;; (offset 0: buf_ptr i32, offset 4: buf_len i32).
  (func $write_iovecs
    (param $handle i32) (param $iovs i32) (param $iovs_len i32)
    (param $nwritten_ptr i32)
    (result i32)
    (local $i i32) (local $total i32) (local $rec i32)
    (local $buf i32) (local $len i32) (local $ret i32)
    i32.const 0
    local.set $i
    i32.const 0
    local.set $total
    block $done
      loop $next
        local.get $i
        local.get $iovs_len
        i32.ge_u
        br_if $done
        ;; rec = iovs + (i << 3)
        local.get $iovs
        local.get $i
        i32.const 3
        i32.shl
        i32.add
        local.tee $rec
        i32.load        ;; buf
        local.set $buf
        local.get $rec
        i32.load offset=4 ;; len
        local.set $len
        local.get $handle
        local.get $buf
        local.get $len
        call $write_one
        local.tee $ret
        if
          ;; stream-error: publish partial count + bail.
          local.get $nwritten_ptr
          local.get $total
          i32.store
          local.get $ret
          return
        end
        local.get $total
        local.get $len
        i32.add
        local.set $total
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $next
      end
    end
    local.get $nwritten_ptr
    local.get $total
    i32.store
    i32.const 0)

  ;; Helper: write iovecs to a regular-file fd at byte offset
  ;; `$position`. Returns a preview1 errno (0 on success). On
  ;; success, `*nwritten_ptr` holds the total bytes written; on
  ;; partial-failure (`stream-error` mid-stream), `*nwritten_ptr`
  ;; holds the bytes successfully streamed before the error.
  ;;
  ;; Sequence:
  ;;
  ;;   1. Open a fresh `output-stream` via
  ;;      `descriptor.write-via-stream(handle, position)`. On
  ;;      `error-code`, map to errno and return.
  ;;   2. Iterate iovecs through `$write_iovecs(stream, …)`.
  ;;   3. Drop the stream via `[resource-drop]output-stream` so the
  ;;      host releases its per-call buffering — important when the
  ;;      caller does many small writes back-to-back.
  ;;   4. Return the iovec write's errno.
  ;;
  ;; The caller (`$fd_write` user-fd branch / `$fd_pwrite`) is
  ;; responsible for advancing the per-fd tracked position in the
  ;; `$descriptor_table` slot — this helper deliberately doesn't
  ;; touch slot state so it works for both `fd_write` (advances)
  ;; and `fd_pwrite` (doesn't).
  (func $write_at_position
    (param $handle i32) (param $position i64)
    (param $iovs i32) (param $iovs_len i32) (param $nwritten_ptr i32)
    (result i32)
    (local $ra i32) (local $stream i32) (local $err i32)
    call $ensure_ret_area
    local.set $ra
    local.get $handle
    local.get $position
    local.get $ra
    call $descriptor_write_via_stream
    ;; ret-area: tag(u8) at 0, payload(i32) at 4. tag=0 → ok with
    ;; output-stream handle in payload; tag=1 → err with error-code
    ;; ordinal in payload.
    local.get $ra
    i32.load8_u
    if
      ;; Open failed: publish 0 bytes written + return mapped errno.
      local.get $nwritten_ptr
      i32.const 0
      i32.store
      local.get $ra
      i32.load offset=4
      call $errno_from_error_code
      return
    end
    local.get $ra
    i32.load offset=4
    local.set $stream
    local.get $stream
    local.get $iovs
    local.get $iovs_len
    local.get $nwritten_ptr
    call $write_iovecs
    local.set $err
    local.get $stream
    call $output_stream_drop
    local.get $err)

  ;; preview1 `fd_write(fd, iovs, iovs_len, nwritten_ptr) -> errno`.
  ;;
  ;; Stdio (fd 1 / 2): route through the cached
  ;; `wasi:cli/{stdout,stderr}.get-{stdout,stderr}` handles +
  ;; `$write_iovecs`.
  ;;
  ;; User-opened files (fd ≥ 3): `$resolve_fd` to a descriptor
  ;; handle + slot_addr, open a fresh `output-stream` via
  ;; `descriptor.write-via-stream(position)`, stream every iovec
  ;; through `output-stream.blocking-write-and-flush`, drop the
  ;; stream, and advance the slot's tracked position by total
  ;; bytes written. Mirrors `$fd_read`'s shape (one stream churn
  ;; per preview1 call). Preopens are not writeable → EBADF.
  ;;
  ;; fd 0 (stdin) and any unmatched fd return EBADF.
  (func $fd_write (type $fd_write_sig)
    (local $handle i32) (local $ra i32) (local $slot_addr i32)
    (local $position i64) (local $err i32) (local $written i32)
    block $bad_fd
      local.get 0   ;; fd
      i32.const 1
      i32.eq
      if
        call $get_stdout_cached
        local.set $handle
      else
        local.get 0
        i32.const 2
        i32.eq
        if
          call $get_stderr_cached
          local.set $handle
        else
          local.get 0
          i32.const 3
          i32.lt_u
          if
            br $bad_fd               ;; fd 0 (stdin) — not writeable
          end
          ;; User-opened fd path. Resolve to (handle, slot_addr);
          ;; preopens (slot_addr == 0) → EBADF since they're
          ;; directories, not writeable streams.
          call $ensure_ret_area
          local.set $ra
          local.get 0
          local.get $ra                      ;; out_handle_ptr
          local.get $ra  i32.const 4 i32.add ;; out_n_preopens_ptr
          local.get $ra  i32.const 8 i32.add ;; out_slot_addr_ptr
          call $resolve_fd
          local.tee $err
          if  local.get $err  return  end
          local.get $ra
          i32.load offset=8
          local.tee $slot_addr
          i32.eqz
          if  br $bad_fd  end
          local.get $ra
          i32.load offset=0
          local.set $handle
          local.get $slot_addr
          i64.load offset=8
          local.set $position
          local.get $handle
          local.get $position
          local.get 1   ;; iovs
          local.get 2   ;; iovs_len
          local.get 3   ;; nwritten_ptr
          call $write_at_position
          local.set $err
          ;; Advance the per-fd tracked position by the bytes
          ;; actually written (read back from *nwritten_ptr — set
          ;; on both success and partial-failure paths).
          local.get 3
          i32.load
          local.set $written
          local.get $slot_addr
          local.get $position
          local.get $written
          i64.extend_i32_u
          i64.add
          i64.store offset=8
          local.get $err
          return
        end
      end
      local.get $handle
      local.get 1   ;; iovs
      local.get 2   ;; iovs_len
      local.get 3   ;; nwritten_ptr
      call $write_iovecs
      return
    end
    i32.const 8) ;; EBADF

  ;; preview1 `fd_pwrite(fd, iovs, iovs_len, offset, nwritten_ptr)
  ;; -> errno`. POSIX `pwrite` semantics — writes at the explicit
  ;; `offset` without touching the per-fd position. Stdio returns
  ;; ESPIPE (matches `fd_seek` stdio behaviour); preopens / unknown
  ;; user fds return EBADF.
  (func $fd_pwrite (type $fd_pwrite_sig)
    (local $ra i32) (local $handle i32) (local $slot_addr i32)
    (local $err i32)
    local.get 0
    i32.const 3
    i32.lt_u
    if
      i32.const 70                       ;; ESPIPE for stdio
      return
    end
    call $ensure_ret_area
    local.set $ra
    local.get 0
    local.get $ra                        ;; out_handle_ptr
    local.get $ra  i32.const 4 i32.add   ;; out_n_preopens_ptr
    local.get $ra  i32.const 8 i32.add   ;; out_slot_addr_ptr
    call $resolve_fd
    local.tee $err
    if  local.get $err  return  end
    local.get $ra
    i32.load offset=8
    local.tee $slot_addr
    i32.eqz
    if
      i32.const 8                        ;; EBADF — preopens not writeable
      return
    end
    local.get $ra
    i32.load offset=0
    local.set $handle
    local.get $handle
    local.get 3                          ;; explicit offset (i64)
    local.get 1                          ;; iovs
    local.get 2                          ;; iovs_len
    local.get 4                          ;; nwritten_ptr
    call $write_at_position)

  ;; preview1 `fd_read(fd, iovs, iovs_len, nread_ptr) -> errno`.
  ;;
  ;; Strategy (mirrors the wasmtime reference adapter):
  ;;
  ;;   1. Skip leading empty iovs. If all iovs are empty, succeed
  ;;      with *nread=0 — wasi-libc treats that as EOF if it asked
  ;;      for any bytes.
  ;;   2. Take the first non-empty iov's (buf, len). We don't loop
  ;;      over remaining iovs — POSIX `readv` allows short reads
  ;;      and wasi-libc's caller handles continuation. True
  ;;      scatter-gather would require multiple host calls per
  ;;      preview1 invocation, with subtle EOF handling.
  ;;   3. Resolve fd → (handle, slot_addr). Preopens and stdio
  ;;      return EBADF — preview2 reading from a directory or
  ;;      stdin descriptor requires extra wiring deferred to a
  ;;      later subphase.
  ;;   4. Open a fresh `input-stream` via
  ;;      `descriptor.read-via-stream(position)`. On error, map
  ;;      `error-code` → errno and return.
  ;;   5. Call `input-stream.blocking-read(len)` with the one-shot
  ;;      import-alloc override (mode 1) pointing at `buf`. The
  ;;      host's canon-lifted `list<u8>` backing therefore lands
  ;;      directly inside the caller's preview1 iov — zero copy.
  ;;   6. Drop the stream (one resource churn per call; a future
  ;;      optimisation can cache the stream on the fd slot).
  ;;   7. Decode the result. `stream-error.closed` → return 0
  ;;      bytes (EOF). `stream-error.last-operation-failed` → EIO.
  ;;      Success: read `bytes_read` from the ret-area; advance
  ;;      the slot's position by that many bytes; publish to
  ;;      *nread_ptr.
  ;;
  ;; ret-area layout for `result<list<u8>, stream-error>`:
  ;;   offset 0..4  outer tag (u8 + 3 pad)
  ;;   offset 4..12 payload — for ok this is `(ptr i32, len i32)`;
  ;;                for err it's `stream-error { inner_tag u8
  ;;                (+3 pad), inner_payload i32 }`.
  (func $fd_read (type $fd_read_sig)
    (local $iovs i32) (local $iovs_len i32)
    (local $buf i32) (local $buf_len i32)
    (local $ra i32) (local $handle i32) (local $slot_addr i32)
    (local $stream i32) (local $tag i32) (local $bytes_read i32)
    (local $position i64) (local $err i32)
    ;; 1. Skip leading empty iovs.
    local.get 1
    local.set $iovs
    local.get 2
    local.set $iovs_len
    block $found_non_empty
      loop $skip
        local.get $iovs_len
        i32.eqz
        if
          ;; All iovs empty → *nread = 0, return SUCCESS.
          local.get 3
          i32.const 0
          i32.store
          i32.const 0
          return
        end
        local.get $iovs
        i32.load offset=4               ;; iov.buf_len
        local.tee $buf_len
        br_if $found_non_empty
        local.get $iovs
        i32.const 8
        i32.add
        local.set $iovs
        local.get $iovs_len
        i32.const 1
        i32.sub
        local.set $iovs_len
        br $skip
      end
    end
    local.get $iovs
    i32.load offset=0
    local.set $buf
    ;; 2. Resolve fd → (handle, slot_addr).
    call $ensure_ret_area
    local.set $ra
    local.get 0
    local.get $ra                       ;; out_handle (offset 0)
    local.get $ra  i32.const 4  i32.add ;; out_n_preopens (offset 4, ignored)
    local.get $ra  i32.const 8  i32.add ;; out_slot_addr (offset 8)
    call $resolve_fd
    local.tee $err
    if  local.get $err  return  end
    local.get $ra
    i32.load offset=0
    local.set $handle
    local.get $ra
    i32.load offset=8
    local.set $slot_addr
    local.get $slot_addr
    i32.eqz
    if
      ;; Preopen / stdin path — not wired here. EBADF for now.
      i32.const 8
      return
    end
    local.get $slot_addr
    i64.load offset=8
    local.set $position
    ;; 3. Open an input-stream via descriptor.read-via-stream.
    local.get $handle
    local.get $position
    local.get $ra
    call $descriptor_read_via_stream
    local.get $ra
    i32.load8_u offset=0
    local.set $tag
    local.get $tag
    if
      ;; error opening stream — map error-code → errno
      local.get $ra
      i32.load offset=4
      call $errno_from_error_code
      return
    end
    local.get $ra
    i32.load offset=4
    local.set $stream
    ;; 4. blocking-read with the one-shot override targeting buf.
    local.get $buf
    global.set $oneshot_ptr
    i32.const 1
    global.set $import_alloc_mode
    local.get $stream
    local.get $buf_len
    i64.extend_i32_u
    local.get $ra
    call $input_stream_blocking_read
    ;; Defensive cleanup of the override slot (should already be 0).
    i32.const 0  global.set $import_alloc_mode
    i32.const 0  global.set $oneshot_ptr
    ;; 5. Drop the stream regardless of outcome.
    local.get $stream
    call $input_stream_drop
    ;; 6. Decode result.
    local.get $ra
    i32.load8_u offset=0
    local.set $tag
    local.get $tag
    if
      ;; stream-error: inner tag at ra+4. 0 = last-operation-failed
      ;; (→ EIO=29); 1 = closed (→ EOF, return 0 bytes).
      local.get $ra
      i32.load8_u offset=4
      i32.eqz
      if
        i32.const 29
        return
      end
      local.get 3                       ;; nread_ptr
      i32.const 0
      i32.store
      i32.const 0
      return
    end
    ;; ok: payload at ra+4 is `(ptr i32, len i32)`. With mode 1 the
    ;; ptr equals buf; we only need the len.
    local.get $ra
    i32.load offset=8
    local.set $bytes_read
    ;; 7. Advance position += bytes_read.
    local.get $slot_addr
    local.get $position
    local.get $bytes_read
    i64.extend_i32_u
    i64.add
    i64.store offset=8
    ;; 8. *nread_ptr = bytes_read.
    local.get 3
    local.get $bytes_read
    i32.store
    i32.const 0)
  ;; preview1 `fd_close(fd) -> errno`.
  ;;
  ;;   fd 0..2 (stdio)            → success (close-stdio is a no-op
  ;;                                in preview1; matches wasmtime).
  ;;   fd in preopen range         → success (preopens are owned by
  ;;                                the host and are immortal for the
  ;;                                process lifetime; closing them is
  ;;                                a no-op).
  ;;   fd in user-table range      → drop the descriptor handle via
  ;;                                `[resource-drop]descriptor`,
  ;;                                clear the slot, return SUCCESS.
  ;;   anything else               → EBADF.
  ;;
  ;; Lifts preopens via `$resolve_fd` to discover both the
  ;; descriptor handle and `n_preopens` for the user-fd offset
  ;; computation in one go.
  (func $fd_close (type $fd_close_sig)
    (local $ra i32) (local $idx i32) (local $list_len i32)
    (local $slot i32) (local $tbl i32) (local $entry i32)
    (local $handle i32)
    local.get 0
    i32.const 3
    i32.sub
    local.tee $idx
    i32.const 0
    i32.lt_s
    if
      i32.const 0                       ;; stdio close: no-op
      return
    end
    ;; Lift preopens to learn n_preopens.
    i32.const 0  global.set $arena_cur
    i32.const 0  global.set $strings_sz
    i32.const 2  global.set $import_alloc_mode
    call $ensure_ret_area
    local.tee $ra
    call $get_directories
    i32.const 0  global.set $import_alloc_mode
    local.get $ra
    i32.load offset=4
    local.set $list_len
    i32.const 0  global.set $arena_cur
    i32.const 0  global.set $strings_sz
    local.get $idx
    local.get $list_len
    i32.lt_u
    if
      i32.const 0                       ;; preopen close: no-op
      return
    end
    ;; user fd: slot = idx - list_len; bounds check; drop + clear.
    local.get $idx
    local.get $list_len
    i32.sub
    local.tee $slot
    i32.const 128
    i32.ge_u
    if
      i32.const 8                       ;; EBADF
      return
    end
    call $ensure_descriptor_table
    local.get $slot
    i32.const 4                          ;; slot stride 16 = 1 << 4
    i32.shl
    i32.add
    local.tee $entry
    i32.load offset=0
    local.tee $handle
    i32.const -1
    i32.eq
    if
      i32.const 8                       ;; EBADF — slot already free
      return
    end
    local.get $handle
    call $descriptor_drop
    local.get $entry
    i32.const -1
    i32.store offset=0
    i32.const 0)

  ;; preview1 `path_open(dirfd, dirflags, path_ptr, path_len,
  ;; oflags, fs_rights_base, fs_rights_inheriting, fdflags,
  ;; opened_fd_ptr) -> errno`.
  ;;
  ;; 1. Resolve dirfd → preview2 descriptor handle via
  ;;    `$resolve_fd` (which also publishes `n_preopens` so we can
  ;;    compute the returned fd).
  ;; 2. Translate preview1 flag bundles into the preview2
  ;;    `path-flags` / `open-flags` / `descriptor-flags` triple.
  ;;    The bit assignments for `path-flags.symlink-follow` and
  ;;    the four `open-flags` happen to coincide with their preview1
  ;;    counterparts so the translation is a bitmask passthrough.
  ;;    `descriptor-flags` requires explicit conversion from
  ;;    `fs_rights_base` + `fdflags`.
  ;; 3. Call `descriptor.open-at`. On success the return-area holds
  ;;    `(tag=0, payload=descriptor handle)`; on error
  ;;    `(tag=1, payload=error-code ordinal)`.
  ;; 4. Allocate a slot in `$descriptor_table`; if full, drop the
  ;;    new handle and return `ENFILE=41`.
  ;; 5. Write the resulting preview1 fd at `*opened_fd_ptr`.
  ;;
  ;; `fs_rights_inheriting` is advisory in preview1 with no preview2
  ;; equivalent; silently ignored, matching wasmtime.
  ;; `FDFLAGS_APPEND` and `FDFLAGS_NONBLOCK` are deferred to a
  ;; later subphase (they would require `descriptor.set-flags` and
  ;; per-call `read` vs `blocking-read` selection).
  (func $path_open (type $path_open_sig)
    (local $dir_handle i32) (local $n_preopens i32) (local $err i32)
    (local $path_flags i32) (local $open_flags i32) (local $desc_flags i32)
    (local $rights_lo i32) (local $ra i32)
    (local $tag i32) (local $payload i32) (local $slot i32)
    ;; 1. Resolve dirfd. Use offsets in the short-lived ret-slot
    ;;    (0..32) for the three out-pointers (handle, n_preopens,
    ;;    slot_addr — we ignore slot_addr here but $resolve_fd
    ;;    needs the param). We'll overwrite ret-slot bytes 0..8
    ;;    with the open-at result later.
    call $ensure_ret_area
    local.set $ra
    local.get 0                         ;; dirfd
    local.get $ra                       ;; out_handle_ptr (offset 0)
    local.get $ra
    i32.const 4
    i32.add                              ;; out_n_preopens_ptr (offset 4)
    local.get $ra
    i32.const 8
    i32.add                              ;; out_slot_addr_ptr (offset 8, ignored)
    call $resolve_fd
    local.tee $err
    if
      local.get $err
      return
    end
    local.get $ra
    i32.load offset=0
    local.set $dir_handle
    local.get $ra
    i32.load offset=4
    local.set $n_preopens
    ;; 2. Flag translation.
    local.get 1                         ;; dirflags
    i32.const 1
    i32.and
    local.set $path_flags
    local.get 4                         ;; oflags (i32)
    i32.const 0xF
    i32.and
    local.set $open_flags
    ;; descriptor-flags from rights + fdflags.
    ;; rights low 32 bits: FD_READ=0x02, FD_WRITE=0x40, FD_DATASYNC=0x01,
    ;; FD_SYNC=0x10. fs_rights_base is i64 in the param list.
    local.get 5                         ;; fs_rights_base (i64)
    i32.wrap_i64
    local.set $rights_lo
    i32.const 0
    local.set $desc_flags
    ;; READ
    local.get $rights_lo
    i32.const 0x02
    i32.and
    if
      local.get $desc_flags
      i32.const 1
      i32.or
      local.set $desc_flags
    end
    ;; WRITE
    local.get $rights_lo
    i32.const 0x40
    i32.and
    if
      local.get $desc_flags
      i32.const 2
      i32.or
      local.set $desc_flags
    end
    ;; FILE_INTEGRITY_SYNC ← FDFLAGS_SYNC (16)
    local.get 7                         ;; fdflags
    i32.const 16
    i32.and
    if
      local.get $desc_flags
      i32.const 4
      i32.or
      local.set $desc_flags
    end
    ;; DATA_INTEGRITY_SYNC ← FDFLAGS_DSYNC (2)
    local.get 7
    i32.const 2
    i32.and
    if
      local.get $desc_flags
      i32.const 8
      i32.or
      local.set $desc_flags
    end
    ;; REQUESTED_WRITE_SYNC ← FDFLAGS_RSYNC (8)
    local.get 7
    i32.const 8
    i32.and
    if
      local.get $desc_flags
      i32.const 16
      i32.or
      local.set $desc_flags
    end
    ;; 3. Call descriptor.open-at(self, path_flags, path_ptr,
    ;;    path_len, open_flags, desc_flags, ret_area).
    local.get $dir_handle
    local.get $path_flags
    local.get 2                         ;; path_ptr
    local.get 3                         ;; path_len
    local.get $open_flags
    local.get $desc_flags
    local.get $ra
    call $descriptor_open_at
    ;; 4. Read result.
    local.get $ra
    i32.load8_u offset=0
    local.set $tag
    local.get $ra
    i32.load offset=4
    local.set $payload
    local.get $tag
    if
      ;; err: payload is the error-code ordinal.
      local.get $payload
      call $errno_from_error_code
      return
    end
    ;; 5. payload is the new descriptor handle. Allocate a slot.
    local.get $payload
    call $alloc_fd_slot
    local.tee $slot
    i32.const 0
    i32.lt_s
    if
      ;; Table full: drop the new handle to avoid leaking it host-side,
      ;; return ENFILE=41 ("too many files open in system").
      local.get $payload
      call $descriptor_drop
      i32.const 41
      return
    end
    ;; 5b. Zero the position slot for the new fd. `$alloc_fd_slot`
    ;;     writes only the handle field; the position bytes carry
    ;;     stale garbage from a previous fd_close or from the
    ;;     uninitialised cabi_realloc page.
    call $ensure_descriptor_table
    local.get $slot
    i32.const 4
    i32.shl
    i32.add
    i64.const 0
    i64.store offset=8
    ;; 6. *opened_fd_ptr = 3 + n_preopens + slot.
    local.get 8                         ;; opened_fd_ptr
    local.get $n_preopens
    local.get $slot
    i32.add
    i32.const 3
    i32.add
    i32.store
    i32.const 0)

  ;; preview1 `fd_seek(fd, offset, whence, newoffset_ptr) -> errno`.
  ;;
  ;; Stdio (fd 0/1/2) cannot seek — return ESPIPE so wasi-libc's
  ;; `isatty` probe and Rust's `std::io::Stdout` line-buffering
  ;; codepaths see the "this is a pipe" signal rather than a hard
  ;; "function not supported" error. Matches the wasmtime reference
  ;; adapter's stdio branch.
  ;;
  ;; For fd ≥ 3, preview2 has no `seek` method on `descriptor`;
  ;; the file position is purely adapter-side state stored in the
  ;; `$descriptor_table` slot's `position` field. Each `fd_read`
  ;; opens a fresh `read-via-stream(position)`; `fd_seek` just
  ;; updates that position.
  ;;
  ;; Dispatch on whence:
  ;;   SET (0): new_pos = offset
  ;;   CUR (1): new_pos = position + offset (i64 add; signed semantics)
  ;;   END (2): ENOTSUP — needs `descriptor.stat` (subphase c of #165)
  ;;   other  : EINVAL
  ;;
  ;; Negative new_pos → EINVAL (rejected via i64.lt_s against 0).
  ;;
  ;; Preopen-directory fd → ESPIPE (matches wasmtime's directory branch).
  ;;
  ;; `__WASI_ERRNO_SPIPE = 70` per `wasi-libc/.../wasip1.h` —
  ;; preview1's own errno table, NOT the Linux POSIX value (29).
  (func $fd_seek (type $fd_seek_sig)
    (local $ra i32) (local $slot_addr i32) (local $position i64)
    (local $new_pos i64) (local $err i32)
    local.get 0
    i32.const 3
    i32.lt_u
    if
      i32.const 70   ;; ESPIPE (stdio)
      return
    end
    call $ensure_ret_area
    local.set $ra
    local.get 0
    local.get $ra                       ;; out_handle_ptr   (ignored)
    local.get $ra  i32.const 4  i32.add ;; out_n_preopens_ptr (ignored)
    local.get $ra  i32.const 8  i32.add ;; out_slot_addr_ptr (read below)
    call $resolve_fd
    local.tee $err
    if  local.get $err  return  end
    local.get $ra
    i32.load offset=8
    local.set $slot_addr
    local.get $slot_addr
    i32.eqz
    if
      ;; Preopen directory — not seekable.
      i32.const 70                       ;; ESPIPE
      return
    end
    local.get $slot_addr
    i64.load offset=8
    local.set $position
    ;; Compute new_pos based on whence.
    local.get 2                          ;; whence
    i32.eqz
    if
      local.get 1                        ;; SET: new_pos = offset
      local.set $new_pos
    else
      local.get 2  i32.const 1  i32.eq
      if
        local.get $position              ;; CUR: new_pos = position + offset
        local.get 1
        i64.add
        local.set $new_pos
      else
        local.get 2  i32.const 2  i32.eq
        if
          i32.const 58                   ;; END: ENOTSUP (needs stat — subphase c)
          return
        end
        i32.const 28                     ;; EINVAL — unknown whence
        return
      end
    end
    ;; Reject negative resulting positions.
    local.get $new_pos
    i64.const 0
    i64.lt_s
    if
      i32.const 28                       ;; EINVAL
      return
    end
    ;; Store new position and publish to caller.
    local.get $slot_addr
    local.get $new_pos
    i64.store offset=8
    local.get 3                          ;; newoffset_ptr
    local.get $new_pos
    i64.store
    i32.const 0)

  ;; preview1 `fd_fdstat_get(fd, statbuf_ptr) -> errno`.
  ;; Stdio (fd 0/1/2) writes a 24-byte `fdstat` reporting
  ;; `fs_filetype = character_device (2)` so Zig's stdlib and
  ;; Rust's `is_terminal()` enter their TTY / line-buffered
  ;; codepaths. Rights bits mirror the wasmtime reference
  ;; adapter's stdio branch: `FD_READ` (bit 1 → 0x02) for fd 0,
  ;; `FD_WRITE` (bit 6 → 0x40) for fd 1/2.
  ;;
  ;; Deliberate divergence from the wasmtime adapter: that adapter
  ;; calls `wasi:cli/terminal-{stdin,stdout,stderr}.get-terminal-*`
  ;; and falls back to `FILETYPE_UNKNOWN` when stdio isn't actually
  ;; a tty. We unconditionally report `character_device` to keep
  ;; this change in the "no new preview2 imports" bucket of
  ;; cataggar/wabt#179. The trade-off is that a guest redirected to
  ;; a file/pipe still believes it's writing to a tty — acceptable
  ;; for the v3 scope (CLI fixtures); revisit alongside the
  ;; terminal-* imports if a fixture surfaces the mismatch.
  ;;
  ;; preview1 fdstat layout (24 bytes, align 8):
  ;;   offset 0:  u8  fs_filetype          (= 2, character_device)
  ;;   offset 1:  pad
  ;;   offset 2:  u16 fs_flags             (= 0; no FDFLAGS for stdio)
  ;;   offset 4:  pad (4 bytes)
  ;;   offset 8:  u64 fs_rights_base       (= FD_READ / FD_WRITE)
  ;;   offset 16: u64 fs_rights_inheriting (= 0)
  ;;
  ;; fd >= 3 keeps the ENOSYS=52 stub — preview2 has
  ;; `descriptor.{get-flags, get-type}` we could lift here, but the
  ;; preview1 `fdstat` also needs `fs_rights_*` which has no
  ;; preview2 equivalent. Tracked under cataggar/wabt#179.
  (func $fd_fdstat_get (type $fd_fdstat_get_sig)
    (local $rights i64)
    local.get 0
    i32.const 3
    i32.ge_u
    if
      i32.const 52   ;; ENOSYS for non-stdio fds
      return
    end
    ;; rights: fd == 0 → FD_READ (0x02); fd ∈ {1,2} → FD_WRITE (0x40)
    local.get 0
    i32.eqz
    if (result i64)
      i64.const 0x02
    else
      i64.const 0x40
    end
    local.set $rights
    ;; Zero bytes 0..8 then overlay filetype at offset 0.
    ;; statbuf_ptr is guaranteed 8-aligned by the canon ABI
    ;; (fdstat has _Alignof == 8 in wasi-libc).
    local.get 1
    i64.const 0
    i64.store offset=0       ;; clears filetype + pad + fs_flags + pad
    local.get 1
    i32.const 2              ;; character_device
    i32.store8 offset=0      ;; overlay fs_filetype
    local.get 1
    local.get $rights
    i64.store offset=8       ;; fs_rights_base
    local.get 1
    i64.const 0
    i64.store offset=16      ;; fs_rights_inheriting
    i32.const 0)             ;; SUCCESS

  (func $fd_fdstat_set_flags (type $fd_fdstat_set_flags_sig) i32.const 52)

  ;; Helper: resolve a preview1 fd to a descriptor handle, ignoring
  ;; whether it's a preopen or a user-fd. Returns 0 on success +
  ;; writes the handle at `*out_handle_ptr`; returns EBADF on
  ;; stdio / unknown fd. Used by every fd_* mutator that doesn't
  ;; care about the slot_addr (sync, datasync, set-size, set-times,
  ;; stat). Wraps `$resolve_fd` and discards the slot pointer.
  (func $resolve_fd_handle (param $fd i32) (param $out_handle_ptr i32)
    (result i32)
    (local $ra i32) (local $err i32)
    call $ensure_ret_area
    local.set $ra
    local.get $fd
    local.get $ra                          ;; out_handle_ptr (scratch)
    local.get $ra  i32.const 4 i32.add     ;; out_n_preopens_ptr (ignored)
    local.get $ra  i32.const 8 i32.add     ;; out_slot_addr_ptr (ignored)
    call $resolve_fd
    local.tee $err
    if  local.get $err  return  end
    local.get $out_handle_ptr
    local.get $ra
    i32.load
    i32.store
    i32.const 0)

  ;; preview1 `fd_sync(fd) -> errno` →
  ;; `wasi:filesystem/types.descriptor.sync(handle) -> result<_, error-code>`.
  ;; Stdio (fd<3) returns EBADF (matches preview1 semantics — `fsync`
  ;; on a tty is a no-op success on POSIX, but wasmtime's reference
  ;; adapter doesn't bother with that nuance and neither do we).
  (func $fd_sync (type $fd_sync_sig)
    (local $ra i32) (local $err i32) (local $handle i32)
    local.get 0
    call $ensure_ret_area
    local.set $ra
    local.get $ra  i32.const 12 i32.add    ;; reserve 0..12 for $resolve_fd_handle
    call $resolve_fd_handle
    local.tee $err
    if  local.get $err  return  end
    local.get $ra  i32.const 12 i32.add
    i32.load
    local.set $handle
    local.get $handle
    local.get $ra
    call $descriptor_sync
    local.get $ra
    call $descriptor_error_only_result)

  ;; preview1 `fd_datasync(fd) -> errno` →
  ;; `descriptor.sync-data(handle) -> result<_, error-code>`. Same
  ;; shape as `$fd_sync`.
  (func $fd_datasync (type $fd_datasync_sig)
    (local $ra i32) (local $err i32) (local $handle i32)
    local.get 0
    call $ensure_ret_area
    local.set $ra
    local.get $ra  i32.const 12 i32.add
    call $resolve_fd_handle
    local.tee $err
    if  local.get $err  return  end
    local.get $ra  i32.const 12 i32.add
    i32.load
    local.set $handle
    local.get $handle
    local.get $ra
    call $descriptor_sync_data
    local.get $ra
    call $descriptor_error_only_result)

  ;; preview1 `fd_filestat_set_size(fd, size: u64) -> errno` →
  ;; `descriptor.set-size(handle, size) -> result<_, error-code>`.
  (func $fd_filestat_set_size (type $fd_filestat_set_size_sig)
    (local $ra i32) (local $err i32) (local $handle i32)
    local.get 0
    call $ensure_ret_area
    local.set $ra
    local.get $ra  i32.const 12 i32.add
    call $resolve_fd_handle
    local.tee $err
    if  local.get $err  return  end
    local.get $ra  i32.const 12 i32.add
    i32.load
    local.set $handle
    local.get $handle
    local.get 1                            ;; size (u64)
    local.get $ra
    call $descriptor_set_size
    local.get $ra
    call $descriptor_error_only_result)

  ;; Helper: project a preview1 fstflags pair (atim_bit,
  ;; atim_now_bit) + raw u64 ns timestamp into a 24-byte
  ;; `new-timestamp` flat-ABI tuple at `*out_ptr`. Layout written:
  ;;
  ;;   offset 0: u8 tag (0=no-change, 1=now, 2=timestamp)
  ;;   offset 4: u32 — only used when tag=2 (lower bits unused
  ;;                 here; canon ABI passes the variant via flat
  ;;                 params, not memory, but we use this layout
  ;;                 internally to assemble call args).
  ;;
  ;; The `set-times` / `set-times-at` host calls take the variant
  ;; flat-lowered into 3 i32/i64 slots: (tag i32, seconds i64,
  ;; nanoseconds i32). This helper writes those three slots into
  ;; the caller's local frame area (`out_ptr` is a 16-byte slab).
  ;;
  ;;   offset 0: i32 tag
  ;;   offset 4: pad (alignment)
  ;;   offset 8: i64 seconds
  ;;   offset 16: i32 nanoseconds
  ;;
  ;; Returns 0 on success, EINVAL if both `atim` and `atim_now`
  ;; bits are set (preview1 rejects this).
  (func $build_new_timestamp
    (param $bit_set i32)              ;; e.g. ATIM (0x01) or MTIM (0x04)
    (param $bit_now i32)              ;; e.g. ATIM_NOW (0x02) or MTIM_NOW (0x08)
    (param $fst_flags i32)
    (param $ns i64)
    (param $out_ptr i32)              ;; 24-byte slot
    (result i32)
    (local $set i32) (local $now i32)
    local.get $fst_flags
    local.get $bit_set
    i32.and
    i32.const 0
    i32.ne
    local.set $set
    local.get $fst_flags
    local.get $bit_now
    i32.and
    i32.const 0
    i32.ne
    local.set $now
    ;; Reject conflicting (set + now) bits.
    local.get $set
    local.get $now
    i32.and
    if
      i32.const 28                         ;; EINVAL
      return
    end
    local.get $now
    if
      ;; tag=1 (now); seconds + nanoseconds slots are unread but
      ;; flat-ABI requires them — zero for cleanliness.
      local.get $out_ptr  i32.const 1  i32.store offset=0
      local.get $out_ptr  i64.const 0  i64.store offset=8
      local.get $out_ptr  i32.const 0  i32.store offset=16
      i32.const 0
      return
    end
    local.get $set
    if
      ;; tag=2 (timestamp(datetime)); split ns into (seconds u64,
      ;; nanoseconds u32). seconds = ns / 1_000_000_000, nanoseconds
      ;; = ns % 1_000_000_000.
      local.get $out_ptr
      i32.const 2
      i32.store offset=0
      local.get $out_ptr
      local.get $ns
      i64.const 1000000000
      i64.div_u
      i64.store offset=8
      local.get $out_ptr
      local.get $ns
      i64.const 1000000000
      i64.rem_u
      i32.wrap_i64
      i32.store offset=16
      i32.const 0
      return
    end
    ;; Neither bit set → tag=0 (no-change).
    local.get $out_ptr  i32.const 0  i32.store offset=0
    local.get $out_ptr  i64.const 0  i64.store offset=8
    local.get $out_ptr  i32.const 0  i32.store offset=16
    i32.const 0)

  ;; preview1 `fd_filestat_set_times(fd, atim: u64, mtim: u64,
  ;;   fstflags: u16) -> errno` →
  ;; `descriptor.set-times(handle, atime: new-timestamp,
  ;;   mtime: new-timestamp) -> result<_, error-code>`.
  ;;
  ;; preview1 fstflags bits:
  ;;   ATIM     = 0x01 → set atim from `atim` arg
  ;;   ATIM_NOW = 0x02 → set atim to host clock
  ;;   MTIM     = 0x04 → set mtim from `mtim` arg
  ;;   MTIM_NOW = 0x08 → set mtim to host clock
  ;; Conflicting (ATIM | ATIM_NOW or MTIM | MTIM_NOW) → EINVAL.
  ;; Unset → no-change (preserve existing timestamp).
  (func $fd_filestat_set_times (type $fd_filestat_set_times_sig)
    (local $ra i32) (local $err i32) (local $handle i32)
    (local $atime_slot i32) (local $mtime_slot i32)
    local.get 0
    call $ensure_ret_area
    local.set $ra
    ;; ret-area layout:
    ;;   0..12   $resolve_fd_handle out (handle + n_preopens + slot_addr)
    ;;   16..40  atime new-timestamp slot (24 bytes)
    ;;   40..64  mtime new-timestamp slot (24 bytes)
    ;;   64..72  set-times result ret-area (8 bytes)
    local.get $ra  i32.const 12 i32.add
    call $resolve_fd_handle
    local.tee $err
    if  local.get $err  return  end
    local.get $ra  i32.const 12 i32.add
    i32.load
    local.set $handle
    local.get $ra  i32.const 16 i32.add
    local.set $atime_slot
    local.get $ra  i32.const 40 i32.add
    local.set $mtime_slot
    i32.const 0x01                         ;; ATIM
    i32.const 0x02                         ;; ATIM_NOW
    local.get 3                            ;; fstflags
    local.get 1                            ;; atim ns
    local.get $atime_slot
    call $build_new_timestamp
    local.tee $err
    if  local.get $err  return  end
    i32.const 0x04                         ;; MTIM
    i32.const 0x08                         ;; MTIM_NOW
    local.get 3                            ;; fstflags
    local.get 2                            ;; mtim ns
    local.get $mtime_slot
    call $build_new_timestamp
    local.tee $err
    if  local.get $err  return  end
    local.get $handle
    local.get $atime_slot  i32.load offset=0
    local.get $atime_slot  i64.load offset=8
    local.get $atime_slot  i32.load offset=16
    local.get $mtime_slot  i32.load offset=0
    local.get $mtime_slot  i64.load offset=8
    local.get $mtime_slot  i32.load offset=16
    local.get $ra  i32.const 64 i32.add
    call $descriptor_set_times
    local.get $ra  i32.const 64 i32.add
    call $descriptor_error_only_result)

  ;; preview1 `path_create_directory(dirfd, path_ptr, path_len)
  ;; -> errno` → `descriptor.create-directory-at(handle, path)`.
  (func $path_create_directory (type $path_only_sig)
    (local $ra i32) (local $err i32) (local $handle i32)
    local.get 0
    call $ensure_ret_area
    local.set $ra
    local.get $ra  i32.const 12 i32.add
    call $resolve_fd_handle
    local.tee $err
    if  local.get $err  return  end
    local.get $ra  i32.const 12 i32.add
    i32.load
    local.set $handle
    local.get $handle
    local.get 1
    local.get 2
    local.get $ra
    call $descriptor_create_directory_at
    local.get $ra
    call $descriptor_error_only_result)

  ;; preview1 `path_remove_directory(dirfd, path_ptr, path_len)
  ;; -> errno` → `descriptor.remove-directory-at(handle, path)`.
  (func $path_remove_directory (type $path_only_sig)
    (local $ra i32) (local $err i32) (local $handle i32)
    local.get 0
    call $ensure_ret_area
    local.set $ra
    local.get $ra  i32.const 12 i32.add
    call $resolve_fd_handle
    local.tee $err
    if  local.get $err  return  end
    local.get $ra  i32.const 12 i32.add
    i32.load
    local.set $handle
    local.get $handle
    local.get 1
    local.get 2
    local.get $ra
    call $descriptor_remove_directory_at
    local.get $ra
    call $descriptor_error_only_result)

  ;; preview1 `path_unlink_file(dirfd, path_ptr, path_len) -> errno`
  ;; → `descriptor.unlink-file-at(handle, path)`.
  (func $path_unlink_file (type $path_only_sig)
    (local $ra i32) (local $err i32) (local $handle i32)
    local.get 0
    call $ensure_ret_area
    local.set $ra
    local.get $ra  i32.const 12 i32.add
    call $resolve_fd_handle
    local.tee $err
    if  local.get $err  return  end
    local.get $ra  i32.const 12 i32.add
    i32.load
    local.set $handle
    local.get $handle
    local.get 1
    local.get 2
    local.get $ra
    call $descriptor_unlink_file_at
    local.get $ra
    call $descriptor_error_only_result)

  ;; preview1 `path_symlink(old_path_ptr, old_path_len, dirfd,
  ;;   new_path_ptr, new_path_len) -> errno` →
  ;; `descriptor.symlink-at(handle, old-path, new-path)`. Note the
  ;; preview1 arg order has `dirfd` between the two paths but the
  ;; preview2 method has both paths after `self`.
  (func $path_symlink (type $path_symlink_sig)
    (local $ra i32) (local $err i32) (local $handle i32)
    local.get 2                            ;; dirfd
    call $ensure_ret_area
    local.set $ra
    local.get $ra  i32.const 12 i32.add
    call $resolve_fd_handle
    local.tee $err
    if  local.get $err  return  end
    local.get $ra  i32.const 12 i32.add
    i32.load
    local.set $handle
    local.get $handle
    local.get 0                            ;; old_path_ptr
    local.get 1                            ;; old_path_len
    local.get 3                            ;; new_path_ptr
    local.get 4                            ;; new_path_len
    local.get $ra
    call $descriptor_symlink_at
    local.get $ra
    call $descriptor_error_only_result)

  ;; preview1 `path_rename(old_dirfd, old_path_ptr, old_path_len,
  ;;   new_dirfd, new_path_ptr, new_path_len) -> errno` →
  ;; `descriptor.rename-at(self=old_handle, old-path,
  ;;   new-descriptor=borrow<new_handle>, new-path)`. Both fds are
  ;; resolved via `$resolve_fd_handle`; the new-fd handle is passed
  ;; as a `borrow<descriptor>` (canon-lowered to the same i32
  ;; resource index).
  (func $path_rename (type $path_rename_sig)
    (local $ra i32) (local $err i32)
    (local $old_handle i32) (local $new_handle i32)
    local.get 0                            ;; old_dirfd
    call $ensure_ret_area
    local.set $ra
    local.get $ra  i32.const 12 i32.add    ;; out slot @ +12
    call $resolve_fd_handle
    local.tee $err
    if  local.get $err  return  end
    local.get $ra  i32.const 12 i32.add
    i32.load
    local.set $old_handle
    local.get 3                            ;; new_dirfd
    local.get $ra  i32.const 16 i32.add    ;; out slot @ +16
    call $resolve_fd_handle
    local.tee $err
    if  local.get $err  return  end
    local.get $ra  i32.const 16 i32.add
    i32.load
    local.set $new_handle
    local.get $old_handle
    local.get 1                            ;; old_path_ptr
    local.get 2                            ;; old_path_len
    local.get $new_handle                  ;; borrow<descriptor>
    local.get 4                            ;; new_path_ptr
    local.get 5                            ;; new_path_len
    local.get $ra
    call $descriptor_rename_at
    local.get $ra
    call $descriptor_error_only_result)

  ;; preview1 `path_link(old_dirfd, old_lookupflags, old_path_ptr,
  ;;   old_path_len, new_dirfd, new_path_ptr, new_path_len)
  ;; -> errno` → `descriptor.link-at(self=old_handle,
  ;;   old-path-flags, old-path, new-descriptor, new-path)`.
  (func $path_link (type $path_link_sig)
    (local $ra i32) (local $err i32)
    (local $old_handle i32) (local $new_handle i32)
    local.get 0
    call $ensure_ret_area
    local.set $ra
    local.get $ra  i32.const 12 i32.add
    call $resolve_fd_handle
    local.tee $err
    if  local.get $err  return  end
    local.get $ra  i32.const 12 i32.add
    i32.load
    local.set $old_handle
    local.get 4                            ;; new_dirfd
    local.get $ra  i32.const 16 i32.add
    call $resolve_fd_handle
    local.tee $err
    if  local.get $err  return  end
    local.get $ra  i32.const 16 i32.add
    i32.load
    local.set $new_handle
    local.get $old_handle
    local.get 1                            ;; old_lookupflags
    local.get 2                            ;; old_path_ptr
    local.get 3                            ;; old_path_len
    local.get $new_handle
    local.get 5                            ;; new_path_ptr
    local.get 6                            ;; new_path_len
    local.get $ra
    call $descriptor_link_at
    local.get $ra
    call $descriptor_error_only_result)

  ;; preview1 `path_filestat_set_times(dirfd, lookupflags,
  ;;   path_ptr, path_len, atim, mtim, fstflags) -> errno` →
  ;; `descriptor.set-times-at(handle, path-flags, path,
  ;;   atime: new-timestamp, mtime: new-timestamp)`.
  (func $path_filestat_set_times (type $path_filestat_set_times_sig)
    (local $ra i32) (local $err i32) (local $handle i32)
    (local $atime_slot i32) (local $mtime_slot i32)
    local.get 0
    call $ensure_ret_area
    local.set $ra
    ;; ret-area layout:
    ;;   0..12   $resolve_fd_handle out
    ;;   16..40  atime new-timestamp slot
    ;;   40..64  mtime new-timestamp slot
    ;;   64..72  set-times-at result ret-area
    local.get $ra  i32.const 12 i32.add
    call $resolve_fd_handle
    local.tee $err
    if  local.get $err  return  end
    local.get $ra  i32.const 12 i32.add
    i32.load
    local.set $handle
    local.get $ra  i32.const 16 i32.add
    local.set $atime_slot
    local.get $ra  i32.const 40 i32.add
    local.set $mtime_slot
    i32.const 0x01
    i32.const 0x02
    local.get 6                            ;; fstflags
    local.get 4                            ;; atim ns
    local.get $atime_slot
    call $build_new_timestamp
    local.tee $err
    if  local.get $err  return  end
    i32.const 0x04
    i32.const 0x08
    local.get 6
    local.get 5                            ;; mtim ns
    local.get $mtime_slot
    call $build_new_timestamp
    local.tee $err
    if  local.get $err  return  end
    local.get $handle
    local.get 1                            ;; lookupflags / path-flags
    local.get 2                            ;; path_ptr
    local.get 3                            ;; path_len
    local.get $atime_slot  i32.load offset=0
    local.get $atime_slot  i64.load offset=8
    local.get $atime_slot  i32.load offset=16
    local.get $mtime_slot  i32.load offset=0
    local.get $mtime_slot  i64.load offset=8
    local.get $mtime_slot  i32.load offset=16
    local.get $ra  i32.const 64 i32.add
    call $descriptor_set_times_at
    local.get $ra  i32.const 64 i32.add
    call $descriptor_error_only_result)

  ;; preview1 sock_* — ENOSYS=52 stubs. The adapter doesn't lift
  ;; the preview2 `wasi:sockets/*` surface (see cataggar/wabt#166's
  ;; "either resolve cleanly or are explicitly elided" branch);
  ;; declaring exports here satisfies the splicer's
  ;; `findExport(p1.name)` check for wasi-libc embeds that pull
  ;; the symbols in via the C runtime startup code, while programs
  ;; that actually `socket()` get a clean ENOSYS through wasi-libc's
  ;; `errno` fallback rather than a splice-time error.
  (func $sock_accept (type $sock_accept_sig) i32.const 52)
  (func $sock_recv (type $sock_recv_sig) i32.const 52)
  (func $sock_send (type $sock_send_sig) i32.const 52)
  (func $sock_shutdown (type $sock_shutdown_sig) i32.const 52)

  ;; Helper: convert a preview2 `descriptor-type` enum ordinal to
  ;; the closest preview1 `__wasi_filetype_t` ordinal. Mappings:
  ;;
  ;;   preview2 → preview1
  ;;   ────────────────────
  ;;   0 unknown          → 0  UNKNOWN
  ;;   1 block-device     → 1  BLOCK_DEVICE
  ;;   2 character-device → 2  CHARACTER_DEVICE
  ;;   3 directory        → 3  DIRECTORY
  ;;   4 fifo             → 6  SOCKET_STREAM (preview1 has no FIFO)
  ;;   5 symbolic-link    → 7  SYMBOLIC_LINK
  ;;   6 regular-file     → 4  REGULAR_FILE
  ;;   7 socket           → 5  SOCKET_DGRAM
  ;;   anything else      → 0  UNKNOWN (defensive)
  (func $preview1_filetype_from_descriptor_type
    (param $dt i32) (result i32)
    local.get $dt  i32.eqz                      if i32.const 0 return end
    local.get $dt  i32.const 1  i32.eq          if i32.const 1 return end
    local.get $dt  i32.const 2  i32.eq          if i32.const 2 return end
    local.get $dt  i32.const 3  i32.eq          if i32.const 3 return end
    local.get $dt  i32.const 4  i32.eq          if i32.const 6 return end
    local.get $dt  i32.const 5  i32.eq          if i32.const 7 return end
    local.get $dt  i32.const 6  i32.eq          if i32.const 4 return end
    local.get $dt  i32.const 7  i32.eq          if i32.const 5 return end
    i32.const 0)

  ;; Helper: read an `option<datetime>` slot at `$opt_ptr` (24
  ;; bytes: tag at 0, datetime{seconds u64, nanoseconds u32} at 8)
  ;; and collapse it to a u64 nanosecond count. Returns 0 when the
  ;; option is `none` (preview1 reports "no timestamp" as 0 ns).
  ;; Saturates on overflow — `seconds * 1e9 + nanoseconds` of a
  ;; well-formed datetime fits in u64 for ~584 years past epoch.
  (func $option_datetime_to_ns (param $opt_ptr i32) (result i64)
    local.get $opt_ptr
    i32.load8_u offset=0
    i32.eqz
    if  i64.const 0  return  end
    local.get $opt_ptr
    i64.load offset=8                          ;; seconds
    i64.const 1000000000
    i64.mul
    local.get $opt_ptr
    i32.load offset=16                         ;; nanoseconds
    i64.extend_i32_u
    i64.add)

  ;; Helper: project a `descriptor-stat` record (96 bytes at
  ;; `$src`) into the 64-byte preview1 `filestat` layout at `$dst`.
  ;;
  ;; preview2 descriptor-stat layout (align 8):
  ;;   offset 0:  u8  type (+7 pad)
  ;;   offset 8:  u64 link-count
  ;;   offset 16: u64 size
  ;;   offset 24: option<datetime> data-access-timestamp (24 bytes)
  ;;   offset 48: option<datetime> data-modification-timestamp (24)
  ;;   offset 72: option<datetime> status-change-timestamp (24)
  ;;
  ;; preview1 filestat layout (align 8):
  ;;   offset 0:  u64 dev (always 0)
  ;;   offset 8:  u64 ino (always 0)
  ;;   offset 16: u8  filetype + 7 pad
  ;;   offset 24: u64 nlink
  ;;   offset 32: u64 size
  ;;   offset 40: u64 atim_ns
  ;;   offset 48: u64 mtim_ns
  ;;   offset 56: u64 ctim_ns
  (func $write_preview1_filestat (param $src i32) (param $dst i32)
    local.get $dst
    i64.const 0
    i64.store offset=0                         ;; dev
    local.get $dst
    i64.const 0
    i64.store offset=8                         ;; ino
    ;; filetype (preview2 → preview1) + zero the 7 pad bytes via
    ;; an i64 store at offset 16 first.
    local.get $dst
    i64.const 0
    i64.store offset=16
    local.get $dst
    local.get $src  i32.load8_u offset=0
    call $preview1_filetype_from_descriptor_type
    i32.store8 offset=16
    local.get $dst
    local.get $src  i64.load offset=8
    i64.store offset=24                        ;; nlink
    local.get $dst
    local.get $src  i64.load offset=16
    i64.store offset=32                        ;; size
    local.get $dst
    local.get $src  i32.const 24 i32.add
    call $option_datetime_to_ns
    i64.store offset=40                        ;; atim
    local.get $dst
    local.get $src  i32.const 48 i32.add
    call $option_datetime_to_ns
    i64.store offset=48                        ;; mtim
    local.get $dst
    local.get $src  i32.const 72 i32.add
    call $option_datetime_to_ns
    i64.store offset=56)                       ;; ctim

  ;; preview1 `fd_filestat_get(fd, filestat_ptr) -> errno` →
  ;; `descriptor.stat(handle) -> result<descriptor-stat, error-code>`.
  ;; The 104-byte stat ret-area lives in the bump arena (need 104,
  ;; the 65536-byte arena easily fits).
  (func $fd_filestat_get (type $fd_filestat_get_sig)
    (local $ra i32) (local $err i32) (local $handle i32)
    (local $stat_area i32)
    local.get 0
    call $ensure_ret_area
    local.set $ra
    local.get $ra  i32.const 12 i32.add
    call $resolve_fd_handle
    local.tee $err
    if  local.get $err  return  end
    local.get $ra  i32.const 12 i32.add
    i32.load
    local.set $handle
    ;; Allocate the 104-byte stat ret-area inside the same scratch
    ;; ret-area block ($ra is 64 KiB, stat-area 16 bytes deep into
    ;; it — well clear of the 32-byte tail used by other helpers).
    local.get $ra  i32.const 32 i32.add
    local.set $stat_area
    local.get $handle
    local.get $stat_area
    call $descriptor_stat
    local.get $stat_area
    i32.load8_u offset=0
    if (result i32)
      local.get $stat_area
      i32.load8_u offset=8                     ;; payload byte 0 = error-code ordinal
      call $errno_from_error_code
    else
      ;; ok: descriptor-stat record starts at $stat_area + 8.
      local.get $stat_area  i32.const 8 i32.add
      local.get 1                              ;; preview1 filestat_ptr
      call $write_preview1_filestat
      i32.const 0
    end)

  ;; preview1 `path_filestat_get(dirfd, lookupflags, path_ptr,
  ;;   path_len, filestat_ptr) -> errno` →
  ;; `descriptor.stat-at(handle, path-flags, path)`.
  (func $path_filestat_get (type $path_filestat_get_sig)
    (local $ra i32) (local $err i32) (local $handle i32)
    (local $stat_area i32)
    local.get 0
    call $ensure_ret_area
    local.set $ra
    local.get $ra  i32.const 12 i32.add
    call $resolve_fd_handle
    local.tee $err
    if  local.get $err  return  end
    local.get $ra  i32.const 12 i32.add
    i32.load
    local.set $handle
    local.get $ra  i32.const 32 i32.add
    local.set $stat_area
    local.get $handle
    local.get 1                                ;; lookupflags
    local.get 2                                ;; path_ptr
    local.get 3                                ;; path_len
    local.get $stat_area
    call $descriptor_stat_at
    local.get $stat_area
    i32.load8_u offset=0
    if (result i32)
      local.get $stat_area
      i32.load8_u offset=8
      call $errno_from_error_code
    else
      local.get $stat_area  i32.const 8 i32.add
      local.get 4                              ;; preview1 filestat_ptr
      call $write_preview1_filestat
      i32.const 0
    end)

  ;; preview1 `fd_readdir(fd, buf, buf_len, cookie, used_ptr)
  ;; -> errno`.
  ;;
  ;; Strategy: open a fresh `directory-entry-stream` via
  ;; `descriptor.read-directory(handle)`, pump
  ;; `read-directory-entry()` in a loop and pack each entry
  ;; (24-byte preview1 dirent + name bytes) into the caller's buf
  ;; until the next entry would no longer fit OR the stream
  ;; returns `option::none` (end-of-stream). Drop the stream.
  ;;
  ;; The input `cookie` is ignored — preview2's stream cursor isn't
  ;; resumable, so we restart from the beginning every call. wasi-
  ;; libc handles this by re-reading the whole listing on each
  ;; `readdir(3)`-batch, which is acceptable for v1 (wasmtime's
  ;; reference adapter behaves identically).
  ;;
  ;; preview1 dirent layout (24 bytes, align 8):
  ;;   offset 0:  u64 d_next   (cookie — adapter writes 1-based
  ;;                            counter so wasi-libc's resume
  ;;                            heuristic sees monotonic values)
  ;;   offset 8:  u64 d_ino    (always 0 — preview2 hides ino)
  ;;   offset 16: u32 d_namlen
  ;;   offset 20: u8  d_type   (preview1 filetype)
  ;;   offset 21..24: pad
  ;;
  ;; read-directory-entry ret-area (20 bytes): outer tag (u8 + 3
  ;; pad) at 0, payload at 4. Payload for ok is option<directory-
  ;; entry>: option_tag at 4 (u8 + 3 pad), directory-entry at 8
  ;; (12 bytes: type u8 at 8 + 3 pad, name string ptr at 12, name
  ;; string len at 16). Payload for err is error-code at 4.
  (func $fd_readdir (type $fd_readdir_sig)
    (local $ra i32) (local $err i32) (local $handle i32)
    (local $stream i32) (local $stream_ra i32)
    (local $cur i32) (local $end i32) (local $cookie i64)
    (local $name_ptr i32) (local $name_len i32) (local $needed i32)
    (local $dt i32)
    local.get 0
    call $ensure_ret_area
    local.set $ra
    local.get $ra  i32.const 12 i32.add
    call $resolve_fd_handle
    local.tee $err
    if  local.get $err  return  end
    local.get $ra  i32.const 12 i32.add
    i32.load
    local.set $handle
    local.get 1
    local.set $cur
    local.get 1
    local.get 2
    i32.add
    local.set $end
    ;; Open the directory-entry-stream. Reuse the bump arena ret-
    ;; area at $ra (8 bytes for read-directory, 20 bytes for each
    ;; subsequent read-directory-entry).
    local.get $handle
    local.get $ra
    call $descriptor_read_directory
    local.get $ra
    i32.load8_u offset=0
    if
      ;; Open failed → publish 0 used + return mapped errno.
      local.get 4
      i32.const 0
      i32.store
      local.get $ra
      i32.load offset=4
      call $errno_from_error_code
      return
    end
    local.get $ra
    i32.load offset=4
    local.set $stream
    ;; Use a separate slot for read-directory-entry's ret-area so
    ;; the read-directory result above stays valid for debugging.
    local.get $ra  i32.const 16 i32.add
    local.set $stream_ra
    i64.const 1
    local.set $cookie
    block $stop
      loop $next
        ;; Install one-shot import-alloc for the directory-entry's
        ;; `string name` so the canon-lifted bytes land directly in
        ;; the bump arena (mode 2 = count). Reset the arena cursor
        ;; per iteration so each entry's name has dedicated space.
        i32.const 0  global.set $arena_cur
        i32.const 0  global.set $strings_sz
        i32.const 2  global.set $import_alloc_mode
        local.get $stream
        local.get $stream_ra
        call $directory_entry_stream_read
        i32.const 0  global.set $import_alloc_mode
        local.get $stream_ra
        i32.load8_u offset=0
        if
          ;; Outer err: stop iteration, drop the stream, return
          ;; mapped errno (with bytes already published).
          local.get 4
          local.get $cur
          local.get 1
          i32.sub
          i32.store
          local.get $stream
          call $directory_entry_stream_drop
          local.get $stream_ra
          i32.load offset=4
          call $errno_from_error_code
          return
        end
        ;; Inner option: tag at +4. 0 = none → end-of-stream.
        local.get $stream_ra
        i32.load8_u offset=4
        i32.eqz
        if  br $stop  end
        ;; some(directory-entry): %type at +8, name string at +12.
        local.get $stream_ra
        i32.load8_u offset=8
        local.set $dt
        local.get $stream_ra
        i32.load offset=12
        local.set $name_ptr
        local.get $stream_ra
        i32.load offset=16
        local.set $name_len
        ;; needed = 24 (dirent header) + name_len
        local.get $name_len
        i32.const 24
        i32.add
        local.set $needed
        ;; If we don't have room for the next dirent header, stop
        ;; iterating. Note we DO write a header even if the name
        ;; bytes are truncated — wasi-libc's `readdir(3)` treats
        ;; (used < buf_len) as end-of-batch and re-issues with the
        ;; cookie advanced.
        local.get $end
        local.get $cur
        i32.sub
        i32.const 24
        i32.lt_u
        if  br $stop  end
        ;; Write the dirent header.
        local.get $cur  local.get $cookie  i64.store offset=0
        local.get $cur  i64.const 0  i64.store offset=8        ;; ino
        local.get $cur  local.get $name_len  i32.store offset=16
        local.get $cur
        local.get $dt
        call $preview1_filetype_from_descriptor_type
        i32.store8 offset=20
        ;; Pad bytes 21..24 are uninitialised — wasi-libc ignores.
        local.get $cur  i32.const 24  i32.add
        local.set $cur
        ;; Copy the name (bounded by the remaining buf space).
        block $name_done
          local.get $name_len
          i32.eqz
          br_if $name_done
          local.get $end
          local.get $cur
          i32.sub
          local.tee $needed                    ;; reuse $needed for "remaining"
          local.get $name_len
          i32.lt_u
          if
            ;; Truncated name: copy what fits then stop.
            local.get $cur
            local.get $name_ptr
            local.get $needed
            memory.copy
            local.get $cur
            local.get $needed
            i32.add
            local.set $cur
            br $stop
          end
          local.get $cur
          local.get $name_ptr
          local.get $name_len
          memory.copy
          local.get $cur
          local.get $name_len
          i32.add
          local.set $cur
        end
        local.get $cookie
        i64.const 1
        i64.add
        local.set $cookie
        br $next
      end
    end
    ;; Stream exhausted (or buf full mid-iteration).
    local.get $stream
    call $directory_entry_stream_drop
    i32.const 0  global.set $arena_cur
    i32.const 0  global.set $strings_sz
    local.get 4
    local.get $cur
    local.get 1
    i32.sub
    i32.store
    i32.const 0)

  ;; preview1 `fd_prestat_get(fd, prestat_ptr) -> errno`.
  ;;
  ;; wasi-libc walks preopens at startup by calling
  ;; `fd_prestat_get(fd)` for `fd = 3, 4, 5, …` until it returns
  ;; `EBADF`. Each call lifts the full preopens list from the host
  ;; via `wasi:filesystem/preopens.get-directories` into the bump
  ;; arena (mode 2), looks up the `idx = fd - 3` entry, writes the
  ;; preview1 `prestat` record, then resets the arena. No
  ;; permanent allocation; each call is stateless.
  ;;
  ;; preview1 `prestat` layout (8 bytes, align 4):
  ;;   offset 0: u8  tag (0 = PREOPENTYPE_DIR)
  ;;   offset 1..3: pad
  ;;   offset 4: u32 pr_name_len
  ;;
  ;; We `i32.store offset=0` a single zero to cover the tag + 3
  ;; pad bytes in one write — `PREOPENTYPE_DIR` is 0.
  ;;
  ;; fd < 3 (stdio) returns `EBADF`; fd >= 3 + n_preopens also
  ;; returns `EBADF`, matching wasmtime's reference adapter.
  (func $fd_prestat_get (type $fd_prestat_get_sig)
    (local $ra i32) (local $idx i32) (local $list_ptr i32)
    (local $list_len i32) (local $entry i32) (local $name_len i32)
    local.get 0
    i32.const 3
    i32.sub
    local.tee $idx
    i32.const 0
    i32.lt_s
    if
      i32.const 8                ;; EBADF for stdio
      return
    end
    ;; mode 2 (count) — the canon list backing + each per-name
    ;; alloc land in the bump arena; nothing reaches the embed's
    ;; heap.
    i32.const 0  global.set $arena_cur
    i32.const 0  global.set $strings_sz
    i32.const 2  global.set $import_alloc_mode
    call $ensure_ret_area
    local.tee $ra
    call $get_directories
    i32.const 0  global.set $import_alloc_mode
    local.get $ra
    i32.load offset=0
    local.set $list_ptr
    local.get $ra
    i32.load offset=4
    local.set $list_len
    local.get $idx
    local.get $list_len
    i32.ge_u
    if
      i32.const 0  global.set $arena_cur
      i32.const 0  global.set $strings_sz
      i32.const 8                ;; EBADF — past the last preopen
      return
    end
    ;; entry = list_ptr + idx * 12 (tuple stride is 12 bytes:
    ;; descriptor handle i32, name_ptr i32, name_len i32)
    local.get $list_ptr
    local.get $idx
    i32.const 12
    i32.mul
    i32.add
    local.tee $entry
    i32.load offset=8
    local.set $name_len
    ;; Write prestat at prestat_ptr.
    local.get 1
    i32.const 0                  ;; tag + 3 pad bytes
    i32.store offset=0
    local.get 1
    local.get $name_len
    i32.store offset=4
    ;; Cleanup.
    i32.const 0  global.set $arena_cur
    i32.const 0  global.set $strings_sz
    i32.const 0)

  ;; preview1 `fd_prestat_dir_name(fd, buf, buf_len) -> errno`.
  ;; Same lift + lookup as `$fd_prestat_get`; instead of writing a
  ;; prestat record we `memory.copy` up to `buf_len` bytes of the
  ;; preopen's name into the caller's buffer. `buf_len` ≥ name_len
  ;; is the normal wasi-libc flow (the caller sized the buffer from
  ;; the preceding `fd_prestat_get`); we clamp defensively.
  (func $fd_prestat_dir_name (type $fd_prestat_dir_name_sig)
    (local $ra i32) (local $idx i32) (local $list_ptr i32)
    (local $list_len i32) (local $entry i32)
    (local $name_ptr i32) (local $name_len i32) (local $copy_len i32)
    local.get 0
    i32.const 3
    i32.sub
    local.tee $idx
    i32.const 0
    i32.lt_s
    if
      i32.const 8
      return
    end
    i32.const 0  global.set $arena_cur
    i32.const 0  global.set $strings_sz
    i32.const 2  global.set $import_alloc_mode
    call $ensure_ret_area
    local.tee $ra
    call $get_directories
    i32.const 0  global.set $import_alloc_mode
    local.get $ra
    i32.load offset=0
    local.set $list_ptr
    local.get $ra
    i32.load offset=4
    local.set $list_len
    local.get $idx
    local.get $list_len
    i32.ge_u
    if
      i32.const 0  global.set $arena_cur
      i32.const 0  global.set $strings_sz
      i32.const 8
      return
    end
    local.get $list_ptr
    local.get $idx
    i32.const 12
    i32.mul
    i32.add
    local.tee $entry
    i32.load offset=4
    local.set $name_ptr
    local.get $entry
    i32.load offset=8
    local.set $name_len
    ;; copy_len = min(buf_len, name_len)
    local.get 2
    local.get $name_len
    i32.lt_u
    if (result i32)
      local.get 2
    else
      local.get $name_len
    end
    local.set $copy_len
    local.get 1                  ;; buf
    local.get $name_ptr
    local.get $copy_len
    memory.copy
    i32.const 0  global.set $arena_cur
    i32.const 0  global.set $strings_sz
    i32.const 0)

  ;; ── args / environ ───────────────────────────────────────────
  ;;
  ;; All four preview1 entry points lower against
  ;; `wasi:cli/environment.{get-arguments, get-environment}` via the
  ;; `count` / `separate` modes of the `$cabi_import_realloc` state
  ;; machine (see the `$import_alloc_*` globals near the top of the
  ;; module). Each preview1 body sets up the right mode, calls the
  ;; host once, then resets the state machine — no main-heap
  ;; allocations are made on this path and the bump arena (32..65536
  ;; in $ret_area) is reused across calls.
  ;;
  ;; Layout:
  ;;
  ;;   args_sizes_get  : mode 2 (count)    — sums args byte sizes.
  ;;   args_get        : mode 3 (separate) — routes strings into argv_buf.
  ;;   environ_sizes_get : mode 2          — sums (key + value) bytes.
  ;;   environ_get     : mode 3            — routes key/value into env_buf.

  ;; preview1 `args_sizes_get(argc_ptr, argv_buf_size_ptr) -> errno`.
  ;; Invokes the host once in `count` mode; the host's per-string
  ;; canon-realloc calls accumulate into `$strings_sz`. We then
  ;; publish list_len at argc_ptr and `strings_sz + list_len` at
  ;; argv_buf_size_ptr — the `+ list_len` accounts for one NUL
  ;; terminator per arg, matching wasi-libc's expected layout.
  (func $args_sizes_get (type $args_sizes_get_sig)
    (local $ra i32) (local $list_len i32)
    i32.const 0  global.set $arena_cur
    i32.const 0  global.set $strings_sz
    i32.const 2  global.set $import_alloc_mode
    call $ensure_ret_area
    local.tee $ra
    call $get_arguments
    i32.const 0  global.set $import_alloc_mode
    local.get $ra
    i32.load offset=4
    local.set $list_len
    local.get 0                    ;; argc_ptr
    local.get $list_len
    i32.store
    local.get 1                    ;; argv_buf_size_ptr
    global.get $strings_sz
    local.get $list_len
    i32.add
    i32.store
    ;; clean up
    i32.const 0  global.set $arena_cur
    i32.const 0  global.set $strings_sz
    i32.const 0)

  ;; preview1 `args_get(argv_ptr_array, argv_buf) -> errno`.
  ;; Invokes the host once in `separate` mode so each string the
  ;; host allocates lands directly inside argv_buf (one byte gap
  ;; after each for the NUL terminator). After the call, walk the
  ;; canon-lifted list (in the bump arena) and:
  ;;   * argv_ptr_array[i] = entry.string_ptr  (already in argv_buf)
  ;;   * *(entry.string_ptr + entry.string_len) = 0  (NUL terminator)
  (func $args_get (type $args_get_sig)
    (local $ra i32) (local $list_ptr i32) (local $list_len i32)
    (local $i i32) (local $entry i32)
    (local $sp i32) (local $sl i32)
    i32.const 0  global.set $arena_cur
    i32.const 0  global.set $strings_cur
    local.get 1  global.set $strings_dst        ;; argv_buf
    i32.const 3  global.set $import_alloc_mode
    call $ensure_ret_area
    local.tee $ra
    call $get_arguments
    i32.const 0  global.set $import_alloc_mode
    local.get $ra
    i32.load offset=0
    local.set $list_ptr
    local.get $ra
    i32.load offset=4
    local.set $list_len
    i32.const 0  local.set $i
    block $done
      loop $next
        local.get $i
        local.get $list_len
        i32.ge_u  br_if $done
        ;; entry = list_ptr + i*8
        local.get $list_ptr
        local.get $i
        i32.const 3
        i32.shl
        i32.add
        local.tee $entry
        i32.load offset=0
        local.set $sp
        local.get $entry
        i32.load offset=4
        local.set $sl
        ;; argv[i] = sp
        local.get 0
        local.get $i
        i32.const 2
        i32.shl
        i32.add
        local.get $sp
        i32.store
        ;; *(sp + sl) = 0
        local.get $sp
        local.get $sl
        i32.add
        i32.const 0
        i32.store8
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $next
      end
    end
    ;; clean up
    i32.const 0  global.set $arena_cur
    i32.const 0  global.set $strings_cur
    i32.const 0  global.set $strings_dst
    i32.const 0)

  ;; preview1 `environ_sizes_get(envc_ptr, env_buf_size_ptr) -> errno`.
  ;; Same `count` mode as args_sizes_get, but each entry has two
  ;; align=1 string allocs (key + value). Publishes list_len at
  ;; envc_ptr and `strings_sz + 2 * list_len` at env_buf_size_ptr
  ;; — `+ 2 * list_len` for the `=` and `\0` per entry.
  (func $environ_sizes_get (type $environ_sizes_get_sig)
    (local $ra i32) (local $list_len i32)
    i32.const 0  global.set $arena_cur
    i32.const 0  global.set $strings_sz
    i32.const 2  global.set $import_alloc_mode
    call $ensure_ret_area
    local.tee $ra
    call $get_environment
    i32.const 0  global.set $import_alloc_mode
    local.get $ra
    i32.load offset=4
    local.set $list_len
    local.get 0                    ;; envc_ptr
    local.get $list_len
    i32.store
    local.get 1                    ;; env_buf_size_ptr
    global.get $strings_sz
    local.get $list_len
    i32.const 1
    i32.shl                        ;; * 2
    i32.add
    i32.store
    i32.const 0  global.set $arena_cur
    i32.const 0  global.set $strings_sz
    i32.const 0)

  ;; preview1 `environ_get(envp_ptr_array, env_buf) -> errno`.
  ;; `separate` mode routes key+value strings into env_buf (each
  ;; over-allocated by 1 byte). After the call, walk the canon
  ;; list (16-byte stride: key_ptr, key_len, val_ptr, val_len) and:
  ;;   * envp_ptr_array[i] = key_ptr
  ;;   * *(key_ptr + key_len) = '='
  ;;   * *(val_ptr + val_len) = 0
  ;; The byte after the key was over-allocated and currently
  ;; precedes val_ptr by exactly one position, so writing '=' there
  ;; preserves preview1's `key=value\0` layout.
  (func $environ_get (type $environ_get_sig)
    (local $ra i32) (local $list_ptr i32) (local $list_len i32)
    (local $i i32) (local $entry i32)
    (local $kp i32) (local $kl i32) (local $vp i32) (local $vl i32)
    i32.const 0  global.set $arena_cur
    i32.const 0  global.set $strings_cur
    local.get 1  global.set $strings_dst        ;; env_buf
    i32.const 3  global.set $import_alloc_mode
    call $ensure_ret_area
    local.tee $ra
    call $get_environment
    i32.const 0  global.set $import_alloc_mode
    local.get $ra
    i32.load offset=0
    local.set $list_ptr
    local.get $ra
    i32.load offset=4
    local.set $list_len
    i32.const 0  local.set $i
    block $done
      loop $next
        local.get $i
        local.get $list_len
        i32.ge_u  br_if $done
        ;; entry = list_ptr + i*16
        local.get $list_ptr
        local.get $i
        i32.const 4
        i32.shl
        i32.add
        local.tee $entry
        i32.load offset=0   local.set $kp
        local.get $entry
        i32.load offset=4   local.set $kl
        local.get $entry
        i32.load offset=8   local.set $vp
        local.get $entry
        i32.load offset=12  local.set $vl
        ;; envp[i] = kp
        local.get 0
        local.get $i
        i32.const 2
        i32.shl
        i32.add
        local.get $kp
        i32.store
        ;; *(kp + kl) = '='
        local.get $kp
        local.get $kl
        i32.add
        i32.const 61                ;; '=' = 0x3D = 61
        i32.store8
        ;; *(vp + vl) = '\0'
        local.get $vp
        local.get $vl
        i32.add
        i32.const 0
        i32.store8
        local.get $i
        i32.const 1
        i32.add
        local.set $i
        br $next
      end
    end
    i32.const 0  global.set $arena_cur
    i32.const 0  global.set $strings_cur
    i32.const 0  global.set $strings_dst
    i32.const 0)

  ;; ── clocks / random ──────────────────────────────────────────

  ;; Helper: collapse a wall-clock `datetime { seconds: u64,
  ;; nanoseconds: u32 }` into a u64 nanosecond count, storing the
  ;; result at `*out_ptr` on success.
  ;;
  ;; Returns errno on the data stack:
  ;;   0  → `*out_ptr` holds `s * 1_000_000_000 + ns_u32`.
  ;;   61 → overflow; `*out_ptr` is untouched. (EOVERFLOW; matches
  ;;        the wasmtime reference adapter.)
  ;;
  ;; Overflow happens when `seconds > floor(u64::MAX / 1e9) =
  ;; 18_446_744_073` (year ~2554-AD), or when the final add of `ns`
  ;; would wrap u64. The helper writes a single u64 via the
  ;; `out_ptr` param to keep the function signature single-result
  ;; — the wabt validator currently rejects multi-result function
  ;; types, though it accepts multi-result block types fine.
  (func $datetime_to_ns
    (param $s i64) (param $ns_u32 i32) (param $out_ptr i32)
    (result i32)
    (local $s_e9 i64) (local $total i64)
    local.get $s
    i64.const 18446744073   ;; floor(u64::MAX / 1_000_000_000)
    i64.gt_u
    if
      i32.const 61          ;; EOVERFLOW
      return
    end
    local.get $s
    i64.const 1000000000
    i64.mul
    local.tee $s_e9
    local.get $ns_u32
    i64.extend_i32_u
    i64.add
    local.tee $total
    local.get $s_e9
    i64.lt_u                ;; total < s_e9 → unsigned add wrapped
    if
      i32.const 61
      return
    end
    local.get $out_ptr
    local.get $total
    i64.store
    i32.const 0)

  ;; preview1 `clock_time_get(clockid, precision, time_ptr) -> errno`.
  ;; Dispatch on clockid:
  ;;   REALTIME (0)  → `wasi:clocks/wall-clock.now()` → datetime →
  ;;                   collapse `s*1e9 + ns` into u64 ns → store.
  ;;   MONOTONIC (1) → `wasi:clocks/monotonic-clock.now()` → u64 →
  ;;                   store directly (already in nanoseconds).
  ;;   2, 3, other   → `EBADF=8`. PROCESS_CPUTIME / THREAD_CPUTIME
  ;;                   have no preview2 equivalent in 0.2.6. We
  ;;                   follow the wasmtime reference adapter
  ;;                   (`crates/wasi-preview1-component-adapter/
  ;;                   src/lib.rs:clock_time_get` returns `ERRNO_BADF`
  ;;                   for unknown clockids) rather than POSIX's
  ;;                   `EINVAL` so wasi-libc / language stdlibs see
  ;;                   the same errno they've been tested against.
  ;;
  ;; `precision` is ignored — advisory; wasmtime and wasi-libc both
  ;; treat it as informational only.
  ;;
  ;; Overflow: if `s*1e9 + ns` exceeds u64 (year ~2554-AD), returns
  ;; `EOVERFLOW=61`, matching wasmtime's `ERRNO_OVERFLOW` branch.
  (func $clock_time_get (type $clock_time_get_sig)
    (local $ra i32)
    ;; MONOTONIC (1) → direct u64 nanoseconds.
    local.get 0
    i32.const 1
    i32.eq
    if
      local.get 2          ;; time_ptr
      call $monotonic_now
      i64.store
      i32.const 0
      return
    end
    ;; REALTIME (0) → datetime → ns conversion.
    local.get 0
    i32.eqz
    if
      call $ensure_ret_area
      local.tee $ra
      call $wall_now
      local.get $ra
      i64.load offset=0    ;; seconds
      local.get $ra
      i32.load offset=8    ;; nanoseconds (u32)
      local.get 2          ;; time_ptr (out)
      call $datetime_to_ns
      return               ;; 0 on success, 61 on overflow
    end
    ;; PROCESS_CPUTIME (2), THREAD_CPUTIME (3), or unknown.
    i32.const 8)           ;; EBADF

  ;; preview1 `clock_res_get(clockid, res_ptr) -> errno`. Same
  ;; dispatch as `$clock_time_get` but calls the preview2 host's
  ;; `resolution()` flavours instead of `now()`.
  (func $clock_res_get (type $clock_res_get_sig)
    (local $ra i32)
    local.get 0
    i32.const 1
    i32.eq
    if
      local.get 1          ;; res_ptr
      call $monotonic_resolution
      i64.store
      i32.const 0
      return
    end
    local.get 0
    i32.eqz
    if
      call $ensure_ret_area
      local.tee $ra
      call $wall_resolution
      local.get $ra
      i64.load offset=0
      local.get $ra
      i32.load offset=8
      local.get 1          ;; res_ptr (out)
      call $datetime_to_ns
      return
    end
    i32.const 8)           ;; EBADF

  ;; preview1 `random_get(buf, len) -> errno`.
  ;;
  ;; Canon-lowers `wasi:random/random.get-random-bytes(len) ->
  ;; list<u8>` against the caller's `buf` via the import-alloc
  ;; state machine's one-shot mode (mode 1). The host's
  ;; canon-lift'd binding allocates the `list<u8>` backing buffer
  ;; by calling our `$cabi_import_realloc`; with mode=1 and
  ;; `$oneshot_ptr = buf`, that call returns `buf` directly and
  ;; clears the slot, so the random bytes land where preview1
  ;; wants them with no extra memcpy and no leaked allocation.
  ;;
  ;; The returned `(ptr, len)` pair in the ret-area is therefore
  ;; redundant — `ptr == buf` and `len == requested_len` by
  ;; construction — so we don't even read it.
  ;;
  ;; len == 0 fast-paths to SUCCESS without invoking the host;
  ;; some preview2 hosts trap on zero-length allocations.
  (func $random_get (type $random_get_sig)
    (local $ra i32)
    local.get 1
    i32.eqz
    if
      i32.const 0
      return
    end
    ;; Arm one-shot mode: the next call into $cabi_import_realloc
    ;; returns $oneshot_ptr and clears the slot + mode.
    local.get 0
    global.set $oneshot_ptr
    i32.const 1
    global.set $import_alloc_mode
    ;; Return-area for the canon-lifted `(ptr, len)` tuple; we
    ;; ignore the stored values after the call.
    call $ensure_ret_area
    local.set $ra
    ;; get-random-bytes(len: u64, ret_area: i32)
    local.get 1
    i64.extend_i32_u
    local.get $ra
    call $get_random_bytes
    ;; Defensive cleanup: if the host somehow didn't consume the
    ;; override (e.g. canon ABI changed under us), force-clear it
    ;; so the next preview2 call doesn't observe stale state.
    i32.const 0
    global.set $import_alloc_mode
    i32.const 0
    global.set $oneshot_ptr
    i32.const 0)
