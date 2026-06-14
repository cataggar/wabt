const cli = @import("wasi_cli");

comptime {
    cli.exportRun(run);
}

fn run() u8 {
    cli.println("Life is not a malfunction.");
    return 0;
}
