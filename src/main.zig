const std = @import("std");
const cli = @import("wasi_cli");

comptime {
    cli.run(run);
}

fn run() u8 {
    const args = cli.arguments();
    const first = if (args.len > 1) args[1] else "";
    if (std.mem.eql(u8, first, "Johnny")) {
        cli.println("Number Five is alive!");
        return 0;
    }
    cli.println("Life is not a malfunction.");
    return 5;
}
