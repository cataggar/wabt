const std = @import("std");
const wasip3 = @import("wasip3");

/// A composed `wasi:http@0.3.0` petstore: an HTTP **web** component that
/// imports `example:petstore/store`, and a separate **store** component that
/// exports it. Each is built `wasm32-freestanding`, wrapped with
/// `wabt component new`, then linked with `wabt component compose` into one
/// servable component. All the tool plumbing lives in `wasip3`'s build helpers.
///
/// `WABT` / `WASMTIME` env vars override the tool binaries (point them at a P3
/// wabt and a wasmtime >= 46); otherwise `wabt` / `wasmtime` from `PATH`.
pub fn build(b: *std.Build) void {
    const dep = b.dependency("wasip3", .{});

    // Generate the store bindings from WIT: import wrappers for the web side
    // (store-consumer world) and `export fn` shells for the store side
    // (store-provider world). Both delegate all marshalling to `canon`.
    const store_consumer = wasip3.wabtComponentBindgen(b, .{ .world = "store-consumer", .impl = "memory_store", .output = "store_consumer.zig" });
    const store_provider = wasip3.wabtComponentBindgen(b, .{ .world = "store-provider", .impl = "root", .output = "store_provider.zig" });

    // ── Web frontend: wasi:http handler importing example:petstore/store ──
    const web_core = wasip3.zigBuildWasm(b, .{
        .source = b.path("src/main.zig"),
        .output = "http.core.wasm",
        .imports = wasip3.resolveWasmImportsWith(b, dep, &.{ "wasi_http", "canon" }, &.{
            .{ .name = "store_consumer", .path = store_consumer, .deps = &.{ "abi", "canon" } },
        }),
    });
    const web = wasip3.wabtComponentNew(b, .{ .wasm_core = web_core, .world = "svc" });

    // ── Store backend: example:petstore/store provider ────────────────
    // `src/memory_store.zig` (the in-memory store) is the root; the generated
    // export shells (`store_provider`) reach it via `@import("root")` and use it
    // for the `Pet`/`Toy` types. `-rdynamic` exports the shells, so no export
    // list is needed.
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

    // ── Compose: bind the web component's `store` import to the provider ──
    const component = wasip3.wabtComponentCompose(b, .{
        .consumer = web,
        .dependencies = &.{store},
        .output = "petstore.wasm",
    });
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(component, .prefix, "petstore.wasm").step);

    // `zig build bindgen` — write the generated store bindings to
    // zig-out/generated/ so they can be inspected.
    const gen_step = b.step("bindgen", "Write the generated store bindings to zig-out/generated/");
    gen_step.dependOn(&b.addInstallFileWithDir(store_consumer, .prefix, "generated/store_consumer.zig").step);
    gen_step.dependOn(&b.addInstallFileWithDir(store_provider, .prefix, "generated/store_provider.zig").step);

    // `zig build serve [-- --addr 127.0.0.1:8080]`
    _ = wasip3.wasmtimeServe(b, .{ .wasm = component, .description = "Serve the composed petstore component with wasmtime (P3)" });

    // `zig build check` is registered automatically by `wasip3.zigBuildWasm`
    // for each guest above (it mirrors the guest's module graph as a real
    // `addExecutable` so ZLS can resolve `@import`s). No wiring needed here.
}
