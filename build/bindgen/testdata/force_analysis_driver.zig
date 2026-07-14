//! Compile-check driver for the `gen-regress` build step (see `build.zig`).
//!
//! `zig build-obj` alone does *not* semantically analyze a `pub fn`'s body
//! unless something actually references it -- an object file with no
//! `export`s or calls into `generated.types.*` would happily "compile" even
//! if every function body were nonsense, since Zig only analyzes what's
//! reachable from a GC-root (an `export fn`, in this case). Each call below
//! forces full body analysis of the corresponding generated wrapper --
//! exactly the code `lowerParams`/`lowerOptionParam`/`lowerAggregateParam`
//! emit -- so a regression like `@intCast(v)` on a `wit_types.Char` struct
//! (option<char>) or an internal `error.UnsupportedWitType` bailout
//! (option<enum>/option<flags>) is a genuine `zig build gen-regress` compile
//! failure, not just a missing string in a generation-time assertion.
//!
//! `null` is a valid argument for every case here (they're all bare
//! `option<T>` params, directly or as one tuple/record field) so this needs
//! no fixture data beyond the WIT world itself. The `imp.@"…"` extern calls
//! the generated bodies make are never linked (this only ever reaches
//! `zig build-obj`, an object with no linking), so it's fine that they name
//! component-model imports with no host to resolve them.

const generated = @import("generated");
const types = generated.types;

export fn __force_analysis() void {
    _ = types.identityOptChar(null);
    _ = types.toggleOptColor(null);
    _ = types.toggleOptPerms(null);
    _ = types.classifyOptShape(null);
    _ = types.mixOptScalarAndColor(null, null);
    _ = types.optAliasChar(null);
    _ = types.optAliasColor(null);
    _ = types.optSingleFieldRecord(null);
    _ = types.optSingleElemTuple(null);
}
