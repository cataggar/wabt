const std = @import("std");

/// `wasip2` — hand-written Zig **guest** bindings (canonical-ABI `extern`
/// wrappers) for the P2 WASI packages bundled by `cataggar/wabt`, plus
/// runnable Component-Model examples.
///
/// The `wasi_*` modules are wasm-only (their `extern` host imports link
/// solely for `wasm32-freestanding` guests), so there is no native
/// library artifact and no native `zig build test`. The meaningful gate
/// is `zig build examples`, which compiles each example to a core wasm,
/// wraps it into a component with the `wabt` CLI, and validates it.
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

    const wasi_http = b.addModule("wasi_http", .{ .root_source_file = b.path("src/wasi_http.zig") });
    wasi_http.addImport("abi", abi);

    const wasi_keyvalue = b.addModule("wasi_keyvalue", .{ .root_source_file = b.path("src/wasi_keyvalue.zig") });
    wasi_keyvalue.addImport("abi", abi);

    // ── Examples ───────────────────────────────────────────────────
    const examples_step = b.step(
        "examples",
        "Build the WebAssembly Component examples in examples/",
    );

    // hello: native `wasi:cli` command. Exports `wasi:cli/run@0.2.6#run`
    // and writes a greeting through `wasi:cli/stdout` + `wasi:io/streams`.
    // Built `wasm32-freestanding`; canonical-ABI plumbing lives in the
    // shared `wasi_cli` / `abi` guest helpers.
    const hello_core = compileZigWasm(b, .{
        .source = "examples/hello/src/main.zig",
        .exports = &.{ "wasi:cli/run@0.2.6#run", "cabi_realloc" },
        .output = "hello.core.wasm",
        .imports = &.{
            .{ .name = "wasi_cli", .path = "src/wasi_cli.zig", .deps = &.{"wasi_io"} },
            .{ .name = "wasi_io", .path = "src/wasi_io.zig", .deps = &.{"abi"}, .root_dep = false },
            .{ .name = "abi", .path = "src/abi.zig", .root_dep = false },
        },
    });
    const hello = makeComponent(b, .{
        .core = hello_core,
        .wit_dir = "examples/hello/wit",
        .world = "hello",
        .output = "hello.wasm",
    });
    installAndValidate(b, examples_step, hello, "hello.wasm");

    // sysinfo: prints a monotonic clock reading + a random u64, exercising
    // the wasi_clocks and wasi_random bindings.
    const sysinfo_core = compileZigWasm(b, .{
        .source = "examples/sysinfo/src/main.zig",
        .exports = &.{ "wasi:cli/run@0.2.6#run", "cabi_realloc" },
        .output = "sysinfo.core.wasm",
        .imports = &.{
            .{ .name = "wasi_cli", .path = "src/wasi_cli.zig", .deps = &.{"wasi_io"} },
            .{ .name = "wasi_clocks", .path = "src/wasi_clocks.zig", .deps = &.{"abi"} },
            .{ .name = "wasi_random", .path = "src/wasi_random.zig", .deps = &.{"abi"} },
            .{ .name = "wasi_io", .path = "src/wasi_io.zig", .deps = &.{"abi"}, .root_dep = false },
            .{ .name = "abi", .path = "src/abi.zig", .root_dep = false },
        },
    });
    const sysinfo = makeComponent(b, .{
        .core = sysinfo_core,
        .wit_dir = "examples/sysinfo/wit",
        .world = "sysinfo",
        .output = "sysinfo.wasm",
    });
    installAndValidate(b, examples_step, sysinfo, "sysinfo.wasm");

    // preopens: lists the host's preopened directories, exercising the
    // wasi_filesystem preopens binding.
    const preopens_core = compileZigWasm(b, .{
        .source = "examples/preopens/src/main.zig",
        .exports = &.{ "wasi:cli/run@0.2.6#run", "cabi_realloc" },
        .output = "preopens.core.wasm",
        .imports = &.{
            .{ .name = "wasi_cli", .path = "src/wasi_cli.zig", .deps = &.{"wasi_io"} },
            .{ .name = "wasi_filesystem", .path = "src/wasi_filesystem.zig", .deps = &.{"abi"} },
            .{ .name = "wasi_io", .path = "src/wasi_io.zig", .deps = &.{"abi"}, .root_dep = false },
            .{ .name = "abi", .path = "src/abi.zig", .root_dep = false },
        },
    });
    const preopens = makeComponent(b, .{
        .core = preopens_core,
        .wit_dir = "examples/preopens/wit",
        .world = "preopens",
        .output = "preopens.wasm",
    });
    installAndValidate(b, examples_step, preopens, "preopens.wasm");

    // resolve: resolves localhost to IP addresses via the async
    // wasi_sockets ip-name-lookup path (+ wasi_io poll).
    const resolve_core = compileZigWasm(b, .{
        .source = "examples/resolve/src/main.zig",
        .exports = &.{ "wasi:cli/run@0.2.6#run", "cabi_realloc" },
        .output = "resolve.core.wasm",
        .imports = &.{
            .{ .name = "wasi_cli", .path = "src/wasi_cli.zig", .deps = &.{"wasi_io"} },
            .{ .name = "wasi_sockets", .path = "src/wasi_sockets.zig", .deps = &.{ "abi", "wasi_io" } },
            .{ .name = "wasi_io", .path = "src/wasi_io.zig", .deps = &.{"abi"}, .root_dep = false },
            .{ .name = "abi", .path = "src/abi.zig", .root_dep = false },
        },
    });
    const resolve = makeComponent(b, .{
        .core = resolve_core,
        .wit_dir = "examples/resolve/wit",
        .world = "resolve",
        .output = "resolve.wasm",
    });
    installAndValidate(b, examples_step, resolve, "resolve.wasm");

    // config: reads runtime configuration via the off-by-default
    // wasi:config proposal. Builds + validates; running needs a host
    // that implements wasi:config.
    const config_core = compileZigWasm(b, .{
        .source = "examples/config/src/main.zig",
        .exports = &.{ "wasi:cli/run@0.2.6#run", "cabi_realloc" },
        .output = "config.core.wasm",
        .imports = &.{
            .{ .name = "wasi_cli", .path = "src/wasi_cli.zig", .deps = &.{"wasi_io"} },
            .{ .name = "wasi_config", .path = "src/wasi_config.zig", .deps = &.{"abi"} },
            .{ .name = "wasi_io", .path = "src/wasi_io.zig", .deps = &.{"abi"}, .root_dep = false },
            .{ .name = "abi", .path = "src/abi.zig", .root_dep = false },
        },
    });
    const config = makeComponent(b, .{
        .core = config_core,
        .wit_dir = "examples/config/wit",
        .world = "config",
        .output = "config.wasm",
    });
    installAndValidate(b, examples_step, config, "config.wasm");

    // Default `zig build` builds the examples.
    b.getInstallStep().dependOn(examples_step);
}

// ── Build helpers (ported from cataggar/wamr) ──────────────────────

const ZigWasmImport = struct {
    /// Import name, e.g. `wasi_cli` for `@import("wasi_cli")`.
    name: []const u8,
    /// Repo-relative path to the module's root source file.
    path: []const u8,
    /// Names of other modules in the same `imports` list this module
    /// `@import`s (e.g. `&.{"abi"}`). Wired as `--dep` flags before this
    /// module's `-M` entry.
    deps: []const []const u8 = &.{},
    /// When true, the root source `@import`s this module directly (so it
    /// gets a `--dep` on the root). Transitive-only modules (like `abi`,
    /// reached via the `wasi_*` helpers) set this false.
    root_dep: bool = true,
};

const ZigWasmCompile = struct {
    source: []const u8,
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
fn compileZigWasm(b: *std.Build, opts: ZigWasmCompile) std.Build.LazyPath {
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
        cmd.addFileArg(b.path(opts.source));
    } else {
        // `--dep` flags attach to the next `-M` module. A `dep` name
        // resolves to the single matching `-M<name>=` module, so a
        // shared module (`abi`) is one instance across all importers.
        for (opts.imports) |imp| {
            if (!imp.root_dep) continue;
            cmd.addArg("--dep");
            cmd.addArg(imp.name);
        }
        cmd.addPrefixedFileArg("-Mroot=", b.path(opts.source));
        for (opts.imports) |imp| {
            for (imp.deps) |dep| {
                cmd.addArg("--dep");
                cmd.addArg(dep);
            }
            cmd.addPrefixedFileArg(b.fmt("-M{s}=", .{imp.name}), b.path(imp.path));
        }
    }
    const out = cmd.addPrefixedOutputFileArg("-femit-bin=", opts.output);
    cmd.setName(b.fmt("zig build-exe {s}", .{opts.output}));
    return out;
}

const ReactorComponent = struct {
    core: std.Build.LazyPath,
    /// WIT package directory to embed (`--wit`).
    wit_dir: []const u8,
    /// World to embed (`--world`).
    world: []const u8,
    /// Output basename for the produced component LazyPath.
    output: []const u8,
};

/// One-step `wabt component new --world <world> --wit <dir>`: embeds the
/// WIT, wraps the core into a component, and validates — in one call.
/// The bundled WASI WIT + wasi-preview1 adapter are auto-attached, so no
/// on-disk `wit/deps/` copy is needed.
fn makeComponent(b: *std.Build, opts: ReactorComponent) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{ "wabt", "component", "new", "--world", opts.world, "--wit" });
    cmd.addDirectoryArg(b.path(opts.wit_dir));
    cmd.addFileArg(opts.core);
    cmd.addArg("-o");
    return cmd.addOutputFileArg(opts.output);
}

/// `wabt module validate` the component, then install it under
/// `zig-out/examples/<basename>`.
fn installAndValidate(
    b: *std.Build,
    parent: *std.Build.Step,
    component: std.Build.LazyPath,
    install_basename: []const u8,
) void {
    const validate = b.addSystemCommand(&.{ "wabt", "module", "validate" });
    validate.addFileArg(component);
    validate.setName(b.fmt("wabt module validate {s}", .{install_basename}));

    const install = b.addInstallFileWithDir(component, .{ .custom = "examples" }, install_basename);
    install.step.dependOn(&validate.step);
    parent.dependOn(&install.step);
}
