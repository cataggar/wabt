;; subtask.cancel (sync + async) + context.get / context.set (i32 slot 0).
(module
  (import "[task-return]local:p/run@0.1.0#run" "task-return" (func (param i32)))
  (import "[subtask]" "cancel" (func (param i32) (result i32)))
  (import "[subtask]" "cancel-async" (func (param i32) (result i32)))
  (import "[context]" "get-i32-0" (func (result i32)))
  (import "[context]" "set-i32-0" (func (param i32)))
  (memory (export "memory") 1)
  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 0))
  (func (export "local:p/run@0.1.0#run") (call 0 (i32.const 0)))
)
