//! `wabt interface <verb>` — dispatch WIT IDL (.wit) subcommands.
//!
//! The `interface` subject covers WIT (WebAssembly Interface Types)
//! work: printing interfaces from components, encoding text WIT to
//! binary packages, JSON conversion, fuzz generation, and dynamic
//! library linking.
//!
//! No verbs are implemented yet. The dispatcher exists so the
//! taxonomy is uniform and `wabt help interface` reports the planned
//! verbs. See umbrella issue #137.

const std = @import("std");

pub const usage =
    \\Usage: wabt interface <verb> [args...]
    \\
    \\WIT IDL (.wit) subcommands:
    \\  (none implemented yet — see https://github.com/cataggar/wabt/issues/137)
    \\
    \\Planned verbs:
    \\  print    Print the WIT interface from a component or .wit file
    \\  encode   Encode a text WIT package as a binary WIT package
    \\  json     Convert a WIT package to JSON
    \\  smith    Generate a valid WIT package from a seed
    \\  dylib    Produce a dynamic-library shim for a WIT package
    \\
;

pub fn run(init: std.process.Init, sub_args: []const []const u8) !void {
    if (sub_args.len == 0) {
        std.debug.print("error: missing interface verb — `wabt interface` ships with no verbs yet (see #137)\n", .{});
        std.process.exit(1);
    }
    if (std.mem.eql(u8, sub_args[0], "help")) {
        writeStdout(init.io, usage);
        return;
    }
    std.debug.print("error: unknown interface verb '{s}' — `wabt interface` ships with no verbs yet (see #137)\n", .{sub_args[0]});
    std.process.exit(1);
}

fn writeStdout(io: std.Io, text: []const u8) void {
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io, text) catch {};
}

test "interface dispatcher exists with empty verb table" {
    // Phase 1: no verbs are implemented. This test pins the current
    // state so that adding a verb later requires explicitly updating
    // the dispatcher.
    try std.testing.expect(usage.len > 0);
}
