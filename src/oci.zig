//! OCI foundation namespace.
//!
//! The implementation provenance and pinned upstream source mapping are
//! recorded in `SOURCE_PROVENANCE.md`.

test "namespace is importable" {
    @import("std").testing.refAllDecls(@This());
}
