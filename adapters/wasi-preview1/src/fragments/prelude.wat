;; ── wasi:cli@0.2.x preview1 → preview2 adapter ──────────────────────────
;;
;; Hand-authored WAT for the wabt-native preview1 adapter (tracks
;; cataggar/wamr#453). Shape mirrors the wasmtime
;; `wasi_snapshot_preview1.command.wasm` adapter (see
;; ../README.md for the side-by-side dissection) with one
;; deliberate divergence: `proc_exit` lowers through
;; `wasi:cli/exit.exit-with-code(u8)` rather than the lossy
;; `wasi:cli/exit.exit(result)`. That preserves the numeric exit
;; code end-to-end and lets wamr drop the `exit_code_sink`
;; workaround added in #447/#448.
;;
;; Status: full preview1 surface wired through the v3 scope
;; (cataggar/wabt#165 read-side + #166 write-side / sockets /
;; remaining filestat-readdir leftovers). What's wired:
;;
;;   * `proc_exit` — `wasi:cli/exit.exit-with-code(u8)` with a
;;     stable-`exit(result)` fallback;
;;   * `sched_yield` — trivial success;
;;   * `proc_raise` — ENOSYS (no preview2 equivalent; advisory);
;;   * `fd_write` — stdio (fd 1/2) routes through cached
;;     `wasi:cli/{stdout,stderr}.get-{stdout,stderr}` handles +
;;     `[method]output-stream.blocking-write-and-flush`. User-fds
;;     (fd ≥ 3) open a fresh `output-stream` via
;;     `descriptor.write-via-stream(position)`, stream every iovec,
;;     drop the stream, and advance the per-fd tracked position.
;;   * `fd_pwrite` — same as user-fd `fd_write` but with explicit
;;     `offset` arg; does NOT advance the tracked position.
;;     Stdio → ESPIPE, preopens → EBADF.
;;   * `fd_read` — for user-opened files, opens a fresh
;;     `descriptor.read-via-stream(position)` and routes the
;;     canon-lifted `list<u8>` from `input-stream.blocking-read`
;;     directly into the caller's iov buffer via the one-shot
;;     import-alloc override (mode 1). Stdio currently → EBADF.
;;   * `fd_close` — for stdio + preopens, no-op (matches wasmtime);
;;     for user-opened fds, drops the descriptor handle via
;;     `[resource-drop]descriptor` and frees the slot.
;;   * `fd_seek` (user fds) — SET/CUR update the adapter-tracked
;;     position in-place (no host call). END returns `ENOTSUP`
;;     pending `descriptor.stat`-based size lookup. Stdio still
;;     returns ESPIPE per the original wasmtime behaviour.
;;   * `fd_sync` / `fd_datasync` — pass-through to
;;     `descriptor.sync` / `descriptor.sync-data`.
;;   * `fd_fdstat_get` (stdio only) — fills a 24-byte preview1
;;     `fdstat` with `fs_filetype = character_device` and the
;;     matching `FD_READ` / `FD_WRITE` rights so Zig's stdlib and
;;     Rust's `is_terminal()` enter their TTY codepaths. fd ≥ 3 is
;;     ENOSYS (deferred — needs `descriptor.get-flags` +
;;     `.get-type`).
;;   * `fd_filestat_get` / `path_filestat_get` — call
;;     `descriptor.stat` / `.stat-at`, project the returned
;;     `descriptor-stat` (with optional<datetime> timestamps) into
;;     the 64-byte preview1 `filestat` layout. dev / ino are 0
;;     (preview2 hides them); option::none timestamps → 0 ns.
;;   * `fd_filestat_set_size` — pass-through to `descriptor.set-size`.
;;   * `fd_filestat_set_times` / `path_filestat_set_times` —
;;     translate preview1 fstflags bits + raw u64 ns timestamps
;;     into 2 × `new-timestamp` variant args; conflicting
;;     (ATIM | ATIM_NOW) → EINVAL.
;;   * `fd_readdir` — opens a fresh
;;     `directory-entry-stream` per call, pumps
;;     `read-directory-entry()` packing each entry into the caller's
;;     buf, drops the stream. Cookie ignored (re-reads from start
;;     each call, matching the wasmtime reference adapter for
;;     non-resumable preview2 streams).
;;   * `path_open` — resolves the dirfd to a preview2 descriptor,
;;     translates preview1 `dirflags` / `oflags` / `fdflags` /
;;     `fs_rights_base` into the preview2 `path-flags` /
;;     `open-flags` / `descriptor-flags` triple, calls
;;     `wasi:filesystem/types.descriptor.open-at`, allocates a slot
;;     in the user-fd descriptor table for the new handle.
;;   * `path_create_directory` / `path_remove_directory` /
;;     `path_unlink_file` — single-string mutations, pass-through
;;     to `descriptor.{create,remove}-directory-at` /
;;     `descriptor.unlink-file-at`.
;;   * `path_symlink` / `path_rename` / `path_link` — multi-arg
;;     mutations; `rename-at` and `link-at` resolve both fds to
;;     descriptor handles and pass the new-fd as
;;     `borrow<descriptor>`.
;;   * `random_get` — canon-lowers `wasi:random/random.get-random-
;;     bytes` against the caller's `buf` via a one-shot
;;     `cabi_import_realloc` override so the host writes random
;;     bytes directly into preview1 memory (zero copy).
;;   * `clock_time_get` / `clock_res_get` — REALTIME (0) routes
;;     through `wasi:clocks/wall-clock.{now,resolution}` (datetime
;;     record → u64 ns with overflow check), MONOTONIC (1) routes
;;     through `wasi:clocks/monotonic-clock.{now,resolution}`
;;     (already u64 ns), PROCESS/THREAD CPUTIME + unknown clockids
;;     return `EBADF` (matching wasmtime).
;;   * `args_get` / `args_sizes_get` / `environ_get` /
;;     `environ_sizes_get` — canon-lower
;;     `wasi:cli/environment.{get-arguments, get-environment}`
;;     through a `count` / `separate` bump-arena state machine so
;;     the host writes strings directly into the caller's preview1
;;     argv_buf / env_buf (no main-heap allocation for any of these
;;     paths).
;;   * `fd_prestat_get` / `fd_prestat_dir_name` — lifts
;;     `wasi:filesystem/preopens.get-directories` once per call into
;;     the bump arena (no permanent cache) and reads the i-th
;;     preopen out for `wasi-libc`'s startup walk.
;;   * `sock_accept` / `sock_recv` / `sock_send` / `sock_shutdown`
;;     — exported as ENOSYS=52 stubs so wasi-libc embeds that pull
;;     these in via the C runtime startup splice cleanly. Programs
;;     that actually call socket(2) get a well-defined errno
;;     (deferred preview2 sockets → cataggar/wabt#178).
;;
;; Declared preview2 imports the adapter consumes:
;;
;;   * `wasi:cli/exit@0.2.6` — `exit-with-code(u8)` + `exit(result)`;
;;   * `wasi:cli/stdout@0.2.6` / `wasi:cli/stderr@0.2.6` — handle
;;     factories for stdout / stderr;
;;   * `wasi:cli/environment@0.2.6` — `get-arguments` +
;;     `get-environment`;
;;   * `wasi:io/streams@0.2.6` — `[method]output-stream.blocking-
;;     write-and-flush`, `[method]input-stream.blocking-read`,
;;     `[resource-drop]{output,input}-stream`;
;;   * `wasi:io/error@0.2.6` — the resource the streams interface's
;;     `stream-error.last-operation-failed(own<error>)` payload
;;     references;
;;   * `wasi:random/random@0.2.6.get-random-bytes` — backing for the
;;     preview1 `random_get` import;
;;   * `wasi:clocks/wall-clock@0.2.6.{now, resolution}` +
;;     `wasi:clocks/monotonic-clock@0.2.6.{now, resolution}` —
;;     backing for the preview1 `clock_*_get` imports;
;;   * `wasi:filesystem/preopens@0.2.6.get-directories` — backing
;;     for `fd_prestat_*` and dirfd resolution in every path_* /
;;     fd_* call;
;;   * `wasi:filesystem/types@0.2.6.[method]descriptor.{open-at,
;;     read-via-stream, write-via-stream, append-via-stream,
;;     set-size, set-times, set-times-at, stat, stat-at,
;;     create-directory-at, remove-directory-at, unlink-file-at,
;;     symlink-at, rename-at, link-at, sync, sync-data,
;;     read-directory}`, `[resource-drop]descriptor`, plus
;;     `[method]directory-entry-stream.read-directory-entry` +
;;     `[resource-drop]directory-entry-stream`.
;;
;; Still ENOSYS / not lifted (sub-issues split out of #168):
;;
;;   * `fd_fdstat_set_flags` — no preview2 equivalent for the flags
;;     preview1 cares about (cataggar/wabt#179).
;;   * `fd_pread`, `fd_advise`, `fd_allocate`, `fd_renumber`,
;;     `fd_tell`, `path_readlink` — out of v3 scope
;;     (cataggar/wabt#180).
;;   * `sock_*` — ENOSYS stubs only; preview2 `wasi:sockets/*`
;;     surface deferred (cataggar/wabt#178).

(module
  ;; ── func types ────────────────────────────────────────────────
  (type $void          (func))
  (type $i32_void      (func (param i32)))
  (type $run_sig       (func (result i32)))
  (type $cabi_realloc  (func (param i32 i32 i32 i32) (result i32)))

  ;; preview1 fd_* signatures (i32 errno return)
  (type $fd_write_sig         (func (param i32 i32 i32 i32) (result i32)))
  (type $fd_pwrite_sig        (func (param i32 i32 i32 i64 i32) (result i32)))
  (type $fd_read_sig          (func (param i32 i32 i32 i32) (result i32)))
  (type $fd_close_sig         (func (param i32) (result i32)))
  (type $fd_seek_sig          (func (param i32 i64 i32 i32) (result i32)))
  (type $fd_fdstat_get_sig    (func (param i32 i32) (result i32)))
  (type $fd_fdstat_set_flags_sig (func (param i32 i32) (result i32)))
  (type $fd_filestat_get_sig  (func (param i32 i32) (result i32)))
  (type $fd_filestat_set_size_sig (func (param i32 i64) (result i32)))
  (type $fd_filestat_set_times_sig (func (param i32 i64 i64 i32) (result i32)))
  (type $fd_prestat_get_sig   (func (param i32 i32) (result i32)))
  (type $fd_prestat_dir_name_sig (func (param i32 i32 i32) (result i32)))
  (type $fd_readdir_sig       (func (param i32 i32 i32 i64 i32) (result i32)))
  (type $fd_sync_sig          (func (param i32) (result i32)))
  (type $fd_datasync_sig      (func (param i32) (result i32)))

  ;; preview1 path_* signature. `path_open` takes 9 params:
  ;;   (dirfd: i32, dirflags: u32, path_ptr: i32, path_len: i32,
  ;;    oflags: u16, fs_rights_base: u64, fs_rights_inheriting: u64,
  ;;    fdflags: u16, opened_fd_ptr: i32) -> errno
  ;; The u16 flags are passed as i32 in core wasm.
  (type $path_open_sig
    (func (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))

  ;; preview1 path_* mutators. Single-string mutations
  ;; (`path_create_directory`, `path_remove_directory`,
  ;; `path_unlink_file`) take (dirfd, path_ptr, path_len) → errno.
  (type $path_only_sig        (func (param i32 i32 i32) (result i32)))

  ;; `path_filestat_get(dirfd, lookupflags, path_ptr, path_len,
  ;;   filestat_ptr) -> errno` — same shape as
  ;; `path_filestat_set_times` minus the trailing (atim, mtim,
  ;; fstflags) triple. Matches the wasi-libc canonical signature.
  (type $path_filestat_get_sig
    (func (param i32 i32 i32 i32 i32) (result i32)))

  ;; `path_filestat_set_times(dirfd, lookupflags, path_ptr,
  ;;   path_len, atim, mtim, fstflags) -> errno`.
  (type $path_filestat_set_times_sig
    (func (param i32 i32 i32 i32 i64 i64 i32) (result i32)))

  ;; `path_symlink(old_path_ptr, old_path_len, dirfd, new_path_ptr,
  ;;   new_path_len) -> errno`. Argument order is preview1's
  ;; `(target, dirfd, linkpath)` (matches POSIX `symlinkat`).
  (type $path_symlink_sig     (func (param i32 i32 i32 i32 i32) (result i32)))

  ;; `path_rename(old_dirfd, old_path_ptr, old_path_len,
  ;;   new_dirfd, new_path_ptr, new_path_len) -> errno`.
  (type $path_rename_sig
    (func (param i32 i32 i32 i32 i32 i32) (result i32)))

  ;; `path_link(old_dirfd, old_lookupflags, old_path_ptr,
  ;;   old_path_len, new_dirfd, new_path_ptr, new_path_len) -> errno`.
  (type $path_link_sig
    (func (param i32 i32 i32 i32 i32 i32 i32) (result i32)))

  ;; preview1 sock_* signatures. The current adapter keeps these as
  ;; ENOSYS=52 stubs (cataggar/wabt#166's "either resolve cleanly
  ;; or are explicitly elided" branch); declaring exports lets the
  ;; splicer match wasi-libc's startup imports without
  ;; `error.AdapterMissingPreview1Export`. Programs that actually
  ;; invoke a `sock_*` get the errno back through wasi-libc's
  ;; standard fallback path.
  (type $sock_accept_sig      (func (param i32 i32 i32) (result i32)))
  (type $sock_recv_sig
    (func (param i32 i32 i32 i32 i32 i32) (result i32)))
  (type $sock_send_sig
    (func (param i32 i32 i32 i32 i32) (result i32)))
  (type $sock_shutdown_sig    (func (param i32 i32) (result i32)))

  ;; preview1 args / environ / clock / random signatures
  (type $args_get_sig         (func (param i32 i32) (result i32)))
  (type $args_sizes_get_sig   (func (param i32 i32) (result i32)))
  (type $environ_get_sig      (func (param i32 i32) (result i32)))
  (type $environ_sizes_get_sig (func (param i32 i32) (result i32)))
  (type $clock_time_get_sig   (func (param i32 i64 i32) (result i32)))
  (type $clock_res_get_sig    (func (param i32 i32) (result i32)))
  (type $random_get_sig       (func (param i32 i32) (result i32)))

  ;; preview1 proc / sched signatures
  (type $proc_exit_sig        (func (param i32)))
  (type $proc_raise_sig       (func (param i32) (result i32)))
  (type $sched_yield_sig      (func (result i32)))

  ;; preview2 import signatures (canon-lower'd by the wrapping
  ;; component; here they are plain core-wasm function types). The
  ;; full set covers exit, stdout/stderr handle factories,
  ;; output/input streams (write + read hot paths), random/clocks,
  ;; environment, filesystem preopens, and the broad
  ;; `wasi:filesystem/types` surface (open/read/write/seek/close
  ;; plus stat / set-times / readdir / mutations).

  ;; `wasi:cli/{stdout,stderr}.get-{stdout,stderr}: () -> own<output-stream>`
  ;;   canon-lower'd to `(func (result i32))` — returns an opaque
  ;;   handle index in the per-instance resource table.
  (type $get_stream_sig (func (result i32)))

  ;; `[method]output-stream.blocking-write-and-flush(self,
  ;;     contents: list<u8>) -> result<_, stream-error>`
  ;;   canon-lower'd to `(func (param i32 i32 i32 i32))` — the
  ;;   params are (self, buf_ptr, buf_len, ret_area_ptr) where
  ;;   the ret_area is canon-lifted from the embed's `env.memory`.
  (type $blocking_write_sig (func (param i32 i32 i32 i32)))

  ;; `wasi:random/random.get-random-bytes(len: u64) -> list<u8>`
  ;;   canon-lower'd to `(func (param i64 i32))` — params are
  ;;   `(len, ret_area_ptr)`. The host writes `(buf_ptr, buf_len)`
  ;;   into the ret_area on return; the backing buffer itself is
  ;;   allocated via the adapter's `cabi_import_realloc` import.
  (type $get_random_bytes_sig (func (param i64 i32)))

  ;; `wasi:clocks/wall-clock.{now, resolution}() -> datetime`
  ;;   `datetime` is `record { seconds: u64, nanoseconds: u32 }`
  ;;   (size 16, align 8). 2 scalars exceed max-flat-results=1 so
  ;;   the lowered shape is `(func (param i32))` where the i32 is a
  ;;   caller-provided ret_area ptr. The host writes:
  ;;     offset 0: u64 seconds
  ;;     offset 8: u32 nanoseconds
  ;;     offset 12: pad to 16
  (type $wall_clock_sig (func (param i32)))

  ;; `wasi:clocks/monotonic-clock.{now, resolution}() -> u64`
  ;;   `instant` / `duration` are u64 aliases; a single primitive
  ;;   result fits in flat results, so the lowered shape is
  ;;   `(func (result i64))` — no ret_area.
  (type $monotonic_clock_sig (func (result i64)))

  ;; `wasi:cli/environment.{get-arguments, get-environment}` both
  ;;   canon-lower to `(func (param i32))` — a list return doesn't
  ;;   fit in flat results, so the i32 is a caller-provided ret_area
  ;;   into which the host writes `(list_ptr, list_len)` (i32 each)
  ;;   after running the host-side iteration.
  (type $get_arguments_sig   (func (param i32)))
  (type $get_environment_sig (func (param i32)))

  ;; `wasi:filesystem/preopens.get-directories() ->
  ;;   list<tuple<descriptor, string>>` — same shape as the
  ;;   `wasi:cli/environment` calls above. The host writes
  ;;   `(list_ptr, list_len)` at the ret_area; the list backing is
  ;;   12-byte tuples of `(descriptor_handle: i32, name_ptr: i32,
  ;;   name_len: i32)`.
  (type $get_directories_sig (func (param i32)))

  ;; `wasi:filesystem/types.[method]descriptor.open-at(self,
  ;;   path-flags: u8, path: string, open-flags: u8,
  ;;   flags: descriptor-flags u8) -> result<own<descriptor>,
  ;;   error-code>` — canon-lowered to 7 i32 params (self, path_flags,
  ;;   path_ptr, path_len, open_flags, desc_flags, ret_area). The
  ;;   ret_area holds `{ tag: u8 (+3 pad), payload: i32 }` — payload
  ;;   is either an owned descriptor handle (tag=0) or an
  ;;   `error-code` ordinal (tag=1).
  (type $descriptor_open_at_sig
    (func (param i32 i32 i32 i32 i32 i32 i32)))

  ;; `wasi:filesystem/types.[method]descriptor.read-via-stream(self,
  ;;   offset: u64) -> result<own<input-stream>, error-code>` —
  ;;   canon-lowered to `(func (param i32 i64 i32))`. Same result
  ;;   layout as `open-at`: ret_area `{ tag: u8 (+3 pad), payload:
  ;;   i32 }` where the i32 payload is either an input-stream
  ;;   handle (tag=0) or an `error-code` ordinal (tag=1).
  ;;
  ;; Re-used by `write-via-stream(self, offset: u64) ->
  ;; result<own<output-stream>, error-code>` (same flat shape) and
  ;; `set-size(self, size: u64) -> result<_, error-code>` (same flat
  ;; shape; result payload is unused on tag=0, holds error ordinal
  ;; on tag=1).
  (type $read_via_stream_sig
    (func (param i32 i64 i32)))

  ;; Generic `(self, ret_area)` shape covering every descriptor /
  ;; directory-entry-stream method whose only argument is the
  ;; implicit `self` handle and whose result spills to a ret_area:
  ;;
  ;;   * `descriptor.append-via-stream() ->
  ;;     result<own<output-stream>, error-code>`
  ;;   * `descriptor.stat() -> result<descriptor-stat, error-code>`
  ;;   * `descriptor.sync() -> result<_, error-code>`
  ;;   * `descriptor.sync-data() -> result<_, error-code>`
  ;;   * `descriptor.read-directory() ->
  ;;     result<own<directory-entry-stream>, error-code>`
  ;;   * `directory-entry-stream.read-directory-entry() ->
  ;;     result<option<directory-entry>, error-code>`
  ;;
  ;; The ret-area layout differs per method (8 bytes for the
  ;; handle/empty payload variants, 104 bytes for `descriptor-stat`,
  ;; 20 bytes for `option<directory-entry>`); the function type only
  ;; cares that there's a single trailing i32 pointer.
  (type $descriptor_void_sig
    (func (param i32 i32)))

  ;; `descriptor.<X>-at(self, path: string) -> result<_, error-code>`
  ;; — single-string mutators: `create-directory-at`,
  ;; `remove-directory-at`, `unlink-file-at`. Params are
  ;; (self, path_ptr, path_len, ret_area).
  (type $descriptor_path_only_sig
    (func (param i32 i32 i32 i32)))

  ;; `descriptor.stat-at(self, path-flags: u8, path: string) ->
  ;; result<descriptor-stat, error-code>` — params (self,
  ;; path_flags, path_ptr, path_len, ret_area). Shape happens to
  ;; match `path_*` calls that take a single string + path-flags
  ;; prefix.
  (type $descriptor_stat_at_sig
    (func (param i32 i32 i32 i32 i32)))

  ;; `descriptor.symlink-at(self, old-path: string, new-path: string)
  ;; -> result<_, error-code>` — params (self, old_ptr, old_len,
  ;; new_ptr, new_len, ret_area).
  (type $descriptor_symlink_at_sig
    (func (param i32 i32 i32 i32 i32 i32)))

  ;; `descriptor.rename-at(self, old-path: string,
  ;; new-descriptor: borrow<descriptor>, new-path: string) ->
  ;; result<_, error-code>` — params (self, old_ptr, old_len,
  ;; new_desc, new_ptr, new_len, ret_area). Note `borrow<descriptor>`
  ;; canon-lowers to a plain i32 handle slot; the host borrows the
  ;; same resource the adapter owns in its fd table.
  (type $descriptor_rename_at_sig
    (func (param i32 i32 i32 i32 i32 i32 i32)))

  ;; `descriptor.link-at(self, old-path-flags: u8, old-path: string,
  ;; new-descriptor: borrow<descriptor>, new-path: string) ->
  ;; result<_, error-code>` — params (self, old_path_flags, old_ptr,
  ;; old_len, new_desc, new_ptr, new_len, ret_area).
  (type $descriptor_link_at_sig
    (func (param i32 i32 i32 i32 i32 i32 i32 i32)))

  ;; `descriptor.set-times(self, atime: new-timestamp,
  ;; mtime: new-timestamp) -> result<_, error-code>` — `new-timestamp`
  ;; is a 3-case variant {no-change, now, timestamp(datetime)} that
  ;; flattens to (tag i32, seconds i64, nanoseconds i32). Two
  ;; variants in args + (self, ret_area) → 8 flat slots.
  (type $descriptor_set_times_sig
    (func (param i32 i32 i64 i32 i32 i64 i32 i32)))

  ;; `descriptor.set-times-at(self, path-flags: u8, path: string,
  ;; atime: new-timestamp, mtime: new-timestamp) ->
  ;; result<_, error-code>` — same as `set-times` plus the
  ;; (path_flags, path_ptr, path_len) prefix → 11 flat slots.
  (type $descriptor_set_times_at_sig
    (func (param i32 i32 i32 i32 i32 i64 i32 i32 i64 i32 i32)))

  ;; `wasi:io/streams.[method]input-stream.blocking-read(self,
  ;;   len: u64) -> result<list<u8>, stream-error>` — canon-lowered
  ;;   to `(func (param i32 i64 i32))`. The ret_area holds:
  ;;     offset 0: u8 outer tag (0 = ok, 1 = err)
  ;;     offset 4: payload — for ok this is `(ptr: i32, len: i32)`;
  ;;              for err it's a `stream-error` variant
  ;;              `{ inner_tag: u8 (+3 pad), inner_payload: i32 }`
  ;;              where inner_tag=0 is `last-operation-failed`
  ;;              (`own<error>` payload, which we discard) and
  ;;              inner_tag=1 is `closed` (no payload).
  ;;   Total ret_area size: 12 bytes.
  (type $input_stream_read_sig
    (func (param i32 i64 i32)))

  ;; ── imports ──────────────────────────────────────────────────
  ;;
  ;; env.memory — the embed's linear memory. The adapter reads
  ;; iovec lists and writes preview1 errno return values into it.
  (import "env" "memory" (memory 0))
