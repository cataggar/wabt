//! `wabt component <verb>` — dispatch component-model subcommands.
//!
//! Mirrors the `wasm-tools component` two-token form so call sites
//! using `wasm-tools component embed/new/compose` can swap to
//! `wabt component embed/new/compose` without changing argv shape.

const std = @import("std");

const embed_cmd = @import("component_embed.zig");
const new_cmd = @import("component_new.zig");

pub const usage =
    \\Usage: wabt component <verb> [args...]
    \\
    \\Component-model subcommands:
    \\  embed          Embed a `component-type` custom section into a core wasm
    \\  new            Wrap a core wasm + embedded metadata into a component
    \\
    \\(Future verb: `compose` — link components by matching imports to exports.)
    \\
    \\Run `wabt help component <verb>` for verb-specific help.
    \\
;

pub const Verb = enum {
    embed,
    new,
    help,
};

pub fn parseVerb(s: []const u8) ?Verb {
    if (std.mem.eql(u8, s, "embed")) return .embed;
    if (std.mem.eql(u8, s, "new")) return .new;
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
                .help => usage,
            });
        },
    }
}

fn writeStdout(io: std.Io, text: []const u8) void {
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io, text) catch {};
}
