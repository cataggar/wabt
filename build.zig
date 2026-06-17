const std = @import("std");
const wasip3 = @import("wasip3");

/// A composed `wasi:http@0.3.0` petstore: an HTTP **frontend** component that
/// imports `example:petstore/store`, and a separate **storage** component that
/// exports it. Each is built `wasm32-freestanding`, wrapped with
/// `wabt component new`, then linked with `wabt component compose` into one
/// servable component.
///
/// `WABT` / `WASMTIME` env vars override the tool binaries (point them at a P3
/// wabt and a wasmtime >= 46); otherwise `wabt` / `wasmtime` from `PATH`.
pub fn build(b: *std.Build) void {
    const dep = b.dependency("wasip3", .{});

    const wabt_bin = b.graph.environ_map.get("WABT") orelse "wabt";
    const wasmtime_bin = b.graph.environ_map.get("WASMTIME") orelse "wasmtime";

    // ── Generate the store bindings from WIT via `wabt component bindgen` ──
    // Import wrappers for the frontend (store-consumer world) and export shells
    // for the backend (store-provider world); both delegate marshalling to `canon`.
    const store_imports = bindgen(b, wabt_bin, "store-consumer", "store_impl", "store_imports.zig");
    const store_exports = bindgen(b, wabt_bin, "store-provider", "store_impl", "store_exports.zig");

    // ── Frontend: wasi:http handler importing example:petstore/store ──
    const fe_base = wasip3.resolveWasmImports(b, dep, &.{ "wasi_http", "canon" });
    const fe_imports = b.allocator.alloc(wasip3.ZigWasmImport, fe_base.len + 1) catch @panic("OOM");
    @memcpy(fe_imports[0..fe_base.len], fe_base);
    fe_imports[fe_base.len] = .{
        .name = "store",
        .path = store_imports,
        .deps = &.{ "abi", "canon" },
        .root_dep = true,
    };

    const fe_core = wasip3.zigBuildWasm(b, .{
        .source = b.path("src/main.zig"),
        .output = "http.core.wasm",
        .imports = fe_imports,
    });
    const frontend = componentNew(b, wabt_bin, fe_core, "svc", "http.wasm");

    // ── Backend: example:petstore/store provider ──────────────────────
    // Generated export shells (`store_bindings`) call the in-memory store
    // (`store_impl`); the two reference each other (types ↔ logic).
    const be_core = wasip3.zigBuildWasm(b, .{
        .source = b.path("src/store_backend_root.zig"),
        .output = "store.core.wasm",
        .imports = &.{
            .{ .name = "store_bindings", .path = store_exports, .deps = &.{ "store_impl", "canon", "abi" }, .root_dep = true },
            .{ .name = "store_impl", .path = b.path("src/store_impl.zig"), .deps = &.{"store_bindings"}, .root_dep = false },
            .{ .name = "canon", .path = dep.path("src/canon.zig"), .root_dep = false },
            .{ .name = "abi", .path = dep.path("src/abi.zig"), .root_dep = false },
        },
    });
    const backend = componentNew(b, wabt_bin, be_core, "store-provider", "store.wasm");

    // ── Compose: bind the consumer's `store` import to the provider ───
    // wabt component compose -d <provider> -o <out> <consumer>
    const compose = b.addSystemCommand(&.{ wabt_bin, "component", "compose" });
    compose.addArg("-d");
    compose.addFileArg(backend);
    compose.addArg("-o");
    const component = compose.addOutputFileArg("petstore.wasm");
    compose.addFileArg(frontend);

    const install = b.addInstallFileWithDir(component, .prefix, "petstore.wasm");
    b.getInstallStep().dependOn(&install.step);

    // `zig build bindgen` — write the generated store bindings to
    // zig-out/generated/ so they can be inspected.
    const gen_step = b.step("bindgen", "Write the generated store bindings to zig-out/generated/");
    gen_step.dependOn(&b.addInstallFileWithDir(store_imports, .prefix, "generated/store_imports.zig").step);
    gen_step.dependOn(&b.addInstallFileWithDir(store_exports, .prefix, "generated/store_exports.zig").step);

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
    const serve_step = b.step("serve", "Serve the composed petstore component with wasmtime (P3)");
    serve_step.dependOn(&serve.step);
}

/// `wabt component new --world <world> --wit wit <core> -o <out>`.
fn componentNew(
    b: *std.Build,
    wabt_bin: []const u8,
    core: std.Build.LazyPath,
    world: []const u8,
    out: []const u8,
) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{ wabt_bin, "component", "new" });
    cmd.addArg("--world");
    cmd.addArg(world);
    cmd.addArg("--wit");
    cmd.addDirectoryArg(b.path("wit"));
    cmd.addFileArg(core);
    cmd.addArg("-o");
    return cmd.addOutputFileArg(out);
}

/// `wabt component bindgen --wit wit --world <world> --impl <impl> -o <out>`.
fn bindgen(
    b: *std.Build,
    wabt_bin: []const u8,
    world: []const u8,
    impl: []const u8,
    out: []const u8,
) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{ wabt_bin, "component", "bindgen", "--wit" });
    cmd.addDirectoryArg(b.path("wit"));
    cmd.addArgs(&.{ "--world", world, "--impl", impl, "-o" });
    return cmd.addOutputFileArg(out);
}
