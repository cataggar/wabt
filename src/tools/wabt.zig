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
//! During the migration the old flat verbs (`wabt parse`, `wabt
//! validate`, …) continue to dispatch to the same underlying
//! modules. They are transparent passthroughs and will be marked
//! deprecated, then removed, in later phases of #137.

const std = @import("std");
const wabt = @import("wabt");

const parse_cmd = @import("parse.zig");
const print_cmd = @import("print.zig");
const validate_cmd = @import("validate.zig");
const objdump_cmd = @import("objdump.zig");
const strip_cmd = @import("strip.zig");
const json_from_wast_cmd = @import("json_from_wast.zig");
const decompile_cmd = @import("decompile.zig");
const stats_cmd = @import("stats.zig");
const desugar_cmd = @import("desugar.zig");
const spectest_cmd = @import("spectest.zig");
const shrink_cmd = @import("shrink.zig");
const component_cmd = @import("component.zig");
const text_cmd = @import("text.zig");
const module_cmd = @import("module.zig");
const interface_cmd = @import("interface.zig");
const compose_cmd = @import("compose.zig");
const spec_cmd = @import("spec.zig");

pub const Subcommand = enum {
    // Subject roots (canonical):
    text,
    module,
    component,
    interface,
    compose,
    spec,
    // Global:
    version,
    help,
    // Flat verbs (transparent passthrough during migration; will be
    // deprecated then removed per #137):
    parse,
    print,
    validate,
    objdump,
    strip,
    json_from_wast,
    decompile,
    stats,
    desugar,
    spectest,
    shrink,
};

pub fn parseSubcommand(s: []const u8) ?Subcommand {
    // Subject roots first (the canonical entry points).
    if (std.mem.eql(u8, s, "text")) return .text;
    if (std.mem.eql(u8, s, "module")) return .module;
    if (std.mem.eql(u8, s, "component")) return .component;
    if (std.mem.eql(u8, s, "interface")) return .interface;
    if (std.mem.eql(u8, s, "compose")) return .compose;
    if (std.mem.eql(u8, s, "spec")) return .spec;
    // Global.
    if (std.mem.eql(u8, s, "version")) return .version;
    if (std.mem.eql(u8, s, "help")) return .help;
    // Flat passthroughs (migration aids).
    if (std.mem.eql(u8, s, "parse")) return .parse;
    if (std.mem.eql(u8, s, "print")) return .print;
    if (std.mem.eql(u8, s, "validate")) return .validate;
    if (std.mem.eql(u8, s, "objdump")) return .objdump;
    if (std.mem.eql(u8, s, "strip")) return .strip;
    if (std.mem.eql(u8, s, "json-from-wast")) return .json_from_wast;
    if (std.mem.eql(u8, s, "decompile")) return .decompile;
    if (std.mem.eql(u8, s, "stats")) return .stats;
    if (std.mem.eql(u8, s, "desugar")) return .desugar;
    if (std.mem.eql(u8, s, "spectest")) return .spectest;
    if (std.mem.eql(u8, s, "shrink")) return .shrink;
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
        // Subject dispatchers.
        .text => try text_cmd.run(init, sub_args),
        .module => try module_cmd.run(init, sub_args),
        .component => try component_cmd.run(init, sub_args),
        .interface => try interface_cmd.run(init, sub_args),
        .compose => try compose_cmd.run(init, sub_args),
        .spec => try spec_cmd.run(init, sub_args),
        // Flat passthroughs.
        .parse => try parse_cmd.run(init, sub_args),
        .print => try print_cmd.run(init, sub_args),
        .validate => try validate_cmd.run(init, sub_args),
        .objdump => try objdump_cmd.run(init, sub_args),
        .strip => try strip_cmd.run(init, sub_args),
        .json_from_wast => try json_from_wast_cmd.run(init, sub_args),
        .decompile => try decompile_cmd.run(init, sub_args),
        .stats => try stats_cmd.run(init, sub_args),
        .desugar => try desugar_cmd.run(init, sub_args),
        .spectest => try spectest_cmd.run(init, sub_args),
        .shrink => try shrink_cmd.run(init, sub_args),
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
    \\During migration the old flat verb names (parse, print,
    \\validate, objdump, strip, json-from-wast, decompile, stats,
    \\desugar, spectest, shrink) still work as transparent
    \\passthroughs. They will be deprecated and removed per #137.
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
    \\Print top-level help, or help for a specific subject or flat verb.
    \\Examples:
    \\  wabt help              top-level overview
    \\  wabt help text         verbs in the `text` subject
    \\  wabt help text parse   help for `wabt text parse`
    \\  wabt help validate     help for the (deprecated) flat `wabt validate`
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
        // Subject roots: print the subject overview. For verb-specific
        // help, run `wabt <subject> help <verb>` directly.
        .text => writeStdout(io, text_cmd.usage),
        .module => writeStdout(io, module_cmd.usage),
        .component => writeStdout(io, component_cmd.usage),
        .interface => writeStdout(io, interface_cmd.usage),
        .compose => writeStdout(io, compose_cmd.usage),
        .spec => writeStdout(io, spec_cmd.usage),
        // Flat passthroughs.
        .parse => writeStdout(io, parse_cmd.usage),
        .print => writeStdout(io, print_cmd.usage),
        .validate => writeStdout(io, validate_cmd.usage),
        .objdump => writeStdout(io, objdump_cmd.usage),
        .strip => writeStdout(io, strip_cmd.usage),
        .json_from_wast => writeStdout(io, json_from_wast_cmd.usage),
        .decompile => writeStdout(io, decompile_cmd.usage),
        .stats => writeStdout(io, stats_cmd.usage),
        .desugar => writeStdout(io, desugar_cmd.usage),
        .spectest => writeStdout(io, spectest_cmd.usage),
        .shrink => writeStdout(io, shrink_cmd.usage),
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
}

test "parseSubcommand recognizes flat passthroughs (migration aids)" {
    try std.testing.expectEqual(@as(?Subcommand, .parse), parseSubcommand("parse"));
    try std.testing.expectEqual(@as(?Subcommand, .print), parseSubcommand("print"));
    try std.testing.expectEqual(@as(?Subcommand, .validate), parseSubcommand("validate"));
    try std.testing.expectEqual(@as(?Subcommand, .objdump), parseSubcommand("objdump"));
    try std.testing.expectEqual(@as(?Subcommand, .strip), parseSubcommand("strip"));
    try std.testing.expectEqual(@as(?Subcommand, .json_from_wast), parseSubcommand("json-from-wast"));
    try std.testing.expectEqual(@as(?Subcommand, .decompile), parseSubcommand("decompile"));
    try std.testing.expectEqual(@as(?Subcommand, .stats), parseSubcommand("stats"));
    try std.testing.expectEqual(@as(?Subcommand, .desugar), parseSubcommand("desugar"));
    try std.testing.expectEqual(@as(?Subcommand, .spectest), parseSubcommand("spectest"));
    try std.testing.expectEqual(@as(?Subcommand, .shrink), parseSubcommand("shrink"));
    try std.testing.expectEqual(@as(?Subcommand, .version), parseSubcommand("version"));
    try std.testing.expectEqual(@as(?Subcommand, .help), parseSubcommand("help"));
}

test "parseSubcommand rejects unknown and old names" {
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand(""));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("--help"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("-h"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("--version"));
    // Old binary names are not aliased — clean break.
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("wat2wasm"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("wasm2wat"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("wast2json"));
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("spectest-interp"));
    // json_from_wast uses hyphens externally, not snake_case.
    try std.testing.expectEqual(@as(?Subcommand, null), parseSubcommand("json_from_wast"));
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
