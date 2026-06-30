//! `wasi_cli` — ergonomic guest-side helper for `wasi:cli@0.3.0` command
//! components in pure Zig (WASI 0.3 / Component-Model async).
//!
//! The canonical-ABI client wrappers are **generated** by
//! `wabt component bindgen` (see `wasi_cli_bindings.zig`); this module is the
//! thin ergonomic layer over them — driving the `stream<u8>` / `future` channels
//! and exposing plain Zig functions. The command entry point is
//! `wasi:cli/run@0.3.0#run`, an **async** `func() -> result`; stdout/stderr are
//! written through `write-via-stream(stream<u8>) -> future<result<_, error-code>>`
//! (there is no `wasi:io` in 0.3 — `stream<u8>` is a canonical-ABI primitive).
//!
//! ## Usage
//!
//! ```zig
//! const cli = @import("wasi_cli");
//! comptime { cli.run(run); }
//! fn run() u8 {
//!     cli.println("hello from a wasi 0.3 zig component");
//!     for (cli.arguments()) |a| cli.println(a);
//!     return 0; // 0 -> result::ok, nonzero -> exit code via exit-with-code
//! }
//! ```

const b = @import("wasi_cli_bindings");
const wit_types = @import("wit_types");
const wit_async = @import("wit_async");

const ByteStream = wit_types.Stream(u8);

/// Canonical `stream`/`future` status: blocked (operation pending).
const BLOCKED: i32 = @bitCast(@as(u32, 0xffff_ffff));

/// Re-exported generated types.
pub const ErrorCode = b.ErrorCode;
pub const TerminalInput = b.TerminalInput;
pub const TerminalOutput = b.TerminalOutput;

// ── async helpers (drive the generated stream/future channels) ──────

/// Block on `waitable` until it makes progress; returns the event payload
/// (`waitable-set.wait` writes `[waitable, payload]` to the ret-area).
fn waitCode(waitable: i32) u32 {
    const set = wit_async.WaitableSet.create();
    set.add(waitable);
    _ = set.waitOne();
    const code: u32 = wit_types.abi.retWords()[1];
    set.drop();
    return code;
}

/// Write all of `bytes` to a stream's writable end, waiting on a blocked write.
fn writeStreamAll(s: ByteStream, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const status = s.write(bytes[off..]);
        const code: u32 = if (status == BLOCKED) waitCode(s.handle) else @bitCast(status);
        const n: usize = code >> 4;
        if (n == 0) break;
        off += n;
    }
}

/// Drive a `future<result<_, error-code>>` to completion (the value is ignored)
/// and drop its readable end. `fut` is the generated channel type.
fn awaitFuture(fut: anytype) void {
    var buf: [16]u8 align(8) = undefined;
    const status = fut.readInto(&buf);
    if (status == BLOCKED) _ = waitCode(fut.handle);
    fut.dropReadable();
}

// ── stdout / stderr ─────────────────────────────────────────────────

/// Write `bytes` to stdout, flushing fully before returning.
pub fn print(bytes: []const u8) void {
    if (bytes.len == 0) return;
    const ends = ByteStream.new();
    const fut = b.stdout.writeViaStream(ends.readable); // host drains the readable end
    writeStreamAll(ends.writable, bytes);
    ends.writable.dropWritable(); // EOF
    awaitFuture(fut);
}

/// Write `bytes` followed by a newline to stdout.
pub fn println(bytes: []const u8) void {
    print(bytes);
    print("\n");
}

/// Write `bytes` to stderr, flushing fully before returning.
pub fn eprint(bytes: []const u8) void {
    if (bytes.len == 0) return;
    const ends = ByteStream.new();
    const fut = b.stderr.writeViaStream(ends.readable);
    writeStreamAll(ends.writable, bytes);
    ends.writable.dropWritable();
    awaitFuture(fut);
}

/// Write `bytes` followed by a newline to stderr.
pub fn eprintln(bytes: []const u8) void {
    eprint(bytes);
    eprint("\n");
}

// ── stdin ───────────────────────────────────────────────────────────

/// Read up to `buf.len` bytes from stdin into `buf`, waiting on blocked reads.
/// Returns the prefix that was read (EOF when shorter than `buf`).
pub fn readStdin(buf: []u8) []const u8 {
    const tup = b.stdin.readViaStream();
    const stream: ByteStream = tup[0];
    const fut = tup[1]; // future<result<_, error-code>> signalling read results
    var len: usize = 0;
    while (len < buf.len) {
        const status = stream.read(buf[len..]);
        const code: u32 = if (status == BLOCKED) waitCode(stream.handle) else @bitCast(status);
        len += @as(usize, code >> 4);
        if (code & 0xf != 0) break; // closed / EOF
        if (code >> 4 == 0) break; // no progress
    }
    stream.dropReadable();
    fut.dropReadable();
    return buf[0..len];
}

// ── environment ─────────────────────────────────────────────────────

/// The program arguments (borrows the scratch arena; copy out to retain).
pub fn arguments() []const []const u8 {
    return b.environment.getArguments();
}

/// The POSIX-style environment as `(name, value)` pairs (borrows the scratch
/// arena; copy out to retain).
pub fn environment() []const wit_types.Tuple(.{ []const u8, []const u8 }) {
    return b.environment.getEnvironment();
}

/// The initial working directory, if any (borrows the scratch arena).
pub fn initialCwd() ?[]const u8 {
    return b.environment.getInitialCwd();
}

// ── exit ────────────────────────────────────────────────────────────

/// Exit with `code` (0 = success). Does not return.
pub fn exit(code: u8) void {
    b.exit.exitWithCode(code);
}

/// Exit reporting `result::ok` (`true`) or `result::err` (`false`).
pub fn exitResult(ok: bool) void {
    b.exit.exit(if (ok) .{ .ok = {} } else .{ .err = {} });
}

// ── terminal ────────────────────────────────────────────────────────

/// Whether stdout is attached to a terminal.
pub fn isStdoutTerminal() bool {
    if (b.terminal_stdout.getTerminalStdout()) |t| {
        t.deinit();
        return true;
    }
    return false;
}

/// Whether stderr is attached to a terminal.
pub fn isStderrTerminal() bool {
    if (b.terminal_stderr.getTerminalStderr()) |t| {
        t.deinit();
        return true;
    }
    return false;
}

// ── run export ──────────────────────────────────────────────────────

/// `task.return` for `wasi:cli/run@0.3.0#run`'s `result` (bare ok/err → one i32
/// discriminant).
const run_task = struct {
    extern "[task-return]wasi:cli/run@0.3.0#run" fn @"task-return"(result_disc: i32) void;
};

/// Emit the async `wasi:cli/run@0.3.0#run` export that dispatches to `impl`.
/// `impl` returns a `u8` that is treated as the process exit code: `0` reports
/// `result::ok` via `task.return`, while any nonzero value is propagated
/// exactly through `exit-with-code` (which terminates and does not return).
pub fn run(comptime impl: fn () u8) void {
    const Wrapper = struct {
        fn run() callconv(.c) void {
            wit_types.abi.resetScratch();
            const code = impl();
            if (code == 0) {
                run_task.@"task-return"(0);
            } else {
                b.exit.exitWithCode(code); // conveys the exact code; terminates
            }
        }
    };
    @export(&Wrapper.run, .{ .name = "wasi:cli/run@0.3.0#run" });
}
