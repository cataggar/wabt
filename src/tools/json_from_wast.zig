const std = @import("std");
const wabt = @import("wabt");
const wast = wabt.wast_runner;
const Parser = wabt.text.Parser;
const writer = wabt.binary.writer;

pub const usage =
    \\Usage: wabt spec to-json [options] <file.wast>
    \\
    \\Convert a `*.wast` WebAssembly spec test into a `*.json` file
    \\and associated `*.wasm` binaries.
    \\
    \\Options:
    \\  -o, --output <file>   Output JSON file (default: output.json)
    \\
;

/// Result of in-memory wast2json conversion.
pub const WastToJsonResult = struct {
    json: []u8,
    /// Map of filename → wasm bytes for each module.
    modules: std.StringHashMapUnmanaged([]u8),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WastToJsonResult) void {
        self.allocator.free(self.json);
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.modules.deinit(self.allocator);
    }

    /// Look up a module's wasm bytes by filename.
    pub fn getModule(self: *const WastToJsonResult, filename: []const u8) ?[]const u8 {
        return self.modules.get(filename);
    }
};

/// Convert .wast source to JSON + in-memory wasm modules (no disk I/O).
pub fn wastToJsonInMemory(allocator: std.mem.Allocator, source: []const u8, base_name: []const u8) !WastToJsonResult {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var modules: std.StringHashMapUnmanaged([]u8) = .{};
    const w = &aw.writer;
    try w.writeAll("{\"commands\":[");

    var pos: usize = 0;
    var module_idx: u32 = 0;
    var first = true;
    var line_num: u32 = 1;

    while (pos < source.len) {
        pos = wast.skipWhitespaceAndComments(source, pos);
        if (pos >= source.len) break;
        if (source[pos] != '(') { pos += 1; continue; }

        line_num = 1;
        for (source[0..pos]) |c| { if (c == '\n') line_num += 1; }

        const sexpr = wast.extractSExpr(source, pos) orelse break;
        pos = sexpr.end;

        if (!first) try w.writeByte(',');
        first = false;

        const cmd = wast.classifyCommand(sexpr.text);
        switch (cmd) {
            .module => {
                const filename = try std.fmt.allocPrint(allocator, "{s}.{d}.wasm", .{ base_name, module_idx });
                if (wast.isBinaryOrQuoteModule(sexpr.text)) {
                    if (wast.isBinaryModule(sexpr.text)) {
                        const wasm_bytes = wast.decodeWastHexStrings(allocator, sexpr.text) catch {
                            try writeModuleCmd(w, line_num, filename, "binary");
                            module_idx += 1;
                            continue;
                        };
                        modules.put(allocator, filename, wasm_bytes) catch {};
                        try writeModuleCmd(w, line_num, filename, "binary");
                    } else {
                        try writeModuleCmd(w, line_num, filename, "text");
                        allocator.free(filename);
                    }
                } else {
                    var mod = Parser.parseModule(allocator, sexpr.text) catch {
                        try writeModuleCmd(w, line_num, filename, "text");
                        module_idx += 1;
                        allocator.free(filename);
                        continue;
                    };
                    defer mod.deinit();
                    const wasm_bytes = writer.writeModule(allocator, &mod) catch {
                        try writeModuleCmd(w, line_num, filename, "text");
                        module_idx += 1;
                        allocator.free(filename);
                        continue;
                    };
                    modules.put(allocator, filename, wasm_bytes) catch {};
                    try writeModuleCmd(w, line_num, filename, "binary");
                }
                module_idx += 1;
            },
            .assert_return => try writeAssertCmd(w, sexpr.text, "assert_return", line_num),
            .assert_trap => try writeAssertCmd(w, sexpr.text, "assert_trap", line_num),
            .assert_invalid, .assert_malformed, .assert_unlinkable => {
                const type_str = switch (cmd) {
                    .assert_invalid => "assert_invalid",
                    .assert_malformed => "assert_malformed",
                    .assert_unlinkable => "assert_unlinkable",
                    else => unreachable,
                };
                const filename = try std.fmt.allocPrint(allocator, "{s}.{d}.wasm", .{ base_name, module_idx });
                module_idx += 1;
                const mod_start = std.mem.indexOf(u8, sexpr.text, "(module") orelse {
                    try w.print("{{\"type\":\"{s}\",\"line\":{d},\"filename\":\"{s}\",\"module_type\":\"binary\"}}", .{ type_str, line_num, filename });
                    allocator.free(filename);
                    continue;
                };
                const mod_sexpr = wast.extractSExpr(sexpr.text, mod_start) orelse {
                    try w.print("{{\"type\":\"{s}\",\"line\":{d},\"filename\":\"{s}\",\"module_type\":\"binary\"}}", .{ type_str, line_num, filename });
                    allocator.free(filename);
                    continue;
                };
                const module_type = if (wast.isQuoteModule(mod_sexpr.text)) "text" else "binary";
                if (wast.isBinaryModule(mod_sexpr.text)) {
                    const wasm_bytes = wast.decodeWastHexStrings(allocator, mod_sexpr.text) catch {
                        try w.print("{{\"type\":\"{s}\",\"line\":{d},\"filename\":\"{s}\",\"module_type\":\"{s}\"}}", .{ type_str, line_num, filename, module_type });
                        allocator.free(filename);
                        continue;
                    };
                    modules.put(allocator, filename, wasm_bytes) catch {};
                } else if (!wast.isQuoteModule(mod_sexpr.text)) {
                    var mod2 = Parser.parseModule(allocator, mod_sexpr.text) catch {
                        try w.print("{{\"type\":\"{s}\",\"line\":{d},\"filename\":\"{s}\",\"module_type\":\"text\"}}", .{ type_str, line_num, filename });
                        allocator.free(filename);
                        continue;
                    };
                    defer mod2.deinit();
                    const wasm_bytes = writer.writeModule(allocator, &mod2) catch {
                        try w.print("{{\"type\":\"{s}\",\"line\":{d},\"filename\":\"{s}\",\"module_type\":\"text\"}}", .{ type_str, line_num, filename });
                        allocator.free(filename);
                        continue;
                    };
                    modules.put(allocator, filename, wasm_bytes) catch {};
                } else {
                    allocator.free(filename);
                }
                const text = extractQuotedStringAfterModule(sexpr.text) orelse "";
                const fn2 = try std.fmt.allocPrint(allocator, "{s}.{d}.wasm", .{ base_name, module_idx - 1 });
                defer allocator.free(fn2);
                try w.print("{{\"type\":\"{s}\",\"line\":{d},\"filename\":\"{s}\",\"text\":\"{s}\",\"module_type\":\"{s}\"}}", .{ type_str, line_num, fn2, text, module_type });
            },
            .assert_exhaustion => try writeAssertCmd(w, sexpr.text, "assert_exhaustion", line_num),
            .register => try writeRegisterCmd(w, sexpr.text, line_num),
            .invoke => try writeAssertCmd(w, sexpr.text, "action", line_num),
            .get => try writeAssertCmd(w, sexpr.text, "action", line_num),
            .assert_exception => try writeAssertCmd(w, sexpr.text, "assert_trap", line_num),
            .unknown => { first = true; }, // undo the comma
        }
    }

    try w.writeAll("]}");
    return .{
        .json = try aw.toOwnedSlice(),
        .modules = modules,
        .allocator = allocator,
    };
}

/// Convert a .wast file to JSON + .wasm files on disk (CLI mode).
pub fn wastToJson(allocator: std.mem.Allocator, io: std.Io, source: []const u8, output_dir: []const u8, base_name: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"commands\":[");

    var pos: usize = 0;
    var module_idx: u32 = 0;
    var first = true;
    var line_num: u32 = 1;

    while (pos < source.len) {
        // Count lines up to current position
        pos = wast.skipWhitespaceAndComments(source, pos);
        if (pos >= source.len) break;
        if (source[pos] != '(') { pos += 1; continue; }

        // Calculate line number
        line_num = 1;
        for (source[0..pos]) |c| { if (c == '\n') line_num += 1; }

        const sexpr = wast.extractSExpr(source, pos) orelse break;
        pos = sexpr.end;

        if (!first) try w.writeByte(',');
        first = false;

        const cmd = wast.classifyCommand(sexpr.text);
        switch (cmd) {
            .module => {
                const filename = try std.fmt.allocPrint(allocator, "{s}.{d}.wasm", .{ base_name, module_idx });
                defer allocator.free(filename);

                if (wast.isBinaryOrQuoteModule(sexpr.text)) {
                    if (wast.isBinaryModule(sexpr.text)) {
                        // Decode binary module hex strings
                        const wasm_bytes = wast.decodeWastHexStrings(allocator, sexpr.text) catch {
                            try writeSkippedModule(w, line_num, filename, "binary");
                            module_idx += 1;
                            continue;
                        };
                        defer allocator.free(wasm_bytes);
                        writeWasmFile(io, output_dir, filename, wasm_bytes) catch {};
                        try writeModuleCmd(w, line_num, filename, "binary");
                    } else {
                        try writeSkippedModule(w, line_num, filename, "text");
                    }
                } else {
                    // WAT text module — parse and convert to .wasm
                    var mod = Parser.parseModule(allocator, sexpr.text) catch {
                        try writeSkippedModule(w, line_num, filename, "text");
                        module_idx += 1;
                        continue;
                    };
                    defer mod.deinit();
                    const wasm_bytes = writer.writeModule(allocator, &mod) catch {
                        try writeSkippedModule(w, line_num, filename, "text");
                        module_idx += 1;
                        continue;
                    };
                    defer allocator.free(wasm_bytes);
                    writeWasmFile(io, output_dir, filename, wasm_bytes) catch {};
                    try writeModuleCmd(w, line_num, filename, "binary");
                }
                module_idx += 1;
            },
            .assert_return => try writeAssertCmd(w, sexpr.text, "assert_return", line_num),
            .assert_trap => try writeAssertCmd(w, sexpr.text, "assert_trap", line_num),
            .assert_invalid => try writeAssertFileCmd(w, allocator, io, sexpr.text, "assert_invalid", line_num, base_name, &module_idx, output_dir),
            .assert_malformed => try writeAssertFileCmd(w, allocator, io, sexpr.text, "assert_malformed", line_num, base_name, &module_idx, output_dir),
            .assert_unlinkable => try writeAssertFileCmd(w, allocator, io, sexpr.text, "assert_unlinkable", line_num, base_name, &module_idx, output_dir),
            .assert_exhaustion => try writeAssertCmd(w, sexpr.text, "assert_exhaustion", line_num),
            .register => try writeRegisterCmd(w, sexpr.text, line_num),
            .invoke => try writeAssertCmd(w, sexpr.text, "action", line_num),
            .get => try writeAssertCmd(w, sexpr.text, "action", line_num),
            .assert_exception => try writeAssertCmd(w, sexpr.text, "assert_trap", line_num),
            .unknown => {},
        }
    }

    try w.writeAll("]}");
    return aw.toOwnedSlice();
}

fn writeModuleCmd(w: anytype, line: u32, filename: []const u8, module_type: []const u8) !void {
    try w.print("{{\"type\":\"module\",\"line\":{d},\"filename\":\"{s}\",\"module_type\":\"{s}\"}}", .{ line, filename, module_type });
}

fn writeSkippedModule(w: anytype, line: u32, filename: []const u8, module_type: []const u8) !void {
    try w.print("{{\"type\":\"module\",\"line\":{d},\"filename\":\"{s}\",\"module_type\":\"{s}\"}}", .{ line, filename, module_type });
}

fn writeAssertCmd(w: anytype, sexpr: []const u8, cmd_type: []const u8, line: u32) !void {
    // Extract the text message (last string in the s-expression)
    const text = extractQuotedString(sexpr) orelse "";
    try w.print("{{\"type\":\"{s}\",\"line\":{d},\"text\":\"{s}\"}}", .{ cmd_type, line, text });
}

fn writeAssertFileCmd(w: anytype, allocator: std.mem.Allocator, io: std.Io, sexpr: []const u8, cmd_type: []const u8, line: u32, base_name: []const u8, module_idx: *u32, output_dir: []const u8) !void {
    const filename = try std.fmt.allocPrint(allocator, "{s}.{d}.wasm", .{ base_name, module_idx.* });
    defer allocator.free(filename);
    module_idx.* += 1;

    // Extract the embedded module text
    const mod_start = std.mem.indexOf(u8, sexpr, "(module") orelse {
        try w.print("{{\"type\":\"{s}\",\"line\":{d},\"filename\":\"{s}\",\"module_type\":\"binary\"}}", .{ cmd_type, line, filename });
        return;
    };
    const mod_sexpr = wast.extractSExpr(sexpr, mod_start) orelse {
        try w.print("{{\"type\":\"{s}\",\"line\":{d},\"filename\":\"{s}\",\"module_type\":\"binary\"}}", .{ cmd_type, line, filename });
        return;
    };

    const module_type = if (wast.isBinaryOrQuoteModule(mod_sexpr.text))
        (if (wast.isQuoteModule(mod_sexpr.text)) "text" else "binary")
    else
        "binary";

    if (wast.isBinaryModule(mod_sexpr.text)) {
        const wasm_bytes = wast.decodeWastHexStrings(allocator, mod_sexpr.text) catch {
            try w.print("{{\"type\":\"{s}\",\"line\":{d},\"filename\":\"{s}\",\"module_type\":\"{s}\"}}", .{ cmd_type, line, filename, module_type });
            return;
        };
        defer allocator.free(wasm_bytes);
        writeWasmFile(io, output_dir, filename, wasm_bytes) catch {};
    } else if (!wast.isQuoteModule(mod_sexpr.text)) {
        var mod = Parser.parseModule(allocator, mod_sexpr.text) catch {
            try w.print("{{\"type\":\"{s}\",\"line\":{d},\"filename\":\"{s}\",\"module_type\":\"text\"}}", .{ cmd_type, line, filename });
            return;
        };
        defer mod.deinit();
        const wasm_bytes = writer.writeModule(allocator, &mod) catch {
            try w.print("{{\"type\":\"{s}\",\"line\":{d},\"filename\":\"{s}\",\"module_type\":\"text\"}}", .{ cmd_type, line, filename });
            return;
        };
        defer allocator.free(wasm_bytes);
        writeWasmFile(io, output_dir, filename, wasm_bytes) catch {};
    }

    const text = extractQuotedStringAfterModule(sexpr) orelse "";
    try w.print("{{\"type\":\"{s}\",\"line\":{d},\"filename\":\"{s}\",\"text\":\"{s}\",\"module_type\":\"{s}\"}}", .{ cmd_type, line, filename, text, module_type });
}

fn writeRegisterCmd(w: anytype, sexpr: []const u8, line: u32) !void {
    const name = extractQuotedString(sexpr) orelse "";
    try w.print("{{\"type\":\"register\",\"line\":{d},\"as\":\"{s}\"}}", .{ line, name });
}

fn writeWasmFile(io: std.Io, dir: []const u8, filename: []const u8, data: []const u8) !void {
    const path = try std.fs.path.join(std.heap.page_allocator, &.{ dir, filename });
    defer std.heap.page_allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn extractQuotedString(text: []const u8) ?[]const u8 {
    // Find the last quoted string in the s-expression
    var last_start: ?usize = null;
    var last_end: ?usize = null;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '"') {
            const start = i + 1;
            i += 1;
            while (i < text.len and text[i] != '"') : (i += 1) {
                if (text[i] == '\\' and i + 1 < text.len) i += 1;
            }
            last_start = start;
            last_end = i;
        }
    }
    if (last_start) |s| {
        if (last_end) |e| return text[s..e];
    }
    return null;
}

fn extractQuotedStringAfterModule(text: []const u8) ?[]const u8 {
    // Find the last quoted string AFTER the module's closing paren
    const mod_end = findModuleEnd(text) orelse return null;
    return extractQuotedString(text[mod_end..]);
}

fn findModuleEnd(text: []const u8) ?usize {
    const start = std.mem.indexOf(u8, text, "(module") orelse return null;
    const sexpr = wast.extractSExpr(text, start) orelse return null;
    return sexpr.end;
}

pub fn run(init: std.process.Init, sub_args: []const []const u8) !void {
    if (sub_args.len > 0 and std.mem.eql(u8, sub_args[0], "help")) {
        writeStdout(init.io, usage);
        return;
    }
    const alloc = init.gpa;

    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= sub_args.len) {
                std.debug.print("error: {s} requires an argument\n", .{arg});
                std.process.exit(1);
            }
            output_file = sub_args[i];
        } else {
            input_file = arg;
        }
    }

    const in_path = input_file orelse {
        std.debug.print("error: no input file. Use `wabt spec to-json help` for usage.\n", .{});
        std.process.exit(1);
    };

    const source = std.Io.Dir.cwd().readFileAlloc(init.io, in_path, alloc, std.Io.Limit.limited(wabt.max_input_file_size)) catch |err| {
        std.debug.print("error: cannot read '{s}': {any}\n", .{ in_path, err });
        std.process.exit(1);
    };
    defer alloc.free(source);

    // Derive output dir and base name from output file path
    const out_path = output_file orelse "output.json";
    const dir = std.fs.path.dirname(out_path) orelse ".";
    const base = std.fs.path.stem(out_path);

    const json = wastToJson(alloc, init.io, source, dir, base) catch |err| {
        std.debug.print("error: {any}\n", .{err});
        std.process.exit(1);
    };
    defer alloc.free(json);

    std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = json }) catch |err| {
        std.debug.print("error: cannot write '{s}': {any}\n", .{ out_path, err });
        std.process.exit(1);
    };
}

fn writeStdout(io: std.Io, text: []const u8) void {
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io, text) catch {};
}

test "empty module produces JSON with commands array" {
    var result = try wastToJsonInMemory(std.testing.allocator, "(module)", "test");
    defer result.deinit();
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"commands\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.json, "\"module\"") != null);
}
