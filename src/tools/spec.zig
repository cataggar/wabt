//! `wabt spec <verb>` — dispatch spec-test (.wast) subcommands.
//!
//! The `spec` subject covers WebAssembly spec testing: running
//! .wast assertion files, converting them to JSON commands, and
//! structural validation of .wast inputs.

const std = @import("std");

const spectest_cmd = @import("spectest.zig");
const json_from_wast_cmd = @import("json_from_wast.zig");

pub const usage =
    \\Usage: wabt spec <verb> [args...]
    \\
    \\Spec-test (.wast) subcommands:
    \\  run      Run a WebAssembly spec test (.wast) (was spectest / spectest-interp)
    \\  to-json  Convert a .wast spec test to JSON + .wasm files (was wast2json / json-from-wast)
    \\
    \\Planned (not yet implemented — see #137):
    \\  validate  Structurally validate a .wast file
    \\
    \\Run `wabt help spec <verb>` for verb-specific help.
    \\
;

pub const Verb = enum {
    run,
    to_json,
    help,
};

pub fn parseVerb(s: []const u8) ?Verb {
    if (std.mem.eql(u8, s, "run")) return .run;
    if (std.mem.eql(u8, s, "to-json")) return .to_json;
    if (std.mem.eql(u8, s, "help")) return .help;
    return null;
}

pub fn run(init: std.process.Init, sub_args: []const []const u8) !void {
    if (sub_args.len == 0) {
        std.debug.print("error: missing spec verb — try `wabt help spec`\n", .{});
        std.process.exit(1);
    }
    const verb = parseVerb(sub_args[0]) orelse {
        std.debug.print("error: unknown spec verb '{s}' — try `wabt help spec`\n", .{sub_args[0]});
        std.process.exit(1);
    };
    const verb_args = sub_args[1..];
    switch (verb) {
        .run => try spectest_cmd.run(init, verb_args),
        .to_json => try json_from_wast_cmd.run(init, verb_args),
        .help => {
            if (verb_args.len == 0) {
                writeStdout(init.io, usage);
                return;
            }
            const v = parseVerb(verb_args[0]) orelse {
                std.debug.print("error: unknown spec verb '{s}'\n", .{verb_args[0]});
                std.process.exit(1);
            };
            writeStdout(init.io, switch (v) {
                .run => spectest_cmd.usage,
                .to_json => json_from_wast_cmd.usage,
                .help => usage,
            });
        },
    }
}

fn writeStdout(io: std.Io, text: []const u8) void {
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io, text) catch {};
}

test "parseVerb recognizes all spec verbs" {
    try std.testing.expectEqual(@as(?Verb, .run), parseVerb("run"));
    try std.testing.expectEqual(@as(?Verb, .to_json), parseVerb("to-json"));
    try std.testing.expectEqual(@as(?Verb, .help), parseVerb("help"));
}

test "parseVerb rejects unknown spec verbs" {
    try std.testing.expectEqual(@as(?Verb, null), parseVerb(""));
    try std.testing.expectEqual(@as(?Verb, null), parseVerb("spectest"));
    try std.testing.expectEqual(@as(?Verb, null), parseVerb("validate"));
    try std.testing.expectEqual(@as(?Verb, null), parseVerb("wast2json"));
    try std.testing.expectEqual(@as(?Verb, null), parseVerb("json-from-wast"));
    try std.testing.expectEqual(@as(?Verb, null), parseVerb("to_json"));
}
