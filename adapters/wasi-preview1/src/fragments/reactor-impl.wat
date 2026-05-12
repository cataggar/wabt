  ;; ── reactor-shape trap stubs ─────────────────────────────────
  ;;
  ;; Local-func stand-ins for the `__main_module__.*` symbols the
  ;; shared body references. Reactor shape declares no
  ;; `__main_module__` imports (the splicer's reactor branch
  ;; rejects them), so we define identically-named locals here.
  ;;
  ;;   * `$main_start` — referenced from `$run` in command shape;
  ;;     the reactor footer omits `$run`, so this stub is
  ;;     unreachable at runtime. Defined for symbol-resolution
  ;;     symmetry; the WAT parser pre-scans func names so its
  ;;     presence is required iff some other func references it.
  ;;     Today nothing else does, but we keep it for parity should
  ;;     a future shared helper take a `_start` callback.
  ;;
  ;;   * `$main_cabi_realloc` — referenced from `$ensure_ret_area`
  ;;     (every preview1 entry that materialises a result through
  ;;     the ret-area scratch page) and from `$cabi_import_realloc`
  ;;     mode 0. The reactor adapter has no source of preview2
  ;;     scratch memory until a real fixture wires `cabi_realloc`
  ;;     back to the embed (cataggar/wabt#167). Trapping is the
  ;;     correct deferred behavior: composing a reactor embed that
  ;;     never makes a preview1 call works; the first such call
  ;;     traps deterministically with the source location at
  ;;     `$ensure_ret_area`.
  (func $main_start (type $void)
    unreachable)
  (func $main_cabi_realloc (type $cabi_realloc)
    unreachable)
