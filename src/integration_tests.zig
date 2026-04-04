//! End-to-end integration tests that exercise multiple wabt modules together.
//!
//! Each test crosses at least two module boundaries (parser → writer,
//! reader → validator → writer, etc.) to verify the pipeline works
//! as a whole.

const std = @import("std");
const types = @import("types.zig");
const Mod = @import("Module.zig");
const Validator = @import("Validator.zig");
const binary_reader = @import("binary/reader.zig");
const binary_writer = @import("binary/writer.zig");
const text_parser = @import("text/Parser.zig");
const text_writer = @import("text/Writer.zig");
const CWriter = @import("CWriter.zig");
const Decompiler = @import("Decompiler.zig");
const Interp = @import("interp/Interpreter.zig");

// ── Helpers ─────────────────────────────────────────────────────────────

fn containsSubstring(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    if (needle.len == 0) return true;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ── 1. WAT → WASM → WAT round-trip ─────────────────────────────────────

test "WAT → WASM → WAT round-trip" {
    const allocator = std.testing.allocator;

    const wat =
        \\(module
        \\  (memory 1)
        \\  (export "mem" (memory 0))
        \\)
    ;

    // Parse WAT text into Module IR
    var module1 = try text_parser.parseModule(allocator, wat);
    defer module1.deinit();

    try std.testing.expectEqual(@as(usize, 1), module1.memories.items.len);
    try std.testing.expectEqual(@as(usize, 1), module1.exports.items.len);

    // Write Module IR to WASM binary
    const wasm_bytes = try binary_writer.writeModule(allocator, &module1);
    defer allocator.free(wasm_bytes);

    // Binary must start with the wasm magic + version
    try std.testing.expect(wasm_bytes.len >= 8);
    try std.testing.expect(std.mem.eql(u8, wasm_bytes[0..4], &binary_reader.magic));

    // Read WASM binary back into a new Module IR
    var module2 = try binary_reader.readModule(allocator, wasm_bytes);
    defer module2.deinit();

    // Verify the round-tripped module matches
    try std.testing.expectEqual(@as(usize, 1), module2.memories.items.len);
    try std.testing.expectEqual(@as(usize, 1), module2.exports.items.len);
    try std.testing.expectEqualStrings("mem", module2.exports.items[0].name);
    try std.testing.expectEqual(types.ExternalKind.memory, module2.exports.items[0].kind);

    // Also produce WAT text from the re-read module
    const wat_out = try text_writer.writeModule(allocator, &module2);
    defer allocator.free(wat_out);

    try std.testing.expect(containsSubstring(wat_out, "memory"));
    try std.testing.expect(containsSubstring(wat_out, "export"));
}

// ── 2. Binary read → validate → write → re-read ────────────────────────

test "binary read → validate → write → re-read" {
    const allocator = std.testing.allocator;

    // Minimal wasm with: type section (func ()->void), function section,
    // export section, code section.
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, // magic
        0x01, 0x00, 0x00, 0x00, // version 1
        // Type section (id=1)
        0x01, 0x04, // section id=1, size=4
        0x01, // 1 type
        0x60, 0x00, 0x00, // func () -> ()
        // Function section (id=3)
        0x03, 0x02, // section id=3, size=2
        0x01, // 1 function
        0x00, // type index 0
        // Export section (id=7)
        0x07, 0x08, // section id=7, size=8
        0x01, // 1 export
        0x04, 0x6d, 0x61, 0x69, 0x6e, // "main"
        0x00, // kind = func
        0x00, // func index 0
        // Code section (id=10)
        0x0a, 0x04, // section id=10, size=4
        0x01, // 1 body
        0x02, // body size = 2
        0x00, // 0 locals
        0x0b, // end
    };

    // Read → validate → write
    var module = try binary_reader.readModule(allocator, &wasm);
    defer module.deinit();

    try Validator.validate(&module, .{});

    try std.testing.expectEqual(@as(usize, 1), module.module_types.items.len);
    try std.testing.expectEqual(@as(usize, 1), module.funcs.items.len);
    try std.testing.expectEqual(@as(usize, 1), module.exports.items.len);

    // Write back to binary
    const wasm2 = try binary_writer.writeModule(allocator, &module);
    defer allocator.free(wasm2);

    // Re-read and verify
    var module2 = try binary_reader.readModule(allocator, wasm2);
    defer module2.deinit();

    try std.testing.expectEqual(@as(usize, 1), module2.module_types.items.len);
    try std.testing.expectEqual(@as(usize, 1), module2.funcs.items.len);
    try std.testing.expectEqual(@as(usize, 1), module2.exports.items.len);
    try std.testing.expectEqualStrings("main", module2.exports.items[0].name);
}

// ── 3. Text parse → binary write → binary read ─────────────────────────

test "text parse → binary write → binary read" {
    const allocator = std.testing.allocator;

    const wat =
        \\(module
        \\  (memory 1)
        \\  (export "mem" (memory 0))
        \\)
    ;

    var module = try text_parser.parseModule(allocator, wat);
    defer module.deinit();

    const wasm_bytes = try binary_writer.writeModule(allocator, &module);
    defer allocator.free(wasm_bytes);

    var module2 = try binary_reader.readModule(allocator, wasm_bytes);
    defer module2.deinit();

    try std.testing.expectEqual(@as(usize, 1), module2.memories.items.len);
    try std.testing.expectEqual(@as(u64, 1), module2.memories.items[0].@"type".limits.initial);
    try std.testing.expectEqual(@as(usize, 1), module2.exports.items.len);
    try std.testing.expectEqualStrings("mem", module2.exports.items[0].name);
    try std.testing.expectEqual(types.ExternalKind.memory, module2.exports.items[0].kind);
}

// ── 4. wasm-strip removes custom sections ───────────────────────────────

test "strip custom sections" {
    const allocator = std.testing.allocator;

    // Build a module with a custom section via the IR
    var module = Mod.Module.init(allocator);
    defer module.deinit();

    try module.customs.append(allocator, .{
        .name = "my_custom",
        .data = &[_]u8{ 0xCA, 0xFE },
    });

    // Write to binary — the custom section should be present
    const wasm1 = try binary_writer.writeModule(allocator, &module);
    defer allocator.free(wasm1);

    var mod1 = try binary_reader.readModule(allocator, wasm1);
    defer mod1.deinit();
    try std.testing.expectEqual(@as(usize, 1), mod1.customs.items.len);
    try std.testing.expectEqualStrings("my_custom", mod1.customs.items[0].name);

    // "Strip" by clearing customs and rewriting
    mod1.customs.clearRetainingCapacity();
    const wasm2 = try binary_writer.writeModule(allocator, &mod1);
    defer allocator.free(wasm2);

    var mod2 = try binary_reader.readModule(allocator, wasm2);
    defer mod2.deinit();
    try std.testing.expectEqual(@as(usize, 0), mod2.customs.items.len);
}

// ── 5. Validator catches errors ─────────────────────────────────────────

test "validator catches invalid export index" {
    const allocator = std.testing.allocator;

    // Build a module with an export pointing to a non-existent function
    var module = Mod.Module.init(allocator);
    defer module.deinit();

    try module.exports.append(allocator, .{
        .name = "bad",
        .kind = .func,
        .var_ = .{ .index = 99 }, // no functions exist
    });

    const result = Validator.validate(&module, .{});
    try std.testing.expectError(error.InvalidFuncIndex, result);
}

// ── 6. CWriter produces valid C ─────────────────────────────────────────

test "CWriter produces valid C header" {
    const allocator = std.testing.allocator;

    // Minimal empty module
    var module = Mod.Module.init(allocator);
    defer module.deinit();

    const header = try CWriter.writeHeader(allocator, &module, "test_mod");
    defer allocator.free(header);

    // Should contain include guard and wasm-rt.h reference
    try std.testing.expect(containsSubstring(header, "#ifndef"));
    try std.testing.expect(containsSubstring(header, "TEST_MOD_H_"));
    try std.testing.expect(containsSubstring(header, "wasm-rt.h"));
    try std.testing.expect(containsSubstring(header, "test_mod_init"));
    try std.testing.expect(containsSubstring(header, "test_mod_free"));
}

// ── 7. Decompiler produces output ───────────────────────────────────────

test "decompiler produces output for module with memory" {
    const allocator = std.testing.allocator;

    var module = Mod.Module.init(allocator);
    defer module.deinit();

    try module.memories.append(allocator, .{
        .@"type" = .{ .limits = .{ .initial = 1 } },
    });

    const output = try Decompiler.decompile(allocator, &module);
    defer allocator.free(output);

    try std.testing.expect(output.len > 0);
    try std.testing.expect(containsSubstring(output, "memory"));
    try std.testing.expect(containsSubstring(output, "Memories: 1"));
}

// ── 8. Interpreter arithmetic ───────────────────────────────────────────

test "interpreter i32 arithmetic" {
    const allocator = std.testing.allocator;

    // Create a minimal module for the interpreter
    var module = Mod.Module.init(allocator);
    defer module.deinit();

    var instance = try Interp.Instance.init(allocator, &module);
    defer instance.deinit();

    var interp = Interp.Interpreter.init(allocator, &instance);
    defer interp.deinit();

    // Push 30 and 12, add them
    try interp.i32Const(30);
    try interp.i32Const(12);
    try interp.i32Add();
    const result = try interp.popI32();
    try std.testing.expectEqual(@as(i32, 42), result);

    // Subtraction
    try interp.i32Const(100);
    try interp.i32Const(58);
    try interp.i32Sub();
    const sub_result = try interp.popI32();
    try std.testing.expectEqual(@as(i32, 42), sub_result);

    // Multiplication
    try interp.i32Const(6);
    try interp.i32Const(7);
    try interp.i32Mul();
    const mul_result = try interp.popI32();
    try std.testing.expectEqual(@as(i32, 42), mul_result);
}

// ── 9. Interpreter memory ───────────────────────────────────────────────

test "interpreter memory store and load" {
    const allocator = std.testing.allocator;

    // Module with 1 page of memory
    var module = Mod.Module.init(allocator);
    defer module.deinit();

    try module.memories.append(allocator, .{
        .@"type" = .{ .limits = .{ .initial = 1 } },
    });

    var instance = try Interp.Instance.init(allocator, &module);
    defer instance.deinit();

    // Verify memory was allocated (1 page = 65536 bytes)
    try std.testing.expectEqual(@as(usize, 65536), instance.memory.items.len);

    var interp = Interp.Interpreter.init(allocator, &instance);
    defer interp.deinit();

    // Store 0xDEADBEEF at address 0, offset 100
    try interp.i32Const(0); // base address
    try interp.i32Const(@as(i32, @bitCast(@as(u32, 0xDEADBEEF))));
    try interp.i32Store(100); // offset=100

    // Load it back
    try interp.i32Const(0); // base address
    try interp.i32Load(100); // offset=100
    const loaded = try interp.popI32();
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0xDEADBEEF))), loaded);
}

// ── 10. Multi-section binary ────────────────────────────────────────────

test "multi-section binary: type+import+func+memory+export+code" {
    const allocator = std.testing.allocator;

    // Build a module with multiple section types via the IR
    var module = Mod.Module.init(allocator);
    defer module.deinit();

    // Type section: () -> ()
    const params = try allocator.alloc(types.ValType, 0);
    const results = try allocator.alloc(types.ValType, 0);
    try module.module_types.append(allocator, .{
        .func_type = .{ .params = params, .results = results },
    });

    // Import: env.log () -> ()
    try module.imports.append(allocator, .{
        .module_name = "env",
        .field_name = "log",
        .kind = .func,
        .func = .{ .type_var = .{ .index = 0 }, .sig = .{} },
    });

    // The import creates an imported function
    try module.funcs.append(allocator, .{
        .decl = .{ .type_var = .{ .index = 0 }, .sig = .{} },
        .is_import = true,
    });
    module.num_func_imports = 1;

    // Defined function: type 0
    try module.funcs.append(allocator, .{
        .decl = .{ .type_var = .{ .index = 0 }, .sig = .{} },
    });

    // Memory: 1 page
    try module.memories.append(allocator, .{
        .@"type" = .{ .limits = .{ .initial = 1 } },
    });

    // Exports: "run" -> func 1, "mem" -> memory 0
    try module.exports.append(allocator, .{
        .name = "run",
        .kind = .func,
        .var_ = .{ .index = 1 },
    });
    try module.exports.append(allocator, .{
        .name = "mem",
        .kind = .memory,
        .var_ = .{ .index = 0 },
    });

    // Validate
    try Validator.validate(&module, .{});

    // Write to binary
    const wasm = try binary_writer.writeModule(allocator, &module);
    defer allocator.free(wasm);

    // Read back and verify counts
    var module2 = try binary_reader.readModule(allocator, wasm);
    defer module2.deinit();

    try Validator.validate(&module2, .{});

    try std.testing.expectEqual(@as(usize, 1), module2.module_types.items.len);
    try std.testing.expectEqual(@as(usize, 1), module2.imports.items.len);
    try std.testing.expectEqual(@as(usize, 2), module2.funcs.items.len);
    try std.testing.expectEqual(@as(usize, 1), module2.memories.items.len);
    try std.testing.expectEqual(@as(usize, 2), module2.exports.items.len);
    try std.testing.expectEqualStrings("run", module2.exports.items[0].name);
    try std.testing.expectEqualStrings("mem", module2.exports.items[1].name);
}
