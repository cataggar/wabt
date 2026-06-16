;; error-context: new (memory-opt, shim/fixup) + drop (no-memory, direct).
(module
  (import "[task-return]local:p/run@0.1.0#run" "task-return" (func (param i32)))
  (import "[error-context]" "new" (func (param i32 i32) (result i32)))
  (import "[error-context]" "drop" (func (param i32)))
  (memory (export "memory") 1)
  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 0))
  (func (export "local:p/run@0.1.0#run"))
)
