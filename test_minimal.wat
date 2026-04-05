(module
  (import "spectest" "print_i32" (func $a (param i32)))
  (func $b (import "spectest" "print_i32") (param i32))
)
