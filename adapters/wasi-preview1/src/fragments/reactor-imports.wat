  ;; ── reactor-shape: no `__main_module__` imports ──────────────
  ;;
  ;; The reactor adapter has no `_start` to call into and the
  ;; splicer's reactor branch (src/component/adapter/adapter.zig:1226)
  ;; explicitly rejects any `__main_module__.*` import. The shared
  ;; body still references `$main_start` (inside the command-only
  ;; `$run`, which the reactor footer omits) and `$main_cabi_realloc`
  ;; (inside `$ensure_ret_area` and `$cabi_import_realloc` mode 0).
  ;; Both symbols are supplied as trap-stub *local* funcs by
  ;; `reactor-impl.wat` so the shared body parses without dangling
  ;; references.
  ;;
  ;; Functional consequence: every preview1 entry point that calls
  ;; `$ensure_ret_area` (i.e. every entry that materialises a result
  ;; through the ret-area scratch page) traps in the reactor variant
  ;; until a real reactor fixture motivates wiring `cabi_realloc`
  ;; back to the embed. Tracked under cataggar/wabt#167.
