  ;; ── command-shape `__main_module__` imports ──────────────────
  ;;
  ;; The command-shape adapter calls back into the embed's
  ;; `_start` (from `$run`) and uses the embed's `cabi_realloc`
  ;; for its 64 KiB scratch page allocation (via `$ensure_ret_area`
  ;; → `$main_cabi_realloc`). At splice time the splicer's
  ;; command branch (src/component/adapter/adapter.zig:1175)
  ;; aliases the embed's `_start` / `cabi_realloc` exports under
  ;; a synthetic `__main_module__` core instance to satisfy these
  ;; imports.
  ;;
  ;; The reactor-shape fragment (`reactor-imports.wat` +
  ;; `reactor-impl.wat`) declares no `__main_module__.*` imports
  ;; and instead provides trap-stub local funcs by the same
  ;; identifier so the shared body's references resolve.
  (import "__main_module__" "_start"
    (func $main_start (type $void)))
  (import "__main_module__" "cabi_realloc"
    (func $main_cabi_realloc (type $cabi_realloc)))
