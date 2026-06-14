//! Embedded canonical WASI WIT packages (multi-version).
//!
//! Canonical `wasi:*` packages are vendored verbatim under
//! `wasi-canon/<version>/<pkg>/*.wit` and `@embedFile`d here so the CLI
//! can resolve `wasi:*@<ver>` references without an on-disk
//! `wit/deps/` copy (issue 261). Files are byte-for-byte identical to
//! their upstream git tag; `scripts/vendor_wasi_wit.py` regenerates the
//! tree and documents the source repo + tag for every version.
//!
//! Sources (see the vendoring script's manifest):
//!   * core  — github.com/WebAssembly/WASI tags `v0.2.6`, `v0.2.12`
//!     (cli, clocks, filesystem, http, io, random, sockets).
//!   * proposals (off by default, separate repos):
//!     `wasi:config@0.2.0-rc.1`, `wasi:keyvalue@0.2.0-draft`,
//!     `wasi:nn@0.2.0-rc-2024-10-28`, `wasi:tls@0.2.0-draft`.
//!
//! Resolution precedence for an UNVERSIONED `wasi:*` reference follows
//! `version_sets` order (newest first), so an unversioned `wasi:io`
//! resolves against the newest embedded version. Versioned references
//! (`wasi:io@0.2.6`) select the exact matching version regardless of
//! order via the resolver's version-aware `packageMatches`.
//!
//! NOTE: WASI 0.3.0 (P3) is vendored under `wasi-canon/0.3.0/` but is
//! NOT yet listed in `version_sets`: its `future<T>`/`stream<T>`/
//! `error-context` types are not yet accepted by the parser. It is
//! wired in once parser support lands.
//!
//! This module is the single source of truth for the embedded set: both
//! the resolver (embedded-fallback docs) and the parser acceptance test
//! consume `version_sets` from here.

const std = @import("std");

/// One embedded `.wit` file. `path` is informational (used in error
/// messages); `content` is the verbatim source text. `path` is the
/// version-relative path, e.g. `0.2.6/io/poll.wit`.
pub const File = struct {
    path: []const u8,
    content: []const u8,
};

/// A canonical WASI package: a `wasi:<name>@<ver>` package made of one
/// or more `.wit` files that share a single `package` declaration.
pub const Package = struct {
    /// Bare package name (e.g. `io`, `http`); the namespace is `wasi`.
    name: []const u8,
    /// Member files. The combined source carries one `package
    /// wasi:<name>@<ver>;` declaration.
    files: []const File,
};

/// All packages vendored at a single `wasi-canon/<version>/` directory.
/// `version` is the directory name and the package version string the
/// member packages declare (it doubles as the `@embedFile` path prefix).
pub const VersionSet = struct {
    version: []const u8,
    packages: []const Package,
};

fn f(comptime path: []const u8) File {
    return .{ .path = path, .content = @embedFile("wasi-canon/" ++ path) };
}

/// Build one `Package` from a version dir, package name, and member
/// file basenames. Paths are `<version>/<name>/<file>`.
fn pkg(
    comptime version: []const u8,
    comptime name: []const u8,
    comptime files: []const []const u8,
) Package {
    var fs: [files.len]File = undefined;
    inline for (files, 0..) |fname, i| {
        fs[i] = f(version ++ "/" ++ name ++ "/" ++ fname);
    }
    const frozen = fs;
    return .{ .name = name, .files = &frozen };
}

/// The seven core `wasi:*` packages shared by the 0.2.x P2 tags. The
/// member file set is identical across 0.2.6 and 0.2.12.
fn coreP2(comptime version: []const u8) []const Package {
    const list = [_]Package{
        pkg(version, "cli", &.{
            "command.wit",     "environment.wit", "exit.wit", "imports.wit",
            "run.wit",         "stdio.wit",       "terminal.wit",
        }),
        pkg(version, "clocks", &.{
            "monotonic-clock.wit", "timezone.wit", "wall-clock.wit", "world.wit",
        }),
        pkg(version, "filesystem", &.{ "preopens.wit", "types.wit", "world.wit" }),
        pkg(version, "http", &.{ "handler.wit", "proxy.wit", "types.wit" }),
        pkg(version, "io", &.{ "error.wit", "poll.wit", "streams.wit", "world.wit" }),
        pkg(version, "random", &.{
            "insecure-seed.wit", "insecure.wit", "random.wit", "world.wit",
        }),
        pkg(version, "sockets", &.{
            "instance-network.wit",  "ip-name-lookup.wit",    "network.wit",
            "tcp-create-socket.wit", "tcp.wit",               "udp-create-socket.wit",
            "udp.wit",               "world.wit",
        }),
    };
    const frozen = list;
    return &frozen;
}

/// Every embedded version set, in resolution-precedence order (newest
/// first) so unversioned `wasi:*` references prefer the newest version.
pub const version_sets = [_]VersionSet{
    .{ .version = "0.2.12", .packages = coreP2("0.2.12") },
    .{ .version = "0.2.6", .packages = coreP2("0.2.6") },
    .{ .version = "0.2.0-rc.1", .packages = &.{
        pkg("0.2.0-rc.1", "config", &.{ "store.wit", "world.wit" }),
    } },
    .{ .version = "0.2.0-draft", .packages = &.{
        pkg("0.2.0-draft", "keyvalue", &.{
            "atomic.wit", "batch.wit", "store.wit", "watch.wit", "world.wit",
        }),
        pkg("0.2.0-draft", "tls", &.{ "types.wit", "world.wit" }),
    } },
    .{ .version = "0.2.0-rc-2024-10-28", .packages = &.{
        pkg("0.2.0-rc-2024-10-28", "nn", &.{"wasi-nn.wit"}),
    } },
};

/// Iterate every embedded file across all version sets (declaration
/// order). Convenience for callers (e.g. the parser acceptance test)
/// that want the flat list rather than the per-package grouping.
pub fn eachFile(comptime cb: fn (File) void) void {
    inline for (version_sets) |vs| {
        inline for (vs.packages) |p| {
            inline for (p.files) |file| cb(file);
        }
    }
}
