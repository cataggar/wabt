const std = @import("std");

/// Standalone `hello` Component-Model example: a `wasi:cli/run` command
/// written in Zig that prints a greeting. It depends on the `wasip2`
/// guest-binding library (the `wasi_cli` / `wasi_io` / `abi` modules) and
/// wraps the compiled core wasm into a component with the `wabt` CLI.
///
/// Prerequisites: Zig 0.16 and the `wabt` CLI (cataggar/wabt) on PATH.
pub fn build(b: *std.Build) void {
    // The wasip2 guest-binding library — its vendored `src/*.zig` modules
    // are referenced directly by the build-exe import graph below.
    const wasip2 = b.dependency("wasip2", .{});

    const examples_step = b.step("examples", "Build the hello component");

    const core = compileZigWasm(b, .{
        .source = b.path("src/main.zig"),
        .exports = &.{ "wasi:cli/run@0.2.6#run", "cabi_realloc" },
        .output = "hello.core.wasm",
        .imports = &.{
            .{ .name = "wasi_cli", .path = wasip2.path("src/wasi_cli.zig"), .deps = &.{"wasi_io"} },
            .{ .name = "wasi_io", .path = wasip2.path("src/wasi_io.zig"), .deps = &.{"abi"}, .root_dep = false },
            .{ .name = "abi", .path = wasip2.path("src/abi.zig"), .root_dep = false },
        },
    });
    const hello = makeComponent(b, .{
        .core = core,
        .wit_dir = "wit",
        .world = "hello",
        .output = "hello.wasm",
    });
    installAndValidate(b, examples_step, hello, "hello.wasm");

    b.getInstallStep().dependOn(examples_step);
}

// ── Build helpers (ported from the wasip2 library) ─────────────────

const ZigWasmImport = struct {
    /// Import name, e.g. `wasi_cli` for `@import("wasi_cli")`.
    name: []const u8,
    /// Module root source (a LazyPath — here, into the wasip2 dependency).
    path: std.Build.LazyPath,
    /// Names of other modules in the same list this module `@import`s.
    deps: []const []const u8 = &.{},
    /// When true, the root source `@import`s this module directly.
    root_dep: bool = true,
};

const ZigWasmCompile = struct {
    source: std.Build.LazyPath,
    exports: []const []const u8,
    output: []const u8,
    imports: []const ZigWasmImport = &.{},
    target_triple: []const u8 = "wasm32-freestanding",
};

/// Invoke `zig build-exe -target wasm32-freestanding -O ReleaseSmall
/// -fno-entry --export=…`, reconstructing the module import graph
/// (`root` → `wasi_*` → `abi`) via `--dep` / `-M` flags.
fn compileZigWasm(b: *std.Build, opts: ZigWasmCompile) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{
        b.graph.zig_exe, "build-exe",
        "-target",       opts.target_triple,
        "-O",            "ReleaseSmall",
        "-fno-entry",
    });
    for (opts.exports) |sym| cmd.addArg(b.fmt("--export={s}", .{sym}));

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
    const out = cmd.addPrefixedOutputFileArg("-femit-bin=", opts.output);
    cmd.setName(b.fmt("zig build-exe {s}", .{opts.output}));
    return out;
}

const ReactorComponent = struct {
    core: std.Build.LazyPath,
    wit_dir: []const u8,
    world: []const u8,
    output: []const u8,
};

/// One-step `wabt component new --world <world> --wit <dir>`: embeds the
/// WIT, wraps the core into a component, and validates — in one call.
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
