//! `wasi_sockets` — guest-side bindings for `wasi:sockets@0.2.6`.
//!
//! Demand-driven: currently binds the `ip-name-lookup` path
//! (`instance-network` + `resolve-addresses` + the async
//! `resolve-address-stream`). TCP/UDP are added as examples need them.
//!
//! Resolution is asynchronous: `resolve-next-address` returns the
//! `would-block` error-code until the stream's pollable is ready.

const abi = @import("abi");
const io = @import("wasi_io");

/// `instance-network.instance-network() -> own<network>`.
extern "wasi:sockets/instance-network@0.2.6" fn @"instance-network"() i32;

/// `[resource-drop]network(own<network>)`.
extern "wasi:sockets/network@0.2.6" fn @"[resource-drop]network"(self: i32) void;

/// `ip-name-lookup.resolve-addresses(borrow<network>, string)
///   -> result<own<resolve-address-stream>, error-code>`. retptr (align 4):
/// `[disc @0, handle-or-errcode @4]`.
extern "wasi:sockets/ip-name-lookup@0.2.6" fn @"resolve-addresses"(
    network: i32,
    name_ptr: i32,
    name_len: i32,
    retptr: i32,
) void;

/// `[method]resolve-address-stream.resolve-next-address(borrow)
///   -> result<option<ip-address>, error-code>`. See `AddressStream.next`
/// for the spilled memory layout.
extern "wasi:sockets/ip-name-lookup@0.2.6" fn @"[method]resolve-address-stream.resolve-next-address"(self: i32, retptr: i32) void;

/// `[method]resolve-address-stream.subscribe(borrow) -> own<pollable>`.
extern "wasi:sockets/ip-name-lookup@0.2.6" fn @"[method]resolve-address-stream.subscribe"(self: i32) i32;

/// `[resource-drop]resolve-address-stream(own<resolve-address-stream>)`.
extern "wasi:sockets/ip-name-lookup@0.2.6" fn @"[resource-drop]resolve-address-stream"(self: i32) void;

/// `would-block` error-code discriminant (network.wit enum index 8).
const errcode_would_block: u8 = 8;

pub const Ipv4 = [4]u8;
pub const Ipv6 = [8]u16;

/// `wasi:sockets/network.ip-address`.
pub const IpAddress = union(enum) {
    ipv4: Ipv4,
    ipv6: Ipv6,
};

/// A `wasi:sockets/network.network` handle.
pub const Network = struct {
    handle: i32,

    pub fn drop(self: Network) void {
        @"[resource-drop]network"(self.handle);
    }
};

/// Obtain a handle to the default network instance.
pub fn instanceNetwork() Network {
    return .{ .handle = @"instance-network"() };
}

pub const ResolveError = error{ResolveFailed};

/// Start resolving `name` to a stream of IP addresses.
pub fn resolveAddresses(network: Network, name: []const u8) ResolveError!AddressStream {
    @"resolve-addresses"(
        network.handle,
        @intCast(@intFromPtr(name.ptr)),
        @intCast(name.len),
        abi.retPtr(),
    );
    const w = abi.retWords();
    if (w[0] != 0) return error.ResolveFailed;
    return .{ .handle = @bitCast(w[1]) };
}

/// An in-progress address resolution (`resolve-address-stream`).
pub const AddressStream = struct {
    handle: i32,

    /// One step of resolution.
    pub const Next = union(enum) {
        /// A resolved IP address.
        address: IpAddress,
        /// No more addresses — resolution is complete.
        end,
        /// Not ready yet; `block` on `subscribe()` and retry.
        would_block,
        /// A resolver error-code (network.wit `error-code` index).
        err: u8,
    };

    /// A pollable that becomes ready when more addresses are available.
    pub fn subscribe(self: AddressStream) io.Pollable {
        return .{ .handle = @"[method]resolve-address-stream.subscribe"(self.handle) };
    }

    /// Pull the next resolved address (non-blocking). Decode of the
    /// spilled `result<option<ip-address>, error-code>` memory layout
    /// (align 2): result disc @0; payload @2; option disc @2; ip-address
    /// variant disc @4; ipv4 bytes @6 / ipv6 u16s (LE) @6.
    pub fn next(self: AddressStream) Next {
        @"[method]resolve-address-stream.resolve-next-address"(self.handle, abi.retPtr());
        const base: usize = @intCast(abi.retPtr());
        const b: [*]const u8 = @ptrFromInt(base);
        if (b[0] != 0) {
            const ec = b[2];
            return if (ec == errcode_would_block) .would_block else .{ .err = ec };
        }
        if (b[2] == 0) return .end; // option::none
        if (b[4] == 0) {
            return .{ .address = .{ .ipv4 = .{ b[6], b[7], b[8], b[9] } } };
        }
        var g: Ipv6 = undefined;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            g[i] = @as(u16, b[6 + 2 * i]) | (@as(u16, b[7 + 2 * i]) << 8);
        }
        return .{ .address = .{ .ipv6 = g } };
    }

    pub fn drop(self: AddressStream) void {
        @"[resource-drop]resolve-address-stream"(self.handle);
    }
};
