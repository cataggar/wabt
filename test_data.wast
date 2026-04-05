(assert_malformed
  (module quote
    "(data\"a\")"
  )
  "unknown operator"
)
