//! `wasip3` — re-export index of the WASI 0.3 guest binding modules.
//!
//! A guest can still `@import("wasi_cli")` / `@import("cm_async")`
//! directly; this index gives a single `@import("wasip3").wasi_cli`
//! surface and documents coverage in one place.

pub const abi = @import("abi");
/// Comptime Component-Model canonical-ABI value marshaller (records, strings,
/// options, lists → linear memory).
pub const canon = @import("canon");
/// Component-Model async canonical primitives (future/stream/error-context/
/// waitable-set) — the WASI 0.3 replacement for `wasi:io`.
pub const cm_async = @import("cm_async");
pub const wasi_cli = @import("wasi_cli");
pub const wasi_http = @import("wasi_http");
