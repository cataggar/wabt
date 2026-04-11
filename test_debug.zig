const wabt = @import(\
wabt\); const std = @import(\std\); pub fn main() !void { const alloc = std.heap.page_allocator; const data = try std.fs.cwd().readFileAlloc(alloc, std.os.argv[1], 50*1024*1024); var m = try wabt.text.Parser.parseModule(alloc, data); defer m.deinit(); for (m.funcs.items[m.num_func_imports..], 0..) |func, fi| { if (fi >= 18 and fi <= 22) std.debug.print(\func[
d
]
name=
s
type_idx=
d
\n\, .{ fi, func.name orelse \?\, func.decl.type_var.index }); } }
