const std = @import("std");
const wabt = @import("wabt");

pub fn main() void {
    // Fuzz entry point: reads wasm binary, converts to wat
    _ = wabt;
}
