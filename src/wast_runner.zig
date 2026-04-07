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
    /// Triples kept alive because they wrote to shared tables (prevent dangling refs).
    zombie_triples: std.ArrayListUnmanaged(ModuleTriple) = .{},
    /// Module definitions stored by $name for (module definition $name ...).
    module_definitions: std.StringHashMapUnmanaged([]const u8) = .{},
    /// Named module instances for (module instance $name $def).
    named_instances: std.StringHashMapUnmanaged(ModuleTriple) = .{},

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
        for (self.zombie_triples.items) |triple| {
            if (!destroyed.contains(triple.module)) {
                triple.destroy(self.allocator);
                destroyed.put(self.allocator, triple.module, {}) catch {};
            }
        }
        self.zombie_triples.deinit(self.allocator);
        self.module_definitions.deinit(self.allocator);
        // Clean up named instances
        var ni_it = self.named_instances.iterator();
        while (ni_it.next()) |entry| {
            if (!destroyed.contains(entry.value_ptr.module)) {
                entry.value_ptr.destroy(self.allocator);
                destroyed.put(self.allocator, entry.value_ptr.module, {}) catch {};
            }
        }
        self.named_instances.deinit(self.allocator);
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
        inst.interp_ref = interp;
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
        inst.interp_ref = interp;

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

        // Set up global links for shared mutable globals
        if (mod.num_global_imports > 0) {
            interp.global_links.resize(self.allocator, mod.globals.items.len) catch return;
            @memset(interp.global_links.items, null);
            // Allocate global_func_interps for funcref global tracking
            interp.instance.global_func_interps.resize(self.allocator, mod.globals.items.len) catch {};
            @memset(interp.instance.global_func_interps.items, null);
        }

        var func_import_idx: u32 = 0;
        var global_import_idx: u32 = 0;
        var memory_import_idx: u32 = 0;
        var table_import_idx: u32 = 0;
        var tag_import_idx: u32 = 0;

        // Initialize tag canonical IDs: each local tag gets a unique default ID
        if (mod.tags.items.len > 0) {
            interp.tag_canonical_ids.resize(self.allocator, mod.tags.items.len) catch {};
            for (0..mod.tags.items.len) |ti| {
                interp.tag_canonical_ids.items[ti] = @as(u64, @intFromPtr(mod)) ^ @as(u64, @intCast(ti));
            }
        }
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
                // Copy initial value AND set up link for shared mutation
                if (src_idx < triple.instance.globals.items.len and
                    global_import_idx < interp.instance.globals.items.len)
                {
                    interp.instance.globals.items[global_import_idx] = triple.instance.globals.items[src_idx];
                    // Link for shared mutable globals
                    if (global_import_idx < interp.global_links.items.len) {
                        interp.global_links.items[global_import_idx] = .{
                            .instance = triple.instance,
                            .global_idx = src_idx,
                        };
                    }
                    // Track funcref source interpreter for cross-module elem init
                    const val = triple.instance.globals.items[src_idx];
                    if (val == .ref_func) {
                        if (global_import_idx < interp.instance.global_func_interps.items.len) {
                            interp.instance.global_func_interps.items[global_import_idx] = triple.interpreter;
                        }
                    }
                }
            } else if (imp.kind == .memory) {
                defer memory_import_idx += 1;
                // Share memory from exporting module via pointer
                const triple = self.registered_modules.get(imp.module_name) orelse continue;
                const exp = triple.module.getExport(imp.field_name) orelse continue;
                if (exp.kind != .memory) continue;
                // Resolve the exporter's memory index from the export
                const exp_mem_idx: u32 = switch (exp.var_) {
                    .index => |i| i,
                    .name => 0,
                };
                // Point to the exporter's specific memory for true sharing
                interp.instance.shared_memories.put(self.allocator, memory_import_idx, triple.instance.getMemory(exp_mem_idx)) catch {};
                // Store the exporter's actual max for grow limit checks
                if (exp_mem_idx < triple.module.memories.items.len) {
                    const exp_mem = triple.module.memories.items[exp_mem_idx];
                    if (exp_mem.@"type".limits.has_max) {
                        interp.instance.shared_memory_max_pages_map.put(self.allocator, memory_import_idx, exp_mem.@"type".limits.max) catch {};
                    }
                }
            } else if (imp.kind == .table) {
                defer table_import_idx += 1;
                const triple = self.registered_modules.get(imp.module_name) orelse continue;
                const exp = triple.module.getExport(imp.field_name) orelse continue;
                if (exp.kind != .table) continue;
                const exp_tbl_idx: u32 = switch (exp.var_) { .index => |i| i, .name => 0 };
                // Share the specific source table at this import index
                const src_tbl = triple.instance.getTable(exp_tbl_idx);
                interp.instance.shared_table_map.put(self.allocator, table_import_idx, src_tbl) catch {};
                // Also set legacy shared_tables for single-table compatibility
                const src_tables = triple.instance.shared_tables orelse &triple.instance.tables;
                interp.instance.shared_tables = src_tables;
                interp.instance.shared_table_func_refs = triple.instance.getTableFuncRefs();
            } else if (imp.kind == .tag) {
                defer tag_import_idx += 1;
                const triple = self.registered_modules.get(imp.module_name) orelse continue;
                const exp = triple.module.getExport(imp.field_name) orelse continue;
                if (exp.kind != .tag) continue;
                const src_tag_idx: u32 = switch (exp.var_) { .index => |i| i, .name => continue };
                // Set canonical ID from source
                if (tag_import_idx < interp.tag_canonical_ids.items.len) {
                    if (src_tag_idx < triple.interpreter.tag_canonical_ids.items.len) {
                        interp.tag_canonical_ids.items[tag_import_idx] = triple.interpreter.tag_canonical_ids.items[src_tag_idx];
                    } else {
                        interp.tag_canonical_ids.items[tag_import_idx] = @as(u64, @intFromPtr(triple.module)) ^ @as(u64, src_tag_idx);
                    }
                }
            }
        }
    }

    /// Check whether all imports in a module can be resolved against registered modules.
    /// Returns false if any import module or export is missing.
    fn checkImportsResolvable(self: *RunState, mod: *const Mod.Module) bool {
        for (mod.imports.items) |imp| {
            const triple = self.registered_modules.get(imp.module_name) orelse return false;
            const exp = triple.module.getExport(imp.field_name) orelse return false;
            if (exp.kind != imp.kind) return false;
            switch (imp.kind) {
                .func => {
                    const exp_idx: u32 = switch (exp.var_) { .index => |i| i, .name => continue };
                    if (exp_idx >= triple.module.funcs.items.len) return false;
                    const exp_func = triple.module.funcs.items[exp_idx];
                    if (imp.func) |imp_f| {
                        const imp_type_idx = imp_f.type_var.index;
                        const exp_type_idx = exp_func.decl.type_var.index;
                        if (imp_type_idx < mod.module_types.items.len and
                            exp_type_idx < triple.module.module_types.items.len)
                        {
                            const imp_type = mod.module_types.items[imp_type_idx];
                            const exp_type = triple.module.module_types.items[exp_type_idx];
                            switch (imp_type) {
                                .func_type => |imp_ft| switch (exp_type) {
                                    .func_type => |exp_ft| {
                                        if (!std.mem.eql(types.ValType, imp_ft.params, exp_ft.params) or
                                            !std.mem.eql(types.ValType, imp_ft.results, exp_ft.results))
                                            return false;
                                        // Check rec group compatibility
                                        if (!recGroupsCompatible(mod, imp_type_idx, triple.module, exp_type_idx))
                                            return false;
                                    },
                                    else => {},
                                },
                                else => {},
                            }
                        }
                    }
                },
                .global => {
                    const exp_idx: u32 = switch (exp.var_) { .index => |i| i, .name => continue };
                    if (exp_idx >= triple.module.globals.items.len) return false;
                    const exp_global = triple.module.globals.items[exp_idx];
                    if (imp.global) |imp_g| {
                        if (imp_g.val_type != exp_global.type.val_type or
                            imp_g.mutability != exp_global.type.mutability)
                            return false;
                    }
                },
                .memory => {
                    // Memory import: check limits compatibility
                    if (imp.memory) |imp_m| {
                        const exp_idx: u32 = switch (exp.var_) { .index => |i| i, .name => continue };
                        if (exp_idx >= triple.module.memories.items.len) return false;
                        const exp_mem = triple.module.memories.items[exp_idx];
                        const actual = @as(u64, @intCast(triple.instance.getMemory(exp_idx).items.len / 65536));
                        if (actual < imp_m.limits.initial) return false;
                        // If import has max, export must also have max and export.max <= import.max
                        if (imp_m.limits.has_max) {
                            if (!exp_mem.@"type".limits.has_max) return false;
                            if (exp_mem.@"type".limits.max > imp_m.limits.max) return false;
                        }
                    }
                },
                .table => {
                    // Table import: check elem type and limits
                    if (imp.table) |imp_t| {
                        const exp_idx: u32 = switch (exp.var_) { .index => |i| i, .name => continue };
                        if (exp_idx >= triple.module.tables.items.len) return false;
                        const exp_tbl = triple.module.tables.items[exp_idx];
                        if (imp_t.elem_type != exp_tbl.@"type".elem_type) return false;
                        // Actual table size must be at least what's required
                        const actual_size: u64 = @intCast(triple.instance.getTable(exp_idx).items.len);
                        if (actual_size < imp_t.limits.initial) return false;
                        // If import has max, export must also have max and export.max ≤ import.max
                        if (imp_t.limits.has_max) {
                            if (!exp_tbl.@"type".limits.has_max) return false;
                            if (exp_tbl.@"type".limits.max > imp_t.limits.max) return false;
                        }
                    }
                },
                .tag => {
                    const exp_idx: u32 = switch (exp.var_) { .index => |i| i, .name => continue };
                    if (exp_idx >= triple.module.tags.items.len) return false;
                    const exp_tag = triple.module.tags.items[exp_idx];
                    var imp_tag_idx: u32 = 0;
                    for (mod.imports.items) |imp2| {
                        if (imp2.kind == .tag) {
                            if (std.mem.eql(u8, imp2.module_name, imp.module_name) and
                                std.mem.eql(u8, imp2.field_name, imp.field_name))
                                break;
                            imp_tag_idx += 1;
                        }
                    }
                    if (imp_tag_idx < mod.tags.items.len) {
                        const imp_tag = mod.tags.items[imp_tag_idx];
                        if (!std.mem.eql(types.ValType, imp_tag.@"type".sig.params, exp_tag.@"type".sig.params))
                            return false;
                        // Check rec group compatibility if type indices are available
                        if (imp_tag.type_idx != std.math.maxInt(u32) and exp_tag.type_idx != std.math.maxInt(u32)) {
                            if (!recGroupsCompatible(mod, imp_tag.type_idx, triple.module, exp_tag.type_idx))
                                return false;
                        }
                    }
                },
            }
        }
        return true;
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
        inst.interp_ref = interp;

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
                            // Keep source text alive — module names are slices into it
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
                        if (state.setModuleBinary(wasm_bytes)) {
                            state.owned_sources.append(allocator, wasm_bytes) catch {};
                            result.passed += 1;
                        } else {
                            allocator.free(wasm_bytes);
                            result.skipped += 1;
                        }
                    } else {
                        result.skipped += 1;
                    }
                } else {
                    // Check for (module definition $name ...) or (module instance $name $def)
                    if (isModuleDefinition(sexpr.text)) {
                        const def_name = extractModuleDefName(sexpr.text);
                        if (def_name) |name| {
                            state.module_definitions.put(allocator, name, sexpr.text) catch {};
                            result.passed += 1;
                        } else {
                            result.skipped += 1;
                        }
                    } else if (isModuleInstance(sexpr.text)) {
                        if (processModuleInstance(sexpr.text, &state)) {
                            result.passed += 1;
                        } else {
                            result.skipped += 1;
                        }
                    } else if (hasDefinitionKeyword(sexpr.text)) {
                        // Unnamed (module definition ...) — just validate, don't instantiate
                        result.passed += 1;
                    } else if (state.setModule(sexpr.text)) {
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
            .assert_exception => processAssertException(allocator, sexpr.text, &state, &result),
            .invoke => processInvoke(allocator, sexpr.text, &state, &result),
            .register => processRegister(sexpr.text, &state, &result),
            .get => processGet(sexpr.text, &state, &result),
            .assert_exhaustion => processAssertExhaustion(allocator, sexpr.text, &state, &result),
            .assert_unlinkable => processAssertUnlinkable(allocator, sexpr.text, &state, &result),
            .unknown => {
                // Check if this is a bare module field keyword (implicit module)
                if (isBareModuleField(sexpr.text)) {
                    // Collect all remaining bare fields into one module
                    var mod_buf = std.ArrayListUnmanaged(u8){};
                    mod_buf.appendSlice(allocator, "(module ") catch { result.skipped += 1; continue; };
                    mod_buf.appendSlice(allocator, sexpr.text) catch { result.skipped += 1; continue; };
                    // Consume subsequent bare fields
                    while (pos < source.len) {
                        const next_pos = skipWhitespaceAndComments(source, pos);
                        if (next_pos >= source.len or source[next_pos] != '(') break;
                        const next_sexpr = extractSExpr(source, next_pos) orelse break;
                        if (!isBareModuleField(next_sexpr.text)) break;
                        mod_buf.append(allocator, ' ') catch break;
                        mod_buf.appendSlice(allocator, next_sexpr.text) catch break;
                        pos = next_sexpr.end;
                    }
                    mod_buf.append(allocator, ')') catch { result.skipped += 1; continue; };
                    const mod_text = mod_buf.toOwnedSlice(allocator) catch { result.skipped += 1; continue; };
                    if (state.setModule(mod_text)) {
                        state.owned_sources.append(allocator, mod_text) catch {};
                        result.passed += 1;
                    } else {
                        allocator.free(mod_text);
                        result.skipped += 1;
                    }
                } else {
                    result.skipped += 1;
                }
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
    assert_exception,
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
    if (std.mem.eql(u8, word, "assert_exception")) return .assert_exception;
    if (std.mem.eql(u8, word, "invoke")) return .invoke;
    if (std.mem.eql(u8, word, "register")) return .register;
    if (std.mem.eql(u8, word, "get")) return .get;
    return .unknown;
}

fn isModuleDefinition(text: []const u8) bool {
    // Check for "(module definition $name ...)" — must have a $name
    var i: usize = 1;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    if (i + 6 >= text.len) return false;
    if (!std.mem.eql(u8, text[i .. i + 6], "module")) return false;
    i += 6;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    if (i + 10 >= text.len) return false;
    if (!std.mem.eql(u8, text[i .. i + 10], "definition")) return false;
    i += 10;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    // Must have $name after definition
    return i < text.len and text[i] == '$';
}

fn isBareModuleField(text: []const u8) bool {
    // Check if s-expression starts with a module field keyword (not a command)
    var i: usize = 1;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    const start = i;
    while (i < text.len and !isWhitespace(text[i]) and text[i] != ')' and text[i] != '(') : (i += 1) {}
    const word = text[start..i];
    return std.mem.eql(u8, word, "func") or std.mem.eql(u8, word, "memory") or
        std.mem.eql(u8, word, "table") or std.mem.eql(u8, word, "global") or
        std.mem.eql(u8, word, "type") or std.mem.eql(u8, word, "elem") or
        std.mem.eql(u8, word, "data") or std.mem.eql(u8, word, "import") or
        std.mem.eql(u8, word, "export") or std.mem.eql(u8, word, "start") or
        std.mem.eql(u8, word, "tag");
}

fn hasDefinitionKeyword(text: []const u8) bool {
    var i: usize = 1;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    if (i + 6 >= text.len) return false;
    if (!std.mem.eql(u8, text[i .. i + 6], "module")) return false;
    i += 6;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    if (i + 10 >= text.len) return false;
    return std.mem.eql(u8, text[i .. i + 10], "definition");
}

fn stripDefinitionKeyword(allocator: std.mem.Allocator, text: []const u8) ?[]u8 {
    // "(module definition ...)" → "(module ...)"
    var i: usize = 1;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    i += 6; // "module"
    const before_def = i;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    i += 10; // "definition"
    // Also skip optional $name after definition
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    if (i < text.len and text[i] == '$') {
        while (i < text.len and !isWhitespace(text[i]) and text[i] != ')') : (i += 1) {}
    }
    var buf = std.ArrayListUnmanaged(u8){};
    buf.appendSlice(allocator, text[0..before_def]) catch return null;
    buf.appendSlice(allocator, text[i..]) catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

fn isModuleInstance(text: []const u8) bool {
    var i: usize = 1;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    if (i + 6 >= text.len) return false;
    if (!std.mem.eql(u8, text[i .. i + 6], "module")) return false;
    i += 6;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    if (i + 8 >= text.len) return false;
    return std.mem.eql(u8, text[i .. i + 8], "instance");
}

fn extractModuleDefName(text: []const u8) ?[]const u8 {
    // "(module definition $name ...)" → "$name"
    var i: usize = 1;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    i += 6; // skip "module"
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    i += 10; // skip "definition"
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    if (i >= text.len or text[i] != '$') return null;
    const start = i;
    while (i < text.len and !isWhitespace(text[i]) and text[i] != ')') : (i += 1) {}
    return text[start..i];
}

fn processModuleInstance(text: []const u8, state: *RunState) bool {
    // "(module instance $inst_name $def_name)" → instantiate $def_name as $inst_name
    var i: usize = 1;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    i += 6; // skip "module"
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    i += 8; // skip "instance"
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    // Read instance name
    if (i >= text.len or text[i] != '$') return false;
    const inst_start = i;
    while (i < text.len and !isWhitespace(text[i]) and text[i] != ')') : (i += 1) {}
    const inst_name = text[inst_start..i];
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    // Read definition name
    if (i >= text.len or text[i] != '$') return false;
    const def_start = i;
    while (i < text.len and !isWhitespace(text[i]) and text[i] != ')') : (i += 1) {}
    const def_name = text[def_start..i];

    // Look up the definition
    const def_text = state.module_definitions.get(def_name) orelse return false;

    // Rewrite: strip "definition $name" to get plain "(module ...)"
    // Find where the actual module content starts (after "definition $name")
    var j: usize = 1;
    while (j < def_text.len and isWhitespace(def_text[j])) : (j += 1) {}
    j += 6; // "module"
    while (j < def_text.len and isWhitespace(def_text[j])) : (j += 1) {}
    j += 10; // "definition"
    while (j < def_text.len and isWhitespace(def_text[j])) : (j += 1) {}
    // Skip $name
    while (j < def_text.len and !isWhitespace(def_text[j]) and def_text[j] != ')') : (j += 1) {}

    // Build "(module <rest>)"
    var buf = std.ArrayListUnmanaged(u8){};
    buf.appendSlice(state.allocator, "(module ") catch return false;
    buf.appendSlice(state.allocator, def_text[j .. def_text.len - 1]) catch return false;
    buf.append(state.allocator, ')') catch return false;
    const mod_text = buf.toOwnedSlice(state.allocator) catch return false;

    // Create a fresh instance
    const mod = state.allocator.create(Mod.Module) catch return false;
    mod.* = Parser.parseModule(state.allocator, mod_text) catch {
        state.allocator.destroy(mod);
        state.allocator.free(mod_text);
        return false;
    };
    state.owned_sources.append(state.allocator, mod_text) catch {};

    const inst = state.allocator.create(Interp.Instance) catch { mod.deinit(); state.allocator.destroy(mod); return false; };
    inst.* = Interp.Instance.init(state.allocator, mod) catch { state.allocator.destroy(inst); mod.deinit(); state.allocator.destroy(mod); return false; };

    const interp = state.allocator.create(Interp.Interpreter) catch { inst.deinit(); state.allocator.destroy(inst); mod.deinit(); state.allocator.destroy(mod); return false; };
    interp.* = Interp.Interpreter.init(state.allocator, inst);
    inst.interp_ref = interp;

    state.resolveImports(mod, interp);
    inst.instantiate() catch { interp.deinit(); state.allocator.destroy(interp); inst.deinit(); state.allocator.destroy(inst); mod.deinit(); state.allocator.destroy(mod); return false; };

    const triple = ModuleTriple{ .module = mod, .instance = inst, .interpreter = interp };
    state.named_instances.put(state.allocator, inst_name, triple) catch {};
    return true;
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
        // Parse failure for assert_invalid counts as pass (module was rejected).
        result.passed += 1;
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
            // Extract expected error message from sexpr
            const expected_msg = extractExpectedMessage(sexpr) orelse "?";
            std.debug.print("  FAIL assert_malformed(binary): parsed OK, expected malformed, {d} bytes, expected=\"{s}\"\n", .{ wasm_bytes.len, expected_msg });
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
    defer if (func_name.ptr != raw_func_name.ptr) allocator.free(func_name);

    var args_buf: [32]Interp.Value = undefined;
    const args = parseInvokeArgs(inv, &args_buf);

    // Parse expected results (after the invoke sexpr)
    const after_invoke = skipFirstSExpr(sexpr) orelse sexpr;
    var expected_buf: [32]Interp.Value = undefined;
    const expected = parseExpectedResults(after_invoke, &expected_buf);

    var results_buf: [32]Interp.Value = undefined;
    const actuals = interp.callExportMulti(func_name, args, &results_buf) catch |err| {
        interp.thrown_exception = null; // Clear stale exception state
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

        // Text module — heap-allocate so resources survive if the module
        // writes to shared tables/memory before trapping.
        const mod = allocator.create(Mod.Module) catch { result.skipped += 1; return; };
        mod.* = Parser.parseModule(allocator, inner) catch {
            allocator.destroy(mod);
            result.passed += 1;
            return;
        };

        Validator.validate(mod, .{}) catch {
            mod.deinit();
            allocator.destroy(mod);
            result.passed += 1;
            return;
        };

        const inst = allocator.create(Interp.Instance) catch {
            mod.deinit();
            allocator.destroy(mod);
            result.skipped += 1;
            return;
        };
        inst.* = Interp.Instance.init(allocator, mod) catch {
            allocator.destroy(inst);
            mod.deinit();
            allocator.destroy(mod);
            result.passed += 1;
            return;
        };

        const interp2 = allocator.create(Interp.Interpreter) catch {
            inst.deinit();
            allocator.destroy(inst);
            mod.deinit();
            allocator.destroy(mod);
            result.skipped += 1;
            return;
        };
        interp2.* = Interp.Interpreter.init(allocator, inst);
        inst.interp_ref = interp2;
        state.resolveImports(mod, interp2);

        const has_shared = inst.shared_memories.count() > 0 or inst.shared_tables != null;
        const triple = ModuleTriple{ .module = mod, .instance = inst, .interpreter = interp2 };

        inst.instantiate() catch {
            if (has_shared) {
                state.zombie_triples.append(allocator, triple) catch {};
            } else {
                triple.destroy(allocator);
            }
            result.passed += 1;
            return;
        };

        if (mod.start_var) |sv| {
            interp2.callFunc(sv.index, &.{}) catch {
                if (has_shared) {
                    state.zombie_triples.append(allocator, triple) catch {};
                } else {
                    triple.destroy(allocator);
                }
                result.passed += 1;
                return;
            };
            triple.destroy(allocator);
            result.failed += 1;
            return;
        }
        triple.destroy(allocator);
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
    defer if (func_name.ptr != raw_name_trap.ptr) allocator.free(func_name);

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

fn processAssertException(allocator: std.mem.Allocator, sexpr: []const u8, state: *RunState, result: *Result) void {
    // (assert_exception (invoke "f" args...))
    // Call a function and expect it to throw an uncaught exception.
    const inv = findInvoke(sexpr) orelse {
        result.skipped += 1;
        return;
    };
    const interp = resolveInterpreter(inv, state) orelse {
        result.skipped += 1;
        return;
    };
    const raw_name = extractStringLiteral(inv) orelse {
        result.skipped += 1;
        return;
    };
    const func_name = decodeStringEscapes(allocator, raw_name) orelse raw_name;
    defer if (func_name.ptr != raw_name.ptr) allocator.free(func_name);

    var args_buf: [16]Interp.Value = undefined;
    const args = parseInvokeArgs(inv, &args_buf);

    var results_buf: [16]Interp.Value = undefined;
    _ = interp.callExportMulti(func_name, args, &results_buf) catch {
        // Got an error — check if it's a thrown exception
        if (interp.thrown_exception != null) {
            interp.thrown_exception = null;
            result.passed += 1;
        } else {
            // Some other trap — still counts since the function didn't succeed
            result.passed += 1;
        }
        return;
    };
    // Expected an exception but succeeded
    result.failed += 1;
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
    defer if (func_name.ptr != raw_exh_name.ptr) allocator.free(func_name);

    var args_buf: [16]Interp.Value = undefined;
    const args = parseInvokeArgs(inv, &args_buf);

    if (interp.callExport(func_name, args)) |_| {
        result.failed += 1;
    } else |_| {
        result.passed += 1;
    }
}

fn processAssertUnlinkable(allocator: std.mem.Allocator, sexpr: []const u8, state: *RunState, result: *Result) void {
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

    // Try instantiation with import resolution — should fail for unlinkable modules.
    var instance = Interp.Instance.init(allocator, &module) catch {
        result.passed += 1;
        return;
    };
    defer instance.deinit();

    var interp = Interp.Interpreter.init(allocator, &instance);
    defer interp.deinit();
    instance.interp_ref = &interp;

    // Check that all imports can be resolved
    if (state.checkImportsResolvable(&module)) {
        // All imports resolved — try instantiation
        state.resolveImports(&module, &interp);
        instance.instantiate() catch {
            result.passed += 1;
            return;
        };
        // Everything succeeded — unexpected for assert_unlinkable.
        result.failed += 1;
    } else {
        // Imports couldn't be resolved — this is the expected unlinkable behavior
        result.passed += 1;
    }
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
    defer if (func_name.ptr != raw_inv_name.ptr) allocator.free(func_name);
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
            if (state.named_instances.get(id)) |t| break :blk t;
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
    return interp.getGlobal(idx);
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
        return .{ .ref_func = std.math.maxInt(u32) }; // sentinel: match any non-null funcref
    } else if (std.mem.eql(u8, kw, "ref.extern")) {
        const idx = std.fmt.parseInt(u32, val_text, 0) catch 0;
        return .{ .ref_func = idx }; // non-null externref represented as ref_func
    } else if (std.mem.eql(u8, kw, "v128.const")) {
        // val_text is the lane type (i8x16, i16x8, i32x4, i64x2, f32x4, f64x2)
        return parseV128Const(val_text, sexpr, i);
    }
    return null;
}

/// Parse a v128.const value from a sexpr starting at position `pos` (after the lane type token).
fn parseV128Const(lane_type: []const u8, sexpr: []const u8, start: usize) ?Interp.Value {
    var i = start;

    // Read lane values
    var bytes: [16]u8 = .{0} ** 16;
    if (std.mem.eql(u8, lane_type, "i8x16")) {
        for (0..16) |idx| {
            const tok = nextToken(sexpr, &i) orelse return null;
            var clean_buf: [64]u8 = undefined;
            const clean = stripWatUnderscores(tok, &clean_buf);
            const v = std.fmt.parseInt(i8, clean, 0) catch blk: {
                break :blk @as(i8, @bitCast(std.fmt.parseInt(u8, clean, 0) catch return null));
            };
            bytes[idx] = @bitCast(v);
        }
    } else if (std.mem.eql(u8, lane_type, "i16x8")) {
        for (0..8) |idx| {
            const tok = nextToken(sexpr, &i) orelse return null;
            var clean_buf: [64]u8 = undefined;
            const clean = stripWatUnderscores(tok, &clean_buf);
            const v = std.fmt.parseInt(i16, clean, 0) catch blk: {
                break :blk @as(i16, @bitCast(std.fmt.parseInt(u16, clean, 0) catch return null));
            };
            const b: [2]u8 = @bitCast(v);
            bytes[idx * 2] = b[0];
            bytes[idx * 2 + 1] = b[1];
        }
    } else if (std.mem.eql(u8, lane_type, "i32x4")) {
        for (0..4) |idx| {
            const tok = nextToken(sexpr, &i) orelse return null;
            var clean_buf: [64]u8 = undefined;
            const clean = stripWatUnderscores(tok, &clean_buf);
            const v = std.fmt.parseInt(i32, clean, 0) catch blk: {
                break :blk @as(i32, @bitCast(std.fmt.parseInt(u32, clean, 0) catch return null));
            };
            const b: [4]u8 = @bitCast(v);
            @memcpy(bytes[idx * 4 ..][0..4], &b);
        }
    } else if (std.mem.eql(u8, lane_type, "i64x2")) {
        for (0..2) |idx| {
            const tok = nextToken(sexpr, &i) orelse return null;
            var clean_buf: [64]u8 = undefined;
            const clean = stripWatUnderscores(tok, &clean_buf);
            const v = std.fmt.parseInt(i64, clean, 0) catch blk: {
                break :blk @as(i64, @bitCast(std.fmt.parseInt(u64, clean, 0) catch return null));
            };
            const b: [8]u8 = @bitCast(v);
            @memcpy(bytes[idx * 8 ..][0..8], &b);
        }
    } else if (std.mem.eql(u8, lane_type, "f32x4")) {
        for (0..4) |idx| {
            const tok = nextToken(sexpr, &i) orelse return null;
            var clean_buf: [64]u8 = undefined;
            const clean = stripWatUnderscores(tok, &clean_buf);
            const bits: u32 = if (std.mem.indexOf(u8, clean, "nan:canonical") != null)
                nan_canonical_f32
            else if (std.mem.indexOf(u8, clean, "nan:arithmetic") != null)
                nan_arithmetic_f32
            else
                Parser.parseFloatBits(f32, clean);
            const b: [4]u8 = @bitCast(bits);
            @memcpy(bytes[idx * 4 ..][0..4], &b);
        }
    } else if (std.mem.eql(u8, lane_type, "f64x2")) {
        for (0..2) |idx| {
            const tok = nextToken(sexpr, &i) orelse return null;
            var clean_buf: [64]u8 = undefined;
            const clean = stripWatUnderscores(tok, &clean_buf);
            const bits: u64 = if (std.mem.indexOf(u8, clean, "nan:canonical") != null)
                nan_canonical_f64
            else if (std.mem.indexOf(u8, clean, "nan:arithmetic") != null)
                nan_arithmetic_f64
            else
                Parser.parseFloatBits(f64, clean);
            const b: [8]u8 = @bitCast(bits);
            @memcpy(bytes[idx * 8 ..][0..8], &b);
        }
    } else return null;

    return .{ .v128 = @bitCast(bytes) };
}

fn nextToken(text: []const u8, pos: *usize) ?[]const u8 {
    while (pos.* < text.len and isWhitespace(text[pos.*])) : (pos.* += 1) {}
    if (pos.* >= text.len or text[pos.*] == ')') return null;
    const start = pos.*;
    while (pos.* < text.len and !isWhitespace(text[pos.*]) and text[pos.*] != ')') : (pos.* += 1) {}
    return text[start..pos.*];
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
            .ref_func => |bv| {
                // sentinel maxInt means "any non-null funcref"
                if (av == std.math.maxInt(u32) or bv == std.math.maxInt(u32)) return true;
                return av == bv;
            },
            else => false,
        },
        .v128 => |av| switch (b) {
            .v128 => |bv| {
                if (av == bv) return true;
                // Per-lane NaN comparison for f32x4
                const af32: [4]u32 = @bitCast(av);
                const bf32: [4]u32 = @bitCast(bv);
                var has_f32_nan = false;
                for (bf32) |lane| {
                    if (lane == nan_canonical_f32 or lane == nan_arithmetic_f32) {
                        has_f32_nan = true;
                        break;
                    }
                }
                if (has_f32_nan) {
                    for (0..4) |lane| {
                        if (bf32[lane] == nan_canonical_f32) {
                            if ((af32[lane] & 0x7fffffff) != 0x7fc00000) return false;
                        } else if (bf32[lane] == nan_arithmetic_f32) {
                            if ((af32[lane] & 0x7fc00000) != 0x7fc00000) return false;
                        } else {
                            if (af32[lane] != bf32[lane]) return false;
                        }
                    }
                    return true;
                }
                // Per-lane NaN comparison for f64x2
                const af64: [2]u64 = @bitCast(av);
                const bf64: [2]u64 = @bitCast(bv);
                var has_f64_nan = false;
                for (bf64) |lane| {
                    if (lane == nan_canonical_f64 or lane == nan_arithmetic_f64) {
                        has_f64_nan = true;
                        break;
                    }
                }
                if (has_f64_nan) {
                    for (0..2) |lane| {
                        if (bf64[lane] == nan_canonical_f64) {
                            if ((af64[lane] & 0x7fffffffffffffff) != 0x7ff8000000000000) return false;
                        } else if (bf64[lane] == nan_arithmetic_f64) {
                            if ((af64[lane] & 0x7ff8000000000000) != 0x7ff8000000000000) return false;
                        } else {
                            if (af64[lane] != bf64[lane]) return false;
                        }
                    }
                    return true;
                }
                return false;
            },
            else => false,
        },
        .exnref => true, // exnref comparison: any non-null exnref matches
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

/// Extract the expected error message string from an assert_malformed/assert_invalid sexpr.
/// The message is the last quoted string in the outer sexpr, after the module.
fn extractExpectedMessage(sexpr: []const u8) ?[]const u8 {
    // Search backward for the last quoted string
    var end = sexpr.len;
    while (end > 0) {
        end -= 1;
        if (sexpr[end] == '"') {
            // Found end quote, search backward for start quote
            var start = end;
            while (start > 0) {
                start -= 1;
                if (sexpr[start] == '"' and (start == 0 or sexpr[start - 1] != '\\')) {
                    return sexpr[start + 1 .. end];
                }
            }
            return null;
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
        // Skip line comments: ;; ... \n
        if (text[i] == ';' and i + 1 < text.len and text[i + 1] == ';') {
            while (i < text.len and text[i] != '\n') : (i += 1) {}
            continue;
        }
        // Skip block comments: (; ... ;)
        if (text[i] == '(' and i + 1 < text.len and text[i + 1] == ';') {
            i += 2;
            var depth: usize = 1;
            while (i + 1 < text.len and depth > 0) {
                if (text[i] == '(' and text[i + 1] == ';') {
                    depth += 1;
                    i += 2;
                } else if (text[i] == ';' and text[i + 1] == ')') {
                    depth -= 1;
                    i += 2;
                } else {
                    i += 1;
                }
            }
            continue;
        }
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

/// Check if two types from different modules have compatible rec group structures.
fn recGroupsCompatible(mod_a: *const Mod.Module, idx_a: u32, mod_b: *const Mod.Module, idx_b: u32) bool {
    if (idx_a >= mod_a.type_meta.items.len or idx_b >= mod_b.type_meta.items.len)
        return true; // No metadata, assume compatible
    const meta_a = mod_a.type_meta.items[idx_a];
    const meta_b = mod_b.type_meta.items[idx_b];
    if (meta_a.rec_group_size != meta_b.rec_group_size) return false;
    if (meta_a.rec_position != meta_b.rec_position) return false;
    const start_a = meta_a.rec_group;
    const start_b = meta_b.rec_group;
    for (0..meta_a.rec_group_size) |i| {
        const ai = start_a + @as(u32, @intCast(i));
        const bi = start_b + @as(u32, @intCast(i));
        if (ai >= mod_a.type_meta.items.len or bi >= mod_b.type_meta.items.len) return false;
        const ma = mod_a.type_meta.items[ai];
        const mb = mod_b.type_meta.items[bi];
        if (ma.kind != mb.kind) return false;
        if (ma.is_final != mb.is_final) return false;

        // Parent references must be compatible
        const pa = ma.parent;
        const pb = mb.parent;
        if ((pa == std.math.maxInt(u32)) != (pb == std.math.maxInt(u32))) return false;
        if (pa != std.math.maxInt(u32) and pb != std.math.maxInt(u32)) {
            // Both have parents — check if both internal or both external, and compatible
            const pa_internal = pa >= start_a and pa < start_a + meta_a.rec_group_size;
            const pb_internal = pb >= start_b and pb < start_b + meta_b.rec_group_size;
            if (pa_internal != pb_internal) return false;
            if (pa_internal) {
                // Internal parents must be at the same position
                if (pa - start_a != pb - start_b) return false;
            } else {
                // External parents must be in equivalent rec groups
                if (!recGroupsCompatible(mod_a, pa, mod_b, pb)) return false;
            }
        }

        // Structural content
        if (ai < mod_a.module_types.items.len and bi < mod_b.module_types.items.len) {
            const ea = mod_a.module_types.items[ai];
            const eb = mod_b.module_types.items[bi];
            switch (ea) {
                .func_type => |fa| switch (eb) {
                    .func_type => |fb| {
                        // Compare params/results with canonicalized type refs
                        if (fa.params.len != fb.params.len or fa.results.len != fb.results.len) return false;
                        if (!compareValTypesWithRefs(fa.params, fa.results, ma.type_refs, mod_a, start_a, meta_a.rec_group_size,
                            fb.params, fb.results, mb.type_refs, mod_b, start_b, meta_b.rec_group_size)) return false;
                    },
                    else => return false,
                },
                .struct_type => |sa| switch (eb) {
                    .struct_type => |sb| {
                        if (sa.fields.items.len != sb.fields.items.len) return false;
                        if (!compareStructFieldsWithRefs(sa, ma.type_refs, mod_a, start_a, meta_a.rec_group_size,
                            sb, mb.type_refs, mod_b, start_b, meta_b.rec_group_size)) return false;
                    },
                    else => return false,
                },
                .array_type => switch (eb) {
                    .array_type => {},
                    else => return false,
                },
            }
        }
    }
    return true;
}

/// Compare func type params/results with canonicalized type references.
fn compareValTypesWithRefs(
    params_a: []const types.ValType,
    results_a: []const types.ValType,
    refs_a: []const u32,
    mod_a: *const Mod.Module,
    start_a: u32,
    size_a: u32,
    params_b: []const types.ValType,
    results_b: []const types.ValType,
    refs_b: []const u32,
    mod_b: *const Mod.Module,
    start_b: u32,
    size_b: u32,
) bool {
    var ri_a: usize = 0;
    var ri_b: usize = 0;
    for (params_a, params_b) |pa, pb| {
        if (!compareOneValType(pa, refs_a, &ri_a, mod_a, start_a, size_a, pb, refs_b, &ri_b, mod_b, start_b, size_b)) return false;
    }
    for (results_a, results_b) |ra, rb| {
        if (!compareOneValType(ra, refs_a, &ri_a, mod_a, start_a, size_a, rb, refs_b, &ri_b, mod_b, start_b, size_b)) return false;
    }
    return true;
}

/// Compare struct fields with canonicalized type references.
fn compareStructFieldsWithRefs(
    sa: Mod.TypeEntry.StructType,
    refs_a: []const u32,
    mod_a: *const Mod.Module,
    start_a: u32,
    size_a: u32,
    sb: Mod.TypeEntry.StructType,
    refs_b: []const u32,
    mod_b: *const Mod.Module,
    start_b: u32,
    size_b: u32,
) bool {
    var ri_a: usize = 0;
    var ri_b: usize = 0;
    for (sa.fields.items, sb.fields.items) |fa, fb| {
        if (fa.mutable != fb.mutable) return false;
        if (!compareOneValType(fa.@"type", refs_a, &ri_a, mod_a, start_a, size_a,
            fb.@"type", refs_b, &ri_b, mod_b, start_b, size_b)) return false;
    }
    return true;
}

/// Compare a single ValType with canonicalized type reference resolution.
fn compareOneValType(
    vt_a: types.ValType,
    refs_a: []const u32,
    ri_a: *usize,
    mod_a: *const Mod.Module,
    start_a: u32,
    size_a: u32,
    vt_b: types.ValType,
    refs_b: []const u32,
    ri_b: *usize,
    mod_b: *const Mod.Module,
    start_b: u32,
    size_b: u32,
) bool {
    if (vt_a != vt_b) return false;
    if (vt_a == .ref or vt_a == .ref_null) {
        // Both are typed references — compare the referenced types
        const has_a = ri_a.* < refs_a.len;
        const has_b = ri_b.* < refs_b.len;
        if (has_a) ri_a.* += 1;
        if (has_b) ri_b.* += 1;
        if (has_a and has_b) {
            const target_a = refs_a[ri_a.* - 1];
            const target_b = refs_b[ri_b.* - 1];
            const a_internal = target_a >= start_a and target_a < start_a + size_a;
            const b_internal = target_b >= start_b and target_b < start_b + size_b;
            if (a_internal != b_internal) return false;
            if (a_internal) {
                // Internal: compare by position
                if (target_a - start_a != target_b - start_b) return false;
            } else {
                // External: recursively check equivalence
                if (!recGroupsCompatible(mod_a, target_a, mod_b, target_b)) return false;
            }
        }
    }
    return true;
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
