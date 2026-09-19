//! `wabt oci <verb>` — canonical OCI artifact command shell.
//!
//! This increment owns dispatch, help, and complete argument validation only.
//! Every well-formed leaf remains explicitly non-successful until execution is
//! wired in a later increment.

const std = @import("std");

const copy_cmd = @import("oci_copy.zig");
const inspect_cmd = @import("oci_inspect.zig");
const list_tags_cmd = @import("oci_list_tags.zig");
const pull_cmd = @import("oci_pull.zig");
const push_cmd = @import("oci_push.zig");
const resolve_cmd = @import("oci_resolve.zig");
const runtime_mod = @import("oci_runtime.zig");

pub const usage =
    "Usage: wabt oci <verb> [args...]\n" ++
    "\n" ++
    "OCI artifact command shell (argument validation only; execution pending):\n" ++
    "  push       Validate a tagged registry destination and Wasm file\n" ++
    "  pull       Validate a selected registry source and output filename\n" ++
    "  copy       Validate registry/layout source and destination references\n" ++
    "  inspect    Validate a selected registry reference for inspection\n" ++
    "  resolve    Validate a selected registry reference for resolution\n" ++
    "  list-tags  Validate a selector-less registry repository\n" ++
    "\n" ++
    "Run `wabt help oci <verb>` for verb-specific syntax and options.\n";

pub const Verb = enum {
    push,
    pull,
    copy,
    inspect,
    resolve,
    list_tags,
    help,
};

pub fn parseVerb(text: []const u8) ?Verb {
    if (std.mem.eql(u8, text, "push")) return .push;
    if (std.mem.eql(u8, text, "pull")) return .pull;
    if (std.mem.eql(u8, text, "copy")) return .copy;
    if (std.mem.eql(u8, text, "inspect")) return .inspect;
    if (std.mem.eql(u8, text, "resolve")) return .resolve;
    if (std.mem.eql(u8, text, "list-tags")) return .list_tags;
    if (std.mem.eql(u8, text, "help")) return .help;
    return null;
}

pub const DispatchResult = union(enum) {
    help: []const u8,
};

pub const Error =
    push_cmd.Error ||
    pull_cmd.Error ||
    copy_cmd.Error ||
    inspect_cmd.Error ||
    resolve_cmd.Error ||
    list_tags_cmd.Error ||
    error{
        MissingVerb,
        UnknownVerb,
        UnexpectedArgument,
    };

pub fn dispatch(
    args: []const []const u8,
    runtime: *runtime_mod.Runtime,
) Error!DispatchResult {
    if (args.len == 0) return error.MissingVerb;
    const verb = parseVerb(args[0]) orelse return error.UnknownVerb;
    const verb_args = args[1..];

    if (verb == .help) {
        if (verb_args.len == 0) return .{ .help = usage };
        if (verb_args.len > 1) return error.UnexpectedArgument;
        const help_verb = parseVerb(verb_args[0]) orelse return error.UnknownVerb;
        return .{ .help = helpForVerb(help_verb) };
    }

    if (verb_args.len > 0 and std.mem.eql(u8, verb_args[0], "help")) {
        if (verb_args.len != 1) return error.UnexpectedArgument;
        return .{ .help = helpForVerb(verb) };
    }

    switch (verb) {
        .push => push_cmd.execute(verb_args, runtime) catch |err| return err,
        .pull => pull_cmd.execute(verb_args, runtime) catch |err| return err,
        .copy => copy_cmd.execute(verb_args, runtime) catch |err| return err,
        .inspect => inspect_cmd.execute(verb_args, runtime) catch |err| return err,
        .resolve => resolve_cmd.execute(verb_args, runtime) catch |err| return err,
        .list_tags => list_tags_cmd.execute(verb_args, runtime) catch |err| return err,
        .help => unreachable,
    }
    unreachable;
}

fn helpForVerb(verb: Verb) []const u8 {
    return switch (verb) {
        .push => push_cmd.usage,
        .pull => pull_cmd.usage,
        .copy => copy_cmd.usage,
        .inspect => inspect_cmd.usage,
        .resolve => resolve_cmd.usage,
        .list_tags => list_tags_cmd.usage,
        .help => usage,
    };
}

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    var counters: runtime_mod.Counters = .{};
    var runtime = runtime_mod.Runtime.init(&counters);
    const result = dispatch(args, &runtime) catch |err| {
        if (args.len > 0 and parseVerb(args[0]) != null and parseVerb(args[0]).? != .help) {
            std.debug.print("error: wabt oci {s}: {s}\n", .{ args[0], @errorName(err) });
        } else {
            std.debug.print("error: wabt oci: {s}\n", .{@errorName(err)});
        }
        std.process.exit(1);
    };
    switch (result) {
        .help => |text| {
            var stdout_file = std.Io.File.stdout();
            stdout_file.writeStreamingAll(init.io, text) catch |err| {
                std.debug.print("error: wabt oci help: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
        },
    }
}

test "OCI verbs have exactly one canonical spelling" {
    try std.testing.expectEqual(@as(?Verb, .push), parseVerb("push"));
    try std.testing.expectEqual(@as(?Verb, .pull), parseVerb("pull"));
    try std.testing.expectEqual(@as(?Verb, .copy), parseVerb("copy"));
    try std.testing.expectEqual(@as(?Verb, .inspect), parseVerb("inspect"));
    try std.testing.expectEqual(@as(?Verb, .resolve), parseVerb("resolve"));
    try std.testing.expectEqual(@as(?Verb, .list_tags), parseVerb("list-tags"));
    try std.testing.expectEqual(@as(?Verb, .help), parseVerb("help"));

    for ([_][]const u8{
        "",
        "registry",
        "artifact",
        "pin",
        "list_tags",
        "listtags",
        "component",
        "Push",
    }) |alias| {
        try std.testing.expectEqual(@as(?Verb, null), parseVerb(alias));
    }
}

test "subject and leaf help are stable and side-effect free" {
    const expected_subject =
        "Usage: wabt oci <verb> [args...]\n" ++
        "\n" ++
        "OCI artifact command shell (argument validation only; execution pending):\n" ++
        "  push       Validate a tagged registry destination and Wasm file\n" ++
        "  pull       Validate a selected registry source and output filename\n" ++
        "  copy       Validate registry/layout source and destination references\n" ++
        "  inspect    Validate a selected registry reference for inspection\n" ++
        "  resolve    Validate a selected registry reference for resolution\n" ++
        "  list-tags  Validate a selector-less registry repository\n" ++
        "\n" ++
        "Run `wabt help oci <verb>` for verb-specific syntax and options.\n";
    try std.testing.expectEqualStrings(expected_subject, usage);

    var counters: runtime_mod.Counters = .{};
    var runtime = runtime_mod.Runtime.init(&counters);
    const subject = try dispatch(&.{"help"}, &runtime);
    try std.testing.expectEqualStrings(usage, subject.help);

    const cases = [_]struct {
        args: []const []const u8,
        expected: []const u8,
    }{
        .{ .args = &.{ "help", "push" }, .expected = push_cmd.usage },
        .{ .args = &.{ "push", "help" }, .expected = push_cmd.usage },
        .{ .args = &.{ "help", "pull" }, .expected = pull_cmd.usage },
        .{ .args = &.{ "help", "copy" }, .expected = copy_cmd.usage },
        .{ .args = &.{ "help", "inspect" }, .expected = inspect_cmd.usage },
        .{ .args = &.{ "help", "resolve" }, .expected = resolve_cmd.usage },
        .{ .args = &.{ "help", "list-tags" }, .expected = list_tags_cmd.usage },
    };
    for (cases) |case| {
        const result = try dispatch(case.args, &runtime);
        try std.testing.expectEqualStrings(case.expected, result.help);
    }
    try std.testing.expect(counters.isZero());
}

test "well-formed unwired commands return CommandNotImplemented without side effects" {
    const commands = [_][]const []const u8{
        &.{ "push", "registry.example/team/app:tag", "app.wasm" },
        &.{ "pull", "registry.example/team/app:tag", "-o", "app.wasm" },
        &.{ "copy", "oci:source", "oci:destination" },
        &.{ "inspect", "registry.example/team/app:tag" },
        &.{ "resolve", "registry.example/team/app:tag" },
        &.{ "list-tags", "registry.example/team/app" },
        &.{
            "copy",
            "localhost:5000/team/source:tag",
            "localhost:6000/team/destination:tag",
            "--source-password-stdin",
            "--source-username",
            "source-user",
            "--destination-token-stdin",
            "--source-plain-http",
            "--destination-plain-http",
        },
    };

    for (commands) |command| {
        var counters: runtime_mod.Counters = .{};
        var runtime = runtime_mod.Runtime.init(&counters);
        try std.testing.expectError(
            error.CommandNotImplemented,
            dispatch(command, &runtime),
        );
        try std.testing.expect(counters.isZero());
    }
}

test "invalid parse paths return before all runtime boundaries" {
    const commands = [_][]const []const u8{
        &.{ "push", "registry.example/team/app", "app.wasm" },
        &.{ "pull", "registry.example/team/app:tag", "-o", "out/" },
        &.{ "copy", "oci:source", "oci:destination", "--source-auth-file", "auth.json" },
        &.{ "resolve", "registry.example/team/app:tag", "--password", "do-not-read" },
    };
    for (commands) |command| {
        var counters: runtime_mod.Counters = .{};
        var runtime = runtime_mod.Runtime.init(&counters);
        _ = dispatch(command, &runtime) catch {};
        try std.testing.expect(counters.isZero());
    }
}
