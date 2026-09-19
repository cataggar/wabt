//! OCI foundation namespace.
//!
//! The implementation provenance and pinned upstream source mapping are
//! recorded in `SOURCE_PROVENANCE.md`.

const std = @import("std");

pub const content = @import("oci/content.zig");
pub const reference = @import("oci/reference.zig");
pub const auth = @import("oci/auth.zig");
pub const model = @import("oci/model.zig");
pub const transport = @import("oci/transport.zig");
pub const graph = @import("oci/graph.zig");
pub const layout = @import("oci/layout.zig");
pub const copy = @import("oci/copy.zig");
pub const wasm_metadata = @import("oci/wasm_metadata.zig");

pub const Digest = content.Digest;
pub const ContentVerifier = content.Verifier;

pub const CredentialPolicy = auth.CredentialPolicy;
pub const SuppliedCredential = auth.SuppliedCredential;
pub const BasicCredential = auth.BasicCredential;
pub const OwnedCredential = auth.OwnedCredential;
pub const ResolvedCredential = auth.ResolvedCredential;
pub const CredentialTarget = auth.CredentialTarget;
pub const AuthLimits = auth.Limits;
pub const AuthResolutionContext = auth.ResolutionContext;
pub const DistributionChallenge = auth.DistributionChallenge;
pub const Token = auth.Token;
pub const TokenCache = auth.TokenCache;
pub const TokenCacheKey = auth.TokenCacheKey;
pub const resolveCredential = auth.resolveCredential;
pub const parseWwwAuthenticate = auth.parseWwwAuthenticate;
pub const selectDistributionChallenge = auth.selectDistributionChallenge;

pub const Descriptor = model.Descriptor;
pub const Platform = model.Platform;
pub const Index = model.Index;
pub const Manifest = model.Manifest;
pub const ConfigPlatform = model.ConfigPlatform;
pub const ImageConfigPlatform = model.ImageConfigPlatform;
pub const MediaTypeClass = model.MediaTypeClass;
pub const ParsedDocument = model.ParsedDocument;
pub const classifyMediaType = model.classifyMediaType;
pub const parseDocument = model.parseDocument;
pub const validateArtifactManifest = model.validateArtifactManifest;
pub const validateImageManifest = model.validateImageManifest;

pub const Source = transport.Source;
pub const Destination = transport.Destination;
pub const TransferCounts = transport.Counts;
pub const TransferResult = transport.Result;

pub const GraphLimits = graph.Limits;
pub const GraphRoot = graph.Root;
pub const GraphPlan = graph.Plan;
pub const planGraphCopy = graph.planCopy;

pub const LayoutSource = layout.Source;
pub const LayoutDestination = layout.Destination;
pub const LayoutResolvedRoot = layout.ResolvedRoot;
pub const LayoutFailurePoint = layout.FailurePoint;
pub const copyLayoutToLayout = copy.layoutToLayout;
pub const copyPlannedGraph = copy.executePlan;

pub const WasmKind = wasm_metadata.WasmKind;
pub const WasmV0Target = wasm_metadata.WasmV0Target;
pub const WasmExternKind = wasm_metadata.ExternKind;
pub const WasmExtern = wasm_metadata.Extern;
pub const WasmComponentMetadata = wasm_metadata.ComponentMetadata;
pub const WasmPayloadMetadata = wasm_metadata.PayloadMetadata;
pub const WasmValidationError = wasm_metadata.ValidationError;
pub const validateWasmPayload = wasm_metadata.validatePayload;
pub const classifyWasmPayload = wasm_metadata.classifyPayload;

pub const parseReference = reference.parse;
pub const Reference = reference.Reference;
pub const RegistryReference = reference.RegistryReference;
pub const LayoutReference = reference.LayoutReference;
pub const Selection = reference.Selection;
pub const Operation = reference.Operation;
pub const ParseMode = reference.ParseMode;

test {
    std.testing.refAllDecls(@This());
    _ = @import("oci/content.zig");
    _ = @import("oci/reference.zig");
    _ = @import("oci/auth.zig");
    _ = @import("oci/model.zig");
    _ = @import("oci/transport.zig");
    _ = @import("oci/graph.zig");
    _ = @import("oci/layout.zig");
    _ = @import("oci/copy.zig");
    _ = @import("oci/wasm_metadata.zig");
    _ = @import("oci/integration_tests.zig");
}
