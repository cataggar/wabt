const std = @import("std");
const cli = @import("wasi_cli");
const nn = @import("wasi_nn");

comptime {
    cli.exportRun(run);
}

fn run() u8 {
    var buf: [128]u8 = undefined;
    const dims = [_]u32{ 2, 2 };
    const data = [_]u8{ 1, 2, 3, 4 };
    const t = nn.Tensor.init(&dims, .uint8, &data);
    const d = t.dimensions();
    cli.print(std.fmt.bufPrint(&buf, "tensor rank {d}, {d} data bytes\n", .{ d.len, t.data().len }) catch return 1);
    t.drop();
    return 0;
}
