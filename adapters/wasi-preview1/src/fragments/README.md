# `adapters/wasi-preview1/src/fragments/`

Per-shape and shared WAT fragments concatenated by
`tools/build_adapter.zig` to produce
`wasi_snapshot_preview1.{command,reactor}.wasm`.

Concatenation order (passed on the build-tool command line in this
order):

    prelude.wat
    {command,reactor}-imports.wat
    body.wat
    {command,reactor}-impl.wat
    realloc.wat
    exports.wat
    {command,reactor}-footer.wat

Fragment responsibilities:

  * **`prelude.wat`** (SHARED) — file-level comments, `(module`,
    every type def, and `env.memory` import. Ends after
    `env.memory` so the next fragment can supply per-shape
    `__main_module__` imports while still being in the import
    section.

  * **`command-imports.wat`** — `__main_module__._start` +
    `__main_module__.cabi_realloc` imports. Satisfied at splice
    time by aliasing the embed's exports under a synthetic
    `__main_module__` core instance
    (`src/component/adapter/adapter.zig:1175`).

  * **`reactor-imports.wat`** — no imports; just a banner. The
    splicer's reactor branch rejects any `__main_module__.*`
    import (`src/component/adapter/adapter.zig:1226`), so the
    `_start` / `cabi_realloc` symbols the shared body references
    are supplied as trap-stub local funcs by `reactor-impl.wat`
    instead.

  * **`body.wat`** (SHARED) — preview2 instance imports (every
    `wasi:cli/*`, `wasi:io/*`, `wasi:clocks/*`, `wasi:random/*`,
    `wasi:filesystem/*` slot the adapter consumes), state
    globals, helper funcs, and every preview1 trampoline. The
    body references `$main_start` (only via `$run`, which is
    command-only) and `$main_cabi_realloc` (via
    `$ensure_ret_area` + `$cabi_import_realloc` mode 0). Both
    are resolved by the per-shape `*-imports.wat` (command —
    imports) or `*-impl.wat` (reactor — local trap stubs).

  * **`command-impl.wat`** — `$run` func that calls
    `$main_start` and returns `0`. The wabt-style command
    adapter exports this as `wasi:cli/run@0.2.6#run`.

  * **`reactor-impl.wat`** — trap-stub local funcs
    `$main_start` + `$main_cabi_realloc`. See the file body for
    the rationale. Until a real reactor fixture motivates a
    proper `cabi_realloc` wire-back, every preview1 entry that
    materialises a result through the ret-area traps
    deterministically inside `$ensure_ret_area`.

  * **`realloc.wat`** (SHARED) — `$cabi_import_realloc`. Mode 0
    delegates to `$main_cabi_realloc`; in reactor shape that's a
    trap stub from `reactor-impl.wat`, in command shape it's the
    real `__main_module__.cabi_realloc` import.

  * **`exports.wat`** (SHARED) — flat preview1 surface exports
    (`fd_write`, `fd_pwrite`, `clock_time_get`, …).

  * **`command-footer.wat`** — `wasi:cli/run@0.2.6#run` +
    `cabi_import_realloc` exports + module close `)`.

  * **`reactor-footer.wat`** — `cabi_import_realloc` export +
    module close `)`. No `wasi:cli/run@0.2.6#run`.
