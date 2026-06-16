;; waitable-set new/wait/drop (wait is memory-opt) + waitable.join.
(module
  (import "[task-return]local:p/run@0.1.0#run" "task-return" (func (param i32)))
  (import "[waitable-set]" "new" (func (result i32)))
  (import "[waitable-set]" "wait" (func (param i32 i32) (result i32)))
  (import "[waitable-set]" "drop" (func (param i32)))
  (import "[waitable]" "join" (func (param i32 i32)))
  (memory (export "memory") 1)
  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 0))
  (func (export "local:p/run@0.1.0#run"))
)
