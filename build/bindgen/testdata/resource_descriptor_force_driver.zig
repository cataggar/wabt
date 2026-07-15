const generated = @import("generated");
const wit_types = @import("wit_types");

const A = generated.ProviderAItem;
const B = generated.ProviderBItem;
const AAlias = generated.ProviderAItemAlias;
const BAlias = generated.ProviderBItemAlias;
const RenamedA = generated.RenamedItem;
const NestedHolder = generated.NestedProviderNestedHolder;
const CollisionHolder = generated.CollisionProviderNestedHolder;
const SourceValue = generated.SourceValue;
const FinalBox = generated.FinalBox;
const SourceThing = generated.RecordSourceThing;

comptime {
    const a = wit_types.resourceInfo(A) orelse @compileError("missing provider-a resource metadata");
    const b = wit_types.resourceInfo(B) orelse @compileError("missing provider-b resource metadata");
    const a_alias = wit_types.resourceInfo(AAlias) orelse @compileError("missing provider-a alias metadata");
    const renamed_a = wit_types.resourceInfo(RenamedA) orelse @compileError("missing renamed provider-a metadata");
    const a_borrow = wit_types.resourceInfo(wit_types.Borrow(AAlias)) orelse @compileError("missing borrow metadata");

    if (!a.descriptor.eql(a_alias.descriptor) or
        !a.descriptor.eql(renamed_a.descriptor))
    {
        @compileError("resource alias changed canonical identity");
    }
    if (a.descriptor.eql(b.descriptor))
        @compileError("same-named resources from different providers collided");
    if (a.ownership != .own or a_borrow.ownership != .borrow)
        @compileError("resource ownership mode was not preserved");
    if (wit_types.flatCount(wit_types.Own(AAlias)) != 1 or
        wit_types.flatCount(wit_types.Borrow(AAlias)) != 1)
    {
        @compileError("resource handle did not flatten to one core slot");
    }
}

export fn __force_resource_analysis(a_handle: i32, b_handle: i32) void {
    const a_owned: wit_types.Own(AAlias) = .{ .handle = a_handle };
    const a_borrowed: wit_types.Borrow(AAlias) = a_owned.__wit_borrow();
    const b_owned: wit_types.Own(BAlias) = .{ .handle = b_handle };
    const b_borrowed: wit_types.Borrow(BAlias) = b_owned.__wit_borrow();
    const source_value: wit_types.Own(SourceValue) = .{ .handle = b_handle };
    const nested_holder: wit_types.Own(NestedHolder) = .{ .handle = a_handle };
    const collision_holder: wit_types.Own(CollisionHolder) = .{ .handle = b_handle };

    _ = generated.provider_a.transfer(a_owned);
    _ = generated.provider_a.inspect(a_borrowed);
    _ = generated.provider_b.transfer(b_owned);
    _ = generated.provider_b.inspect(b_borrowed);
    _ = generated.facade.inspectRenamed(.{ .handle = a_handle });

    const constructed = A.init();
    _ = constructed.__wit_borrow().inspectMethod();
    _ = constructed.inspectMethod();
    _ = nested_holder.__wit_borrow().inspectOther(source_value.__wit_borrow());
    nested_holder.__wit_borrow().receive(.{ .handle = b_handle });
    _ = collision_holder;

    const box: FinalBox = .{ .value = SourceThing{ .value = 1 } };
    _ = box;
}
