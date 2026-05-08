//! wabt — WebAssembly Binary Toolkit (single-binary CLI).
//!
//! All wabt tools are exposed as bare-word subcommands of one `wabt`
//! executable, mirroring the `wasm-tools` and `zig` style:
//!
//!   wabt parse <file.wat>           Translate WAT text to wasm binary
//!   wabt print <file.wasm>          Print wasm binary as WAT text
//!   wabt validate <file.wasm>       Validate a wasm binary
//!   wabt objdump <file.wasm>        Dump wasm section info
//!   wabt strip <file.wasm>          Strip custom sections
//!   wabt json-from-wast <file.wast> Convert .wast to JSON + wasm
//!   wabt decompile <file.wasm>      Decompile to readable pseudo-code
//!   wabt stats <file.wasm>          Show module statistics
//!   wabt desugar <file.wat>         Round-trip .wat through the parser
//!   wabt spectest <file.wast>       Run a WebAssembly spec test
//!   wabt version                    Print version
//!   wabt help [subcommand]          Print help

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

pub const Subcommand = enum {
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
    version,
    help,
};

pub fn parseSubcommand(s: []const u8) ?Subcommand {
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
    \\Usage: wabt <subcommand> [args...]
    \\
    \\Subcommands:
    \\  parse           Translate WebAssembly text format to binary (was wat2wasm)
    \\  print           Print a wasm binary as WebAssembly text format (was wasm2wat)
    \\  validate        Validate a WebAssembly binary
    \\  objdump         Dump information about a WebAssembly binary
    \\  strip           Strip custom sections from a WebAssembly binary
    \\  json-from-wast  Convert a .wast spec test to JSON + .wasm files (was wast2json)
    \\  decompile       Decompile a wasm binary into readable pseudo-code
    \\  stats           Print module statistics
    \\  desugar         Parse and re-emit WebAssembly text format
    \\  spectest        Run a WebAssembly spec test (.wast)
    \\  shrink          Minimize a wasm binary while preserving a property
    \\  version         Print the wabt version and exit
    \\  help            Print this help; `wabt help <subcommand>` for details
    \\
;

const version_usage =
    \\Usage: wabt version
    \\
    \\Print the wabt version and exit.
    \\
;

const help_usage =
    \\Usage: wabt help [subcommand]
    \\
    \\Print top-level help, or help for a specific subcommand.
    \\
;

fn runHelp(io: std.Io, args: []const []const u8) void {
    if (args.len == 0) {
        writeStdout(io, top_usage);
        return;
    }
    const sub = parseSubcommand(args[0]) orelse {
        std.debug.print("error: unknown subcommand '{s}' — try `wabt help`\n", .{args[0]});
        std.process.exit(1);
    };
    writeStdout(io, switch (sub) {
        .parse => parse_cmd.usage,
        .print => print_cmd.usage,
        .validate => validate_cmd.usage,
        .objdump => objdump_cmd.usage,
        .strip => strip_cmd.usage,
        .json_from_wast => json_from_wast_cmd.usage,
        .decompile => decompile_cmd.usage,
        .stats => stats_cmd.usage,
        .desugar => desugar_cmd.usage,
        .spectest => spectest_cmd.usage,
        .shrink => shrink_cmd.usage,
        .version => version_usage,
        .help => help_usage,
    });
}

test "parseSubcommand recognizes all subcommands" {
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
}
