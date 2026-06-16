;; thread.yield: no-memory cooperative-yield built-in (lowers to `(func (result i32))`).
(module
  (import "[task-return]local:p/run@0.1.0#run" "task-return" (func (param i32)))
  (import "[yield]" "yield" (func (result i32)))
  (memory (export "memory") 1)
  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 0))
  (func (export "local:p/run@0.1.0#run")
    (drop (call 1))            ;; thread.yield -> i32, discard
    (call 0 (i32.const 0)))    ;; task.return
)
