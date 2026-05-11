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
;; Status: scaffold. Most function bodies are `unreachable` traps.
;; `proc_exit` and `run` are fully wired; `fd_write` and the rest
;; of the preview1 surface land in subsequent commits.

(module
  ;; ── func types ────────────────────────────────────────────────
  (type $void          (func))
  (type $i32_void      (func (param i32)))
  (type $get_handle    (func (result i32)))
  (type $run_sig       (func (result i32)))
  (type $cabi_realloc  (func (param i32 i32 i32 i32) (result i32)))

  ;; preview1 fd_* signatures (i32 errno return)
  (type $fd_write_sig         (func (param i32 i32 i32 i32) (result i32)))
  (type $fd_read_sig          (func (param i32 i32 i32 i32) (result i32)))
  (type $fd_close_sig         (func (param i32) (result i32)))
  (type $fd_seek_sig          (func (param i32 i64 i32 i32) (result i32)))
  (type $fd_fdstat_get_sig    (func (param i32 i32) (result i32)))
  (type $fd_fdstat_set_flags_sig (func (param i32 i32) (result i32)))
  (type $fd_prestat_get_sig   (func (param i32 i32) (result i32)))
  (type $fd_prestat_dir_name_sig (func (param i32 i32 i32) (result i32)))

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
  ;; component; here they are plain core-wasm function types).
  ;;
  ;; `[method]output-stream.blocking-write-and-flush(self, contents)
  ;; -> result<_, stream-error>` canon-lowers to:
  ;;   (self: i32 handle, ptr: i32, len: i32, retptr: i32) -> ()
  ;; The retptr is a 12-byte return-area in linear memory; the
  ;; first byte is the result tag (0 = ok, 1 = err), followed by
  ;; the (variant-tagged) stream-error payload on the err branch.
  (type $stream_write_sig (func (param i32 i32 i32 i32)))

  ;; ── imports ──────────────────────────────────────────────────
  ;;
  ;; env.memory — the embed's linear memory. The adapter reads
  ;; iovec lists and writes preview1 errno return values into it.
  (import "env" "memory" (memory 0))

  ;; The embed exports we call back into.
  (import "__main_module__" "_start"
    (func $main_start (type $void)))
  (import "__main_module__" "cabi_realloc"
    (func $main_cabi_realloc (type $cabi_realloc)))

  ;; preview2 instances we lower into. Initial scope per
  ;; cataggar/wamr#453 — fd_write / fd_read / stdio + exit-with-code.
  (import "wasi:cli/exit@0.2.6" "exit-with-code"
    (func $exit_with_code (type $i32_void)))
  (import "wasi:cli/stdout@0.2.6" "get-stdout"
    (func $get_stdout (type $get_handle)))
  (import "wasi:cli/stderr@0.2.6" "get-stderr"
    (func $get_stderr (type $get_handle)))
  (import "wasi:cli/stdin@0.2.6" "get-stdin"
    (func $get_stdin (type $get_handle)))
  (import "wasi:io/streams@0.2.6" "[method]output-stream.blocking-write-and-flush"
    (func $owrite_flush (type $stream_write_sig)))
  (import "wasi:io/streams@0.2.6" "[resource-drop]output-stream"
    (func $ostream_drop (type $i32_void)))
  (import "wasi:io/streams@0.2.6" "[resource-drop]input-stream"
    (func $istream_drop (type $i32_void)))

  ;; ── preview1 surface ─────────────────────────────────────────
  ;;
  ;; proc_exit(code: i32) -> ! :  preview1 declares no return, but
  ;; the canon-lift'd signature in core wasm is `(i32) -> ()`. The
  ;; body lowers through `wasi:cli/exit.exit-with-code(u8)` and
  ;; then traps so the call never returns. The host's
  ;; `exit-with-code` itself traps after stashing the code on the
  ;; `WasiCliAdapter.exit_code` slot, so in practice the
  ;; `unreachable` here is defensive.
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
  (func $fd_write (type $fd_write_sig)
    ;; TODO: iterate iovec list, call $owrite_flush against
    ;; stdout/stderr handle. For now: ENOSYS.
    i32.const 52)

  (func $fd_read (type $fd_read_sig)         i32.const 52)
  (func $fd_close (type $fd_close_sig)       i32.const 52)
  (func $fd_seek (type $fd_seek_sig)         i32.const 52)
  (func $fd_fdstat_get (type $fd_fdstat_get_sig) i32.const 52)
  (func $fd_fdstat_set_flags (type $fd_fdstat_set_flags_sig) i32.const 52)
  (func $fd_prestat_get (type $fd_prestat_get_sig) i32.const 52)
  (func $fd_prestat_dir_name (type $fd_prestat_dir_name_sig) i32.const 52)

  ;; ── args / environ ───────────────────────────────────────────
  ;;
  ;; ENOSYS until subsequent commits wire these to
  ;; `wasi:cli/environment.get-arguments` /
  ;; `get-environment` (both return canon-lift'd `list<string>`
  ;; which needs a return-area + iterate). The scaffold body is
  ;; intentionally trivial — wasi-libc treats a non-zero return as
  ;; "no env / no args available", so the wamr examples that don't
  ;; consult argv (`zig-hello`, `zig-exit`) still work.
  (func $args_get (type $args_get_sig)             i32.const 52)
  (func $args_sizes_get (type $args_sizes_get_sig) i32.const 52)
  (func $environ_get (type $environ_get_sig)       i32.const 52)
  (func $environ_sizes_get (type $environ_sizes_get_sig) i32.const 52)

  ;; ── clocks / random (ENOSYS for now) ─────────────────────────
  (func $clock_time_get (type $clock_time_get_sig) i32.const 52)
  (func $clock_res_get (type $clock_res_get_sig)   i32.const 52)
  (func $random_get (type $random_get_sig)         i32.const 52)

  ;; ── run entry ────────────────────────────────────────────────
  ;;
  ;; wasi:cli/run.run() -> result<_, _>
  ;;   canon-lift'd to core wasm: () -> i32
  ;;   0 = Ok(()), 1 = Err(())
  ;;
  ;; Call the embed's _start. If _start returns normally we
  ;; return 0 (ok). proc_exit traps so it never reaches this
  ;; tail.
  (func $run (type $run_sig)
    call $main_start
    i32.const 0)

  ;; canon-lower realloc helper — delegate to the embed's
  ;; cabi_realloc. None of the preview1 imports we currently
  ;; implement route a list / string return back through realloc,
  ;; so this is a defensive delegation rather than a hot path.
  (func $cabi_import_realloc (type $cabi_realloc)
    local.get 0
    local.get 1
    local.get 2
    local.get 3
    call $main_cabi_realloc)

  ;; ── exports ──────────────────────────────────────────────────
  ;;
  ;; Flat preview1 names (no `wasi_snapshot_preview1.` prefix —
  ;; the splicer matches by name against whichever `--adapt
  ;; name=…` module the user specified, defaulting to
  ;; `wasi_snapshot_preview1`).
  (export "proc_exit"            (func $proc_exit))
  (export "proc_raise"           (func $proc_raise))
  (export "sched_yield"          (func $sched_yield))
  (export "fd_write"             (func $fd_write))
  (export "fd_read"              (func $fd_read))
  (export "fd_close"             (func $fd_close))
  (export "fd_seek"              (func $fd_seek))
  (export "fd_fdstat_get"        (func $fd_fdstat_get))
  (export "fd_fdstat_set_flags"  (func $fd_fdstat_set_flags))
  (export "fd_prestat_get"       (func $fd_prestat_get))
  (export "fd_prestat_dir_name"  (func $fd_prestat_dir_name))
  (export "args_get"             (func $args_get))
  (export "args_sizes_get"       (func $args_sizes_get))
  (export "environ_get"          (func $environ_get))
  (export "environ_sizes_get"    (func $environ_sizes_get))
  (export "clock_time_get"       (func $clock_time_get))
  (export "clock_res_get"        (func $clock_res_get))
  (export "random_get"           (func $random_get))

  ;; Component-level run entry + canon-lower realloc helper.
  (export "wasi:cli/run@0.2.6#run" (func $run))
  (export "cabi_import_realloc"    (func $cabi_import_realloc))
)
