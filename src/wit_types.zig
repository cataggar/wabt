//! `wit_types` — the shared WIT value + canonical-ABI surface.
//!
//! This is the public umbrella for the guest-side canonical ABI helpers:
//! `abi` for scratch/ret-area plumbing and `canon` for value lowering/lifting
//! and typed `future` / `stream` wrappers.

const abi_impl = @import("abi");
const canon_impl = @import("canon");

pub const abi = abi_impl;
pub const canon = canon_impl;
