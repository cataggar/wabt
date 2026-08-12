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

// ── 8. Multi-section binary ─────────────────────────────────────────────

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

// ── 9. Element-segment reference types survive the round trip ───────────

test "an element segment's reference type reaches the binary and comes back" {
    const allocator = std.testing.allocator;

    // An abstract reference type, a bottom type and a concrete one, in the
    // three segment forms. Each has to be written into the element section
    // and read back as itself: the segment defaults to funcref, so a type
    // that is dropped anywhere along the way is silently wrong rather than
    // rejected.
    const wat =
        \\(module
        \\  (type $t (func))
        \\  (table $anys 1 anyref)
        \\  (table $funcs 1 funcref)
        \\  (table $concrete 1 (ref null $t))
        \\  (elem (table $anys) (i32.const 0) anyref (ref.null any))
        \\  (elem declare i31ref (ref.null i31))
        \\  (elem nullfuncref (ref.null nofunc) (ref.null nofunc))
        \\  (elem (table $concrete) (i32.const 0) (ref null $t))
        \\)
    ;

    var module = try text_parser.parseModule(allocator, wat);
    defer module.deinit();
    try Validator.validate(&module, .{});

    const wasm = try binary_writer.writeModule(allocator, &module);
    defer allocator.free(wasm);

    var reread = try binary_reader.readModule(allocator, wasm);
    defer reread.deinit();
    try Validator.validate(&reread, .{});

    const segs = reread.elem_segments.items;
    try std.testing.expectEqual(@as(usize, 4), segs.len);

    try std.testing.expectEqual(types.ValType.anyref, segs[0].elem_type);
    try std.testing.expectEqual(types.SegmentKind.active, segs[0].kind);
    try std.testing.expectEqual(@as(u32, 1), segs[0].elem_expr_count);

    try std.testing.expectEqual(types.ValType.i31ref, segs[1].elem_type);
    try std.testing.expectEqual(types.SegmentKind.declared, segs[1].kind);

    // A reference type the elemlist rule did not know used to be read as the
    // segment's offset, which made this passive segment an active one.
    try std.testing.expectEqual(types.ValType.nullfuncref, segs[2].elem_type);
    try std.testing.expectEqual(types.SegmentKind.passive, segs[2].kind);
    try std.testing.expectEqual(@as(u32, 2), segs[2].elem_expr_count);

    // A segment with no elements still has to say what type it holds none
    // of, and only the expression form of the encoding has room to say it.
    try std.testing.expectEqual(types.ValType.concrete_ref_null, segs[3].elem_type);
    try std.testing.expectEqual(@as(u32, 0), segs[3].elem_type_idx);
    try std.testing.expectEqual(@as(u32, 0), segs[3].elem_expr_count);
    try std.testing.expect(segs[3].uses_elem_exprs);
}

test "an element segment with no table is not made into one that needs a table" {
    const allocator = std.testing.allocator;

    // Reading the first element expression as an offset invented an active
    // segment, and a module with no table then failed on the table index
    // rather than on anything it actually said.
    var passive = try text_parser.parseModule(allocator,
        \\(module (elem nullfuncref (ref.null nofunc)))
    );
    defer passive.deinit();
    try Validator.validate(&passive, .{});
    try std.testing.expectEqual(types.SegmentKind.passive, passive.elem_segments.items[0].kind);

    // An active segment in a module with no table is still rejected.
    var active = try text_parser.parseModule(allocator,
        \\(module (elem (i32.const 0) func))
    );
    defer active.deinit();
    try std.testing.expectError(error.InvalidTableIndex, Validator.validate(&active, .{}));
}

test "an element segment whose type does not fit is still rejected" {
    const allocator = std.testing.allocator;

    // Now that the element type is recorded rather than defaulted, the
    // checks that use it have to keep failing when they should.
    const rejected = .{
        // Element type is not a subtype of the table's.
        \\(module (table 1 anyref) (elem (table 0) (i32.const 0) funcref (ref.null func)))
        ,
        \\(module (table 1 eqref) (elem (table 0) (i32.const 0) anyref (ref.null any)))
        ,
        // Element expression is not of the type the segment names.
        \\(module (func) (elem declare anyref (ref.func 0)))
        ,
        // Two concrete types that are not each other.
        \\(module (type $a (func)) (type $b (struct)) (table 1 (ref null $b))
        \\  (elem (table 0) (i32.const 0) (ref null $a)))
    };
    inline for (rejected) |src| {
        var module = try text_parser.parseModule(allocator, src);
        defer module.deinit();
        try std.testing.expectError(error.TypeMismatch, Validator.validate(&module, .{}));
    }

    // The subtyping that should pass still passes: nullfuncref is below
    // funcref, and a table of the supertype accepts it.
    var accepted = try text_parser.parseModule(allocator,
        \\(module (table 1 funcref) (elem (table 0) (i32.const 0) nullfuncref (ref.null nofunc)))
    );
    defer accepted.deinit();
    try Validator.validate(&accepted, .{});
}

test "an element segment carries a concrete type index of any size" {
    const allocator = std.testing.allocator;

    // #402 made the writer spell a concrete heap type index as the s33 it
    // is; this is the element segment's share of that, which nothing could
    // reach until the segment kept its type. Index 93 is past the point
    // where the signed and unsigned spellings part company, and `ref.null
    // 93` has to name the same type the elemlist does or the segment does
    // not validate.
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(allocator);
    try src.appendSlice(allocator, "(module\n");
    for (0..94) |_| try src.appendSlice(allocator, "  (type (func))\n");
    try src.appendSlice(allocator,
        \\  (table 1 (ref null 93))
        \\  (elem (table 0) (i32.const 0) (ref null 93) (ref.null 93))
        \\)
    );

    var module = try text_parser.parseModule(allocator, src.items);
    defer module.deinit();
    try Validator.validate(&module, .{});

    const wasm = try binary_writer.writeModule(allocator, &module);
    defer allocator.free(wasm);

    var reread = try binary_reader.readModule(allocator, wasm);
    defer reread.deinit();
    try Validator.validate(&reread, .{});
    try std.testing.expectEqual(types.ValType.concrete_ref_null, reread.elem_segments.items[0].elem_type);
    try std.testing.expectEqual(@as(u32, 93), reread.elem_segments.items[0].elem_type_idx);
    try std.testing.expectEqual(@as(u32, 1), reread.elem_segments.items[0].elem_expr_count);
}
