
  ;; Canon-lower realloc helper. Reactor shape omits the
  ;; `wasi:cli/run@0.2.6#run` export — the wrapping component
  ;; lifts the embed's own exports (e.g. `wasi:http/incoming-
  ;; handler.handle`) directly. See cataggar/wabt#167.
  (export "cabi_import_realloc"    (func $cabi_import_realloc))
)
