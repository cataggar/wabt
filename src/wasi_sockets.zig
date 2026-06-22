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
const wit_types = @import("wit_types");
const wit_async = @import("wit_async");

const canon = wit_types;
const abi = wit_types.abi;
const cm = wit_async;

const ByteStream = wit_types.Stream(u8);
// The send/receive completion `future<result<_, error-code>>`, recovered by
// reflection on the generated `tcp-socket.send` signature (its return type).
const SendFut = @typeInfo(@TypeOf(b.TcpSocket.send)).@"fn".return_type.?;
// The accept stream `stream<tcp-socket>` returned by `tcp-socket.listen`,
// recovered from the `.ok` arm of its `canon.Result(stream, error-code)` return.
const ListenRet = @typeInfo(@TypeOf(b.TcpSocket.listen)).@"fn".return_type.?;
const AcceptStream = @typeInfo(ListenRet).@"union".fields[0].type;

/// Canonical `stream`/`future` status: blocked (operation pending).
const BLOCKED: i32 = @bitCast(@as(u32, 0xffff_ffff));

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

// ── address helpers ─────────────────────────────────────────────────

/// Build an IPv4 socket address from octets + port.
pub fn ipv4(a: u8, c: u8, d: u8, e: u8, port: u16) IpSocketAddress {
    return .{ .ipv4 = .{ .port = port, .address = .{ a, c, d, e } } };
}

/// The address family of a socket address.
pub fn familyOf(addr: IpSocketAddress) IpAddressFamily {
    return switch (addr) {
        .ipv4 => .ipv4,
        .ipv6 => .ipv6,
    };
}

// ── async helpers (drive the generated stream/future channels) ──────

/// Block on `waitable` until it makes progress; returns the event payload.
fn waitCode(waitable: i32) u32 {
    const set = cm.WaitableSet.create();
    set.add(waitable);
    _ = set.waitOne();
    const code: u32 = abi.retWords()[1];
    set.drop();
    return code;
}

/// Write all of `bytes` to a stream's writable end, waiting on a blocked write.
fn writeStreamAll(s: ByteStream, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const status = s.write(bytes[off..]);
        const code: u32 = if (status == BLOCKED) waitCode(s.handle) else @bitCast(status);
        const n: usize = code >> 4;
        if (n == 0) break;
        off += n;
    }
}

/// Drive a `future<result<_, error-code>>` to completion (value ignored) and
/// drop its readable end.
fn awaitFuture(fut: anytype) void {
    var buf: [16]u8 align(8) = undefined;
    const status = fut.readInto(&buf);
    if (status == BLOCKED) _ = waitCode(fut.handle);
    fut.dropReadable();
}

// ── TCP client ──────────────────────────────────────────────────────

/// A connected TCP stream — a thin wrapper driving the `tcp-socket` resource's
/// `send` / `receive` byte streams (the same pattern as `wasi_filesystem` file
/// I/O and the cli stdout stream).
pub const TcpStream = struct {
    socket: TcpSocket,

    /// Send all of `bytes`, flushing fully before returning.
    pub fn send(self: TcpStream, bytes: []const u8) void {
        const ends = ByteStream.new();
        const fut = self.socket.send(ends.readable); // host drains the readable end
        writeStreamAll(ends.writable, bytes);
        ends.writable.dropWritable(); // EOF
        awaitFuture(fut);
    }

    /// Receive up to `buf.len` bytes into `buf`, waiting on blocked reads.
    /// Returns the prefix read (shorter than `buf` at end-of-stream).
    pub fn recv(self: TcpStream, buf: []u8) []const u8 {
        const tup = self.socket.receive();
        const stream: ByteStream = tup[0];
        const fut: SendFut = tup[1];
        var len: usize = 0;
        while (len < buf.len) {
            const status = stream.read(buf[len..]);
            const code: u32 = if (status == BLOCKED) waitCode(stream.handle) else @bitCast(status);
            len += @as(usize, code >> 4);
            if (code & 0xf != 0) break; // closed / EOF
            if (code >> 4 == 0) break; // no progress
        }
        stream.dropReadable();
        awaitFuture(fut);
        return buf[0..len];
    }

    /// Drop the underlying socket handle.
    pub fn close(self: TcpStream) void {
        self.socket.deinit();
    }
};

/// Open a TCP connection to `remote` (creating + connecting a socket of the
/// matching address family). `connect` is async; it blocks until established.
pub fn connect(remote: IpSocketAddress) canon.Result(TcpStream, ErrorCode) {
    const sock = switch (TcpSocket.create(familyOf(remote))) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    switch (sock.connect(remote)) {
        .ok => {},
        .err => |e| {
            sock.deinit();
            return .{ .err = e };
        },
    }
    return .{ .ok = .{ .socket = sock } };
}

// ── TCP server ──────────────────────────────────────────────────────

/// A listening TCP socket whose `accept` yields inbound connections by reading
/// the `stream<tcp-socket>` the host produces — each element is an accepted
/// `tcp-socket` resource handle.
pub const TcpListener = struct {
    socket: TcpSocket,
    accepts: AcceptStream,

    /// Accept the next inbound connection, blocking until one arrives. Returns
    /// null when the accept stream closes.
    pub fn accept(self: TcpListener) ?TcpStream {
        var one: [1]TcpSocket = undefined;
        const status = self.accepts.read(&one);
        const code: u32 = if (status == BLOCKED) waitCode(self.accepts.handle) else @bitCast(status);
        if (code >> 4 == 0) return null; // closed / no socket delivered
        return .{ .socket = one[0] };
    }

    /// Stop listening: drop the accept stream and the listener socket.
    pub fn close(self: TcpListener) void {
        self.accepts.dropReadable();
        self.socket.deinit();
    }
};

/// Bind + listen on `local`; the returned listener's `accept` yields inbound
/// `TcpStream`s.
pub fn listen(local: IpSocketAddress) canon.Result(TcpListener, ErrorCode) {
    const sock = switch (TcpSocket.create(familyOf(local))) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    switch (sock.bind(local)) {
        .ok => {},
        .err => |e| {
            sock.deinit();
            return .{ .err = e };
        },
    }
    const accepts = switch (sock.listen()) {
        .ok => |s| s,
        .err => |e| {
            sock.deinit();
            return .{ .err = e };
        },
    };
    return .{ .ok = .{ .socket = sock, .accepts = accepts } };
}

// ── UDP ─────────────────────────────────────────────────────────────

/// Create + `connect` a UDP socket to `remote` (so `udpSend`/`udpRecv` use it as
/// the default peer).
pub fn udpConnect(remote: IpSocketAddress) canon.Result(UdpSocket, ErrorCode) {
    const sock = switch (UdpSocket.create(familyOf(remote))) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    switch (sock.connect(remote)) {
        .ok => {},
        .err => |e| {
            sock.deinit();
            return .{ .err = e };
        },
    }
    return .{ .ok = sock };
}

/// Send a UDP datagram (`remote` = null uses the connected peer). Async.
pub fn udpSend(sock: UdpSocket, bytes: []const u8, remote: ?IpSocketAddress) canon.Result(void, ErrorCode) {
    return sock.send(bytes, remote);
}

/// Receive a UDP datagram: the payload (borrows the scratch arena) + the sender
/// address. Async.
pub fn udpRecv(sock: UdpSocket) canon.Result(canon.Tuple(.{ []const u8, IpSocketAddress }), ErrorCode) {
    return sock.receive();
}
