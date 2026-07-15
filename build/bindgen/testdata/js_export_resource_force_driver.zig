const generated = @import("generated");

export fn __force_js_export_resource_analysis(a_rep: i32, b_rep: i32) u32 {
    const a: generated.ProviderAItem = .{ .handle = a_rep };
    const b: generated.ProviderBItem = .{ .handle = b_rep };
    const a_borrowed: generated.ProviderAItem.Borrowed = a.__wit_borrow();
    const b_borrowed: generated.ProviderBItem.Borrowed = b.__wit_borrow();
    const alias: generated.ProviderAItemAlias = a;
    const nested: generated.OwnedBox = .{ .value = alias };
    const many = [_]generated.ProviderAItem{a};
    const facade_item: generated.FacadeItem = .{ .handle = a_rep };
    const payload: generated.Payload = .{ .item = facade_item };

    _ = nested;
    _ = many;
    _ = payload;
    return @bitCast(a_borrowed.handle +% b_borrowed.handle);
}
