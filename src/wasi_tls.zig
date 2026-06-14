//! `wasi_tls` — minimal guest bindings for the `wasi:tls@0.2.0-draft`
//! proposal (the `types` interface handshake handles).
//!
//! Demand-driven: the handshake-result decode (`future-client-streams.get`
//! → `option<result<result<tuple<connection, in, out>, io-error>>>`) is not
//! yet wrapped; only the handle plumbing is bound so far.

const io = @import("wasi_io");

/// `[constructor]client-handshake(server-name: string, input: input-stream,
///   output: output-stream) -> own<client-handshake>`.
extern "wasi:tls/types@0.2.0-draft" fn @"[constructor]client-handshake"(
    name_ptr: i32,
    name_len: i32,
    input: i32,
    output: i32,
) i32;
/// `[static]client-handshake.finish(this: own<client-handshake>)
///   -> own<future-client-streams>`. Consumes `this`.
extern "wasi:tls/types@0.2.0-draft" fn @"[static]client-handshake.finish"(this: i32) i32;
/// `[resource-drop]client-handshake`.
extern "wasi:tls/types@0.2.0-draft" fn @"[resource-drop]client-handshake"(self: i32) void;
/// `[method]future-client-streams.subscribe(borrow) -> own<pollable>`.
extern "wasi:tls/types@0.2.0-draft" fn @"[method]future-client-streams.subscribe"(self: i32) i32;
/// `[resource-drop]future-client-streams`.
extern "wasi:tls/types@0.2.0-draft" fn @"[resource-drop]future-client-streams"(self: i32) void;
/// `[method]client-connection.close-output(borrow)`.
extern "wasi:tls/types@0.2.0-draft" fn @"[method]client-connection.close-output"(self: i32) void;
/// `[resource-drop]client-connection`.
extern "wasi:tls/types@0.2.0-draft" fn @"[resource-drop]client-connection"(self: i32) void;

/// A `wasi:tls/types.client-handshake` handle.
pub const ClientHandshake = struct {
    handle: i32,

    /// Begin a client TLS handshake over the given byte streams.
    pub fn init(server_name: []const u8, input: io.InputStream, output: io.OutputStream) ClientHandshake {
        return .{ .handle = @"[constructor]client-handshake"(
            @intCast(@intFromPtr(server_name.ptr)),
            @intCast(server_name.len),
            input.handle,
            output.handle,
        ) };
    }

    /// Drive the handshake; returns a future yielding the connection and
    /// its plaintext streams. Consumes the handshake handle.
    pub fn finish(self: ClientHandshake) FutureClientStreams {
        return .{ .handle = @"[static]client-handshake.finish"(self.handle) };
    }

    pub fn drop(self: ClientHandshake) void {
        @"[resource-drop]client-handshake"(self.handle);
    }
};

/// A `wasi:tls/types.future-client-streams` handle.
pub const FutureClientStreams = struct {
    handle: i32,

    /// A pollable that becomes ready when the handshake completes.
    pub fn subscribe(self: FutureClientStreams) io.Pollable {
        return .{ .handle = @"[method]future-client-streams.subscribe"(self.handle) };
    }

    pub fn drop(self: FutureClientStreams) void {
        @"[resource-drop]future-client-streams"(self.handle);
    }
};

/// A `wasi:tls/types.client-connection` handle.
pub const ClientConnection = struct {
    handle: i32,

    /// Signal that the guest will send no more plaintext.
    pub fn closeOutput(self: ClientConnection) void {
        @"[method]client-connection.close-output"(self.handle);
    }

    pub fn drop(self: ClientConnection) void {
        @"[resource-drop]client-connection"(self.handle);
    }
};
