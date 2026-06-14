//! Build-only smoke target: imports the binding modules that have no
//! runnable component example (`wasi_http`, `wasi_keyvalue`, `wasi_tls`)
//! and references representative functions so `zig build examples`
//! type-checks them. It is compiled to a core wasm but not wrapped into a
//! component and not run.

const http = @import("wasi_http");
const kv = @import("wasi_keyvalue");
const tls = @import("wasi_tls");
const io = @import("wasi_io");

comptime {
    // Instantiating the reactor wrapper type-checks the wasi_http guts.
    http.exportIncomingHandler(handle);
}

fn handle(req: http.Request, res: *http.Responder) void {
    _ = req;
    _ = res;
}

// Exported so the body — and the keyvalue / tls calls — are analyzed.
export fn _smoke() callconv(.c) void {
    if (kv.open("bucket")) |b| {
        _ = b.get("k");
        _ = b.set("k", "v");
        _ = b.exists("k");
        _ = b.delete("k");
    }

    const hs = tls.ClientHandshake.init(
        "example.com",
        io.InputStream{ .handle = 0 },
        io.OutputStream{ .handle = 0 },
    );
    const fut = hs.finish();
    const p = fut.subscribe();
    p.block();
    fut.drop();
}
