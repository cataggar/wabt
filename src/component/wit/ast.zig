//! WIT AST.
//!
//! The data model the parser produces. Intentionally a thin
//! reflection of the WIT text grammar — semantic resolution
//! (type-name → index, dependency ordering, equivalence checks) is
//! the job of `resolve.zig` (Phase B follow-up).
//!
//! All slices and strings borrow from the original source text or
//! arena-allocated copies; the parser uses an arena allocator
//! throughout so callers don't have to manage piecewise frees.

const std = @import("std");

pub const PackageId = struct {
    /// Namespace (left of the colon: `docs:` → `docs`).
    namespace: []const u8,
    /// Name (right of the colon: `docs:adder` → `adder`).
    name: []const u8,
    /// Optional `@<semver>` suffix as raw text (e.g. `0.1.0`).
    version: ?[]const u8 = null,
};

pub const InterfaceRef = struct {
    /// Either a simple identifier (`add`) referring to an in-package
    /// interface, or a fully-qualified ref (`docs:adder/add@0.1.0`).
    /// In the qualified form, fields are populated; in the simple
    /// form, only `name` is set.
    package: ?PackageId = null,
    /// Interface name within the package.
    name: []const u8,
};

pub const Type = union(enum) {
    bool,
    u8,
    u16,
    u32,
    u64,
    s8,
    s16,
    s32,
    s64,
    f32,
    f64,
    char,
    string,
    list: *const Type,
    option: *const Type,
    result: struct {
        ok: ?*const Type,
        err: ?*const Type,
    },
    tuple: []const Type,
    /// `borrow<R>` handle type — R is a resource declared elsewhere
    /// in scope. Resolved by the encoder when emitting the body.
    borrow: []const u8,
    /// `own<R>` handle type — explicit ownership transfer. Bare
    /// references to a resource by name (`R` without `own<>` /
    /// `borrow<>`) also lower to own-handles; the encoder is
    /// responsible for that distinction based on the resolution of
    /// `name`.
    own: []const u8,
    /// Reference to a type defined elsewhere in the same scope by
    /// name. Resolved by `resolve.zig`.
    name: []const u8,
};

pub const Param = struct {
    name: []const u8,
    type: Type,
};

pub const Func = struct {
    params: []const Param,
    /// Result is either a single anonymous type, no result, or named
    /// results (legacy form, still accepted by the spec but no
    /// longer emitted).
    result: ?Type,
};

pub const Field = struct {
    docs: []const u8 = "",
    name: []const u8,
    type: Type,
};

pub const Case = struct {
    docs: []const u8 = "",
    name: []const u8,
    type: ?Type,
};

pub const TypeDefKind = union(enum) {
    /// `type foo = bar` — alias.
    alias: Type,
    /// `record foo { … }`.
    record: []const Field,
    /// `variant foo { … }`.
    variant: []const Case,
    /// `enum foo { a, b, c }`.
    @"enum": []const []const u8,
    /// `flags foo { read, write }`.
    flags: []const []const u8,
    /// `resource foo { method-decls }`.
    ///
    /// The body lists methods, static methods, and an optional
    /// constructor. The encoder synthesizes the canonical
    /// `[method]R.M`, `[static]R.M`, `[constructor]R`, and
    /// `[resource-drop]R` external names; the implicit
    /// `self: borrow<R>` (methods) and `-> own<R>` (constructor)
    /// are not present in the AST.
    resource: []const ResourceMethod,
};

pub const ResourceMethodKind = enum {
    method,
    static,
    constructor,
};

pub const ResourceMethod = struct {
    docs: []const u8 = "",
    kind: ResourceMethodKind,
    /// Method-local name. Empty for `constructor`.
    name: []const u8 = "",
    func: Func,
};

pub const TypeDef = struct {
    docs: []const u8 = "",
    name: []const u8,
    kind: TypeDefKind,
};

pub const InterfaceItem = union(enum) {
    type: TypeDef,
    /// `name: func(...) -> ...`.
    func: struct {
        docs: []const u8 = "",
        name: []const u8,
        func: Func,
    },
    /// `use pkg:name/iface.{a, b};`.
    use: Use,
};

pub const Use = struct {
    from: InterfaceRef,
    /// Imported names, optionally renamed via `as`.
    names: []const UseName,
};

pub const UseName = struct {
    name: []const u8,
    rename: ?[]const u8 = null,
};

pub const Interface = struct {
    docs: []const u8 = "",
    name: []const u8,
    items: []const InterfaceItem,
};

pub const WorldItem = union(enum) {
    /// `import|export <iface-ref>;` or `import|export name: func(...) -> ...;`.
    import: WorldExtern,
    @"export": WorldExtern,
    use: Use,
    type: TypeDef,
    include: Include,
};

pub const WorldExtern = union(enum) {
    /// `import name: func(...) -> ...;` — a named function import.
    named_func: struct {
        docs: []const u8 = "",
        name: []const u8,
        func: Func,
    },
    /// `import name: interface { … };` — an inline-interface import.
    named_interface: struct {
        docs: []const u8 = "",
        name: []const u8,
        items: []const InterfaceItem,
    },
    /// `import pkg:name/iface@semver;` — an interface ref import.
    interface_ref: struct {
        docs: []const u8 = "",
        ref: InterfaceRef,
    },
};

pub const Include = struct {
    docs: []const u8 = "",
    target: InterfaceRef,
    /// Optional `with { name as renamed, ... }` mappings.
    with: []const UseName = &.{},
};

pub const World = struct {
    docs: []const u8 = "",
    name: []const u8,
    items: []const WorldItem,
};

pub const TopLevelItem = union(enum) {
    interface: Interface,
    world: World,
    /// `use pkg:name/iface.{a, b};` at the package level.
    use: Use,
};

pub const Document = struct {
    /// Optional `package <id>;` declaration. The spec allows files
    /// without a `package` decl when they're part of a multi-file
    /// package whose name is declared in some other file.
    package: ?PackageId = null,
    items: []const TopLevelItem,
};
