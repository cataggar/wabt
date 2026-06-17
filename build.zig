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

    // `zig build check` — a no-install analysis target so ZLS can resolve the
    // guests' imports. The real build compiles each guest by shelling out to
    // `zig build-exe` (via `wasip3.zigBuildWasm`), which ZLS cannot introspect;
    // these `addExecutable` + `addImport` modules mirror the same graph
    // (`main.zig` → wasi_http + the generated `store_consumer`; `memory_store.zig`
    // → the generated `store_provider`, whose shells reach the store via
    // `@import("root")`) so the language server sees the modules. `entry =
    // .disabled` + `rdynamic` match the freestanding guest link; nothing here is
    // wired into `install`.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });

    const store_consumer_mod = b.createModule(.{ .root_source_file = store_consumer });
    store_consumer_mod.addImport("abi", dep.module("abi"));
    store_consumer_mod.addImport("canon", dep.module("canon"));
    const web_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = wasm_target });
    web_mod.addImport("wasi_http", dep.module("wasi_http"));
    web_mod.addImport("store_consumer", store_consumer_mod);
    const web_check = b.addExecutable(.{ .name = "web-check", .root_module = web_mod });
    web_check.entry = .disabled;
    web_check.rdynamic = true;

    const store_provider_mod = b.createModule(.{ .root_source_file = store_provider });
    store_provider_mod.addImport("canon", dep.module("canon"));
    store_provider_mod.addImport("abi", dep.module("abi"));
    const store_mod = b.createModule(.{ .root_source_file = b.path("src/memory_store.zig"), .target = wasm_target });
    store_mod.addImport("store_provider", store_provider_mod);
    const store_check = b.addExecutable(.{ .name = "store-check", .root_module = store_mod });
    store_check.entry = .disabled;
    store_check.rdynamic = true;

    const check = b.step("check", "Analyze the guest modules for ZLS (no install)");
    check.dependOn(&web_check.step);
    check.dependOn(&store_check.step);
}
