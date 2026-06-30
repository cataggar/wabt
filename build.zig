const std = @import("std");
const wasip3 = @import("wasip3");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("wasip3", .{});
    const web_bindings = wasip3.bindgen(b, dep, .{ .world = "web" });
    const storage_bindings = wasip3.bindgen(b, dep, .{ .world = "storage" });

    const web_core = wasip3.zigBuildWasm(b, .{
        .source = b.path("src/main.zig"),
        .output = "http.core.wasm",
        .imports = wasip3.guestImports(b, dep, &.{ "wit_types", "wit_async", "wasi_http" }, &.{
            .{ .bindings = web_bindings },
        }),
    });
    const web = wasip3.wabtComponentNew(b, .{ .wasm_core = web_core, .world = "web" });

    const store_core = wasip3.zigBuildWasm(b, .{
        .source = b.path("src/memory_store.zig"),
        .output = "store.core.wasm",
        .imports = wasip3.guestImports(b, dep, &.{"wit_types"}, &.{
            .{ .bindings = storage_bindings },
        }),
    });
    const store = wasip3.wabtComponentNew(b, .{ .wasm_core = store_core, .world = "storage" });

    const petstore = wasip3.wabtComponentCompose(b, .{
        .consumer = web,
        .dependencies = &.{store},
        .output = "petstore.wasm",
    });
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(petstore, .prefix, "petstore.wasm").step);

    // `zig build serve [-- --addr 127.0.0.1:8080]`
    _ = wasip3.wasmtimeServe(b, .{ .wasm = petstore, .description = "Serve with wasmtime" });

    // ── demo client (a `wasi:cli` command that walks every endpoint) ──
    // The outgoing-HTTP driver lives in wasip3's `wasi_http_client` (over the
    // generated `wasi:http/types` resources), so the client source just imports
    // `wasi_cli` + `wasi_http_client` — no per-package bindgen needed here.
    const client_imports = wasip3.resolveWasmImports(b, dep, &.{ "wasi_cli", "wasi_http_client" });
    const client_core = wasip3.zigBuildWasm(b, .{
        .source = b.path("src/client.zig"),
        .output = "client.core.wasm",
        .imports = client_imports,
    });
    const client = wasip3.wabtComponentNew(b, .{ .wasm_core = client_core, .world = "client" });
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(client, .prefix, "client.wasm").step);

    // `zig build run-client [-- 127.0.0.1:8080]` — needs the P3 async features
    // plus the outgoing `wasi:http` and `wasi:cli` host support.
    const run_cmd = b.addSystemCommand(&.{ wasip3.wasmtimeBin(b), "run" });
    for ([_][]const u8{
        "component-model-async",
        "component-model-async-stackful",
        "component-model-more-async-builtins",
        "component-model-error-context",
    }) |f| {
        run_cmd.addArg("-W");
        run_cmd.addArg(f);
    }
    run_cmd.addArg("-S");
    run_cmd.addArg("p3,http,cli");
    run_cmd.addFileArg(client);
    if (b.args) |forwarded| run_cmd.addArgs(forwarded);
    const run_client = b.step("run-client", "Run the demo client that walks every endpoint");
    run_client.dependOn(&run_cmd.step);
}
