import sys

with open('src/text/Parser.zig', 'rb') as f:
    data = f.read()

old = b"""else if (self.peek().kind == .kw_data) {\r
                // Inline (data "...") \xe2\x80\x94 skip for now\r
                self.lexer.pos = sp;\r
                self.peeked = spk;\r
                break;\r
            } else {\r
                self.lexer.pos = sp;\r
                self.peeked = spk;\r
                break;\r
            }\r
        }\r
\r
        const initial = try self.parseU32();\r
        var limits = types.Limits{ .initial = initial };\r
        if (self.peek().kind == .integer) {\r
            limits.max = try self.parseU32();\r
            limits.has_max = true;\r
        }\r
        try module.memories.append(self.allocator, .{\r
            .type = .{ .limits = limits },\r
        });\r
    }"""

new = b"""else if (self.peek().kind == .kw_data) {\r
                // Inline (data "...") abbreviation\r
                _ = self.advance(); // consume 'data'\r
                var data_parts: std.ArrayListUnmanaged(u8) = .{};\r
                defer data_parts.deinit(self.allocator);\r
                while (self.peek().kind == .string) {\r
                    const tok = self.advance();\r
                    const stripped = stripQuotes(tok.text);\r
                    decodeWatStringInto(stripped, &data_parts, self.allocator);\r
                }\r
                try self.expect(.r_paren); // close (data ...)\r
                const data_len: u64 = @intCast(data_parts.items.len);\r
                const page_size: u64 = 65536;\r
                const pages: u64 = if (data_len == 0) 1 else (data_len + page_size - 1) / page_size;\r
                try module.memories.append(self.allocator, .{\r
                    .type = .{ .limits = .{ .initial = pages, .max = pages, .has_max = true } },\r
                });\r
                // Create active data segment at offset 0\r
                var seg = Mod.DataSegment{};\r
                seg.kind = .active;\r
                seg.memory_var = .{ .index = mem_idx };\r
                const ob = self.allocator.alloc(u8, 2) catch return error.OutOfMemory;\r
                ob[0] = 0x41; // i32.const\r
                ob[1] = 0x00; // 0\r
                seg.offset_expr_bytes = ob;\r
                seg.owns_offset_expr_bytes = true;\r
                if (data_parts.items.len > 0) {\r
                    seg.data = data_parts.toOwnedSlice(self.allocator) catch &.{};\r
                    seg.owns_data = true;\r
                }\r
                try module.data_segments.append(self.allocator, seg);\r
                return;\r
            } else if (self.peek().kind == .kw_import) {\r
                // Inline (import "mod" "name") abbreviation for memory\r
                _ = self.advance(); // consume 'import'\r
                const mod_name = self.parseName(self.advance().text);\r
                const field_name = self.parseName(self.advance().text);\r
                try self.expect(.r_paren); // close (import ...)\r
                const initial = try self.parseU32();\r
                var limits = types.Limits{ .initial = initial };\r
                if (self.peek().kind == .integer) {\r
                    limits.max = try self.parseU32();\r
                    limits.has_max = true;\r
                }\r
                try module.memories.append(self.allocator, .{\r
                    .type = .{ .limits = limits },\r
                    .is_import = true,\r
                });\r
                module.num_memory_imports += 1;\r
                var import = Mod.Import{\r
                    .module_name = mod_name,\r
                    .field_name = field_name,\r
                    .kind = .memory,\r
                };\r
                import.memory = .{ .limits = limits };\r
                try module.imports.append(self.allocator, import);\r
                return;\r
            } else {\r
                self.lexer.pos = sp;\r
                self.peeked = spk;\r
                break;\r
            }\r
        }\r
\r
        const initial = try self.parseU32();\r
        var limits = types.Limits{ .initial = initial };\r
        if (self.peek().kind == .integer) {\r
            limits.max = try self.parseU32();\r
            limits.has_max = true;\r
        }\r
        try module.memories.append(self.allocator, .{\r
            .type = .{ .limits = limits },\r
        });\r
    }"""

if old not in data:
    print("ERROR: old text not found!")
    sys.exit(1)

data = data.replace(old, new, 1)
with open('src/text/Parser.zig', 'wb') as f:
    f.write(data)
print("SUCCESS: replacement done")
