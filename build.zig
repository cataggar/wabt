const std = @import("std");
const wasip2_build = @import("wasip2");

pub fn build(b: *std.Build) void {
    const wasip2 = b.dependency("wasip2", .{});

    const core = wasip2_build.compileZigWasm(b, .{
        .source = b.path("src/main.zig"),
        .exports = &.{ "wasi:cli/run@0.2.6#run", "cabi_realloc" },
        .output = "hello.core.wasm",
        .imports = &.{
            .{ .name = "wasi_cli", .path = wasip2.path("src/wasi_cli.zig"), .deps = &.{"wasi_io"} },
            .{ .name = "wasi_io", .path = wasip2.path("src/wasi_io.zig"), .deps = &.{"abi"}, .root_dep = false },
            .{ .name = "abi", .path = wasip2.path("src/abi.zig"), .root_dep = false },
        },
    });
    const hello = wasip2_build.makeComponent(b, .{
        .core = core,
        .wit_dir = b.path("wit"),
        .world = "hello",
        .output = "hello.wasm",
    });
    wasip2_build.installAndValidate(b, b.getInstallStep(), hello, "hello.wasm");
}
