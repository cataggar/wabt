//! `wabt text <verb>` — dispatch text-format (.wat) subcommands.
//!
//! The `text` subject covers WAT text format work: parsing text to
//! binary, printing binary back to text, and round-tripping text
//! through the parser.

const std = @import("std");

const parse_cmd = @import("parse.zig");
const print_cmd = @import("print.zig");
const desugar_cmd = @import("desugar.zig");

pub const usage =
    \\Usage: wabt text <verb> [args...]
    \\
    \\Text-format (.wat) subcommands:
    \\  parse    Translate WebAssembly text format to binary (was wat2wasm)
    \\  print    Print a wasm binary as WebAssembly text format (was wasm2wat)
    \\  desugar  Parse and re-emit WebAssembly text format
    \\
    \\Run `wabt help text <verb>` for verb-specific help.
    \\
;

pub const Verb = enum {
    parse,
    print,
    desugar,
    help,
};

pub fn parseVerb(s: []const u8) ?Verb {
    if (std.mem.eql(u8, s, "parse")) return .parse;
    if (std.mem.eql(u8, s, "print")) return .print;
    if (std.mem.eql(u8, s, "desugar")) return .desugar;
    if (std.mem.eql(u8, s, "help")) return .help;
    return null;
}

pub fn run(init: std.process.Init, sub_args: []const []const u8) !void {
    if (sub_args.len == 0) {
        std.debug.print("error: missing text verb — try `wabt help text`\n", .{});
        std.process.exit(1);
    }
    const verb = parseVerb(sub_args[0]) orelse {
        std.debug.print("error: unknown text verb '{s}' — try `wabt help text`\n", .{sub_args[0]});
        std.process.exit(1);
    };
    const verb_args = sub_args[1..];
    switch (verb) {
        .parse => try parse_cmd.run(init, verb_args),
        .print => try print_cmd.run(init, verb_args),
        .desugar => try desugar_cmd.run(init, verb_args),
        .help => {
            if (verb_args.len == 0) {
                writeStdout(init.io, usage);
                return;
            }
            const v = parseVerb(verb_args[0]) orelse {
                std.debug.print("error: unknown text verb '{s}'\n", .{verb_args[0]});
                std.process.exit(1);
            };
            writeStdout(init.io, switch (v) {
                .parse => parse_cmd.usage,
                .print => print_cmd.usage,
                .desugar => desugar_cmd.usage,
                .help => usage,
            });
        },
    }
}

fn writeStdout(io: std.Io, text: []const u8) void {
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io, text) catch {};
}

test "parseVerb recognizes all text verbs" {
    try std.testing.expectEqual(@as(?Verb, .parse), parseVerb("parse"));
    try std.testing.expectEqual(@as(?Verb, .print), parseVerb("print"));
    try std.testing.expectEqual(@as(?Verb, .desugar), parseVerb("desugar"));
    try std.testing.expectEqual(@as(?Verb, .help), parseVerb("help"));
}

test "parseVerb rejects unknown text verbs" {
    try std.testing.expectEqual(@as(?Verb, null), parseVerb(""));
    try std.testing.expectEqual(@as(?Verb, null), parseVerb("validate"));
    try std.testing.expectEqual(@as(?Verb, null), parseVerb("wat2wasm"));
}
