const std = @import("std");
const wasip2_build = @import("wasip2");

pub fn build(b: *std.Build) void {
    const wasip2 = b.dependency("wasip2", .{});
    const wasm_core = wasip2_build.zigBuildWasm(b, .{
        .source = b.path("src/main.zig"),
        .exports = &.{"wasi:cli/run@0.2.6#run"},
        .output = "hello.core.wasm",
        .imports = wasip2_build.resolveWasmImports(b, wasip2, &.{"wasi_cli"}),
    });
    const wasm = wasip2_build.wabtComponentNew(b, .{
        .wasm_core = wasm_core,
    });
    wasip2_build.wabtModuleValidate(b, .{
        .parent = b.getInstallStep(),
        .wasm = wasm,
    });
    _ = wasip2_build.wasmtimeRun(b, .{ .wasm = wasm });
}
