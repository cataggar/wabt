//! wabt — WebAssembly Binary Toolkit
//!
//! A Zig implementation of tools for working with WebAssembly.
//! Provides parsing, validation, interpretation, and transformation
//! of WebAssembly modules in both binary (.wasm) and text (.wat) formats.

pub const types = @import("types.zig");
pub const Opcode = @import("Opcode.zig");
pub const Feature = @import("Feature.zig");
pub const Module = @import("Module.zig");
pub const Validator = @import("Validator.zig");
pub const CWriter = @import("CWriter.zig");
pub const Decompiler = @import("Decompiler.zig");
pub const wast_runner = @import("wast_runner.zig");

pub const leb128 = @import("leb128.zig");

pub const binary = struct {
    pub const reader = @import("binary/reader.zig");
    pub const writer = @import("binary/writer.zig");
};

pub const text = struct {
    pub const Lexer = @import("text/Lexer.zig");
    pub const Parser = @import("text/Parser.zig");
    pub const Writer = @import("text/Writer.zig");
};

pub const interp = struct {
    pub const Interpreter = @import("interp/Interpreter.zig");
};

pub const component = struct {
    pub const types = @import("component/types.zig");
    pub const loader = @import("component/loader.zig");
    pub const writer = @import("component/writer.zig");
    pub const compose = @import("component/compose.zig");
    pub const type_walk = @import("component/type_walk.zig");
    pub const wit = struct {
        pub const lexer = @import("component/wit/lexer.zig");
        pub const ast = @import("component/wit/ast.zig");
        pub const parser = @import("component/wit/parser.zig");
        pub const resolver = @import("component/wit/resolver.zig");
        pub const metadata_encode = @import("component/wit/metadata_encode.zig");
        pub const metadata_decode = @import("component/wit/metadata_decode.zig");
    };
    pub const adapter = struct {
        pub const decode = @import("component/adapter/decode.zig");
        pub const core_imports = @import("component/adapter/core_imports.zig");
        pub const shim = @import("component/adapter/shim.zig");
        pub const fixup = @import("component/adapter/fixup.zig");
        pub const types_import = @import("component/adapter/types_import.zig");
        pub const abi = @import("component/adapter/abi.zig");
        pub const adapter = @import("component/adapter/adapter.zig");
        pub const gc = @import("component/adapter/gc.zig");
        pub const world_gc = @import("component/adapter/world_gc.zig");
    };
};

/// Maximum input file size (256 MiB). Prevents OOM from oversized or malicious input.
pub const max_input_file_size = 256 * 1024 * 1024;

const build_options = @import("build_options");
pub const version: []const u8 = build_options.version;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("component/types.zig");
    _ = @import("component/loader.zig");
    _ = @import("component/writer.zig");
    _ = @import("component/compose.zig");
    _ = @import("component/type_walk.zig");
    _ = @import("component/wit/lexer.zig");
    _ = @import("component/wit/ast.zig");
    _ = @import("component/wit/parser.zig");
    _ = @import("component/wit/resolver.zig");
    _ = @import("component/wit/metadata_encode.zig");
    _ = @import("component/wit/metadata_decode.zig");
    _ = @import("component/adapter/decode.zig");
    _ = @import("component/adapter/core_imports.zig");
    _ = @import("component/adapter/shim.zig");
    _ = @import("component/adapter/fixup.zig");
    _ = @import("component/adapter/types_import.zig");
    _ = @import("component/adapter/abi.zig");
    _ = @import("component/adapter/adapter.zig");
    _ = @import("component/adapter/gc.zig");
    _ = @import("component/adapter/world_gc.zig");
    _ = @import("integration_tests.zig");
    _ = @import("spec_tests.zig");
}
