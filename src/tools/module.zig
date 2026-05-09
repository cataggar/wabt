//! `wabt module <verb>` — dispatch core-wasm (.wasm) subcommands.
//!
//! The `module` subject covers operations on core wasm binaries:
//! validation, inspection, transformation, generation, debug-info
//! lookup, and metadata editing.

const std = @import("std");

const validate_cmd = @import("validate.zig");
const objdump_cmd = @import("objdump.zig");
const strip_cmd = @import("strip.zig");
const stats_cmd = @import("stats.zig");
const decompile_cmd = @import("decompile.zig");
const shrink_cmd = @import("shrink.zig");

pub const usage =
    \\Usage: wabt module <verb> [args...]
    \\
    \\Core wasm (.wasm) subcommands:
    \\  validate   Validate a WebAssembly binary
    \\  objdump    Dump information about a WebAssembly binary
    \\  strip      Strip custom sections from a WebAssembly binary
    \\  stats      Print module statistics
    \\  decompile  Decompile a wasm binary into readable pseudo-code
    \\  shrink     Minimize a wasm binary while preserving a property
    \\
    \\Run `wabt help module <verb>` for verb-specific help.
    \\
;

pub const Verb = enum {
    validate,
    objdump,
    strip,
    stats,
    decompile,
    shrink,
    help,
};

pub fn parseVerb(s: []const u8) ?Verb {
    if (std.mem.eql(u8, s, "validate")) return .validate;
    if (std.mem.eql(u8, s, "objdump")) return .objdump;
    if (std.mem.eql(u8, s, "strip")) return .strip;
    if (std.mem.eql(u8, s, "stats")) return .stats;
    if (std.mem.eql(u8, s, "decompile")) return .decompile;
    if (std.mem.eql(u8, s, "shrink")) return .shrink;
    if (std.mem.eql(u8, s, "help")) return .help;
    return null;
}

pub fn run(init: std.process.Init, sub_args: []const []const u8) !void {
    if (sub_args.len == 0) {
        std.debug.print("error: missing module verb — try `wabt help module`\n", .{});
        std.process.exit(1);
    }
    const verb = parseVerb(sub_args[0]) orelse {
        std.debug.print("error: unknown module verb '{s}' — try `wabt help module`\n", .{sub_args[0]});
        std.process.exit(1);
    };
    const verb_args = sub_args[1..];
    switch (verb) {
        .validate => try validate_cmd.run(init, verb_args),
        .objdump => try objdump_cmd.run(init, verb_args),
        .strip => try strip_cmd.run(init, verb_args),
        .stats => try stats_cmd.run(init, verb_args),
        .decompile => try decompile_cmd.run(init, verb_args),
        .shrink => try shrink_cmd.run(init, verb_args),
        .help => {
            if (verb_args.len == 0) {
                writeStdout(init.io, usage);
                return;
            }
            const v = parseVerb(verb_args[0]) orelse {
                std.debug.print("error: unknown module verb '{s}'\n", .{verb_args[0]});
                std.process.exit(1);
            };
            writeStdout(init.io, switch (v) {
                .validate => validate_cmd.usage,
                .objdump => objdump_cmd.usage,
                .strip => strip_cmd.usage,
                .stats => stats_cmd.usage,
                .decompile => decompile_cmd.usage,
                .shrink => shrink_cmd.usage,
                .help => usage,
            });
        },
    }
}

fn writeStdout(io: std.Io, text: []const u8) void {
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io, text) catch {};
}

test "parseVerb recognizes all module verbs" {
    try std.testing.expectEqual(@as(?Verb, .validate), parseVerb("validate"));
    try std.testing.expectEqual(@as(?Verb, .objdump), parseVerb("objdump"));
    try std.testing.expectEqual(@as(?Verb, .strip), parseVerb("strip"));
    try std.testing.expectEqual(@as(?Verb, .stats), parseVerb("stats"));
    try std.testing.expectEqual(@as(?Verb, .decompile), parseVerb("decompile"));
    try std.testing.expectEqual(@as(?Verb, .shrink), parseVerb("shrink"));
    try std.testing.expectEqual(@as(?Verb, .help), parseVerb("help"));
}

test "parseVerb rejects verbs not yet implemented (planned for phase 3)" {
    // dump, demangle, addr-to-line, mutate, smith, metadata are tracked
    // in port-module-verbs (#137); they must NOT silently match here.
    try std.testing.expectEqual(@as(?Verb, null), parseVerb("dump"));
    try std.testing.expectEqual(@as(?Verb, null), parseVerb("demangle"));
    try std.testing.expectEqual(@as(?Verb, null), parseVerb("addr-to-line"));
    try std.testing.expectEqual(@as(?Verb, null), parseVerb("addr2line"));
    try std.testing.expectEqual(@as(?Verb, null), parseVerb("mutate"));
    try std.testing.expectEqual(@as(?Verb, null), parseVerb("smith"));
    try std.testing.expectEqual(@as(?Verb, null), parseVerb("metadata"));
}
