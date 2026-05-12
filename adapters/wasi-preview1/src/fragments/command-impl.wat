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
