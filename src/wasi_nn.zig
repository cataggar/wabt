//! `wasi_nn` — minimal guest bindings for the experimental
//! `wasi:nn@0.2.0-rc-2024-10-28` proposal (the `tensor` interface).
//!
//! Demand-driven: `graph` / `inference` / `errors` are added as examples
//! need them.

const abi = @import("abi");

/// `tensor.tensor-type` enum (wasi-nn.wit order: FP16, FP32, FP64, BF16,
/// U8, I32). Named descriptively to avoid escaping primitive identifiers.
pub const TensorType = enum(i32) {
    fp16 = 0,
    fp32 = 1,
    fp64 = 2,
    bf16 = 3,
    uint8 = 4,
    int32 = 5,
};

/// `[constructor]tensor(dimensions: list<u32>, ty: tensor-type,
///   data: list<u8>) -> own<tensor>`. 5 flat params (≤16) → direct call.
extern "wasi:nn/tensor@0.2.0-rc-2024-10-28" fn @"[constructor]tensor"(
    dims_ptr: i32,
    dims_len: i32,
    ty: i32,
    data_ptr: i32,
    data_len: i32,
) i32;
/// `[method]tensor.dimensions(borrow) -> list<u32>` — retptr `[ptr, len]`.
extern "wasi:nn/tensor@0.2.0-rc-2024-10-28" fn @"[method]tensor.dimensions"(self: i32, retptr: i32) void;
/// `[method]tensor.ty(borrow) -> tensor-type` — single i32 enum result.
extern "wasi:nn/tensor@0.2.0-rc-2024-10-28" fn @"[method]tensor.ty"(self: i32) i32;
/// `[method]tensor.data(borrow) -> list<u8>` — retptr `[ptr, len]`.
extern "wasi:nn/tensor@0.2.0-rc-2024-10-28" fn @"[method]tensor.data"(self: i32, retptr: i32) void;
/// `[resource-drop]tensor(own<tensor>)`.
extern "wasi:nn/tensor@0.2.0-rc-2024-10-28" fn @"[resource-drop]tensor"(self: i32) void;

/// A `wasi:nn/tensor.tensor` handle.
pub const Tensor = struct {
    handle: i32,

    /// Construct a tensor from its dimensions, element type, and bytes.
    pub fn init(dims: []const u32, element_type: TensorType, bytes: []const u8) Tensor {
        return .{ .handle = @"[constructor]tensor"(
            @intCast(@intFromPtr(dims.ptr)),
            @intCast(dims.len),
            @intFromEnum(element_type),
            @intCast(@intFromPtr(bytes.ptr)),
            @intCast(bytes.len),
        ) };
    }

    /// Tensor dimensions (borrows the scratch arena).
    pub fn dimensions(self: Tensor) []const u32 {
        @"[method]tensor.dimensions"(self.handle, abi.retPtr());
        const w = abi.retWords();
        const p: [*]const u32 = @ptrFromInt(w[0]);
        return p[0..w[1]];
    }

    /// Tensor element type.
    pub fn ty(self: Tensor) TensorType {
        return @enumFromInt(@"[method]tensor.ty"(self.handle));
    }

    /// Raw tensor bytes (borrows the scratch arena).
    pub fn data(self: Tensor) []const u8 {
        @"[method]tensor.data"(self.handle, abi.retPtr());
        const w = abi.retWords();
        const p: [*]const u8 = @ptrFromInt(w[0]);
        return p[0..w[1]];
    }

    pub fn drop(self: Tensor) void {
        @"[resource-drop]tensor"(self.handle);
    }
};
