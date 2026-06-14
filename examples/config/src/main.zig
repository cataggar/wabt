const std = @import("std");
const cli = @import("wasi_cli");
const config = @import("wasi_config");

comptime {
    cli.exportRun(run);
}

fn run() u8 {
    var buf: [256]u8 = undefined;

    if (config.get("greeting") catch {
        cli.print("config error\n");
        return 1;
    }) |val| {
        cli.print(std.fmt.bufPrint(&buf, "greeting = {s}\n", .{val}) catch return 1);
    } else {
        cli.print("greeting not set\n");
    }

    const all = config.getAll() catch {
        cli.print("config error\n");
        return 1;
    };
    var i: usize = 0;
    while (i < all.len()) : (i += 1) {
        const e = all.get(i);
        cli.print(std.fmt.bufPrint(&buf, "{s} = {s}\n", .{ e.key, e.value }) catch return 1);
    }
    return 0;
}
