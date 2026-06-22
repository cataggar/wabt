//! `wasip3` — re-export index of the WASI 0.3 guest binding modules.
//!
//! A guest can still `@import("wasi_cli")` / `@import("wit_types")` /
//! `@import("wit_async")` directly; this index gives a single
//! `@import("wasip3")` surface and documents coverage in one place.

pub const abi = @import("abi");
/// Comptime Component-Model canonical-ABI value marshaller (records, strings,
/// options, lists → linear memory).
pub const canon = @import("canon");
/// Component-Model async canonical primitives (future/stream/error-context/
/// waitable-set) — the WASI 0.3 replacement for `wasi:io`.
pub const cm_async = @import("cm_async");
pub const wit_types = @import("wit_types");
pub const wit_async = @import("wit_async");
pub const wasi_cli = @import("wasi_cli");
/// `wasi:clocks@0.3.0` — monotonic + system clocks (async waits).
pub const wasi_clocks = @import("wasi_clocks");
/// `wasi:random@0.3.0` — secure + insecure random, insecure-seed.
pub const wasi_random = @import("wasi_random");
/// `wasi:filesystem@0.3.0` — preopens + descriptors (async stat/open, `stream<u8>` I/O).
pub const wasi_filesystem = @import("wasi_filesystem");
/// `wasi:sockets@0.3.0` — tcp/udp socket resources + ip-name-lookup.
pub const wasi_sockets = @import("wasi_sockets");
pub const wasi_http = @import("wasi_http");
