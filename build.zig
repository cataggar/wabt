const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info from binaries") orelse false;

    const stack_protector = b.option(bool, "stack-protector", "Enable stack protector (requires libc linkage)") orelse false;
    const link_libc = b.option(bool, "link-libc", "Link against libc") orelse stack_protector;
    const version = b.option([]const u8, "version", "Version string") orelse "dev";

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    // Core library module
    const wabt_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (strip) true else null,
        .stack_protector = if (stack_protector) true else null,
        .link_libc = if (link_libc) true else null,
    });
    wabt_mod.addOptions("build_options", options);

    // Static library
    const lib = b.addLibrary(.{
        .name = "wabt",
        .root_module = wabt_mod,
    });
    b.installArtifact(lib);

    // Per-subcommand source files (each exposes pub const usage and pub fn run).
    // Order is unimportant; this list drives both the inline-test loop and
    // documents the subcommand inventory.
    const subcommand_sources = [_][]const u8{
        "src/tools/parse.zig",
        "src/tools/print.zig",
        "src/tools/validate.zig",
        "src/tools/objdump.zig",
        "src/tools/strip.zig",
        "src/tools/json_from_wast.zig",
        "src/tools/decompile.zig",
        "src/tools/stats.zig",
        "src/tools/desugar.zig",
        "src/tools/spectest.zig",
        "src/tools/shrink.zig",
        "src/tools/component.zig",
        "src/tools/component_embed.zig",
        "src/tools/component_new.zig",
        "src/tools/component_compose.zig",
        // Subject dispatchers (added by #137 — six conceptual roots).
        "src/tools/text.zig",
        "src/tools/module.zig",
        "src/tools/interface.zig",
        "src/tools/compose.zig",
        "src/tools/spec.zig",
    };

    // Single wabt CLI exe — dispatches to subcommand modules at runtime.
    const wabt_cli_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/wabt.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (strip) true else null,
        .stack_protector = if (stack_protector) true else null,
        .link_libc = if (link_libc) true else null,
        .imports = &.{
            .{ .name = "wabt", .module = wabt_mod },
        },
    });

    const wabt_exe = b.addExecutable(.{
        .name = "wabt",
        .root_module = wabt_cli_mod,
    });
    // Increase default stack size for deeply nested Wasm blocks
    wabt_exe.stack_size = 128 * 1024 * 1024; // 128 MB
    b.installArtifact(wabt_exe);

    // ── wasi-preview1 → preview2 adapter ─────────────────────────────────
    //
    // Builds `zig-out/adapter/wasi_snapshot_preview1.command.wasm` from
    // `adapters/wasi-preview1/src/adapter.wat` using the wabt library. See
    // `adapters/wasi-preview1/README.md` for the surface coverage, the
    // current scaffold status, and the roadmap up to the embedded-default
    // adapter for `wabt component new` (tracked under cataggar/wamr#453).
    // Build the tool for the actual host machine (NOT the user's
    // `-Dtarget`): the tool runs at build time on the build platform
    // to produce the adapter wasm. `b.graph.host` in Zig 0.16 returns
    // the user-selected `-Dtarget` when one is set (verified failing
    // on the `wasi`/`riscv64` release matrix entries), so we resolve
    // the native query explicitly here.
    const native_host = b.resolveTargetQuery(.{});

    // The wabt module itself is compiled for the user's target; the
    // tool needs a separate copy compiled for the host so the
    // build-time `build-wasi-preview1-adapter` exe is executable on
    // the CI runner.
    const wabt_host_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = native_host,
        .optimize = optimize,
    });
    wabt_host_mod.addOptions("build_options", options);

    const adapter_tool_mod = b.createModule(.{
        .root_source_file = b.path("adapters/wasi-preview1/tools/build_adapter.zig"),
        .target = native_host,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wabt", .module = wabt_host_mod },
        },
    });
    const adapter_tool_exe = b.addExecutable(.{
        .name = "build-wasi-preview1-adapter",
        .root_module = adapter_tool_mod,
    });
    adapter_tool_exe.stack_size = 128 * 1024 * 1024;

    // ── Adapter artifacts: command + reactor shapes ──────────────────────
    //
    // Both shapes share `src/fragments/{prelude,body,realloc,exports}.wat`
    // and add per-shape `*-imports.wat`, `*-impl.wat`, and `*-footer.wat`
    // fragments. The build tool concatenates argv-order fragments before
    // parsing, so a single tool invocation per shape produces the artifact.
    // See `adapters/wasi-preview1/src/fragments/README.md` for the cut
    // points and the shape-specific differences.
    //
    // Adapter artifacts are wired into the `adapter` umbrella step (both
    // shapes) plus per-shape `adapter-command` / `adapter-reactor` steps.
    // Both blobs are `@embedFile`d into the CLI so `wabt component new`
    // auto-picks the right shape based on the embed's `_start` export
    // (see `src/tools/component_new.zig:pickBuiltinAdapter`).
    const adapter_step = b.step(
        "adapter",
        "Build the wasi-preview1 → preview2 adapter (command + reactor shapes; see adapters/wasi-preview1/README.md)",
    );

    const adapter_wasm_command = buildAdapterArtifact(b, adapter_tool_exe, .command);
    const adapter_install_command = b.addInstallFileWithDir(
        adapter_wasm_command,
        .prefix,
        "adapter/wasi_snapshot_preview1.command.wasm",
    );
    const adapter_step_command = b.step(
        "adapter-command",
        "Build only the command-shape preview1 adapter (wasi_snapshot_preview1.command.wasm)",
    );
    adapter_step_command.dependOn(&adapter_install_command.step);
    adapter_step.dependOn(&adapter_install_command.step);

    const adapter_wasm_reactor = buildAdapterArtifact(b, adapter_tool_exe, .reactor);
    const adapter_install_reactor = b.addInstallFileWithDir(
        adapter_wasm_reactor,
        .prefix,
        "adapter/wasi_snapshot_preview1.reactor.wasm",
    );
    const adapter_step_reactor = b.step(
        "adapter-reactor",
        "Build only the reactor-shape preview1 adapter (wasi_snapshot_preview1.reactor.wasm)",
    );
    adapter_step_reactor.dependOn(&adapter_install_reactor.step);
    adapter_step.dependOn(&adapter_install_reactor.step);

    // ── Builtin adapter module ───────────────────────────────────────────
    //
    // Compile-time bake BOTH adapter blobs into the wabt CLI so
    // `wabt component new` can auto-splice preview1 cores without
    // requiring `--adapt wasi_snapshot_preview1=<path>`. The CLI's
    // `pickBuiltinAdapter` picks command vs reactor by inspecting
    // the embed's exports for `_start`. We stage a generated
    // `builtin.zig` next to both adapter wasms in a single
    // WriteFile dir; `@embedFile` then resolves to the run-tool
    // outputs, which makes Zig pull both adapter wasms in as build
    // dependencies of the CLI exe automatically.
    const builtin_stage = b.addWriteFiles();
    const builtin_zig = builtin_stage.add(
        "builtin.zig",
        "//! Generated by build.zig; do not edit.\n" ++
            "//! Compile-time-embedded wasi-preview1 → preview2 adapters.\n" ++
            "//!\n" ++
            "//! `wasi_preview1_command_wasm` — exports `wasi:cli/run@0.2.6#run`,\n" ++
            "//! drives the embed via `__main_module__._start`. Picked when the\n" ++
            "//! embed core exports `_start`.\n" ++
            "//!\n" ++
            "//! `wasi_preview1_reactor_wasm` — no `wasi:cli/run` export, no\n" ++
            "//! `_start` invocation. Picked when the embed core lacks `_start`\n" ++
            "//! (the wrapping component lifts the embed's own exports\n" ++
            "//! directly). See cataggar/wabt#167.\n" ++
            "pub const wasi_preview1_command_wasm: []const u8 =\n" ++
            "    @embedFile(\"wasi_snapshot_preview1.command.wasm\");\n" ++
            "pub const wasi_preview1_reactor_wasm: []const u8 =\n" ++
            "    @embedFile(\"wasi_snapshot_preview1.reactor.wasm\");\n",
    );
    _ = builtin_stage.addCopyFile(
        adapter_wasm_command,
        "wasi_snapshot_preview1.command.wasm",
    );
    _ = builtin_stage.addCopyFile(
        adapter_wasm_reactor,
        "wasi_snapshot_preview1.reactor.wasm",
    );
    const builtin_adapter_mod = b.createModule(.{
        .root_source_file = builtin_zig,
        .target = target,
        .optimize = optimize,
        .strip = if (strip) true else null,
        .stack_protector = if (stack_protector) true else null,
        .link_libc = if (link_libc) true else null,
    });
    wabt_cli_mod.addImport("builtin_adapter", builtin_adapter_mod);

    // wasm2wat-fuzz: buildable but NOT installed. Existing fuzz scripts
    // expect this exe to live somewhere reachable; keep it as an explicit
    // build step.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/wasm2wat-fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (strip) true else null,
        .stack_protector = if (stack_protector) true else null,
        .link_libc = if (link_libc) true else null,
        .imports = &.{
            .{ .name = "wabt", .module = wabt_mod },
        },
    });
    const fuzz_exe = b.addExecutable(.{
        .name = "wasm2wat-fuzz",
        .root_module = fuzz_mod,
    });
    fuzz_exe.stack_size = 128 * 1024 * 1024;
    const fuzz_step = b.step("fuzz-bin", "Build the wasm2wat-fuzz harness (not installed)");
    fuzz_step.dependOn(&fuzz_exe.step);

    // Tests
    const lib_test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_test_mod.addOptions("build_options", options);
    const lib_tests = b.addTest(.{
        .root_module = lib_test_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);

    // Per-subcommand inline tests
    for (subcommand_sources) |src| {
        const sub_mod = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wabt", .module = wabt_mod },
            },
        });
        // `component_new.zig` references the compile-time-embedded
        // adapter via `@import("builtin_adapter")`; make it resolvable
        // in the test build too.
        if (std.mem.endsWith(u8, src, "component_new.zig")) {
            sub_mod.addImport("builtin_adapter", builtin_adapter_mod);
        }
        const sub_test = b.addTest(.{
            .root_module = sub_mod,
        });
        const run_sub_test = b.addRunArtifact(sub_test);
        test_step.dependOn(&run_sub_test.step);
    }

    // Inline tests for the dispatcher itself (parseSubcommand etc.).
    const dispatcher_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/wabt.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wabt", .module = wabt_mod },
            },
        }),
    });
    const run_dispatcher_test = b.addRunArtifact(dispatcher_test);
    test_step.dependOn(&run_dispatcher_test.step);

    // CLI smoke assertions: subcommand layout, exit codes, version-on-stdout.
    {
        const wabt_version_line = b.fmt("wabt {s}\n", .{version});

        const wabt_version_run = b.addRunArtifact(wabt_exe);
        wabt_version_run.addArg("version");
        wabt_version_run.expectExitCode(0);
        wabt_version_run.expectStdOutEqual(wabt_version_line);
        test_step.dependOn(&wabt_version_run.step);

        const wabt_help_run = b.addRunArtifact(wabt_exe);
        wabt_help_run.addArg("help");
        wabt_help_run.expectExitCode(0);
        test_step.dependOn(&wabt_help_run.step);

        const wabt_no_subcmd = b.addRunArtifact(wabt_exe);
        wabt_no_subcmd.expectExitCode(1);
        test_step.dependOn(&wabt_no_subcmd.step);

        const wabt_unknown = b.addRunArtifact(wabt_exe);
        wabt_unknown.addArg("not-a-real-subcommand");
        wabt_unknown.expectExitCode(1);
        test_step.dependOn(&wabt_unknown.step);

        // ── #185: leaf `help` subword + rejected -h / --help flags ──
        //
        // One representative leaf per subject. The positional `help`
        // form must exit 0; the legacy `-h` / `--help` flags must be
        // rejected as unknown options (exit non-zero). Mirrors the
        // top-level `parseSubcommand` test assertions in
        // `src/tools/wabt.zig` at the verb tier.
        const help_cases = [_][3][]const u8{
            .{ "text", "parse", "<input.wat>" },
            .{ "module", "validate", "<input.wasm>" },
            .{ "component", "new", "<input.wasm>" },
            .{ "spec", "run", "<input.wast>" },
        };
        inline for (help_cases) |c| {
            const subject = c[0];
            const verb = c[1];

            // `wabt <subject> <verb> help` → exit 0.
            const ok = b.addRunArtifact(wabt_exe);
            ok.addArgs(&.{ subject, verb, "help" });
            ok.expectExitCode(0);
            test_step.dependOn(&ok.step);

            // `wabt <subject> <verb> -h` → exit non-zero (the flag is
            // no longer recognised; the leaf falls through to its
            // existing unknown-option / missing-input error path).
            const dash_h = b.addRunArtifact(wabt_exe);
            dash_h.addArgs(&.{ subject, verb, "-h" });
            dash_h.expectExitCode(1);
            test_step.dependOn(&dash_h.step);

            // `wabt <subject> <verb> --help` → exit non-zero, same
            // reasoning as above.
            const dash_help = b.addRunArtifact(wabt_exe);
            dash_help.addArgs(&.{ subject, verb, "--help" });
            dash_help.expectExitCode(1);
            test_step.dependOn(&dash_help.step);
        }
    }
}

/// Adapter shape selector used by `buildAdapterArtifact` to pick
/// the per-shape fragment list. The named output file embeds the
/// shape in its filename so both artifacts can co-exist under
/// `zig-out/adapter/`.
const AdapterShape = enum {
    command,
    reactor,

    fn worldName(self: AdapterShape) []const u8 {
        return switch (self) {
            .command => "command",
            .reactor => "reactor",
        };
    }

    fn outputBasename(self: AdapterShape) []const u8 {
        return switch (self) {
            .command => "wasi_snapshot_preview1.command.wasm",
            .reactor => "wasi_snapshot_preview1.reactor.wasm",
        };
    }
};

/// Run `build-wasi-preview1-adapter` for one shape and return the
/// generated `LazyPath`. Argv layout:
///
///     <wit-dir> <world-name> <output.wasm> \
///         prelude.wat <shape>-imports.wat body.wat <shape>-impl.wat \
///         realloc.wat exports.wat <shape>-footer.wat
///
/// Fragment order matters — see
/// `adapters/wasi-preview1/src/fragments/README.md` for the cut
/// rationale (imports must precede non-import defs; the per-shape
/// `*-impl.wat` supplies trap-stub funcs or the `$run` entry).
fn buildAdapterArtifact(
    b: *std.Build,
    tool_exe: *std.Build.Step.Compile,
    shape: AdapterShape,
) std.Build.LazyPath {
    const run = b.addRunArtifact(tool_exe);
    // <wit-dir>
    run.addDirectoryArg(b.path("adapters/wasi-preview1/wit"));
    // <world-name>
    run.addArg(shape.worldName());
    // <output.wasm>
    const out = run.addOutputFileArg(shape.outputBasename());

    const frag_dir = "adapters/wasi-preview1/src/fragments";
    const per_shape_imports = switch (shape) {
        .command => "command-imports.wat",
        .reactor => "reactor-imports.wat",
    };
    const per_shape_impl = switch (shape) {
        .command => "command-impl.wat",
        .reactor => "reactor-impl.wat",
    };
    const per_shape_footer = switch (shape) {
        .command => "command-footer.wat",
        .reactor => "reactor-footer.wat",
    };
    const fragments = [_][]const u8{
        "prelude.wat",
        per_shape_imports,
        "body.wat",
        per_shape_impl,
        "realloc.wat",
        "exports.wat",
        per_shape_footer,
    };
    for (fragments) |frag| {
        const full = b.pathJoin(&.{ frag_dir, frag });
        run.addFileArg(b.path(full));
    }
    return out;
}
