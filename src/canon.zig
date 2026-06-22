//! Compatibility shim: legacy `@import("canon")` now forwards to `wit_types`.

const wt = @import("wit_types");

pub const Realloc = wt.Realloc;
pub const Result = wt.Result;
pub const Tuple = wt.Tuple;
pub const Future = wt.Future;
pub const FutureOf = wt.FutureOf;
pub const Stream = wt.Stream;
pub const StreamOf = wt.StreamOf;
pub const ErrorContextHandle = wt.ErrorContextHandle;
pub const RetArea = wt.RetArea;
pub const CoreReturn = wt.CoreReturn;
pub const FlatParams = wt.FlatParams;

pub const alignOf = wt.alignOf;
pub const sizeOf = wt.sizeOf;
pub const lower = wt.lower;
pub const lift = wt.lift;
pub const flatCount = wt.flatCount;
pub const resultIsFlat = wt.resultIsFlat;
pub const returnResult = wt.returnResult;
pub const liftResultFlat = wt.liftResultFlat;
pub const liftParams = wt.liftParams;
pub const lowerFlat = wt.lowerFlat;
