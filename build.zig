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

    // CLI tools
    const tool_names = [_][]const u8{
        "wat2wasm",
        "wasm2wat",
        "wast2json",
        "wasm-validate",
        "wasm-objdump",
        "wasm2c",
        "wasm-interp",
        "wasm-decompile",
        "wasm-strip",
        "wasm-stats",
        "wat-desugar",
        "spectest-interp",
        "wasm2wat-fuzz",
    };

    for (tool_names) |name| {
        const tool_mod = b.createModule(.{
            .root_source_file = b.path(
                b.fmt("src/tools/{s}.zig", .{name}),
            ),
            .target = target,
            .optimize = optimize,
            .strip = if (strip) true else null,
            .stack_protector = if (stack_protector) true else null,
            .link_libc = if (link_libc) true else null,
            .imports = &.{
                .{ .name = "wabt", .module = wabt_mod },
            },
        });

        const exe = b.addExecutable(.{
            .name = name,
            .root_module = tool_mod,
        });
        // Increase default stack size for deeply nested Wasm blocks
        exe.stack_size = 128 * 1024 * 1024; // 128 MB
        b.installArtifact(exe);
    }

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

    // Tool tests
    for (tool_names) |name| {
        const tool_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(
                    b.fmt("src/tools/{s}.zig", .{name}),
                ),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "wabt", .module = wabt_mod },
                },
            }),
        });
        const run_tool_test = b.addRunArtifact(tool_test);
        test_step.dependOn(&run_tool_test.step);
    }
}
