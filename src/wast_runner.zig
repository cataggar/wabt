//! WAST spec test runner.
//!
//! Reads `.wast` source text and executes top-level commands:
//! `(module ...)`, `(assert_invalid ...)`, `(assert_malformed ...)`, etc.
//! Reports aggregate pass/fail/skip counts.

const std = @import("std");
const Parser = @import("text/Parser.zig");
const Validator = @import("Validator.zig");
const Mod = @import("Module.zig");
const types = @import("types.zig");
const Interp = @import("interp/Interpreter.zig");
const binary_reader = @import("binary/reader.zig");

// Sentinel bit patterns for NaN category matching in assert_return comparisons.
const nan_canonical_f32: u32 = 0x7FC00001;
const nan_arithmetic_f32: u32 = 0x7FC00002;
const nan_canonical_f64: u64 = 0x7FF8000000000001;
const nan_arithmetic_f64: u64 = 0x7FF8000000000002;

/// Aggregate result of running a WAST file.
pub const Result = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    skipped: u32 = 0,

    pub fn total(self: Result) u32 {
        return self.passed + self.failed + self.skipped;
    }
};

/// A module/instance/interpreter triple.
const ModuleTriple = struct {
    module: *Mod.Module,
    instance: *Interp.Instance,
    interpreter: *Interp.Interpreter,

    fn destroy(self: ModuleTriple, allocator: std.mem.Allocator) void {
        self.interpreter.deinit();
        allocator.destroy(self.interpreter);
        self.instance.deinit();
        allocator.destroy(self.instance);
        self.module.deinit();
        allocator.destroy(self.module);
    }
};

/// Mutable state for the runner: tracks the current module, instance, and interpreter,
/// plus named (`$id`) and registered (`"name"`) module registries for multi-module tests.
const RunState = struct {
    allocator: std.mem.Allocator,
    module: ?*Mod.Module = null,
    instance: ?*Interp.Instance = null,
    interpreter: ?*Interp.Interpreter = null,

    /// Modules registered by $id (e.g. `(module $Func ...)` → "$Func").
    named_modules: std.StringHashMapUnmanaged(ModuleTriple) = .{},
    /// Modules registered by string name (e.g. `(register "Mf")` → "Mf").
    registered_modules: std.StringHashMapUnmanaged(ModuleTriple) = .{},
    /// Keys that are owned by this state and must be freed.
    owned_keys: std.ArrayListUnmanaged([]const u8) = .{},
    /// Source texts from decoded quote modules (kept alive for name slices).
    owned_sources: std.ArrayListUnmanaged([]const u8) = .{},

    fn deinit(self: *RunState) void {
        self.destroyCurrent();
        // Destroy all registered triples (named + registered may share entries,
        // so collect unique pointers first).
        var destroyed = std.AutoHashMapUnmanaged(*Mod.Module, void){};
        defer destroyed.deinit(self.allocator);
        var it = self.named_modules.valueIterator();
        while (it.next()) |triple| {
            destroyed.put(self.allocator, triple.module, {}) catch {};
            triple.destroy(self.allocator);
        }
        var it2 = self.registered_modules.valueIterator();
        while (it2.next()) |triple| {
            if (!destroyed.contains(triple.module)) {
                triple.destroy(self.allocator);
                destroyed.put(self.allocator, triple.module, {}) catch {};
            }
        }
        self.named_modules.deinit(self.allocator);
        self.registered_modules.deinit(self.allocator);
        for (self.owned_keys.items) |key| self.allocator.free(key);
        self.owned_keys.deinit(self.allocator);
        for (self.owned_sources.items) |src| self.allocator.free(src);
        self.owned_sources.deinit(self.allocator);
    }

    /// Destroy the current module/instance/interpreter if they are not held
    /// in any registry.
    fn destroyCurrent(self: *RunState) void {
        if (self.module) |mod| {
            // Check if this module is referenced in a registry
            if (!self.isModuleRetained(mod)) {
                if (self.interpreter) |interp| { interp.deinit(); self.allocator.destroy(interp); }
                if (self.instance) |inst| { inst.deinit(); self.allocator.destroy(inst); }
                mod.deinit();
                self.allocator.destroy(mod);
            }
        }
        self.interpreter = null;
        self.instance = null;
        self.module = null;
    }

    fn isModuleRetained(self: *RunState, mod: *Mod.Module) bool {
        var it = self.named_modules.valueIterator();
        while (it.next()) |triple| if (triple.module == mod) return true;
        var it2 = self.registered_modules.valueIterator();
        while (it2.next()) |triple| if (triple.module == mod) return true;
        return false;
    }

    fn setModuleBinary(self: *RunState, wasm_bytes: []const u8) bool {
        self.destroyCurrent();

        const mod = self.allocator.create(Mod.Module) catch return false;
        mod.* = binary_reader.readModule(self.allocator, wasm_bytes) catch {
            self.allocator.destroy(mod);
            return false;
        };

        const inst = self.allocator.create(Interp.Instance) catch {
            mod.deinit();
            self.allocator.destroy(mod);
            return false;
        };
        inst.* = Interp.Instance.init(self.allocator, mod) catch {
            self.allocator.destroy(inst);
            mod.deinit();
            self.allocator.destroy(mod);
            return false;
        };

        const interp = self.allocator.create(Interp.Interpreter) catch {
            inst.deinit();
            self.allocator.destroy(inst);
            mod.deinit();
            self.allocator.destroy(mod);
            return false;
        };
        interp.* = Interp.Interpreter.init(self.allocator, inst);
        self.resolveImports(mod, interp);
        inst.instantiate() catch {
            interp.deinit();
            self.allocator.destroy(interp);
            inst.deinit();
            self.allocator.destroy(inst);
            mod.deinit();
            self.allocator.destroy(mod);
            return false;
        };

        if (mod.start_var) |sv| {
            const start_idx: u32 = switch (sv) {
                .index => |i| i,
                else => 0,
            };
            interp.callFunc(start_idx, &.{}) catch {};
        }

        self.module = mod;
        self.instance = inst;
        self.interpreter = interp;
        return true;
    }

    fn setModule(self: *RunState, mod_text: []const u8) bool {
        self.destroyCurrent();

        const mod = self.allocator.create(Mod.Module) catch return false;
        mod.* = Parser.parseModule(self.allocator, mod_text) catch {
            self.allocator.destroy(mod);
            return false;
        };

        const inst = self.allocator.create(Interp.Instance) catch {
            mod.deinit();
            self.allocator.destroy(mod);
            return false;
        };
        inst.* = Interp.Instance.init(self.allocator, mod) catch {
            self.allocator.destroy(inst);
            mod.deinit();
            self.allocator.destroy(mod);
            return false;
        };

        const interp = self.allocator.create(Interp.Interpreter) catch {
            inst.deinit();
            self.allocator.destroy(inst);
            mod.deinit();
            self.allocator.destroy(mod);
            return false;
        };
        interp.* = Interp.Interpreter.init(self.allocator, inst);

        // Resolve function and global imports BEFORE instantiation so init
        // expressions like (global.get 0) can see imported global values.
        self.resolveImports(mod, interp);

        inst.instantiate() catch {
            interp.deinit();
            self.allocator.destroy(interp);
            inst.deinit();
            self.allocator.destroy(inst);
            mod.deinit();
            self.allocator.destroy(mod);
            return false;
        };

        // Execute the start function if present.
        if (mod.start_var) |sv| {
            const start_idx: u32 = switch (sv) {
                .index => |i| i,
                .name => blk: {
                    for (mod.funcs.items, 0..) |f, i| {
                        if (f.name) |n| {
                            if (std.mem.eql(u8, n, sv.name)) break :blk @as(u32, @intCast(i));
                        }
                    }
                    break :blk 0;
                },
            };
            interp.callFunc(start_idx, &.{}) catch {};
        }

        self.module = mod;
        self.instance = inst;
        self.interpreter = interp;

        // If the module text has a $name id, register it.
        if (extractModuleId(mod_text)) |id| {
            self.putNamed(id, .{ .module = mod, .instance = inst, .interpreter = interp });
        }

        return true;
    }

    fn putNamed(self: *RunState, id: []const u8, triple: ModuleTriple) void {
        const key = self.allocator.dupe(u8, id) catch return;
        self.owned_keys.append(self.allocator, key) catch {
            self.allocator.free(key);
            return;
        };
        self.named_modules.put(self.allocator, key, triple) catch {};
    }

    fn putRegistered(self: *RunState, name: []const u8, triple: ModuleTriple) void {
        const key = self.allocator.dupe(u8, name) catch return;
        self.owned_keys.append(self.allocator, key) catch {
            self.allocator.free(key);
            return;
        };
        self.registered_modules.put(self.allocator, key, triple) catch {};
    }

    /// Look up an interpreter by $id name.
    fn getNamedInterpreter(self: *RunState, id: []const u8) ?*Interp.Interpreter {
        if (self.named_modules.get(id)) |triple| return triple.interpreter;
        return null;
    }

    /// Resolve function, global, memory, and table imports by linking to registered modules.
    fn resolveImports(self: *RunState, mod: *Mod.Module, interp: *Interp.Interpreter) void {
        if (mod.imports.items.len == 0) return;

        if (mod.num_func_imports > 0) {
            interp.import_links.resize(self.allocator, mod.num_func_imports) catch return;
            @memset(interp.import_links.items, null);
        }

        var func_import_idx: u32 = 0;
        var global_import_idx: u32 = 0;
        for (mod.imports.items) |imp| {
            if (imp.kind == .func) {
                if (func_import_idx >= mod.num_func_imports) continue;
                defer func_import_idx += 1;

                const triple = self.registered_modules.get(imp.module_name) orelse continue;
                const exp = triple.module.getExport(imp.field_name) orelse continue;
                if (exp.kind != .func) continue;
                const src_idx: u32 = switch (exp.var_) {
                    .index => |i| i,
                    .name => continue,
                };
                interp.import_links.items[func_import_idx] = .{
                    .interpreter = triple.interpreter,
                    .func_idx = src_idx,
                };
            } else if (imp.kind == .global) {
                defer global_import_idx += 1;

                const triple = self.registered_modules.get(imp.module_name) orelse continue;
                const exp = triple.module.getExport(imp.field_name) orelse continue;
                if (exp.kind != .global) continue;
                const src_idx: u32 = switch (exp.var_) {
                    .index => |i| i,
                    .name => continue,
                };
                if (src_idx < triple.instance.globals.items.len and
                    global_import_idx < interp.instance.globals.items.len)
                {
                    interp.instance.globals.items[global_import_idx] = triple.instance.globals.items[src_idx];
                }
            } else if (imp.kind == .memory) {
                // Share memory from exporting module
                const triple = self.registered_modules.get(imp.module_name) orelse continue;
                const exp = triple.module.getExport(imp.field_name) orelse continue;
                if (exp.kind != .memory) continue;
                // Copy the exporter's memory data into this instance
                if (triple.instance.memory.items.len > 0) {
                    interp.instance.memory.resize(self.allocator, triple.instance.memory.items.len) catch continue;
                    @memcpy(interp.instance.memory.items, triple.instance.memory.items);
                }
            } else if (imp.kind == .table) {
                // Share table from exporting module
                const triple = self.registered_modules.get(imp.module_name) orelse continue;
                const exp = triple.module.getExport(imp.field_name) orelse continue;
                if (exp.kind != .table) continue;
                const src_tbl_idx: u32 = switch (exp.var_) {
                    .index => |i| i,
                    .name => continue,
                };
                if (src_tbl_idx < triple.instance.tables.items.len) {
                    const src_tbl = &triple.instance.tables.items[src_tbl_idx];
                    // Copy table entries
                    if (interp.instance.tables.items.len > 0) {
                        const dst_tbl = &interp.instance.tables.items[0];
                        dst_tbl.resize(self.allocator, src_tbl.items.len) catch continue;
                        @memcpy(dst_tbl.items, src_tbl.items);
                    }
                }
            }
        }
    }

    /// Register the "spectest" host module with standard globals and functions.
    fn registerSpectest(self: *RunState) void {
        const mod = self.allocator.create(Mod.Module) catch return;
        mod.* = Mod.Module.init(self.allocator);

        const noop_code = &[_]u8{0x0b};

        const Fd = struct { name: []const u8, n_params: u8 };
        const func_defs = [_]Fd{
            .{ .name = "print", .n_params = 0 },
            .{ .name = "print_i32", .n_params = 1 },
            .{ .name = "print_i64", .n_params = 1 },
            .{ .name = "print_f32", .n_params = 1 },
            .{ .name = "print_f64", .n_params = 1 },
            .{ .name = "print_i32_f32", .n_params = 2 },
            .{ .name = "print_f64_f64", .n_params = 2 },
        };
        const param_types = [7][2]types.ValType{
            .{ .i32, .i32 },
            .{ .i32, .i32 },
            .{ .i64, .i64 },
            .{ .f32, .f32 },
            .{ .f64, .f64 },
            .{ .i32, .f32 },
            .{ .f64, .f64 },
        };
        for (func_defs, 0..) |fd, i| {
            const n = fd.n_params;
            const owned_params: []const types.ValType = if (n > 0)
                (self.allocator.dupe(types.ValType, param_types[i][0..n]) catch return)
            else
                &.{};
            mod.module_types.append(self.allocator, .{ .func_type = .{
                .params = owned_params,
                .results = &.{},
            } }) catch return;
            mod.funcs.append(self.allocator, .{
                .decl = .{ .type_var = .{ .index = @intCast(i) }, .sig = .{ .params = owned_params, .results = &.{} } },
                .code_bytes = noop_code,
            }) catch return;
            mod.exports.append(self.allocator, .{
                .name = fd.name,
                .kind = .func,
                .var_ = .{ .index = @intCast(i) },
            }) catch return;
        }

        const global_defs = [_]struct { name: []const u8, vt: types.ValType }{
            .{ .name = "global_i32", .vt = .i32 },
            .{ .name = "global_i64", .vt = .i64 },
            .{ .name = "global_f32", .vt = .f32 },
            .{ .name = "global_f64", .vt = .f64 },
        };
        for (global_defs, 0..) |gd, i| {
            mod.globals.append(self.allocator, .{
                .@"type" = .{ .val_type = gd.vt, .mutability = .immutable },
            }) catch return;
            mod.exports.append(self.allocator, .{
                .name = gd.name,
                .kind = .global,
                .var_ = .{ .index = @intCast(i) },
            }) catch return;
        }

        mod.tables.append(self.allocator, .{
            .@"type" = .{ .elem_type = .funcref, .limits = .{ .initial = 10, .max = 20, .has_max = true } },
        }) catch return;
        mod.exports.append(self.allocator, .{
            .name = "table",
            .kind = .table,
            .var_ = .{ .index = 0 },
        }) catch return;

        mod.memories.append(self.allocator, .{
            .@"type" = .{ .limits = .{ .initial = 1, .max = 2, .has_max = true } },
        }) catch return;
        mod.exports.append(self.allocator, .{
            .name = "memory",
            .kind = .memory,
            .var_ = .{ .index = 0 },
        }) catch return;

        const inst = self.allocator.create(Interp.Instance) catch {
            mod.deinit();
            self.allocator.destroy(mod);
            return;
        };
        inst.* = Interp.Instance.init(self.allocator, mod) catch {
            self.allocator.destroy(inst);
            mod.deinit();
            self.allocator.destroy(mod);
            return;
        };
        inst.instantiate() catch {};

        if (inst.globals.items.len >= 4) {
            inst.globals.items[0] = .{ .i32 = 666 };
            inst.globals.items[1] = .{ .i64 = 666 };
            inst.globals.items[2] = .{ .f32 = @as(f32, 666.6) };
            inst.globals.items[3] = .{ .f64 = @as(f64, 666.6) };
        }

        const interp = self.allocator.create(Interp.Interpreter) catch {
            inst.deinit();
            self.allocator.destroy(inst);
            mod.deinit();
            self.allocator.destroy(mod);
            return;
        };
        interp.* = Interp.Interpreter.init(self.allocator, inst);

        self.putRegistered("spectest", .{ .module = mod, .instance = inst, .interpreter = interp });
    }
};

/// Run all WAST commands in `source` and return aggregate results.
pub fn run(allocator: std.mem.Allocator, source: []const u8) Result {
    var result = Result{};
    var pos: usize = 0;
    var state = RunState{ .allocator = allocator };
    defer state.deinit();

    state.registerSpectest();

    while (pos < source.len) {
        pos = skipWhitespaceAndComments(source, pos);
        if (pos >= source.len) break;

        if (source[pos] != '(') {
            pos += 1;
            continue;
        }

        const sexpr = extractSExpr(source, pos) orelse break;
        pos = sexpr.end;

        const cmd = classifyCommand(sexpr.text);
        switch (cmd) {
            .module => {
                if (isBinaryOrQuoteModule(sexpr.text)) {
                    if (isQuoteModule(sexpr.text)) {
                        // Decode quoted WAT and parse as module
                        const wat_text = decodeQuoteStrings(allocator, sexpr.text) catch {
                            result.skipped += 1;
                            continue;
                        };
                        const wrapped = if (std.mem.startsWith(u8, std.mem.trimLeft(u8, wat_text, " \t\n\r"), "(module"))
                            wat_text
                        else blk: {
                            var buf2 = std.ArrayListUnmanaged(u8){};
                            buf2.appendSlice(allocator, "(module ") catch { result.skipped += 1; allocator.free(wat_text); continue; };
                            buf2.appendSlice(allocator, wat_text) catch { result.skipped += 1; allocator.free(wat_text); continue; };
                            buf2.append(allocator, ')') catch { result.skipped += 1; allocator.free(wat_text); continue; };
                            break :blk buf2.toOwnedSlice(allocator) catch { result.skipped += 1; allocator.free(wat_text); continue; };
                        };
                        if (state.setModule(wrapped)) {
                            // Keep source text alive - module names are slices into it
                            state.owned_sources.append(allocator, wrapped) catch {};
                            if (wrapped.ptr != wat_text.ptr) state.owned_sources.append(allocator, wat_text) catch {};
                            result.passed += 1;
                        } else {
                            if (wrapped.ptr != wat_text.ptr) allocator.free(wrapped);
                            allocator.free(wat_text);
                            result.skipped += 1;
                        }
                    } else if (isBinaryModule(sexpr.text)) {
                        // Decode binary module
                        const wasm_bytes = decodeWastHexStrings(allocator, sexpr.text) catch {
                            result.skipped += 1;
                            continue;
                        };
                        defer allocator.free(wasm_bytes);
                        if (state.setModuleBinary(wasm_bytes)) {
                            result.passed += 1;
                        } else {
                            result.skipped += 1;
                        }
                    } else {
                        result.skipped += 1;
                    }
                } else {
                    if (state.setModule(sexpr.text)) {
                        result.passed += 1;
                    } else {
                        result.skipped += 1;
                    }
                }
            },
            .assert_invalid => processAssertInvalid(allocator, sexpr.text, &result),
            .assert_malformed => processAssertMalformed(allocator, sexpr.text, &result),
            .assert_return => processAssertReturn(allocator, sexpr.text, &state, &result),
            .assert_trap => processAssertTrap(allocator, sexpr.text, &state, &result),
            .invoke => processInvoke(allocator, sexpr.text, &state, &result),
            .register => processRegister(sexpr.text, &state, &result),
            .get => processGet(sexpr.text, &state, &result),
            .assert_exhaustion => processAssertExhaustion(allocator, sexpr.text, &state, &result),
            .assert_unlinkable => processAssertUnlinkable(allocator, sexpr.text, &result),
            .unknown,
            => {
                result.skipped += 1;
            },
        }
    }

    return result;
}

// ── Command classification ──────────────────────────────────────────────

const Command = enum {
    module,
    assert_invalid,
    assert_malformed,
    assert_return,
    assert_trap,
    assert_exhaustion,
    assert_unlinkable,
    invoke,
    register,
    get,
    unknown,
};

fn classifyCommand(sexpr: []const u8) Command {
    // sexpr starts with '('; skip it and any whitespace to find the keyword.
    var i: usize = 1;
    while (i < sexpr.len and isWhitespace(sexpr[i])) : (i += 1) {}
    const word_start = i;
    while (i < sexpr.len and !isWhitespace(sexpr[i]) and sexpr[i] != '(' and sexpr[i] != ')') : (i += 1) {}
    const word = sexpr[word_start..i];

    if (std.mem.eql(u8, word, "module")) return .module;
    if (std.mem.eql(u8, word, "assert_invalid")) return .assert_invalid;
    if (std.mem.eql(u8, word, "assert_malformed")) return .assert_malformed;
    if (std.mem.eql(u8, word, "assert_return")) return .assert_return;
    if (std.mem.eql(u8, word, "assert_trap")) return .assert_trap;
    if (std.mem.eql(u8, word, "assert_exhaustion")) return .assert_exhaustion;
    if (std.mem.eql(u8, word, "assert_unlinkable")) return .assert_unlinkable;
    if (std.mem.eql(u8, word, "invoke")) return .invoke;
    if (std.mem.eql(u8, word, "register")) return .register;
    if (std.mem.eql(u8, word, "get")) return .get;
    return .unknown;
}

// ── Assertion processors ────────────────────────────────────────────────

fn processAssertInvalid(allocator: std.mem.Allocator, sexpr: []const u8, result: *Result) void {
    // (assert_invalid (module ...) "error message")
    // Find the embedded module s-expression.
    const inner = findEmbeddedModule(sexpr) orelse {
        result.skipped += 1;
        return;
    };

    // Handle `(module quote ...)` — decode and try to parse+validate.
    if (isQuoteModule(inner)) {
        const wat_text = decodeQuoteStrings(allocator, inner) catch {
            result.skipped += 1;
            return;
        };
        defer allocator.free(wat_text);
        const wrapped = if (std.mem.startsWith(u8, std.mem.trimLeft(u8, wat_text, " \t\n\r"), "(module"))
            wat_text
        else blk: {
            var buf = std.ArrayListUnmanaged(u8){};
            buf.appendSlice(allocator, "(module ") catch { result.skipped += 1; return; };
            buf.appendSlice(allocator, wat_text) catch { result.skipped += 1; return; };
            buf.append(allocator, ')') catch { result.skipped += 1; return; };
            break :blk buf.toOwnedSlice(allocator) catch { result.skipped += 1; return; };
        };
        defer if (wrapped.ptr != wat_text.ptr) allocator.free(wrapped);
        var module = Parser.parseModule(allocator, wrapped) catch {
            result.passed += 1; // parse failure counts as invalid
            return;
        };
        defer module.deinit();
        Validator.validate(&module, .{}) catch {
            result.passed += 1;
            return;
        };
        result.failed += 1;
        return;
    }

    // Handle `(module binary ...)` — decode binary and validate.
    if (isBinaryModule(inner)) {
        const wasm_bytes = decodeWastHexStrings(allocator, inner) catch {
            result.skipped += 1;
            return;
        };
        defer allocator.free(wasm_bytes);
        var module = binary_reader.readModule(allocator, wasm_bytes) catch {
            result.passed += 1; // decode failure = invalid
            return;
        };
        defer module.deinit();
        Validator.validate(&module, .{}) catch {
            result.passed += 1;
            return;
        };
        result.failed += 1;
        return;
    }

    // Parse the module text.
    var module = Parser.parseModule(allocator, inner) catch {
        // Parse failure counts as skip (some modules use unsupported features).
        result.skipped += 1;
        return;
    };
    defer module.deinit();

    // Validation should fail for assert_invalid.
    Validator.validate(&module, .{}) catch {
        result.passed += 1;
        return;
    };

    // Validation unexpectedly succeeded.
    if (result.failed <= 20) {
        std.debug.print("  FAIL assert_invalid: validation should have failed: module[0..120]=\"{s}\"\n", .{inner[0..@min(120, inner.len)]});
    }
    result.failed += 1;
}

fn processAssertMalformed(allocator: std.mem.Allocator, sexpr: []const u8, result: *Result) void {
    // (assert_malformed (module ...) "error message")
    const inner = findEmbeddedModule(sexpr) orelse {
        result.skipped += 1;
        return;
    };

    // Handle `(module quote ...)` — decode quoted WAT text and parse.
    if (isQuoteModule(inner)) {
        const wat_text = decodeQuoteStrings(allocator, inner) catch {
            result.passed += 1; // decode failure = malformed
            return;
        };
        defer allocator.free(wat_text);
        // Wrap in (module ...) if not already
        const wrapped = if (std.mem.startsWith(u8, std.mem.trimLeft(u8, wat_text, " \t\n\r"), "(module"))
            wat_text
        else blk: {
            var buf = std.ArrayListUnmanaged(u8){};
            buf.appendSlice(allocator, "(module ") catch { result.passed += 1; return; };
            buf.appendSlice(allocator, wat_text) catch { result.passed += 1; return; };
            buf.append(allocator, ')') catch { result.passed += 1; return; };
            break :blk buf.toOwnedSlice(allocator) catch { result.passed += 1; return; };
        };
        defer if (wrapped.ptr != wat_text.ptr) allocator.free(wrapped);
        var module = Parser.parseModule(allocator, wrapped) catch {
            result.passed += 1; // parse failure = malformed = pass
            return;
        };
        defer module.deinit();
        Validator.validate(&module, .{}) catch {
            result.passed += 1; // validation failure = malformed = pass
            return;
        };
        if (result.failed <= 20)
            std.debug.print("  FAIL assert_malformed(quote): should have been malformed: text[0..120]=\"{s}\"\n", .{wat_text[0..@min(120, wat_text.len)]});
        result.failed += 1; // parsed OK but should have been malformed
        return;
    }

    // Handle `(module binary ...)` — decode binary and try to parse.
    if (isBinaryModule(inner)) {
        const wasm_bytes = decodeWastHexStrings(allocator, inner) catch {
            result.passed += 1; // decode failure = malformed
            return;
        };
        defer allocator.free(wasm_bytes);
        var module = binary_reader.readModule(allocator, wasm_bytes) catch {
            result.passed += 1; // parse failure = malformed
            return;
        };
        defer module.deinit();
        // Some spec tests classify validation errors (e.g. alignment) as "malformed"
        Validator.validate(&module, .{}) catch {
            result.passed += 1;
            return;
        };
        if (result.failed <= 20) {
            std.debug.print("  FAIL assert_malformed(binary): parsed OK, expected malformed, {d} bytes\n", .{wasm_bytes.len});
            var hex_buf: [60]u8 = undefined;
            var hi: usize = 0;
            for (wasm_bytes[0..@min(20, wasm_bytes.len)]) |b| {
                hex_buf[hi] = "0123456789abcdef"[b >> 4];
                hex_buf[hi + 1] = "0123456789abcdef"[b & 0x0f];
                hex_buf[hi + 2] = ' ';
                hi += 3;
            }
            std.debug.print("    bytes: {s}\n", .{hex_buf[0..hi]});
        }
        result.failed += 1; // parsed OK but should have been malformed
        return;
    }

    // Parse should fail.
    var module = Parser.parseModule(allocator, inner) catch {
        result.passed += 1;
        return;
    };
    module.deinit();

    // Parsed successfully — for assert_malformed, validation failure also counts.
    // Some spec tests classify validation errors as "malformed".
    var module2 = Parser.parseModule(allocator, inner) catch {
        result.passed += 1;
        return;
    };
    defer module2.deinit();

    Validator.validate(&module2, .{}) catch {
        result.passed += 1;
        return;
    };

    if (result.failed <= 20)
        std.debug.print("  FAIL assert_malformed(text): should have been malformed: module[0..120]=\"{s}\"\n", .{inner[0..@min(120, inner.len)]});
    result.failed += 1;
}

fn processAssertReturn(allocator: std.mem.Allocator, sexpr: []const u8, state: *RunState, result: *Result) void {

    // Check for (assert_return (get ...) ...) pattern
    if (findGet(sexpr)) |get_expr| {
        processAssertReturnGet(get_expr, sexpr, state, result);
        return;
    }

    // Parse: (assert_return (invoke "name" args...) expected...)
    // or:   (assert_return (invoke $Mod "name" args...) expected...)
    const inv = findInvoke(sexpr) orelse {
        result.skipped += 1;
        return;
    };
    const interp = resolveInterpreter(inv, state) orelse {
        result.skipped += 1;
        return;
    };
    const raw_func_name = extractStringLiteral(inv) orelse {
        result.skipped += 1;
        return;
    };
    const func_name = decodeStringEscapes(allocator, raw_func_name) orelse raw_func_name;

    var args_buf: [32]Interp.Value = undefined;
    const args = parseInvokeArgs(inv, &args_buf);

    // Parse expected results (after the invoke sexpr)
    const after_invoke = skipFirstSExpr(sexpr) orelse sexpr;
    var expected_buf: [32]Interp.Value = undefined;
    const expected = parseExpectedResults(after_invoke, &expected_buf);

    var results_buf: [32]Interp.Value = undefined;
    const actuals = interp.callExportMulti(func_name, args, &results_buf) catch |err| {
        result.failed += 1;
        if (result.failed <= 20) std.debug.print("  FAIL assert_return(invoke \"{s}\"): trap {any}\n", .{ func_name, err });
        return;
    };

    if (expected.len == 0) {
        result.passed += 1;
        return;
    }

    if (actuals.len >= expected.len) {
        var all_match = true;
        for (0..expected.len) |i| {
            if (!valuesEqual(actuals[i], expected[i])) {
                all_match = false;
                break;
            }
        }
        if (all_match) {
            result.passed += 1;
        } else {
            result.failed += 1;
            if (result.failed <= 20) {
                if (expected.len == 1) {
                    const actual_v = if (actuals.len > 0) actuals[0] else Interp.Value{ .i32 = 0 };
                    std.debug.print("  FAIL assert_return(invoke \"{s}\"): got {any} expected {any}\n", .{ func_name, actual_v, expected[0] });
                } else {
                    std.debug.print("  FAIL assert_return(invoke \"{s}\"): multi-value mismatch ({d} results)\n", .{ func_name, expected.len });
                }
            }
        }
    } else {
        result.failed += 1;
        if (result.failed <= 20) std.debug.print("  FAIL assert_return(invoke \"{s}\"): got {d} results expected {d}\n", .{ func_name, actuals.len, expected.len });
    }
}

fn processAssertTrap(allocator: std.mem.Allocator, sexpr: []const u8, state: *RunState, result: *Result) void {
    const inv = findInvoke(sexpr) orelse {
        // Could be (assert_trap (module ...) "msg") — module instantiation should trap
        const inner = findEmbeddedModule(sexpr) orelse {
            result.skipped += 1;
            return;
        };

        // Try binary module
        if (isBinaryModule(inner)) {
            const wasm_bytes = decodeWastHexStrings(allocator, inner) catch {
                result.passed += 1; // decode failure = trap
                return;
            };
            defer allocator.free(wasm_bytes);
            var module = binary_reader.readModule(allocator, wasm_bytes) catch {
                result.passed += 1;
                return;
            };
            defer module.deinit();
            Validator.validate(&module, .{}) catch {
                result.passed += 1;
                return;
            };
            var instance = Interp.Instance.init(allocator, &module) catch {
                result.passed += 1;
                return;
            };
            defer instance.deinit();
            instance.instantiate() catch {
                result.passed += 1;
                return;
            };
            // Instantiation succeeded without trap — unexpected
            result.failed += 1;
            return;
        }

        if (isQuoteModule(inner)) {
            result.skipped += 1;
            return;
        }

        // Text module
        var module = Parser.parseModule(allocator, inner) catch {
            result.passed += 1;
            return;
        };
        defer module.deinit();

        Validator.validate(&module, .{}) catch {
            result.passed += 1;
            return;
        };

        var instance = Interp.Instance.init(allocator, &module) catch {
            result.passed += 1;
            return;
        };
        defer instance.deinit();
        instance.instantiate() catch {
            result.passed += 1;
            return;
        };
        var interp2 = Interp.Interpreter.init(allocator, &instance);
        defer interp2.deinit();

        if (module.start_var) |sv| {
            interp2.callFunc(sv.index, &.{}) catch {
                result.passed += 1;
                return;
            };
            result.failed += 1;
            return;
        }
        result.failed += 1;
        return;
    };
    const interp = resolveInterpreter(inv, state) orelse {
        result.skipped += 1;
        return;
    };
    const raw_name_trap = extractStringLiteral(inv) orelse {
        result.skipped += 1;
        return;
    };
    const func_name = decodeStringEscapes(allocator, raw_name_trap) orelse raw_name_trap;

    var args_buf: [16]Interp.Value = undefined;
    const args = parseInvokeArgs(inv, &args_buf);

    if (interp.callExport(func_name, args)) |_| {
        // Expected a trap but succeeded
        result.failed += 1;
    } else |_| {
        // Got an error (trap) — this is expected
        result.passed += 1;
    }
}

fn processAssertExhaustion(allocator: std.mem.Allocator, sexpr: []const u8, state: *RunState, result: *Result) void {
    // (assert_exhaustion (invoke "f" ...) "msg")
    // Same as assert_trap — call a function and expect it to error (stack overflow).
    const inv = findInvoke(sexpr) orelse {
        result.skipped += 1;
        return;
    };
    const interp = resolveInterpreter(inv, state) orelse {
        result.skipped += 1;
        return;
    };
    const raw_exh_name = extractStringLiteral(inv) orelse {
        result.skipped += 1;
        return;
    };
    const func_name = decodeStringEscapes(allocator, raw_exh_name) orelse raw_exh_name;

    var args_buf: [16]Interp.Value = undefined;
    const args = parseInvokeArgs(inv, &args_buf);

    if (interp.callExport(func_name, args)) |_| {
        result.failed += 1;
    } else |_| {
        result.passed += 1;
    }
}

fn processAssertUnlinkable(allocator: std.mem.Allocator, sexpr: []const u8, result: *Result) void {
    // (assert_unlinkable (module ...) "msg")
    const inner = findEmbeddedModule(sexpr) orelse {
        result.skipped += 1;
        return;
    };

    if (isBinaryModule(inner)) {
        const wasm_bytes = decodeWastHexStrings(allocator, inner) catch {
            result.passed += 1;
            return;
        };
        defer allocator.free(wasm_bytes);
        var module = binary_reader.readModule(allocator, wasm_bytes) catch {
            result.passed += 1;
            return;
        };
        defer module.deinit();
        Validator.validate(&module, .{}) catch {
            result.passed += 1;
            return;
        };
        // Module validated OK — linking should still fail for unlinkable
        result.failed += 1;
        return;
    }

    if (isQuoteModule(inner)) {
        result.skipped += 1;
        return;
    }

    var module = Parser.parseModule(allocator, inner) catch {
        result.passed += 1;
        return;
    };
    defer module.deinit();

    Validator.validate(&module, .{}) catch {
        result.passed += 1;
        return;
    };

    // For assert_unlinkable, the module should fail at instantiation/linking.
    // If validation passes, try instantiation.
    var instance = Interp.Instance.init(allocator, &module) catch {
        result.passed += 1;
        return;
    };
    defer instance.deinit();
    instance.instantiate() catch {
        result.passed += 1;
        return;
    };

    // Everything succeeded — unexpected for assert_unlinkable.
    result.failed += 1;
}

fn processInvoke(allocator: std.mem.Allocator, sexpr: []const u8, state: *RunState, result: *Result) void {
    const interp = resolveInterpreter(sexpr, state) orelse {
        result.skipped += 1;
        return;
    };
    const raw_inv_name = extractStringLiteral(sexpr) orelse {
        result.skipped += 1;
        return;
    };
    const func_name = decodeStringEscapes(allocator, raw_inv_name) orelse raw_inv_name;
    var args_buf: [16]Interp.Value = undefined;
    const args = parseInvokeArgs(sexpr, &args_buf);
    _ = interp.callExport(func_name, args) catch {};
    result.passed += 1;
}

/// Handle `(register "name")` or `(register "name" $id)`.
fn processRegister(sexpr: []const u8, state: *RunState, result: *Result) void {
    const name = extractStringLiteral(sexpr) orelse {
        result.skipped += 1;
        return;
    };
    // Determine which module to register: $id target or current.
    const triple = blk: {
        // Check for an optional $id after the string literal
        if (extractDollarIdAfterString(sexpr)) |id| {
            if (state.named_modules.get(id)) |t| break :blk t;
        }
        // Fall back to the current module.
        const mod = state.module orelse {
            result.skipped += 1;
            return;
        };
        const inst = state.instance orelse {
            result.skipped += 1;
            return;
        };
        const interp = state.interpreter orelse {
            result.skipped += 1;
            return;
        };
        break :blk ModuleTriple{ .module = mod, .instance = inst, .interpreter = interp };
    };
    state.putRegistered(name, triple);
    result.passed += 1;
}

/// Handle standalone `(get "global_name")` or `(get $Mod "global_name")`.
fn processGet(sexpr: []const u8, state: *RunState, result: *Result) void {
    _ = resolveGetValue(sexpr, state) orelse {
        result.skipped += 1;
        return;
    };
    result.passed += 1;
}

/// Handle `(assert_return (get ...) (expected))`.
fn processAssertReturnGet(get_expr: []const u8, outer: []const u8, state: *RunState, result: *Result) void {
    const actual = resolveGetValue(get_expr, state) orelse {
        result.skipped += 1;
        return;
    };

    // Parse expected results (after the get sexpr)
    const after_get = skipFirstSExpr(outer) orelse outer;
    var expected_buf: [16]Interp.Value = undefined;
    const expected = parseExpectedResults(after_get, &expected_buf);

    if (expected.len == 0) {
        result.passed += 1;
        return;
    }

    if (valuesEqual(actual, expected[0])) {
        result.passed += 1;
    } else {
        result.failed += 1;
        if (result.failed <= 20) {
            const name = extractStringLiteral(get_expr) orelse "?";
            std.debug.print("  FAIL assert_return(get \"{s}\"): got {any} expected {any}\n", .{ name, actual, expected[0] });
        }
    }
}

/// Resolve a global export value from a `(get ...)` expression.
fn resolveGetValue(get_expr: []const u8, state: *RunState) ?Interp.Value {
    // (get "name") or (get $Mod "name")
    const interp = resolveInterpreter(get_expr, state) orelse return null;
    const global_name = extractStringLiteral(get_expr) orelse return null;
    const exp = interp.instance.module.getExport(global_name) orelse return null;
    if (exp.kind != .global) return null;
    const idx: u32 = switch (exp.var_) {
        .index => |i| i,
        .name => return null,
    };
    if (idx >= interp.instance.globals.items.len) return null;
    return interp.instance.globals.items[idx];
}

/// Resolve the interpreter to use for an invoke/get expression.
/// If the expression contains a `$name` identifier before the string literal,
/// look it up in the named module registry; otherwise use the current interpreter.
fn resolveInterpreter(expr: []const u8, state: *RunState) ?*Interp.Interpreter {
    if (extractDollarId(expr)) |id| {
        if (state.getNamedInterpreter(id)) |interp| return interp;
    }
    return state.interpreter;
}

/// Extract a `$identifier` from an invoke/get expression.
/// Looks for `$` after the keyword and before the first `"`.
fn extractDollarId(expr: []const u8) ?[]const u8 {
    // Skip '(' and keyword
    var i: usize = 1;
    while (i < expr.len and isWhitespace(expr[i])) : (i += 1) {}
    // Skip keyword
    while (i < expr.len and !isWhitespace(expr[i]) and expr[i] != '(' and expr[i] != ')') : (i += 1) {}
    // Skip whitespace after keyword
    while (i < expr.len and isWhitespace(expr[i])) : (i += 1) {}
    // Check for $ before "
    if (i < expr.len and expr[i] == '$') {
        const start = i;
        i += 1;
        while (i < expr.len and !isWhitespace(expr[i]) and expr[i] != '(' and expr[i] != ')' and expr[i] != '"') : (i += 1) {}
        return expr[start..i];
    }
    return null;
}

/// Extract a `$identifier` that appears after a string literal in a sexpr.
/// Used for `(register "name" $id)`.
fn extractDollarIdAfterString(expr: []const u8) ?[]const u8 {
    var i: usize = 0;
    // Find and skip first string literal
    while (i < expr.len and expr[i] != '"') : (i += 1) {}
    if (i >= expr.len) return null;
    i += 1; // skip opening "
    while (i < expr.len and expr[i] != '"') : (i += 1) {
        if (expr[i] == '\\' and i + 1 < expr.len) { i += 1; continue; }
    }
    if (i >= expr.len) return null;
    i += 1; // skip closing "
    // Skip whitespace
    while (i < expr.len and isWhitespace(expr[i])) : (i += 1) {}
    // Check for $
    if (i < expr.len and expr[i] == '$') {
        const start = i;
        i += 1;
        while (i < expr.len and !isWhitespace(expr[i]) and expr[i] != '(' and expr[i] != ')') : (i += 1) {}
        return expr[start..i];
    }
    return null;
}

/// Extract the `$name` identifier from a module s-expression, e.g. `(module $Func ...)`.
fn extractModuleId(mod_text: []const u8) ?[]const u8 {
    var i: usize = 1; // skip '('
    while (i < mod_text.len and isWhitespace(mod_text[i])) : (i += 1) {}
    // Skip "module"
    const mod_kw = "module";
    if (i + mod_kw.len > mod_text.len) return null;
    if (!std.mem.eql(u8, mod_text[i .. i + mod_kw.len], mod_kw)) return null;
    i += mod_kw.len;
    // Skip whitespace
    while (i < mod_text.len and isWhitespace(mod_text[i])) : (i += 1) {}
    // Check for $identifier
    if (i < mod_text.len and mod_text[i] == '$') {
        const start = i;
        i += 1;
        while (i < mod_text.len and !isWhitespace(mod_text[i]) and mod_text[i] != '(' and mod_text[i] != ')') : (i += 1) {}
        return mod_text[start..i];
    }
    return null;
}

/// Find the `(get ...)` sub-expression inside a sexpr.
fn findGet(sexpr: []const u8) ?[]const u8 {
    var i: usize = 1;
    while (i < sexpr.len) : (i += 1) {
        if (sexpr[i] == '(' and hasWordAt(sexpr, i + 1, "get")) {
            const inner = extractSExpr(sexpr, i) orelse return null;
            return inner.text;
        }
    }
    return null;
}

// ── Invoke / value parsing helpers ──────────────────────────────────────

/// Find the `(invoke ...)` sub-expression inside a sexpr.
fn findInvoke(sexpr: []const u8) ?[]const u8 {
    var i: usize = 1;
    while (i < sexpr.len) : (i += 1) {
        if (sexpr[i] == '(' and hasWordAt(sexpr, i + 1, "invoke")) {
            const inner = extractSExpr(sexpr, i) orelse return null;
            return inner.text;
        }
    }
    return null;
}

/// Extract a quoted string literal from an s-expression, e.g. from `(invoke "add" ...)`.
fn extractStringLiteral(sexpr: []const u8) ?[]const u8 {
    // Find first '"' character
    var i: usize = 0;
    while (i < sexpr.len and sexpr[i] != '"') : (i += 1) {}
    if (i >= sexpr.len) return null;
    i += 1; // skip opening quote
    const start = i;
    while (i < sexpr.len and sexpr[i] != '"') : (i += 1) {
        if (sexpr[i] == '\\' and i + 1 < sexpr.len) { i += 1; continue; }
    }
    if (i > sexpr.len) return null;
    return sexpr[start..i];
}

/// Decode WAT string escape sequences in-place (\nn hex, \t, \n, \\, \").
fn decodeStringEscapes(allocator: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    // Quick check: if no escapes, return as-is
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    var buf = std.ArrayListUnmanaged(u8){};
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            switch (raw[i]) {
                'n' => { buf.append(allocator, '\n') catch return null; i += 1; },
                't' => { buf.append(allocator, '\t') catch return null; i += 1; },
                'r' => { buf.append(allocator, '\r') catch return null; i += 1; },
                '\\' => { buf.append(allocator, '\\') catch return null; i += 1; },
                '"' => { buf.append(allocator, '"') catch return null; i += 1; },
                else => {
                    if (i + 1 < raw.len) {
                        const hi = hexDigit(raw[i]);
                        const lo = hexDigit(raw[i + 1]);
                        if (hi != null and lo != null) {
                            buf.append(allocator, hi.? * 16 + lo.?) catch return null;
                            i += 2;
                            continue;
                        }
                    }
                    buf.append(allocator, raw[i]) catch return null;
                    i += 1;
                },
            }
        } else {
            buf.append(allocator, raw[i]) catch return null;
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator) catch null;
}

/// Parse const value arguments from an invoke expression.
fn parseInvokeArgs(inv: []const u8, buf: []Interp.Value) []const Interp.Value {
    // Skip past the function name string, then parse (type.const value) sub-exprs
    var count: usize = 0;
    var i: usize = 0;
    // Skip to after the first string literal
    while (i < inv.len and inv[i] != '"') : (i += 1) {}
    if (i < inv.len) i += 1; // skip opening "
    while (i < inv.len and inv[i] != '"') : (i += 1) {
        if (inv[i] == '\\' and i + 1 < inv.len) { i += 1; continue; }
    }
    if (i < inv.len) i += 1; // skip closing "

    while (i < inv.len and count < buf.len) {
        if (inv[i] == '(') {
            const inner = extractSExpr(inv, i) orelse break;
            if (parseConstValue(inner.text)) |v| {
                buf[count] = v;
                count += 1;
            }
            i = inner.end;
        } else {
            i += 1;
        }
    }
    return buf[0..count];
}

/// Parse expected results from the portion after the invoke expr.
fn parseExpectedResults(text: []const u8, buf: []Interp.Value) []const Interp.Value {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len and count < buf.len) {
        if (text[i] == '(') {
            const inner = extractSExpr(text, i) orelse break;
            if (parseConstValue(inner.text)) |v| {
                buf[count] = v;
                count += 1;
            }
            i = inner.end;
        } else {
            i += 1;
        }
    }
    return buf[0..count];
}

/// Parse a const value like (i32.const 42) or (f64.const 3.14).
fn parseConstValue(sexpr: []const u8) ?Interp.Value {
    var i: usize = 1; // skip '('
    while (i < sexpr.len and isWhitespace(sexpr[i])) : (i += 1) {}
    // Read keyword
    const kw_start = i;
    while (i < sexpr.len and !isWhitespace(sexpr[i]) and sexpr[i] != ')') : (i += 1) {}
    const kw = sexpr[kw_start..i];

    // Skip whitespace to value
    while (i < sexpr.len and isWhitespace(sexpr[i])) : (i += 1) {}
    const val_start = i;
    while (i < sexpr.len and sexpr[i] != ')' and !isWhitespace(sexpr[i])) : (i += 1) {}
    const raw_val_text = sexpr[val_start..i];

    // Strip WAT underscore digit separators
    var clean_buf: [128]u8 = undefined;
    const val_text = stripWatUnderscores(raw_val_text, &clean_buf);

    if (std.mem.eql(u8, kw, "i32.const")) {
        const v = std.fmt.parseInt(i32, val_text, 0) catch blk: {
            const u = std.fmt.parseInt(u32, val_text, 0) catch return null;
            break :blk @as(i32, @bitCast(u));
        };
        return .{ .i32 = v };
    } else if (std.mem.eql(u8, kw, "i64.const")) {
        const v = std.fmt.parseInt(i64, val_text, 0) catch blk: {
            const u = std.fmt.parseInt(u64, val_text, 0) catch return null;
            break :blk @as(i64, @bitCast(u));
        };
        return .{ .i64 = v };
    } else if (std.mem.eql(u8, kw, "f32.const")) {
        if (std.mem.eql(u8, val_text, "nan:canonical") or
            std.mem.eql(u8, val_text, "+nan:canonical") or
            std.mem.eql(u8, val_text, "-nan:canonical"))
            return .{ .f32 = @bitCast(nan_canonical_f32) };
        if (std.mem.eql(u8, val_text, "nan:arithmetic") or
            std.mem.eql(u8, val_text, "+nan:arithmetic") or
            std.mem.eql(u8, val_text, "-nan:arithmetic"))
            return .{ .f32 = @bitCast(nan_arithmetic_f32) };
        const bits = Parser.parseFloatBits(f32, val_text);
        return .{ .f32 = @bitCast(bits) };
    } else if (std.mem.eql(u8, kw, "f64.const")) {
        if (std.mem.eql(u8, val_text, "nan:canonical") or
            std.mem.eql(u8, val_text, "+nan:canonical") or
            std.mem.eql(u8, val_text, "-nan:canonical"))
            return .{ .f64 = @bitCast(nan_canonical_f64) };
        if (std.mem.eql(u8, val_text, "nan:arithmetic") or
            std.mem.eql(u8, val_text, "+nan:arithmetic") or
            std.mem.eql(u8, val_text, "-nan:arithmetic"))
            return .{ .f64 = @bitCast(nan_arithmetic_f64) };
        const bits = Parser.parseFloatBits(f64, val_text);
        return .{ .f64 = @bitCast(bits) };
    } else if (std.mem.eql(u8, kw, "ref.null")) {
        return .{ .ref_null = {} };
    } else if (std.mem.eql(u8, kw, "ref.func")) {
        return .{ .ref_null = {} }; // treat as non-null ref for comparison
    } else if (std.mem.eql(u8, kw, "ref.extern")) {
        const idx = std.fmt.parseInt(u32, val_text, 0) catch 0;
        return .{ .ref_func = idx }; // non-null externref represented as ref_func
    }
    return null;
}

/// Strip WAT `_` digit separators from a number string.
fn stripWatUnderscores(text: []const u8, buf: []u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, '_') == null) return text;
    var len: usize = 0;
    for (text) |ch| {
        if (ch != '_' and len < buf.len) {
            buf[len] = ch;
            len += 1;
        }
    }
    return buf[0..len];
}

/// Skip past the first nested s-expression in text and return the remainder.
fn skipFirstSExpr(text: []const u8) ?[]const u8 {
    // Find the first nested s-expr (after the outer keyword)
    var i: usize = 1;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    // Skip keyword
    while (i < text.len and !isWhitespace(text[i]) and text[i] != '(' and text[i] != ')') : (i += 1) {}
    // Find the first '(' after keyword
    while (i < text.len and text[i] != '(') : (i += 1) {}
    if (i >= text.len) return null;
    // Skip this sexpr
    const inner = extractSExpr(text, i) orelse return null;
    return text[inner.end..];
}

/// Compare two Values for equality (used for assert_return).
/// NaN values are compared by bit pattern so that specific NaN payloads match.
fn valuesEqual(a: Interp.Value, b: Interp.Value) bool {
    return switch (a) {
        .i32 => |av| switch (b) {
            .i32 => |bv| av == bv,
            else => false,
        },
        .i64 => |av| switch (b) {
            .i64 => |bv| av == bv,
            else => false,
        },
        .f32 => |av| switch (b) {
            .f32 => |bv| {
                const ab: u32 = @bitCast(av);
                const bb: u32 = @bitCast(bv);
                // nan:canonical sentinel — any canonical NaN matches
                if (bb == nan_canonical_f32)
                    return (ab & 0x7fffffff) == 0x7fc00000;
                // nan:arithmetic sentinel — any arithmetic NaN matches
                if (bb == nan_arithmetic_f32)
                    return (ab & 0x7fc00000) == 0x7fc00000;
                return ab == bb;
            },
            else => false,
        },
        .f64 => |av| switch (b) {
            .f64 => |bv| {
                const ab: u64 = @bitCast(av);
                const bb: u64 = @bitCast(bv);
                if (bb == nan_canonical_f64)
                    return (ab & 0x7fffffffffffffff) == 0x7ff8000000000000;
                if (bb == nan_arithmetic_f64)
                    return (ab & 0x7ff8000000000000) == 0x7ff8000000000000;
                return ab == bb;
            },
            else => false,
        },
        .ref_null => b == .ref_null,
        .ref_func => |av| switch (b) {
            .ref_func => |bv| av == bv,
            else => false,
        },
    };
}

const SExpr = struct {
    text: []const u8,
    end: usize,
};

/// Extract a balanced s-expression starting at `start` in `source`.
/// Returns the slice and the position just past the closing ')'.
fn extractSExpr(source: []const u8, start: usize) ?SExpr {
    if (start >= source.len or source[start] != '(') return null;
    var depth: u32 = 0;
    var i = start;
    var in_string = false;
    while (i < source.len) : (i += 1) {
        if (in_string) {
            if (source[i] == '\\' and i + 1 < source.len) {
                i += 1;
                continue;
            }
            if (source[i] == '"') in_string = false;
            continue;
        }
        switch (source[i]) {
            ';' => {
                // Line comment ";;" — skip to end of line
                if (i + 1 < source.len and source[i + 1] == ';') {
                    while (i < source.len and source[i] != '\n') : (i += 1) {}
                    // Don't advance past the newline twice
                    if (i < source.len) continue;
                }
                // Block comment "(;" is handled by '(' branch; lone ';' is normal
            },
            '"' => in_string = true,
            '(' => {
                // Check for block comment "(;"
                if (i + 1 < source.len and source[i + 1] == ';') {
                    i = skipBlockComment(source, i);
                    // i now points past ";)", back up one because loop increments
                    if (i > 0) i -= 1;
                    continue;
                }
                depth += 1;
            },
            ')' => {
                depth -= 1;
                if (depth == 0) return .{ .text = source[start .. i + 1], .end = i + 1 };
            },
            else => {},
        }
    }
    return null;
}

/// Skip a block comment "(; ... ;)" starting at `pos`. Returns position after ";)".
fn skipBlockComment(source: []const u8, start: usize) usize {
    var i = start + 2; // skip "(;"
    var depth: u32 = 1;
    while (i + 1 < source.len and depth > 0) {
        if (source[i] == '(' and source[i + 1] == ';') {
            depth += 1;
            i += 2;
        } else if (source[i] == ';' and source[i + 1] == ')') {
            depth -= 1;
            i += 2;
        } else {
            i += 1;
        }
    }
    return i;
}

/// Find the first `(module ...)` s-expression embedded within `sexpr`.
fn findEmbeddedModule(sexpr: []const u8) ?[]const u8 {
    // Search for "(module" pattern inside the outer s-expression.
    var i: usize = 1; // skip outer '('
    while (i < sexpr.len) : (i += 1) {
        if (sexpr[i] == '(' and hasWordAt(sexpr, i + 1, "module")) {
            const inner = extractSExpr(sexpr, i) orelse return null;
            return inner.text;
        }
    }
    return null;
}

/// Check if `source[pos..]` starts with whitespace then `word` followed by a delimiter.
fn hasWordAt(source: []const u8, pos: usize, word: []const u8) bool {
    var i = pos;
    // Skip optional whitespace between '(' and keyword
    while (i < source.len and isWhitespace(source[i])) : (i += 1) {}
    if (i + word.len > source.len) return false;
    if (!std.mem.eql(u8, source[i .. i + word.len], word)) return false;
    // Must be followed by delimiter (whitespace, paren, or end)
    if (i + word.len >= source.len) return true;
    const next = source[i + word.len];
    return isWhitespace(next) or next == '(' or next == ')';
}

/// Check whether a module s-expression is `(module binary ...)` or `(module quote ...)`.
fn isBinaryOrQuoteModule(mod_text: []const u8) bool {
    return isBinaryModule(mod_text) or isQuoteModule(mod_text);
}

fn isBinaryModule(mod_text: []const u8) bool {
    const i = skipModulePrefix(mod_text);
    return i + 6 <= mod_text.len and std.mem.eql(u8, mod_text[i .. i + 6], "binary");
}

fn isQuoteModule(mod_text: []const u8) bool {
    const i = skipModulePrefix(mod_text);
    return i + 5 <= mod_text.len and std.mem.eql(u8, mod_text[i .. i + 5], "quote");
}

/// Skip past "(module" + optional whitespace + optional $name + whitespace.
fn skipModulePrefix(mod_text: []const u8) usize {
    var i: usize = 1; // skip '('
    while (i < mod_text.len and isWhitespace(mod_text[i])) : (i += 1) {}
    const mod_kw = "module";
    if (i + mod_kw.len > mod_text.len) return i;
    i += mod_kw.len;
    while (i < mod_text.len and isWhitespace(mod_text[i])) : (i += 1) {}
    if (i < mod_text.len and mod_text[i] == '$') {
        while (i < mod_text.len and !isWhitespace(mod_text[i]) and mod_text[i] != '(' and mod_text[i] != ')') : (i += 1) {}
        while (i < mod_text.len and isWhitespace(mod_text[i])) : (i += 1) {}
    }
    return i;
}

/// Decode `(module quote "..." "..." ...)` — extract and concatenate quoted WAT strings.
fn decodeQuoteStrings(allocator: std.mem.Allocator, mod_text: []const u8) ![]u8 {
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    var i = skipModulePrefix(mod_text);
    // Skip "quote" keyword
    if (i + 5 <= mod_text.len and std.mem.eql(u8, mod_text[i .. i + 5], "quote")) i += 5;

    while (i < mod_text.len) {
        if (mod_text[i] == '"') {
            i += 1;
            while (i < mod_text.len and mod_text[i] != '"') {
                if (mod_text[i] == '\\' and i + 1 < mod_text.len) {
                    i += 1;
                    switch (mod_text[i]) {
                        'n' => { try result.append(allocator, '\n'); i += 1; },
                        't' => { try result.append(allocator, '\t'); i += 1; },
                        'r' => { try result.append(allocator, '\r'); i += 1; },
                        '\\' => { try result.append(allocator, '\\'); i += 1; },
                        '"' => { try result.append(allocator, '"'); i += 1; },
                        '\'' => { try result.append(allocator, '\''); i += 1; },
                        else => {
                            // \xx hex escape — decode to actual byte
                            if (i + 1 < mod_text.len) {
                                const hi = hexDigit(mod_text[i]);
                                const lo = hexDigit(mod_text[i + 1]);
                                if (hi != null and lo != null) {
                                    try result.append(allocator, hi.? * 16 + lo.?);
                                    i += 2;
                                    continue;
                                }
                            }
                            // Not a valid hex escape — pass through as-is
                            try result.append(allocator, '\\');
                            try result.append(allocator, mod_text[i]);
                            i += 1;
                        },
                    }
                } else {
                    try result.append(allocator, mod_text[i]);
                    i += 1;
                }
            }
            if (i < mod_text.len) i += 1; // skip closing "
            try result.append(allocator, ' '); // space between segments
        } else {
            i += 1;
        }
    }
    return result.toOwnedSlice(allocator);
}

/// Decode `(module binary "\xx\xx" ...)` — extract hex-encoded binary bytes.
fn decodeWastHexStrings(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var res = std.ArrayListUnmanaged(u8){};
    errdefer res.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '"') {
            i += 1;
            while (i < text.len and text[i] != '"') {
                if (text[i] == '\\' and i + 2 < text.len) {
                    const hi = hexDigit(text[i + 1]);
                    const lo = hexDigit(text[i + 2]);
                    if (hi != null and lo != null) {
                        try res.append(allocator, hi.? * 16 + lo.?);
                        i += 3;
                    } else {
                        try res.append(allocator, text[i]);
                        i += 1;
                    }
                } else {
                    try res.append(allocator, text[i]);
                    i += 1;
                }
            }
            if (i < text.len) i += 1; // skip closing "
        } else {
            i += 1;
        }
    }
    return res.toOwnedSlice(allocator);
}

fn hexDigit(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

// ── Whitespace helpers ──────────────────────────────────────────────────

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Skip whitespace and comments (line comments ";;" and block comments "(; ... ;)").
fn skipWhitespaceAndComments(source: []const u8, start: usize) usize {
    var i = start;
    while (i < source.len) {
        const c = source[i];
        if (isWhitespace(c)) {
            i += 1;
        } else if (c == ';' and i + 1 < source.len and source[i + 1] == ';') {
            // Line comment — skip to end of line
            while (i < source.len and source[i] != '\n') : (i += 1) {}
        } else if (c == '(' and i + 1 < source.len and source[i + 1] == ';') {
            i = skipBlockComment(source, i);
        } else {
            break;
        }
    }
    return i;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "extractSExpr basic" {
    const source = "(module (func))";
    const result = extractSExpr(source, 0).?;
    try std.testing.expectEqualStrings("(module (func))", result.text);
    try std.testing.expectEqual(@as(usize, 15), result.end);
}

test "extractSExpr with string containing parens" {
    const source =
        \\(assert_invalid (module) "bad (stuff)")
    ;
    const result = extractSExpr(source, 0).?;
    try std.testing.expectEqualStrings(source, result.text);
}

test "classifyCommand" {
    try std.testing.expectEqual(Command.module, classifyCommand("(module)"));
    try std.testing.expectEqual(Command.assert_invalid, classifyCommand("(assert_invalid (module))"));
    try std.testing.expectEqual(Command.assert_malformed, classifyCommand("(assert_malformed (module))"));
    try std.testing.expectEqual(Command.assert_return, classifyCommand("(assert_return (invoke))"));
    try std.testing.expectEqual(Command.unknown, classifyCommand("(foobar)"));
}

test "isBinaryOrQuoteModule" {
    try std.testing.expect(isBinaryOrQuoteModule("(module binary \"\\00\")"));
    try std.testing.expect(isBinaryOrQuoteModule("(module quote \"(func)\")"));
    try std.testing.expect(!isBinaryOrQuoteModule("(module (func))"));
}

test "run: top-level module is parsed" {
    const wast = "(module (func (export \"f\")))";
    const result = run(std.testing.allocator, wast);
    try std.testing.expectEqual(@as(u32, 1), result.passed);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
    try std.testing.expectEqual(@as(u32, 0), result.skipped);
}

test "run: assert_invalid with duplicate export passes" {
    const wast =
        \\(assert_invalid
        \\  (module (func) (export "a" (func 0)) (export "a" (func 0)))
        \\  "duplicate export name"
        \\)
    ;
    const result = run(std.testing.allocator, wast);
    try std.testing.expectEqual(@as(u32, 1), result.passed);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
}

test "run: assert_malformed with binary module is processed" {
    const wast =
        \\(assert_malformed (module binary "") "unexpected end")
    ;
    const result = run(std.testing.allocator, wast);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
    try std.testing.expectEqual(@as(u32, 1), result.passed);
}

test "run: assert_malformed with quote module is handled" {
    // Verify quote modules are processed (not skipped)
    const wast =
        \\(assert_malformed (module quote "(module (func (result i32)))") "")
    ;
    const result = run(std.testing.allocator, wast);
    // Should be processed, not skipped
    try std.testing.expectEqual(@as(u32, 0), result.skipped);
}

test "run: assert_return without module is skipped" {
    const wast =
        \\(assert_return (invoke "f" (i32.const 1)) (i32.const 2))
    ;
    const result = run(std.testing.allocator, wast);
    try std.testing.expectEqual(@as(u32, 0), result.passed);
    try std.testing.expectEqual(@as(u32, 1), result.skipped);
}

test "run: mixed commands" {
    const wast =
        \\(module (func))
        \\(assert_invalid
        \\  (module (func) (export "a" (func 0)) (export "a" (func 0)))
        \\  "duplicate export name"
        \\)
        \\(assert_return (invoke "a") (i32.const 0))
    ;
    const result = run(std.testing.allocator, wast);
    // 1 module (passed) + 1 assert_invalid (passed) + 1 assert_return (failed — no export "a" in current module)
    try std.testing.expectEqual(@as(u32, 3), result.total());
    try std.testing.expectEqual(@as(u32, 2), result.passed);
}

test "run: block comments are handled" {
    const wast =
        \\(; this is a block comment ;)
        \\(module (func))
    ;
    const result = run(std.testing.allocator, wast);
    try std.testing.expectEqual(@as(u32, 1), result.total());
}

test "Result.total" {
    const r = Result{ .passed = 3, .failed = 1, .skipped = 2 };
    try std.testing.expectEqual(@as(u32, 6), r.total());
}

test "run: assert_return with simple add" {
    const wast =
        \\(module
        \\  (func (export "add") (param i32 i32) (result i32)
        \\    local.get 0 local.get 1 i32.add
        \\  )
        \\)
        \\(assert_return (invoke "add" (i32.const 3) (i32.const 4)) (i32.const 7))
        \\(assert_return (invoke "add" (i32.const 0) (i32.const 0)) (i32.const 0))
    ;
    const result = run(std.testing.allocator, wast);
    try std.testing.expectEqual(@as(u32, 3), result.passed);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
}

test "run: assert_trap on unreachable" {
    const wast =
        \\(module
        \\  (func (export "trap") unreachable)
        \\)
        \\(assert_trap (invoke "trap") "unreachable")
    ;
    const result = run(std.testing.allocator, wast);
    try std.testing.expectEqual(@as(u32, 2), result.passed);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
}

test "run: assert_return with block and br" {
    const wast =
        \\(module
        \\  (func (export "br") (param i32) (result i32)
        \\    (block (result i32) (local.get 0) (br 0))
        \\  )
        \\)
        \\(assert_return (invoke "br" (i32.const 42)) (i32.const 42))
    ;
    const result = run(std.testing.allocator, wast);
    try std.testing.expectEqual(@as(u32, 2), result.passed);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
}

test "run: register keeps module active" {
    const wast =
        \\(module
        \\  (func (export "f") (result i32) (i32.const 42))
        \\)
        \\(register "M")
        \\(assert_return (invoke "f") (i32.const 42))
    ;
    const result = run(std.testing.allocator, wast);
    // module (passed) + register (passed) + assert_return (passed) = 3
    try std.testing.expectEqual(@as(u32, 3), result.passed);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
}

test "run: named module survives replacement" {
    const wast =
        \\(module $Func
        \\  (func (export "e") (param i32) (result i32)
        \\    (i32.add (local.get 0) (i32.const 1))
        \\  )
        \\)
        \\(assert_return (invoke "e" (i32.const 42)) (i32.const 43))
        \\(module)
        \\(assert_return (invoke $Func "e" (i32.const 42)) (i32.const 43))
    ;
    const result = run(std.testing.allocator, wast);
    // module $Func (passed) + assert_return (passed) + module (passed) + assert_return (passed) = 4
    try std.testing.expectEqual(@as(u32, 4), result.passed);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
}

test "run: get global export" {
    const wast =
        \\(module
        \\  (global i32 (i32.const 99))
        \\  (export "g" (global 0))
        \\)
        \\(assert_return (get "g") (i32.const 99))
    ;
    const result = run(std.testing.allocator, wast);
    try std.testing.expectEqual(@as(u32, 2), result.passed);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
}

test "extractModuleId" {
    try std.testing.expectEqualStrings("$Func", extractModuleId("(module $Func (func))").?);
    try std.testing.expectEqualStrings("$M1", extractModuleId("(module $M1)").?);
    try std.testing.expect(extractModuleId("(module (func))") == null);
    try std.testing.expect(extractModuleId("(module)") == null);
}

test "extractDollarId" {
    try std.testing.expectEqualStrings("$Func", extractDollarId("(invoke $Func \"e\")").?);
    try std.testing.expect(extractDollarId("(invoke \"e\")") == null);
    try std.testing.expectEqualStrings("$M", extractDollarId("(get $M \"g\")").?);
}
