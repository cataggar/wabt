const generated = @import("generated");

export fn __force_root_import_analysis(value: u32) u32 {
    generated.notify("semantic compile");
    return generated.addOne(value) +% generated.host.twice(value);
}
