//! Native Wasm payload classification and metadata extraction.
//!
//! This module intentionally stops before OCI config/manifest construction. It
//! validates core modules with WABT's reader and validator, strictly decodes
//! the supported Component Model subset, and exposes only metadata that can be
//! stated without rewriting or guessing from a filename.

const std = @import("std");
const core_reader = @import("../binary/reader.zig");
const Validator = @import("../Validator.zig");
const Feature = @import("../Feature.zig");
const component_loader = @import("../component/loader.zig");
const component_types = @import("../component/types.zig");

pub const WasmKind = enum {
    core_module,
    component,
};

/// Wasm-v0's historical `os` profile label, when native parsing proves it.
pub const WasmV0Target = enum {
    wasip1,
    wasip2,

    pub fn string(self: WasmV0Target) []const u8 {
        return switch (self) {
            .wasip1 => "wasip1",
            .wasip2 => "wasip2",
        };
    }
};

pub const ExternKind = enum {
    module,
    func,
    value,
    type,
    component,
    instance,
};

pub const Extern = struct {
    /// Complete metadata name. A retained structured `versionsuffix` is
    /// appended to its canonical interface name.
    name: []const u8,
    kind: ExternKind,
};

pub const ComponentMetadata = struct {
    imports: []Extern,
    exports: []Extern,
    /// The native loader cannot prove one unique WIT target world.
    target: ?[]const u8 = null,

    fn deinit(self: *ComponentMetadata, allocator: std.mem.Allocator) void {
        freeExterns(allocator, self.imports);
        freeExterns(allocator, self.exports);
        self.* = undefined;
    }
};

pub const PayloadMetadata = struct {
    /// The caller's original bytes, borrowed unchanged.
    payload: []const u8,
    kind: WasmKind,
    wasm_v0_target: ?WasmV0Target,
    component: ?ComponentMetadata,

    pub fn deinit(self: *PayloadMetadata, allocator: std.mem.Allocator) void {
        if (self.component) |*component| component.deinit(allocator);
        self.* = undefined;
    }

    /// Return the Wasm-v0 profile label only when it is supported by native
    /// evidence. A generic core module is not automatically WASI Preview 1.
    pub fn wasmV0Os(self: PayloadMetadata) ValidationError![]const u8 {
        return (self.wasm_v0_target orelse return error.UnsupportedCoreTarget).string();
    }
};

pub const ValidationError = error{
    InvalidWasm,
    UnsupportedCoreFeature,
    UnsupportedComponentSection,
    UnsupportedComponentShape,
    BinaryWitUnsupported,
    UnsupportedExternKind,
    UnsupportedCoreTarget,
    DuplicateExternName,
    DuplicateAttribute,
    InvalidExternName,
    InvalidVersionedName,
    OutOfMemory,
};

/// Fully validate enough of a payload to prepare truthful Wasm-v0 metadata.
///
/// Core modules receive full WABT validation with every implemented feature.
/// Components receive strict structural decoding, recursive validation of
/// nested modules/components, and conservative shape checks. WABT does not yet
/// provide a complete Component Model semantic validator.
pub fn validatePayload(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ValidationError!PayloadMetadata {
    const kind = try detectKind(bytes);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    return switch (kind) {
        .core_module => .{
            .payload = bytes,
            .kind = .core_module,
            .wasm_v0_target = try validateCoreModule(scratch, bytes),
            .component = null,
        },
        .component => blk: {
            const component = component_loader.loadStrict(bytes, scratch) catch |err| {
                return mapComponentLoadError(err);
            };
            try validateComponentTree(scratch, &component);
            try validateComponentShape(&component);

            const imports = try extractImports(allocator, component.imports);
            errdefer freeExterns(allocator, imports);
            const exports = try extractExports(allocator, component.exports);
            errdefer freeExterns(allocator, exports);

            break :blk .{
                .payload = bytes,
                .kind = .component,
                .wasm_v0_target = .wasip2,
                .component = .{
                    .imports = imports,
                    .exports = exports,
                    .target = null,
                },
            };
        },
    };
}

/// Classify a payload only after the corresponding native parser accepts it.
pub fn classifyPayload(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ValidationError!WasmKind {
    var metadata = try validatePayload(allocator, bytes);
    defer metadata.deinit(allocator);
    return metadata.kind;
}

fn detectKind(bytes: []const u8) ValidationError!WasmKind {
    if (bytes.len < 8) return error.InvalidWasm;
    if (!std.mem.eql(u8, bytes[0..4], &core_reader.magic)) return error.InvalidWasm;
    if (std.mem.eql(u8, bytes[4..8], &.{ 0x01, 0x00, 0x00, 0x00 }))
        return .core_module;
    if (std.mem.eql(u8, bytes[4..8], &.{ 0x0d, 0x00, 0x01, 0x00 }))
        return .component;
    return error.InvalidWasm;
}

fn validateCoreModule(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ValidationError!?WasmV0Target {
    const module = core_reader.readModule(allocator, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedOpcode => return error.UnsupportedCoreFeature,
        else => return error.InvalidWasm,
    };
    Validator.validate(&module, .{ .features = Feature.Set.all }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedOpcode, error.LegacyExceptionsUnsupported => return error.UnsupportedCoreFeature,
        else => return error.InvalidWasm,
    };

    for (module.imports.items) |import| {
        if (std.mem.eql(u8, import.module_name, "wasi_snapshot_preview1"))
            return .wasip1;
    }
    return null;
}

fn mapComponentLoadError(err: component_loader.LoadError) ValidationError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedSection => error.UnsupportedComponentSection,
        error.UnsupportedFeature => error.UnsupportedComponentShape,
        error.DuplicateName => error.DuplicateExternName,
        error.DuplicateAttribute => error.DuplicateAttribute,
        else => error.InvalidWasm,
    };
}

fn validateComponentTree(
    allocator: std.mem.Allocator,
    component: *const component_types.Component,
) ValidationError!void {
    for (component.core_modules) |module| {
        _ = try validateCoreModule(allocator, module.data);
    }
    for (component.components) |child| {
        try validateComponentTree(allocator, child);
        try validateComponentShape(child);
    }
}

fn validateComponentShape(component: *const component_types.Component) ValidationError!void {
    if (component.imports.len == 0 and component.exports.len != 0) {
        var only_type_exports = true;
        for (component.exports) |exp| {
            if (!exportsComponentType(component, exp)) {
                only_type_exports = false;
                break;
            }
        }
        if (only_type_exports) return error.BinaryWitUnsupported;
    }

    const has_runtime_definition =
        component.core_modules.len != 0 or
        component.core_instances.len != 0 or
        component.components.len != 0 or
        component.instances.len != 0 or
        component.canons.len != 0 or
        component.start != null or
        component.imports.len != 0 or
        component.exports.len != 0;

    if (!has_runtime_definition) {
        // An actually empty component is a representable component with empty
        // lists. Type/package-only binaries are ambiguous without a binary-WIT
        // decoder and must not be mislabeled as such a component.
        if (component.types.len != 0 or component.core_types.len != 0)
            return error.BinaryWitUnsupported;
        if (component.aliases.len != 0) return error.UnsupportedComponentShape;
    }
}

fn exportsComponentType(
    component: *const component_types.Component,
    exp: component_types.ExportDecl,
) bool {
    const sort_idx = exp.sort_idx orelse return false;
    if (sort_idx.sort != .type or exp.desc != .type) return false;

    const local_idx = if (component.type_indexspace.len == 0)
        sort_idx.idx
    else if (sort_idx.idx < component.type_indexspace.len)
        switch (component.type_indexspace[sort_idx.idx]) {
            .type_def => |idx| idx,
            else => return false,
        }
    else
        return false;
    if (local_idx >= component.types.len) return false;
    return component.types[local_idx] == .component;
}

fn extractImports(
    allocator: std.mem.Allocator,
    declarations: []const component_types.ImportDecl,
) ValidationError![]Extern {
    var result: std.ArrayListUnmanaged(Extern) = .empty;
    errdefer deinitExternList(allocator, &result);

    for (declarations, 0..) |declaration, index| {
        for (declarations[0..index]) |prior| {
            if (std.mem.eql(u8, prior.name, declaration.name))
                return error.DuplicateExternName;
        }
        const kind = kindFromDesc(declaration.desc);
        try appendExtern(allocator, &result, declaration.name, declaration.attributes, kind);
    }
    return result.toOwnedSlice(allocator);
}

fn extractExports(
    allocator: std.mem.Allocator,
    declarations: []const component_types.ExportDecl,
) ValidationError![]Extern {
    var result: std.ArrayListUnmanaged(Extern) = .empty;
    errdefer deinitExternList(allocator, &result);

    for (declarations, 0..) |declaration, index| {
        for (declarations[0..index]) |prior| {
            if (std.mem.eql(u8, prior.name, declaration.name))
                return error.DuplicateExternName;
        }
        const sort_idx = declaration.sort_idx orelse return error.UnsupportedComponentShape;
        const kind = try kindFromSort(sort_idx.sort);
        if (kind != kindFromDesc(declaration.desc))
            return error.UnsupportedComponentShape;
        try appendExtern(allocator, &result, declaration.name, declaration.attributes, kind);
    }
    return result.toOwnedSlice(allocator);
}

fn appendExtern(
    allocator: std.mem.Allocator,
    result: *std.ArrayListUnmanaged(Extern),
    base_name: []const u8,
    attributes: []const component_types.ExternNameAttribute,
    kind: ExternKind,
) ValidationError!void {
    if (kind != .func and kind != .instance) return error.UnsupportedExternKind;
    const name = try completeExternName(allocator, base_name, attributes, kind);
    errdefer allocator.free(name);
    try result.append(allocator, .{ .name = name, .kind = kind });
}

fn kindFromDesc(desc: component_types.ExternDesc) ExternKind {
    return switch (desc) {
        .module => .module,
        .func => .func,
        .value => .value,
        .type => .type,
        .component => .component,
        .instance => .instance,
    };
}

fn kindFromSort(sort: component_types.Sort) ValidationError!ExternKind {
    return switch (sort) {
        .core => |core| if (core == .module)
            .module
        else
            error.UnsupportedComponentShape,
        .func => .func,
        .value => .value,
        .type => .type,
        .component => .component,
        .instance => .instance,
    };
}

fn completeExternName(
    allocator: std.mem.Allocator,
    base_name: []const u8,
    attributes: []const component_types.ExternNameAttribute,
    kind: ExternKind,
) ValidationError![]u8 {
    if (base_name.len == 0) return error.InvalidExternName;

    var version_suffix: ?[]const u8 = null;
    var seen_implements = false;
    var seen_external_id = false;
    for (attributes) |attribute| switch (attribute) {
        .implements => {
            if (seen_implements) return error.DuplicateAttribute;
            seen_implements = true;
            if (kind != .instance) return error.UnsupportedComponentShape;
        },
        .version_suffix => |suffix| {
            if (version_suffix != null) return error.DuplicateAttribute;
            version_suffix = suffix;
        },
        .external_id => {
            if (seen_external_id) return error.DuplicateAttribute;
            seen_external_id = true;
        },
    };

    const suffix = version_suffix orelse return allocator.dupe(u8, base_name);
    const full_name = try std.mem.concat(allocator, u8, &.{ base_name, suffix });
    errdefer allocator.free(full_name);
    try validateVersionSuffix(base_name, full_name);
    return full_name;
}

fn validateVersionSuffix(
    base_name: []const u8,
    full_name: []const u8,
) ValidationError!void {
    const at = std.mem.lastIndexOfScalar(u8, base_name, '@') orelse
        return error.InvalidVersionedName;
    if (at == 0 or at + 1 == base_name.len) return error.InvalidVersionedName;
    if (std.mem.indexOfScalar(u8, base_name[0..at], '@') != null)
        return error.InvalidVersionedName;
    const interface_name = base_name[0..at];
    if (std.mem.indexOfScalar(u8, interface_name, ':') == null or
        std.mem.indexOfScalar(u8, interface_name, '/') == null)
        return error.InvalidVersionedName;

    const canonical = base_name[at + 1 ..];
    // Pre-release versions are not split at the canonical-version boundary;
    // only trailing build metadata is separated. Accept that spec-defined
    // case in addition to ordinary canonical versions.
    if (!isCanonicalVersion(canonical) and
        (std.mem.indexOfScalar(u8, canonical, '-') == null or
            !isValidSemver(canonical)))
        return error.InvalidVersionedName;

    const full_version = full_name[at + 1 ..];
    if (!isValidSemver(full_version)) return error.InvalidVersionedName;
}

fn isCanonicalVersion(version: []const u8) bool {
    var parts = std.mem.splitScalar(u8, version, '.');
    const first = parts.next() orelse return false;
    const second = parts.next();
    const third = parts.next();
    if (parts.next() != null) return false;

    if (second == null) return isNonZeroNumber(first);
    if (!std.mem.eql(u8, first, "0")) return false;
    if (third == null) return isNonZeroNumber(second.?);
    if (!std.mem.eql(u8, second.?, "0")) return false;
    return std.mem.eql(u8, third.?, "0") or isNonZeroNumber(third.?);
}

fn isValidSemver(version: []const u8) bool {
    const plus = std.mem.indexOfScalar(u8, version, '+');
    if (plus) |index| {
        if (std.mem.indexOfScalar(u8, version[index + 1 ..], '+') != null)
            return false;
        if (!validIdentifiers(version[index + 1 ..], false)) return false;
    }
    const without_build = if (plus) |index| version[0..index] else version;
    const dash = std.mem.indexOfScalar(u8, without_build, '-');
    if (dash) |index| {
        if (!validIdentifiers(without_build[index + 1 ..], true)) return false;
    }
    const core = if (dash) |index| without_build[0..index] else without_build;

    var parts = std.mem.splitScalar(u8, core, '.');
    const major = parts.next() orelse return false;
    const minor = parts.next() orelse return false;
    const patch = parts.next() orelse return false;
    if (parts.next() != null) return false;
    return isNumber(major) and isNumber(minor) and isNumber(patch);
}

fn validIdentifiers(value: []const u8, reject_numeric_leading_zero: bool) bool {
    if (value.len == 0) return false;
    var identifiers = std.mem.splitScalar(u8, value, '.');
    while (identifiers.next()) |identifier| {
        if (identifier.len == 0) return false;
        var numeric = true;
        for (identifier) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '-') return false;
            if (!std.ascii.isDigit(byte)) numeric = false;
        }
        if (reject_numeric_leading_zero and numeric and
            identifier.len > 1 and identifier[0] == '0')
            return false;
    }
    return true;
}

fn isNumber(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value.len > 1 and value[0] == '0') return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn isNonZeroNumber(value: []const u8) bool {
    return isNumber(value) and !std.mem.eql(u8, value, "0");
}

fn freeExterns(allocator: std.mem.Allocator, externs: []Extern) void {
    for (externs) |external| allocator.free(external.name);
    allocator.free(externs);
}

fn deinitExternList(
    allocator: std.mem.Allocator,
    externs: *std.ArrayListUnmanaged(Extern),
) void {
    for (externs.items) |external| allocator.free(external.name);
    externs.deinit(allocator);
}

// ── Focused handcrafted fixtures ──────────────────────────────────────────

const testing = std.testing;
const component_writer = @import("../component/writer.zig");

const AttributeFixture = union(enum) {
    implements: []const u8,
    version_suffix: []const u8,
    external_id: []const u8,
};

fn appendU32(bytes: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u32) !void {
    var encoded: [5]u8 = undefined;
    const len = @import("../leb128.zig").writeU32Leb128(&encoded, value);
    try bytes.appendSlice(allocator, encoded[0..len]);
}

fn appendName(
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
) !void {
    try appendU32(bytes, allocator, @intCast(name.len));
    try bytes.appendSlice(allocator, name);
}

fn appendExternName(
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    attributes: []const AttributeFixture,
) !void {
    try bytes.append(allocator, if (attributes.len == 0) 0x00 else 0x02);
    try appendName(bytes, allocator, name);
    if (attributes.len == 0) return;
    try appendU32(bytes, allocator, @intCast(attributes.len));
    for (attributes) |attribute| switch (attribute) {
        .implements => |value| {
            try bytes.append(allocator, 0x00);
            try appendName(bytes, allocator, value);
        },
        .version_suffix => |value| {
            try bytes.append(allocator, 0x01);
            try appendName(bytes, allocator, value);
        },
        .external_id => |value| {
            try bytes.append(allocator, 0x02);
            try appendName(bytes, allocator, value);
        },
    };
}

fn appendSection(
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    id: u8,
    body: []const u8,
) !void {
    try bytes.append(allocator, id);
    try appendU32(bytes, allocator, @intCast(body.len));
    try bytes.appendSlice(allocator, body);
}

fn componentPreamble(bytes: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    try bytes.appendSlice(allocator, &.{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 });
}

fn buildInterfaceComponent(
    allocator: std.mem.Allocator,
    suffix: []const u8,
) ![]u8 {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try componentPreamble(&bytes, allocator);

    try appendSection(&bytes, allocator, 7, &.{
        0x02,
        0x42,
        0x00,
        0x40,
        0x00,
        0x01,
        0x00,
    });

    var imports: std.ArrayListUnmanaged(u8) = .empty;
    defer imports.deinit(allocator);
    try imports.append(allocator, 0x02);
    const attributes = [_]AttributeFixture{
        .{ .implements = "wasi:io/poll@0.2" },
        .{ .version_suffix = suffix },
        .{ .external_id = "urn:wasi:io/poll" },
    };
    try appendExternName(&imports, allocator, "wasi:io/poll@0.2", &attributes);
    try imports.appendSlice(allocator, &.{ 0x05, 0x00 });
    try appendExternName(&imports, allocator, "run-func", &.{});
    try imports.appendSlice(allocator, &.{ 0x01, 0x01 });
    try appendSection(&bytes, allocator, 10, imports.items);

    var exports: std.ArrayListUnmanaged(u8) = .empty;
    defer exports.deinit(allocator);
    try exports.append(allocator, 0x02);
    try appendExternName(&exports, allocator, "wasi:cli/run@0.2.6", &.{});
    try exports.appendSlice(allocator, &.{ 0x05, 0x00, 0x00 });
    try appendExternName(&exports, allocator, "run-func", &.{});
    try exports.appendSlice(allocator, &.{ 0x01, 0x00, 0x00 });
    try appendSection(&bytes, allocator, 11, exports.items);

    return bytes.toOwnedSlice(allocator);
}

fn buildWasiCoreModule(allocator: std.mem.Allocator) ![]u8 {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    try appendSection(&bytes, allocator, 1, &.{ 0x01, 0x60, 0x00, 0x00 });

    var imports: std.ArrayListUnmanaged(u8) = .empty;
    defer imports.deinit(allocator);
    try imports.append(allocator, 0x01);
    try appendName(&imports, allocator, "wasi_snapshot_preview1");
    try appendName(&imports, allocator, "fd_write");
    try imports.appendSlice(allocator, &.{ 0x00, 0x00 });
    try appendSection(&bytes, allocator, 2, imports.items);
    return bytes.toOwnedSlice(allocator);
}

test "classifies validated core, component, and invalid payloads" {
    const allocator = testing.allocator;
    const core = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const component = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 };

    try testing.expectEqual(WasmKind.core_module, try classifyPayload(allocator, &core));
    try testing.expectEqual(WasmKind.component, try classifyPayload(allocator, &component));
    try testing.expectError(error.InvalidWasm, classifyPayload(allocator, "not wasm"));
    try testing.expectError(
        error.InvalidWasm,
        classifyPayload(allocator, &.{ 0x00, 0x61, 0x73, 0x6d, 0x02, 0x00, 0x00, 0x00 }),
    );
}

test "core target requires native WASI Preview 1 import evidence" {
    const allocator = testing.allocator;
    const generic = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    var generic_metadata = try validatePayload(allocator, &generic);
    defer generic_metadata.deinit(allocator);
    try testing.expect(generic_metadata.wasm_v0_target == null);
    try testing.expectError(error.UnsupportedCoreTarget, generic_metadata.wasmV0Os());
    try testing.expectEqual(generic[0..].ptr, generic_metadata.payload.ptr);
    try testing.expectEqualSlices(u8, &generic, generic_metadata.payload);

    const wasi = try buildWasiCoreModule(allocator);
    defer allocator.free(wasi);
    var wasi_metadata = try validatePayload(allocator, wasi);
    defer wasi_metadata.deinit(allocator);
    try testing.expectEqualStrings("wasip1", try wasi_metadata.wasmV0Os());
}

test "extracts complete versioned component names and supported kinds" {
    const allocator = testing.allocator;
    const bytes = try buildInterfaceComponent(allocator, ".6");
    defer allocator.free(bytes);

    var metadata = try validatePayload(allocator, bytes);
    defer metadata.deinit(allocator);
    try testing.expectEqual(WasmKind.component, metadata.kind);
    try testing.expectEqualStrings("wasip2", try metadata.wasmV0Os());
    try testing.expectEqual(bytes.ptr, metadata.payload.ptr);
    try testing.expectEqualSlices(u8, bytes, metadata.payload);

    const component = metadata.component.?;
    try testing.expect(component.target == null);
    try testing.expectEqual(@as(usize, 2), component.imports.len);
    try testing.expectEqual(@as(usize, 2), component.exports.len);
    try testing.expectEqualStrings("wasi:io/poll@0.2.6", component.imports[0].name);
    try testing.expectEqual(ExternKind.instance, component.imports[0].kind);
    try testing.expectEqualStrings("run-func", component.imports[1].name);
    try testing.expectEqual(ExternKind.func, component.imports[1].kind);
    try testing.expectEqualStrings("wasi:cli/run@0.2.6", component.exports[0].name);
    try testing.expectEqual(ExternKind.instance, component.exports[0].kind);
    try testing.expectEqualStrings("run-func", component.exports[1].name);
    try testing.expectEqual(ExternKind.func, component.exports[1].kind);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decoded = try component_loader.loadVerbatim(bytes, arena.allocator());
    try testing.expectEqual(@as(usize, 3), decoded.imports[0].attributes.len);
    const encoded = try component_writer.encode(allocator, &decoded);
    defer allocator.free(encoded);
    try testing.expectEqualSlices(u8, bytes, encoded);
}

test "structured version suffix preserves prerelease and build metadata" {
    const allocator = testing.allocator;
    const attributes = [_]component_types.ExternNameAttribute{
        .{ .version_suffix = "+sha.5114f85" },
    };
    const name = try completeExternName(
        allocator,
        "wasi:example/api@0.0.1-alpha",
        &attributes,
        .instance,
    );
    defer allocator.free(name);
    try testing.expectEqualStrings(
        "wasi:example/api@0.0.1-alpha+sha.5114f85",
        name,
    );
}

test "empty component is distinct from unsupported type-only binary WIT shape" {
    const allocator = testing.allocator;
    const empty = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 };
    var metadata = try validatePayload(allocator, &empty);
    defer metadata.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), metadata.component.?.imports.len);
    try testing.expectEqual(@as(usize, 0), metadata.component.?.exports.len);

    const type_only = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00,
        0x07, 0x03, 0x01, 0x42, 0x00,
    };
    try testing.expectError(
        error.BinaryWitUnsupported,
        validatePayload(allocator, &type_only),
    );

    var encoded_package: std.ArrayListUnmanaged(u8) = .empty;
    defer encoded_package.deinit(allocator);
    try componentPreamble(&encoded_package, allocator);
    try appendSection(&encoded_package, allocator, 7, &.{ 0x01, 0x41, 0x00 });
    var package_export: std.ArrayListUnmanaged(u8) = .empty;
    defer package_export.deinit(allocator);
    try package_export.append(allocator, 0x01);
    try appendExternName(&package_export, allocator, "package", &.{});
    try package_export.appendSlice(allocator, &.{ 0x03, 0x00, 0x00 });
    try appendSection(&encoded_package, allocator, 11, package_export.items);
    try testing.expectError(
        error.BinaryWitUnsupported,
        validatePayload(allocator, encoded_package.items),
    );
}

test "strict component decoding rejects skipped sections, duplicate names, and attributes" {
    const allocator = testing.allocator;
    const value_section = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00,
        0x0c, 0x00,
    };
    try testing.expectError(
        error.UnsupportedComponentSection,
        validatePayload(allocator, &value_section),
    );

    var duplicate_start: std.ArrayListUnmanaged(u8) = .empty;
    defer duplicate_start.deinit(allocator);
    try componentPreamble(&duplicate_start, allocator);
    try appendSection(&duplicate_start, allocator, 9, &.{ 0x00, 0x00, 0x00 });
    try appendSection(&duplicate_start, allocator, 9, &.{ 0x00, 0x00, 0x00 });
    try testing.expectError(
        error.InvalidWasm,
        validatePayload(allocator, duplicate_start.items),
    );

    var duplicate_names: std.ArrayListUnmanaged(u8) = .empty;
    defer duplicate_names.deinit(allocator);
    try componentPreamble(&duplicate_names, allocator);
    try appendSection(&duplicate_names, allocator, 7, &.{ 0x01, 0x42, 0x00 });
    var import_body: std.ArrayListUnmanaged(u8) = .empty;
    defer import_body.deinit(allocator);
    try import_body.append(allocator, 0x01);
    try appendExternName(&import_body, allocator, "same", &.{});
    try import_body.appendSlice(allocator, &.{ 0x05, 0x00 });
    try appendSection(&duplicate_names, allocator, 10, import_body.items);
    try appendSection(&duplicate_names, allocator, 10, import_body.items);
    try testing.expectError(
        error.DuplicateExternName,
        validatePayload(allocator, duplicate_names.items),
    );

    var duplicate_attributes: std.ArrayListUnmanaged(u8) = .empty;
    defer duplicate_attributes.deinit(allocator);
    try componentPreamble(&duplicate_attributes, allocator);
    try appendSection(&duplicate_attributes, allocator, 7, &.{ 0x01, 0x42, 0x00 });
    var duplicate_attr_body: std.ArrayListUnmanaged(u8) = .empty;
    defer duplicate_attr_body.deinit(allocator);
    try duplicate_attr_body.append(allocator, 0x01);
    const attrs = [_]AttributeFixture{
        .{ .version_suffix = ".6" },
        .{ .version_suffix = ".7" },
    };
    try appendExternName(&duplicate_attr_body, allocator, "wasi:io/poll@0.2", &attrs);
    try duplicate_attr_body.appendSlice(allocator, &.{ 0x05, 0x00 });
    try appendSection(&duplicate_attributes, allocator, 10, duplicate_attr_body.items);
    try testing.expectError(
        error.DuplicateAttribute,
        validatePayload(allocator, duplicate_attributes.items),
    );
}

test "rejects malformed lengths, LEB, UTF-8, trailing data, and aliases" {
    const allocator = testing.allocator;
    const malformed_length = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00,
        0x00, 0x02, 0x03, 'x',
    };
    try testing.expectError(error.InvalidWasm, validatePayload(allocator, &malformed_length));

    const crosses_section_boundary = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00,
        0x00, 0x01, 0x02, 0x00, 0x00,
    };
    try testing.expectError(
        error.InvalidWasm,
        validatePayload(allocator, &crosses_section_boundary),
    );

    const malformed_leb = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00,
        0x00, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00,
    };
    try testing.expectError(error.InvalidWasm, validatePayload(allocator, &malformed_leb));

    const malformed_utf8 = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00,
        0x00, 0x02, 0x01, 0xff,
    };
    try testing.expectError(error.InvalidWasm, validatePayload(allocator, &malformed_utf8));

    const trailing = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00,
        0xff,
    };
    try testing.expectError(error.InvalidWasm, validatePayload(allocator, &trailing));

    const malformed_alias = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00,
        0x06, 0x03, 0x01, 0x01, 0xff,
    };
    try testing.expectError(error.InvalidWasm, validatePayload(allocator, &malformed_alias));
}

test "rejects unsupported metadata kinds and malformed structured versions" {
    const allocator = testing.allocator;

    var module_import: std.ArrayListUnmanaged(u8) = .empty;
    defer module_import.deinit(allocator);
    try componentPreamble(&module_import, allocator);
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    try body.append(allocator, 0x01);
    try appendExternName(&body, allocator, "host-module", &.{});
    try body.appendSlice(allocator, &.{ 0x00, 0x11, 0x00 });
    try appendSection(&module_import, allocator, 10, body.items);
    try testing.expectError(
        error.UnsupportedExternKind,
        validatePayload(allocator, module_import.items),
    );

    const bad_version = try buildInterfaceComponent(allocator, ".x");
    defer allocator.free(bad_version);
    try testing.expectError(
        error.InvalidVersionedName,
        validatePayload(allocator, bad_version),
    );
}

test "recursively rejects malformed nested modules and components" {
    const allocator = testing.allocator;

    var nested_module: std.ArrayListUnmanaged(u8) = .empty;
    defer nested_module.deinit(allocator);
    try componentPreamble(&nested_module, allocator);
    try appendSection(
        &nested_module,
        allocator,
        1,
        &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0xff },
    );
    try testing.expectError(
        error.InvalidWasm,
        validatePayload(allocator, nested_module.items),
    );

    var nested_component: std.ArrayListUnmanaged(u8) = .empty;
    defer nested_component.deinit(allocator);
    try componentPreamble(&nested_component, allocator);
    try appendSection(
        &nested_component,
        allocator,
        4,
        &.{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00, 0xff },
    );
    try testing.expectError(
        error.InvalidWasm,
        validatePayload(allocator, nested_component.items),
    );
}
