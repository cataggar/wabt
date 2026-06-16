const std = @import("std");
const wasip3 = @import("wasip3");

/// A standalone `wasi:http@0.3.0` service component written in Zig: it exports
/// the async `wasi:http/handler@0.3.0#handle`, builds a `200` response, and
/// streams `Hello, WASI!` as the body. Built `wasm32-freestanding`, then
/// wrapped into a component with `wabt component new`.
///
/// `WABT` / `WASMTIME` env vars override the tool binaries (point them at a P3
/// wabt and a wasmtime >= 46); otherwise `wabt` / `wasmtime` from `PATH`.
pub fn build(b: *std.Build) void {
    const dep = b.dependency("wasip3", .{});

    const core = wasip3.zigBuildWasm(b, .{
        .source = b.path("src/main.zig"),
        .exports = &.{"wasi:http/handler@0.3.0#handle"},
        .output = "http.core.wasm",
        .imports = wasip3.resolveWasmImports(b, dep, &.{"wasi_http"}),
    });

    const wabt_bin = b.graph.environ_map.get("WABT") orelse "wabt";
    const wasmtime_bin = b.graph.environ_map.get("WASMTIME") orelse "wasmtime";

    // wabt component new --wit wit http.core.wasm -o http.wasm
    const new_cmd = b.addSystemCommand(&.{ wabt_bin, "component", "new" });
    new_cmd.addArg("--wit");
    new_cmd.addDirectoryArg(b.path("wit"));
    new_cmd.addFileArg(core);
    new_cmd.addArg("-o");
    const component = new_cmd.addOutputFileArg("http.wasm");

    const install = b.addInstallFileWithDir(component, .prefix, "http.wasm");
    b.getInstallStep().dependOn(&install.step);

    // `zig build serve [-- --addr 127.0.0.1:8080]`
    const serve = b.addSystemCommand(&.{
        wasmtime_bin,                          "serve",
        "-W",                                  "component-model-async",
        "-W",                                  "component-model-async-stackful",
        "-W",                                  "component-model-more-async-builtins",
        "-W",                                  "component-model-error-context",
        "-S",                                  "p3,cli",
    });
    serve.addFileArg(component);
    if (b.args) |extra| serve.addArgs(extra);
    const serve_step = b.step("serve", "Serve the wasi:http component with wasmtime (P3)");
    serve_step.dependOn(&serve.step);
}
