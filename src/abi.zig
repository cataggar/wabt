//! Compatibility shim: legacy `@import("abi")` now forwards to `wit_types`.

const wt = @import("wit_types");

pub const cabi_realloc = wt.cabi_realloc;
pub const resetScratch = wt.resetScratch;
pub const alloc = wt.alloc;
pub const retPtr = wt.retPtr;
pub const retWords = wt.retWords;
pub const retArea = wt.retArea;
pub const readResultHandle = wt.readResultHandle;
pub const readOptionBytes = wt.readOptionBytes;
