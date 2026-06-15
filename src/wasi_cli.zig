//! `wasi_cli` — guest-side helper for `wasi:cli@0.3.0` command components
//! in pure Zig (WASI 0.3 / Component-Model async).
//!
//! In 0.3 the command entry point is `wasi:cli/run@0.3.0#run`, an
//! **async** `func() -> result`, and stdout is written through
//! `wasi:cli/stdout@0.3.0.write-via-stream(stream<u8>)` — there is no
//! `wasi:io` output-stream resource anymore; the `stream<u8>` is a
//! canonical-ABI primitive provided by `cm_async`.
//!
//! ## Usage
//!
//! ```zig
//! const cli = @import("wasi_cli");
//! comptime { cli.exportRun(run); }
//! fn run() u8 {
//!     cli.println("hello from a wasi 0.3 zig component");
//!     return 0; // 0 -> result::ok, nonzero -> result::err
//! }
//! ```
//!
//! > **Status: provisional / design-stage** (see `cm_async`). The async
//! > `run` lift and the `write-via-stream` flow below define the intended
//! > shape; they build into a runnable component only once wabt grows P3
//! > generation (cataggar/wabt#263), validated on wasmtime 46.

const async_io = @import("cm_async");

// ── Host imports (canonical-ABI lowered signatures) ────────────────

/// `wasi:cli/stdout@0.3.0.write-via-stream(data: stream<u8>)
///   -> future<result<_, error-code>>`. `stream<u8>` lowers to the
/// readable-end handle (i32); the returned `future` lowers to a handle.
extern "wasi:cli/stdout@0.3.0" fn @"write-via-stream"(data: i32) i32;

/// `task.return` for `wasi:cli/run@0.3.0#run`'s `result` (bare ok/err →
/// one i32 discriminant). Reports the async export's result to the host.
const run_task = struct {
    extern "[task-return]wasi:cli/run@0.3.0#run" fn @"task-return"(result_disc: i32) void;
};

// ── Public API ──────────────────────────────────────────────────────

/// Write `bytes` to stdout (best-effort). Creates a `stream<u8>`, hands
/// the readable end to `write-via-stream`, writes `bytes` to the writable
/// end, then drops it (signalling end-of-stream).
pub fn print(bytes: []const u8) void {
    if (bytes.len == 0) return;
    const ends = async_io.ByteStream.new();
    // Host takes the readable end and returns a `future<result>`; this
    // first cut does not await it (best-effort write).
    _ = @"write-via-stream"(ends.readable);
    const writable = async_io.ByteStream{ .handle = ends.writable };
    _ = writable.write(bytes);
    writable.dropWritable();
}

/// Write `bytes` followed by a newline.
pub fn println(bytes: []const u8) void {
    print(bytes);
    print("\n");
}

// ── comptime export wiring ─────────────────────────────────────────

/// Emit the async `wasi:cli/run@0.3.0#run` export that dispatches to
/// `entry`. `entry` returns a `u8` (0 → `result::ok`, nonzero →
/// `result::err`); the wrapper reports it via `task.return`.
pub fn exportRun(comptime entry: fn () u8) void {
    const Wrapper = struct {
        fn run() callconv(.c) i32 {
            const code = entry();
            run_task.@"task-return"(if (code == 0) 0 else 1);
            // Async-lift "completed synchronously" status (provisional —
            // finalized with wabt P3 generation).
            return 0;
        }
    };
    @export(&Wrapper.run, .{ .name = "wasi:cli/run@0.3.0#run" });
}
