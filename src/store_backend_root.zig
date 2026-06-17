//! Storage component root: force-link the `wabt component bindgen`-generated
//! `store` export shells (which call `store_impl`). The shells are top-level
//! `export fn`s in `store_bindings`; referencing the module roots them.

comptime {
    _ = @import("store_bindings");
}
