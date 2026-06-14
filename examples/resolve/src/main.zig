const std = @import("std");
const cli = @import("wasi_cli");
const sockets = @import("wasi_sockets");

comptime {
    cli.exportRun(run);
}

fn run() u8 {
    const name = "localhost";
    var buf: [128]u8 = undefined;

    const net = sockets.instanceNetwork();
    const stream = sockets.resolveAddresses(net, name) catch {
        cli.print("resolve-addresses failed\n");
        return 1;
    };
    const pollable = stream.subscribe();

    var count: usize = 0;
    while (true) {
        switch (stream.next()) {
            .address => |addr| {
                count += 1;
                switch (addr) {
                    .ipv4 => |v| cli.print(std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}\n", .{ v[0], v[1], v[2], v[3] }) catch return 1),
                    .ipv6 => |v| cli.print(std.fmt.bufPrint(&buf, "{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}\n", .{ v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7] }) catch return 1),
                }
            },
            .would_block => pollable.block(),
            .end => break,
            .err => |ec| {
                cli.print(std.fmt.bufPrint(&buf, "resolve error-code {d}\n", .{ec}) catch return 1);
                return 1;
            },
        }
    }

    cli.print(std.fmt.bufPrint(&buf, "resolved {d} address(es) for {s}\n", .{ count, name }) catch return 1);
    return 0;
}
