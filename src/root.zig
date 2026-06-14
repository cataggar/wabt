//! `wasip2` — re-export index of every guest binding module, giving a
//! single import surface for consumers that prefer
//! `@import("wasip2").wasi_cli` over importing each module by name.
//!
//! A guest can still `@import("wasi_cli")` directly; this index exists
//! mainly to document the full coverage in one place.

pub const abi = @import("abi");
pub const wasi_io = @import("wasi_io");
pub const wasi_cli = @import("wasi_cli");
pub const wasi_clocks = @import("wasi_clocks");
pub const wasi_random = @import("wasi_random");
pub const wasi_filesystem = @import("wasi_filesystem");
pub const wasi_sockets = @import("wasi_sockets");
pub const wasi_config = @import("wasi_config");
pub const wasi_http = @import("wasi_http");
pub const wasi_keyvalue = @import("wasi_keyvalue");
pub const wasi_nn = @import("wasi_nn");
pub const wasi_tls = @import("wasi_tls");
