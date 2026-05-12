  ;; canon-lower realloc helper. Dispatches on `$import_alloc_mode`:
  ;;
  ;;   mode 0 (default) — delegate to `$main_cabi_realloc`. Used by
  ;;     any canon-lift'd allocation outside an args/environ /
  ;;     random_get window. Today no preview1 body relies on this
  ;;     path returning a valid pointer (clocks / exit / stdout /
  ;;     stderr never trigger a list/string lift), but it's kept
  ;;     defensively so a future preview2 import that *does*
  ;;     allocate without setting a mode still works.
  ;;
  ;;   mode 1 (one-shot) — return `$oneshot_ptr`, clear it, drop
  ;;     mode back to 0. Used by `$random_get` so the host's single
  ;;     `list<u8>` backing alloc lands in the caller's preview1
  ;;     `buf`.
  ;;
  ;;   mode 2 (count) — every allocation comes from the bump arena
  ;;     (`$ret_area + 32`); `align == 1` allocs additionally bump
  ;;     `$strings_sz` by `size`. Used by `args_sizes_get` /
  ;;     `environ_sizes_get` to compute argv_buf_size /
  ;;     env_buf_size without a second host call.
  ;;
  ;;   mode 3 (separate) — `align == 1` allocs go to
  ;;     `$strings_dst + $strings_cur`, advancing `$strings_cur` by
  ;;     `size + 1` (the +1 leaves room for a NUL/`=`/`\0` byte
  ;;     written after the host call). Non-align-1 allocs (the
  ;;     list backing) come from the bump arena. Used by
  ;;     `args_get` / `environ_get` so strings land in argv_buf /
  ;;     env_buf directly.
  ;;
  ;; All four modes preserve single-shot / per-call semantics: the
  ;; caller resets `$arena_cur` and other globals at the start of
  ;; its body, and the entire state machine resets to mode 0 at the
  ;; end. No state bleeds across preview1 calls.
  (func $cabi_import_realloc (type $cabi_realloc)
    (local $mode i32)
    global.get $import_alloc_mode
    local.tee $mode
    i32.const 1
    i32.eq
    if
      ;; mode 1: one-shot override.
      global.get $oneshot_ptr
      i32.const 0  global.set $oneshot_ptr
      i32.const 0  global.set $import_alloc_mode
      return
    end
    local.get $mode
    i32.const 2
    i32.eq
    if
      ;; mode 2: count. If align == 1, accumulate strings_sz; always
      ;; serve from bump arena.
      local.get 2
      i32.const 1
      i32.eq
      if
        global.get $strings_sz
        local.get 3
        i32.add
        global.set $strings_sz
      end
      local.get 2          ;; align
      local.get 3          ;; size
      call $arena_alloc
      return
    end
    local.get $mode
    i32.const 3
    i32.eq
    if
      ;; mode 3: separate. align == 1 → strings_dst; else → arena.
      local.get 2
      i32.const 1
      i32.eq
      if
        global.get $strings_dst
        global.get $strings_cur
        i32.add
        ;; advance strings_cur by size + 1
        global.get $strings_cur
        local.get 3
        i32.add
        i32.const 1
        i32.add
        global.set $strings_cur
        return
      end
      local.get 2
      local.get 3
      call $arena_alloc
      return
    end
    ;; mode 0 (or anything else, defensively): delegate.
    local.get 0
    local.get 1
    local.get 2
    local.get 3
    call $main_cabi_realloc)
