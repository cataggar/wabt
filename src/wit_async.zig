//! `wit_async` — the shared Component-Model async runtime surface.
//!
//! This is the public umbrella for the guest-side async primitives: waitable
//! sets, stream/future blocking helpers, and async-lowered call driving.

const cm_async_impl = @import("cm_async");

pub const cm_async = cm_async_impl;
