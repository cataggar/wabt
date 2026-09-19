const std = @import("std");
const wabt = @import("wabt");
const fixture = wabt.oci.fixture_support;
const inspect_cmd = @import("oci_inspect.zig");
const pull_cmd = @import("oci_pull.zig");
const resolve_cmd = @import("oci_resolve.zig");
const runtime_mod = @import("oci_runtime.zig");

test "CLI consumes checked-in producer layouts without tools or network" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    var counters: runtime_mod.Counters = .{};
    var capture: Capture = undefined;
    capture.reset();
    var runtime = runtime_mod.Runtime.initForTest(
        allocator,
        std.testing.io,
        &counters,
    );
    capture.attach(&runtime);

    for (fixture.direct_layouts, 0..) |case, index| {
        const base = try std.fmt.allocPrint(allocator, "layout-{d}", .{index});
        defer allocator.free(base);
        try fixture.materialize(
            allocator,
            std.testing.io,
            temporary.dir,
            base,
            case,
        );
        const layout_path = try fixture.cwdPath(
            allocator,
            &temporary.sub_path,
            base,
        );
        defer allocator.free(layout_path);
        const reference = try std.fmt.allocPrint(
            allocator,
            "oci:{s}:fixture",
            .{layout_path},
        );
        defer allocator.free(reference);

        try resolve_cmd.execute(&.{reference}, &runtime);
        try std.testing.expect(std.mem.indexOf(
            u8,
            capture.stdout(),
            case.root_digest,
        ) != null);

        capture.reset();
        capture.attach(&runtime);
        try inspect_cmd.execute(&.{ reference, "--json" }, &runtime);
        try std.testing.expect(std.mem.indexOf(
            u8,
            capture.stdout(),
            case.root_digest,
        ) != null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            capture.stdout(),
            case.profile.?,
        ) != null);

        capture.reset();
        capture.attach(&runtime);
        const output_name = try std.fmt.allocPrint(
            allocator,
            "cli-pulled-{d}.wasm",
            .{index},
        );
        defer allocator.free(output_name);
        const output_path = try fixture.cwdPath(
            allocator,
            &temporary.sub_path,
            output_name,
        );
        defer allocator.free(output_path);
        try pull_cmd.execute(
            &.{ reference, "-o", output_path, "--json" },
            &runtime,
        );
        const pulled = try temporary.dir.readFileAlloc(
            std.testing.io,
            output_name,
            allocator,
            .limited(fixture.component_payload.len + 1),
        );
        defer allocator.free(pulled);
        try std.testing.expectEqualSlices(
            u8,
            fixture.component_payload,
            pulled,
        );
    }
    try std.testing.expect(counters.isZero());
}

test "CLI inspects and copies index semantics but never extracts it" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try fixture.materialize(
        allocator,
        std.testing.io,
        temporary.dir,
        "index",
        fixture.index_layout,
    );
    const layout_path = try fixture.cwdPath(
        allocator,
        &temporary.sub_path,
        "index",
    );
    defer allocator.free(layout_path);
    const reference = try std.fmt.allocPrint(
        allocator,
        "oci:{s}:fixture",
        .{layout_path},
    );
    defer allocator.free(reference);
    const output_path = try fixture.cwdPath(
        allocator,
        &temporary.sub_path,
        "index-output.wasm",
    );
    defer allocator.free(output_path);

    var counters: runtime_mod.Counters = .{};
    var capture: Capture = undefined;
    capture.reset();
    var runtime = runtime_mod.Runtime.initForTest(
        allocator,
        std.testing.io,
        &counters,
    );
    capture.attach(&runtime);
    try inspect_cmd.execute(&.{ reference, "--json" }, &runtime);
    try std.testing.expect(std.mem.indexOf(
        u8,
        capture.stdout(),
        "\"documentKind\":\"index\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        capture.stdout(),
        fixture.index_layout.root_digest,
    ) != null);

    capture.reset();
    capture.attach(&runtime);
    try std.testing.expectError(
        error.UnsupportedContent,
        pull_cmd.execute(
            &.{ reference, "-o", output_path, "--json" },
            &runtime,
        ),
    );
    try std.testing.expectEqualStrings("", capture.stdout());
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.openFile(std.testing.io, "index-output.wasm", .{}),
    );
    try std.testing.expect(counters.isZero());
}

const Capture = struct {
    stdout_buffer: [64 * 1024]u8 = undefined,
    stderr_buffer: [4096]u8 = undefined,
    stdout_writer: std.Io.Writer = undefined,
    stderr_writer: std.Io.Writer = undefined,

    fn reset(self: *Capture) void {
        self.stdout_writer = std.Io.Writer.fixed(&self.stdout_buffer);
        self.stderr_writer = std.Io.Writer.fixed(&self.stderr_buffer);
    }

    fn attach(self: *Capture, runtime: *runtime_mod.Runtime) void {
        runtime.stdout = runtime_mod.OutputSink.fromWriter(&self.stdout_writer);
        runtime.stderr = runtime_mod.OutputSink.fromWriter(&self.stderr_writer);
    }

    fn stdout(self: *const Capture) []const u8 {
        return self.stdout_buffer[0..self.stdout_writer.end];
    }
};
