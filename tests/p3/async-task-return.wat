;; Async lift + task.return: the minimal P3 async export shape.
(module
  (import "[task-return]local:p/run@0.1.0#run" "task-return" (func (param i32)))
  (memory (export "memory") 1)
  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 0))
  (func (export "local:p/run@0.1.0#run") (call 0 (i32.const 0)))
)
