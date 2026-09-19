//! OCI foundation namespace.
//!
//! The implementation provenance and pinned upstream source mapping are
//! recorded in `SOURCE_PROVENANCE.md`.

const std = @import("std");

pub const content = @import("oci/content.zig");
pub const reference = @import("oci/reference.zig");
pub const model = @import("oci/model.zig");
pub const transport = @import("oci/transport.zig");
pub const graph = @import("oci/graph.zig");
pub const layout = @import("oci/layout.zig");
pub const copy = @import("oci/copy.zig");

pub const Digest = content.Digest;
pub const ContentVerifier = content.Verifier;

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
    _ = @import("oci/model.zig");
    _ = @import("oci/transport.zig");
    _ = @import("oci/graph.zig");
    _ = @import("oci/layout.zig");
    _ = @import("oci/copy.zig");
    _ = @import("oci/integration_tests.zig");
}
