const std = @import("std");
const wasip3 = @import("wasip3");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("wasip3", .{});

    const store_consumer = wasip3.wabtComponentBindgen(b, .{ .world = "store-consumer" });
    const store_provider = wasip3.wabtComponentBindgen(b, .{ .world = "store-provider" });

    const web_core = wasip3.zigBuildWasm(b, .{
        .source = b.path("src/main.zig"),
        .output = "http.core.wasm",
        .imports = wasip3.guestImports(b, dep, &.{"wasi_http"}, &.{
            .{ .bindings = store_consumer },
        }),
    });
    const web = wasip3.wabtComponentNew(b, .{ .wasm_core = web_core, .world = "svc" });

    const store_core = wasip3.zigBuildWasm(b, .{
        .source = b.path("src/memory_store.zig"),
        .output = "store.core.wasm",
        .imports = wasip3.guestImports(b, dep, &.{}, &.{
            .{ .bindings = store_provider },
        }),
    });
    const store = wasip3.wabtComponentNew(b, .{ .wasm_core = store_core, .world = "store-provider" });

    const component = wasip3.wabtComponentCompose(b, .{
        .consumer = web,
        .dependencies = &.{store},
        .output = "petstore.wasm",
    });
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(component, .prefix, "petstore.wasm").step);

    // `zig build serve [-- --addr 127.0.0.1:8080]`
    _ = wasip3.wasmtimeServe(b, .{ .wasm = component, .description = "Serve the composed petstore component with wasmtime (P3)" });
}
