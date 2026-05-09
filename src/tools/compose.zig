//! `wabt compose <verb>` — dispatch WAC composition (.wac) subcommands.
//!
//! The `compose` subject covers the WAC composition language. It
//! ships in phase 1 with **no verbs implemented**. The dispatcher
//! exists for taxonomic uniformity — `wabt help compose` reports the
//! original planned verbs that were filed and closed as not planned
//! (#138 – #142). Future WAC integration will require new issues.

const std = @import("std");

pub const usage =
    \\Usage: wabt compose <verb> [args...]
    \\
    \\WAC composition (.wac) subcommands:
    \\  (none — issues #138 – #142 were closed as not planned)
    \\
    \\See umbrella issue #137 for the reorganization plan.
    \\
;

pub fn run(init: std.process.Init, sub_args: []const []const u8) !void {
    if (sub_args.len == 0) {
        std.debug.print("error: missing compose verb — `wabt compose` ships with no verbs (see #137)\n", .{});
        std.process.exit(1);
    }
    if (std.mem.eql(u8, sub_args[0], "help")) {
        writeStdout(init.io, usage);
        return;
    }
    std.debug.print("error: unknown compose verb '{s}' — `wabt compose` ships with no verbs (see #137)\n", .{sub_args[0]});
    std.process.exit(1);
}

fn writeStdout(io: std.Io, text: []const u8) void {
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io, text) catch {};
}

test "compose dispatcher exists with empty verb table" {
    try std.testing.expect(usage.len > 0);
}
