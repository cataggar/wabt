const std = @import("std");
const wasip3 = @import("wasip3");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("wasip3", .{});

    // The `svc` world generates the whole guest surface the frontend needs:
    // the `wasi:http/types` client wrappers, the `store` client, and the async
    // `wasi:http/handler` export. `handle` is generated in manual-return form so
    // the handler can `task.return` the response and then keep streaming its
    // body.
    const svc = wasip3.wabtComponentBindgen(b, .{ .world = "svc", .manual_returns = &.{"handle"} });
    const store_provider = wasip3.wabtComponentBindgen(b, .{ .world = "store-provider" });

    const web_core = wasip3.zigBuildWasm(b, .{
        .source = b.path("src/main.zig"),
        .output = "http.core.wasm",
        .imports = wasip3.guestImports(b, dep, &.{ "wit_types", "wit_async", "wasi_http" }, &.{
            .{ .bindings = svc },
        }),
    });
    const web = wasip3.wabtComponentNew(b, .{ .wasm_core = web_core, .world = "svc" });

    const store_core = wasip3.zigBuildWasm(b, .{
        .source = b.path("src/memory_store.zig"),
        .output = "store.core.wasm",
        .imports = wasip3.guestImports(b, dep, &.{"wit_types"}, &.{
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
