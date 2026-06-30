//! A demo `wasi:cli` command that walks every petstore endpoint in order.
//!
//! It makes outgoing requests through `wasi_http_client` (the host's outgoing
//! HTTP client, imported as `wasi:http/client@0.3.0` and provided by `wasmtime
//! run -S http`) and prints a transcript to stdout. The target authority
//! (`host:port`) is taken from the first non-`.wasm` program argument, then the
//! `BASE_URL` environment variable, then defaults to `localhost:8080` — so a
//! `zig build serve` in another terminal can be driven with
//! `zig build run-client` (optionally `-- 127.0.0.1:8080`).

const std = @import("std");
const cli = @import("wasi_cli");
const http = @import("wasi_http_client");

const Method = http.Method;

// ── transcript helpers ──────────────────────────────────────────────

fn emit(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    cli.print(s);
}

fn methodName(method: Method) []const u8 {
    return switch (method) {
        .get => "GET",
        .post => "POST",
        .delete => "DELETE",
        else => "?",
    };
}

var resp_buf: [64 * 1024]u8 = undefined;

fn step(authority: []const u8, method: Method, path: []const u8, body: ?[]const u8) void {
    emit("\n=== {s} {s} ===\n", .{ methodName(method), path });
    if (body) |b| emit("> {s}\n", .{b});
    if (http.request(authority, method, path, body, &resp_buf)) |reply| {
        emit("< {d}\n< {s}\n", .{ reply.status, reply.body });
    } else {
        emit("< request failed (transport error)\n", .{});
    }
}

// ── authority resolution ────────────────────────────────────────────

const default_authority = "localhost:8080";

fn stripScheme(s: []const u8) []const u8 {
    var v = s;
    if (std.mem.startsWith(u8, v, "http://")) v = v["http://".len..];
    if (std.mem.endsWith(u8, v, "/")) v = v[0 .. v.len - 1];
    return v;
}

fn resolveAuthority() []const u8 {
    // First a program argument that isn't the component path.
    for (cli.arguments()) |a| {
        if (std.mem.endsWith(u8, a, ".wasm")) continue;
        if (a.len == 0) continue;
        return stripScheme(a);
    }
    // Then the `BASE_URL` environment variable.
    for (cli.environment()) |kv| {
        if (std.mem.eql(u8, kv[0], "BASE_URL") and kv[1].len != 0) return stripScheme(kv[1]);
    }
    return default_authority;
}

fn run() u8 {
    const authority = resolveAuthority();
    emit("petstore demo client -> http://{s}\n", .{authority});

    // Walk every endpoint in order.
    step(authority, Method.get, "/pets", null); // initial list
    step(authority, Method.post, "/pets", "{\"name\":\"Whiskers\",\"tag\":\"cat\",\"age\":2}"); // create
    step(authority, Method.post, "/pets", "{\"name\":\"bad\"}"); // invalid -> 400
    step(authority, Method.get, "/pets/1", null); // read one
    step(authority, Method.get, "/pets/1/toys", null); // sub-resource
    step(authority, Method.delete, "/pets/2", null); // delete
    step(authority, Method.get, "/pets/2", null); // gone -> 404
    step(authority, Method.get, "/pets", null); // final list

    emit("\ndone\n", .{});
    return 0;
}

comptime {
    cli.run(run);
}
