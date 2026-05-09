//! wabt — WebAssembly Binary Toolkit (single-binary CLI).
//!
//! Commands are organized under six conceptual-subject roots:
//!
//!   wabt text <verb>        Text format (.wat) work
//!   wabt module <verb>      Core wasm (.wasm) work
//!   wabt component <verb>   Component-model (.wasm) work
//!   wabt interface <verb>   WIT IDL (.wit) work
//!   wabt compose <verb>     WAC composition (.wac) work
//!   wabt spec <verb>        Spec testing (.wast) work
//!   wabt version            Print version
//!   wabt help [topic]       Print help
//!
//! There is exactly one canonical spelling per command. Subject roots
//! are not aliased (`c`, `wit`, `wat`, `wasm`, `wast`, `wac` are all
//! rejected). See #137 for the reorganization rationale.

const std = @import("std");
const wabt = @import("wabt");

const text_cmd = @import("text.zig");
const module_cmd = @import("module.zig");
const component_cmd = @import("component.zig");
const interface_cmd = @import("interface.zig");
const compose_cmd = @import("compose.zig");
const spec_cmd = @import("spec.zig");

pub const Subcommand = enum {
    text,
    module,
    component,
    interface,
    compose,
    spec,
    version,
    help,
};

pub fn parseSubcommand(s: []const u8) ?Subcommand {
    if (std.mem.eql(u8, s, "text")) return .text;
    if (std.mem.eql(u8, s, "module")) return .module;
    if (std.mem.eql(u8, s, "component")) return .component;
    if (std.mem.eql(u8, s, "interface")) return .interface;
    if (std.mem.eql(u8, s, "compose")) return .compose;
    if (std.mem.eql(u8, s, "spec")) return .spec;
    if (std.mem.eql(u8, s, "version")) return .version;
    if (std.mem.eql(u8, s, "help")) return .help;
    return null;
}

pub fn writeStdout(io: std.Io, text: []const u8) void {
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io, text) catch {};
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        std.debug.print("error: missing subcommand — try `wabt help`\n", .{});
        std.process.exit(1);
    }

    const subcmd = parseSubcommand(args[1]) orelse {
        std.debug.print("error: unknown subcommand '{s}' — try `wabt help`\n", .{args[1]});
        std.process.exit(1);
    };

    const sub_args = args[2..];

    switch (subcmd) {
        .version => {
            writeStdout(init.io, "wabt " ++ wabt.version ++ "\n");
            return;
        },
        .help => runHelp(init.io, sub_args),
        .text => try text_cmd.run(init, sub_args),
        .module => try module_cmd.run(init, sub_args),
        .component => try component_cmd.run(init, sub_args),
        .interface => try interface_cmd.run(init, sub_args),
        .compose => try compose_cmd.run(init, sub_args),
        .spec => try spec_cmd.run(init, sub_args),
    }
}

const top_usage =
    \\wabt - WebAssembly Binary Toolkit
    \\
    \\Usage: wabt <subject> <verb> [args...]
    \\
    \\Subjects:
    \\  text       Text format (.wat) work — parse, print, desugar
    \\  module     Core wasm (.wasm) work — validate, objdump, strip, stats, decompile, shrink
    \\  component  Component-model work — new, embed, compose
    \\  interface  WIT IDL work — (planned; see #137)
    \\  compose    WAC composition work — (deferred; see #137)
    \\  spec       Spec testing (.wast) work — run, to-json
    \\
    \\Global:
    \\  version    Print the wabt version and exit
    \\  help       Print this help; `wabt help <subject>` for details
    \\
    \\Run `wabt help <subject>` for the verbs in that subject.
    \\
;

const version_usage =
    \\Usage: wabt version
    \\
    \\Print the wabt version and exit.
    \\
;

const help_usage =
    \\Usage: wabt help [topic]
    \\
    \\Print top-level help, or help for a specific subject.
    \\Examples:
    \\  wabt help              top-level overview
    \\  wabt help text         verbs in the `text` subject
    \\  wabt text help parse   help for `wabt text parse`
    \\
;

fn runHelp(io: std.Io, args: []const []const u8) void {
    if (args.len == 0) {
        writeStdout(io, top_usage);
        return;
    }
    const sub = parseSubcommand(args[0]) orelse {
        std.debug.print("error: unknown topic '{s}' — try `wabt help`\n", .{args[0]});
        std.process.exit(1);
    };
    switch (sub) {
        .text => writeStdout(io, text_cmd.usage),
        .module => writeStdout(io, module_cmd.usage),
        .component => writeStdout(io, component_cmd.usage),
        .interface => writeStdout(io, interface_cmd.usage),
        .compose => writeStdout(io, compose_cmd.usage),
        .spec => writeStdout(io, spec_cmd.usage),
        .version => writeStdout(io, version_usage),
        .help => writeStdout(io, help_usage),
    }
}

test "parseSubcommand recognizes subject roots" {
    try std.testing.expectEqual(@as(?Subcommand, .text), parseSubcommand("text"));
    try std.testing.expectEqual(@as(?Subcommand, .module), parseSubcommand("module"));
    try std.testing.expectEqual(@as(?Subcommand, .component), parseSubcommand("component"));
    try std.testing.expectEqual(@as(?Subcommand, .interface), parseSubcommand("interface"));
    try std.testing.expectEqual(@as(?Subcommand, .compose), parseSubcommand("compose"));
    try std.testing.expectEqual(@as(?Subcommand, .spec), parseSubcommand("spec"));
    try std.testing.expectEqual(@as(?Subcommand, .version), parseSubcommand("version"));
    try std.testing.expectEqual(@as(?Subcommand, .help), parseSubcommand("help"));
}

test "parseSubcommand rejects flat verbs (no longer top-level)" {
    // The old flat verbs are now reachable only via their subject.
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("parse"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("print"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("validate"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("objdump"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("strip"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("json-from-wast"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("decompile"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("stats"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("desugar"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("spectest"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("shrink"));
}

test "parseSubcommand rejects unknown and old names" {
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand(""));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("--help"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("-h"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("--version"));
    // Old C++-era binary names are not aliased.
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("wat2wasm"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("wasm2wat"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("wast2json"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("spectest-interp"));
    // No aliases: `c` is not `component`, `wit` is not `interface`.
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("c"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("wit"));
    // No top-level `wat` / `wasm` / `wast` / `wac` either — those are
    // file extensions, not subjects (per #137 naming conventions).
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("wat"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("wasm"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("wast"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("wac"));
}
