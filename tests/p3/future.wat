;; future<u8>: no-memory future.new / drop-readable / drop-writable.
(module
  (import "[task-return]local:p/run@0.1.0#run" "task-return" (func (param i32)))
  (import "[future]future<u8>" "new" (func (result i64)))
  (import "[future]future<u8>" "drop-readable" (func (param i32)))
  (import "[future]future<u8>" "drop-writable" (func (param i32)))
  (memory (export "memory") 1)
  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 0))
  (func (export "local:p/run@0.1.0#run"))
)
