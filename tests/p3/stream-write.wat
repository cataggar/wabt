;; stream.write: memory-opt intrinsic that routes through the shim/fixup path.
(module
  (import "[task-return]local:p/run@0.1.0#run" "task-return" (func (param i32)))
  (import "[stream]stream<u8>" "new" (func (result i64)))
  (import "[stream]stream<u8>" "write" (func (param i32 i32 i32) (result i32)))
  (import "[stream]stream<u8>" "drop-writable" (func (param i32)))
  (memory (export "memory") 1)
  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 0))
  (func (export "local:p/run@0.1.0#run"))
)
