//! Standalone entry point for the `wasip3` bindgen generator.
//!
//! This is the host build tool behind `wasip3.bindgen` (see `build.zig`). It
//! wraps `component_bindgen.run`, which parses a WIT layout and emits the
//! canonical-ABI guest bindings for a world. Arguments mirror the old
//! `wabt component bindgen` subcommand:
//!
//!   bindgen --wit <dir> --world <name>
//!           [--impl <module> | --dispatch <module>]
//!           [--manual-return <fn>]... [-o <file>]

const std = @import("std");
const bindgen = @import("component_bindgen.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // args[0] is the executable path; forward the rest to the generator.
    try bindgen.run(init, args[1..]);
}
