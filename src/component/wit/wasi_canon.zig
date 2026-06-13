//! Embedded canonical WASI 0.2.6 WIT packages.
//!
//! The full `wasip2` interface tree from
//! https://github.com/WebAssembly/WASI/tree/v0.2.6/wasip2 is vendored
//! verbatim under `wasi-canon/<pkg>/*.wit` and `@embedFile`d here so the
//! CLI can resolve `wasi:*@0.2.x` references without an on-disk
//! `wit/deps/` copy. Every file is byte-for-byte identical to upstream
//! `v0.2.6`; the set is pinned at that version.
//!
//! This module is the single source of truth for the embedded set: both
//! the resolver (embedded-fallback docs) and the parser acceptance test
//! consume `packages` from here.

const std = @import("std");

/// One embedded `.wit` file. `path` is informational (used in error
/// messages); `content` is the verbatim source text.
pub const File = struct {
    path: []const u8,
    content: []const u8,
};

/// A canonical WASI package: a `wasi:<name>@0.2.6` package made of one
/// or more `.wit` files that share a single `package` declaration.
pub const Package = struct {
    /// Bare package name (e.g. `io`, `http`); the namespace is `wasi`.
    name: []const u8,
    /// Member files. The combined source carries one `package
    /// wasi:<name>@0.2.6;` declaration.
    files: []const File,
};

/// The pinned canonical version of every embedded package.
pub const version = "0.2.6";

fn f(comptime path: []const u8) File {
    return .{ .path = path, .content = @embedFile("wasi-canon/" ++ path) };
}

/// All canonical WASI 0.2.6 packages, grouped by package.
pub const packages = [_]Package{
    .{ .name = "cli", .files = &.{
        f("cli/command.wit"),
        f("cli/environment.wit"),
        f("cli/exit.wit"),
        f("cli/imports.wit"),
        f("cli/run.wit"),
        f("cli/stdio.wit"),
        f("cli/terminal.wit"),
    } },
    .{ .name = "clocks", .files = &.{
        f("clocks/monotonic-clock.wit"),
        f("clocks/timezone.wit"),
        f("clocks/wall-clock.wit"),
        f("clocks/world.wit"),
    } },
    .{ .name = "filesystem", .files = &.{
        f("filesystem/preopens.wit"),
        f("filesystem/types.wit"),
        f("filesystem/world.wit"),
    } },
    .{ .name = "http", .files = &.{
        f("http/handler.wit"),
        f("http/proxy.wit"),
        f("http/types.wit"),
    } },
    .{ .name = "io", .files = &.{
        f("io/error.wit"),
        f("io/poll.wit"),
        f("io/streams.wit"),
        f("io/world.wit"),
    } },
    .{ .name = "random", .files = &.{
        f("random/insecure-seed.wit"),
        f("random/insecure.wit"),
        f("random/random.wit"),
        f("random/world.wit"),
    } },
    .{ .name = "sockets", .files = &.{
        f("sockets/instance-network.wit"),
        f("sockets/ip-name-lookup.wit"),
        f("sockets/network.wit"),
        f("sockets/tcp-create-socket.wit"),
        f("sockets/tcp.wit"),
        f("sockets/udp-create-socket.wit"),
        f("sockets/udp.wit"),
        f("sockets/world.wit"),
    } },
};

/// Iterate every embedded file across all packages (declaration order).
/// Convenience for callers (e.g. the parser acceptance test) that want
/// the flat list rather than the per-package grouping.
pub fn eachFile(comptime cb: fn (File) void) void {
    inline for (packages) |pkg| {
        inline for (pkg.files) |file| cb(file);
    }
}
