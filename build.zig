const std = @import("std");
const wasip3_build = @import("wasip3");

pub fn build(b: *std.Build) void {
    const wasip3 = b.dependency("wasip3", .{});
    const wasm_core = wasip3_build.zigBuildWasm(b, .{
        .source = b.path("src/main.zig"),
        .exports = &.{"wasi:cli/run@0.3.0#run"},
        .output = "hello.core.wasm",
        .imports = wasip3_build.resolveWasmImports(b, wasip3, &.{"wasi_cli"}),
    });
    const wasm = wasip3_build.wabtComponentNew(b, .{
        .wasm_core = wasm_core,
    });
    wasip3_build.wabtModuleValidate(b, .{
        .parent = b.getInstallStep(),
        .wasm = wasm,
    });
    _ = wasip3_build.wasmtimeRun(b, .{ .wasm = wasm });
}
