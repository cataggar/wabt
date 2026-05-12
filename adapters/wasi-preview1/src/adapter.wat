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
;; `proc_exit` and `run` are fully wired. `fd_write` is still an
;; ENOSYS stub but the preview2 surface it will call (Phase
;; 1.c.3c/d) is now declared:
;;
;;   * `wasi:cli/stdout@0.2.6.get-stdout` /
;;     `wasi:cli/stderr@0.2.6.get-stderr` — handle factories;
;;   * `wasi:io/streams@0.2.6.[method]output-stream.blocking-write-and-flush`
;;     — single hot path for stdout/stderr writes;
;;   * `wasi:io/streams@0.2.6.[resource-drop]output-stream` —
;;     auto-bound by the splicer for canon `resource.drop` lowering
;;     (we cache handles and never actually drop them, but the
;;     splicer expects every `own<>` resource to have its drop
;;     import declared).
;;
;; The new imports are declared here in Phase 1.c.3b so the
;; encoded-world custom section round-trips through
;; `build_adapter.zig` → `decode.parseFromAdapterCore` against the
;; widened preview1 world. Phase 1.c.3c adds globals + helpers
;; that consume them; Phase 1.c.3d rewires `fd_write` to dispatch
;; on fd=1/2 → stdout/stderr handle and stream the iovec list
;; via `blocking-write-and-flush`. All other preview1 imports
;; remain ENOSYS until later sub-phases.

(module
  ;; ── func types ────────────────────────────────────────────────
  (type $void          (func))
  (type $i32_void      (func (param i32)))
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
  ;; v1 scope (cataggar/wamr#453): only the preview2 imports used
  ;; by `proc_exit` and the (still-stubbed) stdout/stderr write
  ;; path are declared. The wider set (`wasi:filesystem/…`,
  ;; `wasi:cli/environment`, etc.) arrives alongside the real
  ;; `args_get` / `clock_time_get` lowering in a later sub-phase.

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
  ;; result type doesn't fit in flat parameters
  ;; (`blocking-write-and-flush` returns `result<_, stream-error>`
  ;; which is lowered into a 4th `ret_area: i32` param). 16 bytes
  ;; is plenty — the largest result we read back is the result
  ;; outer discriminant (i32) + the inner stream-error
  ;; discriminant (i32) = 8 bytes.
  ;;
  ;; The area is allocated lazily on first fd_write call via the
  ;; embed's `cabi_realloc` and stashed here for re-use. We never
  ;; free it; the embed instance teardown reclaims everything.
  (global $ret_area (mut i32) (i32.const 0))

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

  ;; Helper: ensure `$ret_area` points at a 16-byte block in
  ;; env.memory. Allocates once via the embed's cabi_realloc.
  ;; Returns the cached pointer.
  ;;
  ;; We request a full page (65536 bytes) rather than the 16 bytes
  ;; we actually need. The reason: when the embed itself doesn't
  ;; export `cabi_realloc`, the component-new splicer replaces the
  ;; `__main_module__::cabi_realloc` import with a
  ;; `realloc_via_memory_grow` body (see
  ;; `src/component/adapter/adapter.zig:buildMainModuleFallback`)
  ;; that traps on any allocation request smaller than one page.
  ;; Matches `wit-component`'s upstream allocate_stack_via_realloc
  ;; strategy — allocate one page up-front, carve the small scratch
  ;; area out of its head, ignore the rest. Embeds with real
  ;; cabi_realloc still satisfy the request fine.
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

  ;; preview1 `fd_write(fd, iovs, iovs_len, nwritten_ptr) -> errno`.
  ;; Routes fd 1 → cached stdout handle, fd 2 → cached stderr
  ;; handle, anything else → EBADF (8). The actual byte
  ;; streaming lives in `$write_iovecs`.
  (func $fd_write (type $fd_write_sig)
    (local $handle i32)
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
          br $bad_fd
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
