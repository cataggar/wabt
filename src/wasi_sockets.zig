//! `wasi_sockets` — ergonomic guest-side helper for `wasi:sockets@0.3.0`
//! (WASI 0.3 / Component-Model async).
//!
//! The canonical-ABI client wrappers are **generated** by
//! `wabt component bindgen` (see `wasi_sockets_bindings.zig`); this module is the
//! thin ergonomic layer over them, re-exporting the socket resources + address
//! types and wrapping `ip-name-lookup`. The async members (`resolve-addresses`,
//! `tcp-socket.connect`, …) block via `cm_async.awaitCall` inside the generated
//! wrappers, so they look synchronous to the guest.
//!
//! ## Usage
//!
//! ```zig
//! const sockets = @import("wasi_sockets");
//! switch (sockets.resolveAddresses("example.com")) {
//!     .ok => |addrs| for (addrs) |a| switch (a) {
//!         .ipv4 => |v| { _ = v; },
//!         .ipv6 => |v| { _ = v; },
//!     },
//!     .err => |e| { _ = e; },
//! }
//! ```

const b = @import("wasi_sockets_bindings");
const canon = @import("canon");

// ── re-exported generated types ─────────────────────────────────────
pub const IpAddress = b.IpAddress;
pub const Ipv4Address = b.Ipv4Address;
pub const Ipv6Address = b.Ipv6Address;
pub const IpSocketAddress = b.IpSocketAddress;
pub const Ipv4SocketAddress = b.Ipv4SocketAddress;
pub const Ipv6SocketAddress = b.Ipv6SocketAddress;
pub const IpAddressFamily = b.IpAddressFamily;
pub const TcpSocket = b.TcpSocket;
pub const UdpSocket = b.UdpSocket;
/// `wasi:sockets/types` error code (socket operations).
pub const ErrorCode = b.TypesErrorCode;
/// `wasi:sockets/ip-name-lookup` error code (name resolution).
pub const LookupErrorCode = b.IpNameLookupErrorCode;

// ── ip-name-lookup ──────────────────────────────────────────────────

/// Resolve a host name (or a literal IP-address string, parsed without any
/// external request) to a list of IP addresses. The result list borrows the
/// scratch arena; copy out to retain. Never succeeds with zero results.
pub fn resolveAddresses(name: []const u8) canon.Result([]const IpAddress, LookupErrorCode) {
    return b.ip_name_lookup.resolveAddresses(name);
}
