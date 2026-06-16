;; stream/future cancel-read / cancel-write (sync + async), no-memory direct canons.
(module
  (import "[task-return]local:p/run@0.1.0#run" "task-return" (func (param i32)))
  (import "[stream]stream<u8>" "new" (func (result i64)))
  (import "[stream]stream<u8>" "cancel-read" (func (param i32) (result i32)))
  (import "[stream]stream<u8>" "cancel-write-async" (func (param i32) (result i32)))
  (import "[future]future<u8>" "new" (func (result i64)))
  (import "[future]future<u8>" "cancel-read" (func (param i32) (result i32)))
  (import "[future]future<u8>" "cancel-write" (func (param i32) (result i32)))
  (memory (export "memory") 1)
  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 0))
  (func (export "local:p/run@0.1.0#run"))
)
