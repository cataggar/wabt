const std = @import("std");
const cli = @import("wasi_cli");
const clocks = @import("wasi_clocks");
const random = @import("wasi_random");

comptime {
    cli.exportRun(run);
}

fn run() u8 {
    var buf: [128]u8 = undefined;

    const t = clocks.monotonicNow();
    cli.print(std.fmt.bufPrint(&buf, "monotonic now: {d} ns\n", .{t}) catch return 1);

    const r = random.randomU64();
    cli.print(std.fmt.bufPrint(&buf, "random u64: {d}\n", .{r}) catch return 1);

    return 0;
}
