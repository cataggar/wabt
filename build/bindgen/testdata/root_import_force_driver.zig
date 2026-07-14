const generated = @import("generated");

export fn __force_root_import_analysis(value: u32) u32 {
    generated.notify("semantic compile");
    const point: generated.ImportedPoint = .{ .x = value, .y = value +% 1 };
    const record: generated.RootRecord = .{ .label = "semantic compile", .point = point };
    const reshaped = generated.reshape(record);
    const choice: generated.RootChoiceAlias = .{ .item = reshaped };
    const flipped = generated.flipChoice(choice);
    const translated = generated.translate(point);
    return generated.addOne(value) +% generated.host.twice(value) +%
        translated.x +% switch (flipped) {
        .empty => 0,
        .item => |r| r.point.y,
    };
}
