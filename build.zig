const std = @import("std");
const wasip3 = @import("wasip3");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("wasip3", .{});
    const web_bindings = wasip3.wabtComponentBindgen(b, .{ .world = "web" });
    const storage_bindings = wasip3.wabtComponentBindgen(b, .{ .world = "storage" });

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
    _ = wasip3.wasmtimeServe(b, .{ .wasm = petstore, .description = "Serve petstore with wasmtime" });
}
