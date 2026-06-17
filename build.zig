const std = @import("std");
const wasip3 = @import("wasip3");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("wasip3", .{});

    const store_consumer = wasip3.wabtComponentBindgen(b, .{ .world = "store-consumer", .impl = "memory_store", .output = "store_consumer.zig" });
    const store_provider = wasip3.wabtComponentBindgen(b, .{ .world = "store-provider", .impl = "root", .output = "store_provider.zig" });

    const web_core = wasip3.zigBuildWasm(b, .{
        .source = b.path("src/main.zig"),
        .output = "http.core.wasm",
        .imports = wasip3.resolveWasmImportsWith(b, dep, &.{ "wasi_http", "canon" }, &.{
            .{ .name = "store_consumer", .path = store_consumer, .deps = &.{ "abi", "canon" } },
        }),
    });
    const web = wasip3.wabtComponentNew(b, .{ .wasm_core = web_core, .world = "svc" });

    const store_core = wasip3.zigBuildWasm(b, .{
        .source = b.path("src/memory_store.zig"),
        .output = "store.core.wasm",
        .imports = &.{
            .{ .name = "store_provider", .path = store_provider, .deps = &.{ "canon", "abi" } },
            .{ .name = "canon", .path = dep.path("src/canon.zig"), .root_dep = false },
            .{ .name = "abi", .path = dep.path("src/abi.zig"), .root_dep = false },
        },
    });
    const store = wasip3.wabtComponentNew(b, .{ .wasm_core = store_core, .world = "store-provider" });

    const component = wasip3.wabtComponentCompose(b, .{
        .consumer = web,
        .dependencies = &.{store},
        .output = "petstore.wasm",
    });
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(component, .prefix, "petstore.wasm").step);
}
