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
    {
        const adapter_tool_mod = b.createModule(.{
            .root_source_file = b.path("adapters/wasi-preview1/tools/build_adapter.zig"),
            // Build the tool for the host so we can run it; the adapter
            // artifact it emits is the wasm target itself.
            .target = b.graph.host,
            .optimize = optimize,
            .strip = if (strip) true else null,
            .stack_protector = if (stack_protector) true else null,
            .link_libc = if (link_libc) true else null,
            .imports = &.{
                .{ .name = "wabt", .module = wabt_mod },
            },
        });
        const adapter_tool_exe = b.addExecutable(.{
            .name = "build-wasi-preview1-adapter",
            .root_module = adapter_tool_mod,
        });
        adapter_tool_exe.stack_size = 128 * 1024 * 1024;

        const run_adapter_tool = b.addRunArtifact(adapter_tool_exe);
        run_adapter_tool.addFileArg(b.path("adapters/wasi-preview1/src/adapter.wat"));
        const adapter_wasm = run_adapter_tool.addOutputFileArg(
            "wasi_snapshot_preview1.command.wasm",
        );

        const adapter_install = b.addInstallFileWithDir(
            adapter_wasm,
            .prefix,
            "adapter/wasi_snapshot_preview1.command.wasm",
        );
        const adapter_step = b.step(
            "adapter",
            "Build the wasi-preview1 → preview2 adapter (scaffold; see adapters/wasi-preview1/README.md)",
        );
        adapter_step.dependOn(&adapter_install.step);
    }

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
        const sub_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "wabt", .module = wabt_mod },
                },
            }),
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
    }
}
