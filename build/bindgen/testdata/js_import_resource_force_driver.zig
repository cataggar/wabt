const generated = @import("generated");

export fn __force_js_import_resource_analysis(a_handle: i32, b_handle: i32) u32 {
    const a: generated.ProviderAItem = .{ .handle = a_handle };
    const a_borrowed = a.__wit_borrow();
    const b: generated.ProviderBItem = .{ .handle = b_handle };
    const b_borrowed = b.__wit_borrow();

    const constructed_a = generated.ProviderAItem.init(1);
    const constructed_b = generated.ProviderBItem.init(2);
    const doubled_b = generated.ProviderBItem.fromDouble(3);
    const replaced = a_borrowed.replaceWith(.{ .handle = a_handle });
    const inspected = a.inspect(borrowedFromA(a_handle));
    const static_item = generated.ProviderAItem.fromBorrow(a_borrowed);
    const transferred = generated.provider_a.transfer(
        .{ .handle = a_handle },
        a_borrowed,
        .{ .value = .{ .handle = a_handle } },
    );
    const provider_b_value = generated.provider_b.inspect(b_borrowed);

    const payload: generated.Payload = .{
        .item = .{ .handle = a_handle },
        .token = generated.SourceToken{ .handle = b_handle },
    };
    const routed = generated.facade.route(
        .{ .handle = a_handle },
        (generated.FacadeItem{ .handle = a_handle }).__wit_borrow(),
        payload,
    );

    _ = constructed_a;
    _ = constructed_b;
    _ = doubled_b;
    _ = replaced;
    _ = static_item;
    _ = transferred;
    _ = routed;
    return inspected +% provider_b_value +% b.value();
}

fn borrowedFromA(handle: i32) generated.ProviderAItem.Borrowed {
    return .{ .handle = handle };
}
