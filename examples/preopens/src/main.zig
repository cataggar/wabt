const std = @import("std");
const cli = @import("wasi_cli");
const fs = @import("wasi_filesystem");

comptime {
    cli.exportRun(run);
}

fn run() u8 {
    const dirs = fs.getDirectories();
    if (dirs.len() == 0) {
        cli.print("no preopened directories\n");
        return 0;
    }
    var buf: [512]u8 = undefined;
    var i: usize = 0;
    while (i < dirs.len()) : (i += 1) {
        const d = dirs.get(i);
        cli.print(std.fmt.bufPrint(&buf, "preopen: {s}\n", .{d.path}) catch return 1);
    }
    return 0;
}
