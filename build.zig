const std = @import("std");

/// wasip2 guest bindings
///
/// Prerequisites: Zig 0.16, and the `wabt` CLI (cataggar/wabt) on PATH.
pub fn build(b: *std.Build) void {
    // ── Library modules (guest bindings) ───────────────────────────
    // Public modules so dependents (and the examples below) can
    // `@import` them when compiling a `wasm32-freestanding` guest. Each
    // `wasi_*` helper depends on the shared `abi` module, which owns the
    // sole `cabi_realloc` export and the canonical-ABI ret-area.
    const abi = b.addModule("abi", .{ .root_source_file = b.path("src/abi.zig") });

    // wasi_io is foundational: cli/http/filesystem/sockets hand back
    // input-stream / output-stream / pollable handles bound here.
    const wasi_io = b.addModule("wasi_io", .{ .root_source_file = b.path("src/wasi_io.zig") });
    wasi_io.addImport("abi", abi);

    const wasi_cli = b.addModule("wasi_cli", .{ .root_source_file = b.path("src/wasi_cli.zig") });
    wasi_cli.addImport("wasi_io", wasi_io);

    const wasi_clocks = b.addModule("wasi_clocks", .{ .root_source_file = b.path("src/wasi_clocks.zig") });
    wasi_clocks.addImport("abi", abi);

    const wasi_random = b.addModule("wasi_random", .{ .root_source_file = b.path("src/wasi_random.zig") });
    wasi_random.addImport("abi", abi);

    const wasi_filesystem = b.addModule("wasi_filesystem", .{ .root_source_file = b.path("src/wasi_filesystem.zig") });
    wasi_filesystem.addImport("abi", abi);

    const wasi_sockets = b.addModule("wasi_sockets", .{ .root_source_file = b.path("src/wasi_sockets.zig") });
    wasi_sockets.addImport("abi", abi);
    wasi_sockets.addImport("wasi_io", wasi_io);

    const wasi_config = b.addModule("wasi_config", .{ .root_source_file = b.path("src/wasi_config.zig") });
    wasi_config.addImport("abi", abi);

    const wasi_nn = b.addModule("wasi_nn", .{ .root_source_file = b.path("src/wasi_nn.zig") });
    wasi_nn.addImport("abi", abi);

    const wasi_tls = b.addModule("wasi_tls", .{ .root_source_file = b.path("src/wasi_tls.zig") });
    wasi_tls.addImport("wasi_io", wasi_io);

    const wasi_http = b.addModule("wasi_http", .{ .root_source_file = b.path("src/wasi_http.zig") });
    wasi_http.addImport("abi", abi);

    const wasi_keyvalue = b.addModule("wasi_keyvalue", .{ .root_source_file = b.path("src/wasi_keyvalue.zig") });
    wasi_keyvalue.addImport("abi", abi);

    // Single-import library surface re-exporting every module.
    const wasip2 = b.addModule("wasip2", .{ .root_source_file = b.path("src/root.zig") });
    wasip2.addImport("abi", abi);
    wasip2.addImport("wasi_io", wasi_io);
    wasip2.addImport("wasi_cli", wasi_cli);
    wasip2.addImport("wasi_clocks", wasi_clocks);
    wasip2.addImport("wasi_random", wasi_random);
    wasip2.addImport("wasi_filesystem", wasi_filesystem);
    wasip2.addImport("wasi_sockets", wasi_sockets);
    wasip2.addImport("wasi_config", wasi_config);
    wasip2.addImport("wasi_http", wasi_http);
    wasip2.addImport("wasi_keyvalue", wasi_keyvalue);
    wasip2.addImport("wasi_nn", wasi_nn);
    wasip2.addImport("wasi_tls", wasi_tls);

    // ── Tests ──────────────────────────────────────────────────────
    // Native unit tests for the host-import-free canonical-ABI core in
    // `abi.zig` (bump arena + ret-area decoders). The `wasi_*` wrappers
    // can't be tested natively — their public functions call `extern`
    // host imports that only link for `wasm32-freestanding`.
    const abi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/abi.zig"),
            .target = b.graph.host,
        }),
    });
    const run_abi_tests = b.addRunArtifact(abi_tests);
    const test_step = b.step("test", "Run native unit tests");
    test_step.dependOn(&run_abi_tests.step);
}

// ── Build helpers (ported from cataggar/wamr) ──────────────────────
//
// These are `pub` so dependents can `@import("wasip2")` this build.zig
// and reuse them (e.g. the `example/hello` branch). Path fields are
// `LazyPath` so a dependent points at the vendored sources via
// `dep.path("src/...")`.

pub const ZigWasmImport = struct {
    /// Import name, e.g. `wasi_cli` for `@import("wasi_cli")`.
    name: []const u8,
    /// The module's root source file. A `LazyPath` so callers in another
    /// package can point at this dependency's vendored sources via
    /// `dep.path("src/...")`.
    path: std.Build.LazyPath,
    /// Names of other modules in the same `imports` list this module
    /// `@import`s (e.g. `&.{"abi"}`). Wired as `--dep` flags before this
    /// module's `-M` entry.
    deps: []const []const u8 = &.{},
    /// When true, the root source `@import`s this module directly (so it
    /// gets a `--dep` on the root). Transitive-only modules (like `abi`,
    /// reached via the `wasi_*` helpers) set this false.
    root_dep: bool = true,
};

pub const ZigWasmCompile = struct {
    source: std.Build.LazyPath,
    /// Names passed via `--export=<name>`.
    exports: []const []const u8,
    output: []const u8,
    /// Extra modules importable from the root via `@import("<name>")`.
    imports: []const ZigWasmImport = &.{},
    target_triple: []const u8 = "wasm32-freestanding",
    /// `-fno-llvm` (self-hosted wasm codegen). Off: LLVM/LLD is required
    /// because Zig 0.16's self-hosted wasm linker mis-sets
    /// `__stack_pointer` (cataggar/wamr#843).
    no_llvm: bool = false,
    no_lld: bool = false,
};

/// Invoke `zig build-exe -target wasm32-freestanding -O ReleaseSmall
/// -fno-entry --export=…`, reconstructing the module import graph
/// (`root` → `wasi_*` → `abi`) via `--dep` / `-M` flags. Captures the
/// emitted wasm as a build-graph LazyPath.
pub fn compileZigWasm(b: *std.Build, opts: ZigWasmCompile) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{
        b.graph.zig_exe, "build-exe",
        "-target",       opts.target_triple,
        "-O",            "ReleaseSmall",
        "-fno-entry",
    });
    if (opts.no_llvm) cmd.addArg("-fno-llvm");
    if (opts.no_lld) cmd.addArg("-fno-lld");
    for (opts.exports) |sym| cmd.addArg(b.fmt("--export={s}", .{sym}));

    if (opts.imports.len == 0) {
        cmd.addFileArg(opts.source);
    } else {
        // `--dep` flags attach to the next `-M` module. A `dep` name
        // resolves to the single matching `-M<name>=` module, so a
        // shared module (`abi`) is one instance across all importers.
        for (opts.imports) |imp| {
            if (!imp.root_dep) continue;
            cmd.addArg("--dep");
            cmd.addArg(imp.name);
        }
        cmd.addPrefixedFileArg("-Mroot=", opts.source);
        for (opts.imports) |imp| {
            for (imp.deps) |dep| {
                cmd.addArg("--dep");
                cmd.addArg(dep);
            }
            cmd.addPrefixedFileArg(b.fmt("-M{s}=", .{imp.name}), imp.path);
        }
    }
    const out = cmd.addPrefixedOutputFileArg("-femit-bin=", opts.output);
    cmd.setName(b.fmt("zig build-exe {s}", .{opts.output}));
    return out;
}

pub const WabtComponent = struct {
    core: std.Build.LazyPath,
    /// WIT package directory to embed (`--wit`). Defaults to `wit/`
    /// relative to the build root.
    wit_dir: ?std.Build.LazyPath = null,
    /// World to embed (`--world`).
    world: []const u8,
    /// Output basename for the produced component LazyPath.
    output: []const u8,
};

/// One-step `wabt component new --world <world> --wit <dir>`: embeds the
/// WIT, wraps the core into a component, and validates — in one call.
/// The bundled WASI WIT + wasi-preview1 adapter are auto-attached, so no
/// on-disk `wit/deps/` copy is needed.
pub fn makeComponent(b: *std.Build, opts: WabtComponent) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{ "wabt", "component", "new", "--world", opts.world, "--wit" });
    cmd.addDirectoryArg(opts.wit_dir orelse b.path("wit"));
    cmd.addFileArg(opts.core);
    cmd.addArg("-o");
    return cmd.addOutputFileArg(opts.output);
}

/// `wabt module validate` the component, then install it under
/// `zig-out/<basename>`.
pub fn installAndValidate(
    b: *std.Build,
    parent: *std.Build.Step,
    component: std.Build.LazyPath,
    install_basename: []const u8,
) void {
    const validate = b.addSystemCommand(&.{ "wabt", "module", "validate" });
    validate.addFileArg(component);
    validate.setName(b.fmt("wabt module validate {s}", .{install_basename}));

    const install = b.addInstallFileWithDir(component, .prefix, install_basename);
    install.step.dependOn(&validate.step);
    parent.dependOn(&install.step);
}
