//! `wabt component <verb>` — dispatch component-model subcommands.
//!
//! Mirrors the `wasm-tools component` two-token form so call sites
//! using `wasm-tools component embed/new/compose` can swap to
//! `wabt component embed/new/compose` without changing argv shape.

const std = @import("std");

const embed_cmd = @import("component_embed.zig");
const new_cmd = @import("component_new.zig");
const compose_cmd = @import("component_compose.zig");
const objdump_cmd = @import("component_objdump.zig");
const bindgen_cmd = @import("component_bindgen.zig");

pub const usage =
    \\Usage: wabt component <verb> [args...]
    \\
    \\Component-model subcommands:
    \\  embed          Embed a `component-type` custom section into a core wasm
    \\  new            Wrap a core wasm + embedded metadata into a component
    \\  compose        Link a consumer component's imports to provider exports
    \\  objdump        Dump a structural summary of a Component Model binary
    \\  bindgen        Generate Zig guest bindings (canonical-ABI shells) from WIT
    \\
    \\Run `wabt help component <verb>` for verb-specific help.
    \\
;

pub const Verb = enum {
    embed,
    new,
    compose,
    objdump,
    bindgen,
    help,
};

pub fn parseVerb(s: []const u8) ?Verb {
    if (std.mem.eql(u8, s, "embed")) return .embed;
    if (std.mem.eql(u8, s, "new")) return .new;
    if (std.mem.eql(u8, s, "compose")) return .compose;
    if (std.mem.eql(u8, s, "objdump")) return .objdump;
    if (std.mem.eql(u8, s, "bindgen")) return .bindgen;
    if (std.mem.eql(u8, s, "help")) return .help;
    return null;
}

pub fn run(init: std.process.Init, sub_args: []const []const u8) !void {
    if (sub_args.len == 0) {
        std.debug.print("error: missing component verb — try `wabt help component`\n", .{});
        std.process.exit(1);
    }
    const verb = parseVerb(sub_args[0]) orelse {
        std.debug.print("error: unknown component verb '{s}' — try `wabt help component`\n", .{sub_args[0]});
        std.process.exit(1);
    };
    const verb_args = sub_args[1..];
    switch (verb) {
        .embed => try embed_cmd.run(init, verb_args),
        .new => try new_cmd.run(init, verb_args),
        .compose => try compose_cmd.run(init, verb_args),
        .objdump => try objdump_cmd.run(init, verb_args),
        .bindgen => try bindgen_cmd.run(init, verb_args),
        .help => {
            if (verb_args.len == 0) {
                writeStdout(init.io, usage);
                return;
            }
            const v = parseVerb(verb_args[0]) orelse {
                std.debug.print("error: unknown component verb '{s}'\n", .{verb_args[0]});
                std.process.exit(1);
            };
            writeStdout(init.io, switch (v) {
                .embed => embed_cmd.usage,
                .new => new_cmd.usage,
                .compose => compose_cmd.usage,
                .objdump => objdump_cmd.usage,
                .bindgen => bindgen_cmd.usage,
                .help => usage,
            });
        },
    }
}

fn writeStdout(io: std.Io, text: []const u8) void {
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io, text) catch {};
}

test "parseVerb recognizes all component verbs" {
    try std.testing.expectEqual(@as(?Verb, .embed), parseVerb("embed"));
    try std.testing.expectEqual(@as(?Verb, .new), parseVerb("new"));
    try std.testing.expectEqual(@as(?Verb, .compose), parseVerb("compose"));
    try std.testing.expectEqual(@as(?Verb, .objdump), parseVerb("objdump"));
    try std.testing.expectEqual(@as(?Verb, .help), parseVerb("help"));
}

test "parseVerb rejects unknown verbs" {
    try std.testing.expectEqual(@as(?Verb, null), parseVerb(""));
    try std.testing.expectEqual(@as(?Verb, null), parseVerb("wit"));
    try std.testing.expectEqual(@as(?Verb, null), parseVerb("dump"));
    try std.testing.expectEqual(@as(?Verb, null), parseVerb("Embed"));
}
