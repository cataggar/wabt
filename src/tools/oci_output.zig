const std = @import("std");
const runtime_mod = @import("oci_runtime.zig");

pub const DescriptorV1 = struct {
    mediaType: []const u8,
    digest: []const u8,
    size: u64,
};

pub const GraphSummaryV1 = struct {
    documents: u64,
    descriptors: u64,
    totalSize: u64,
};

pub const ResolveV1 = struct {
    schema: []const u8 = "wabt.oci.resolve",
    schemaVersion: u32 = 1,
    originalReference: []const u8,
    reference: []const u8,
    rootKind: []const u8,
    rootMediaType: []const u8,
    rootDigest: []const u8,
    rootSize: u64,
    manifestMediaType: ?[]const u8,
    manifestDigest: ?[]const u8,
    manifestSize: ?u64,
};

pub const InspectV1 = struct {
    schema: []const u8 = "wabt.oci.inspect",
    schemaVersion: u32 = 1,
    originalReference: []const u8,
    reference: []const u8,
    root: DescriptorV1,
    documentKind: []const u8,
    artifactType: ?[]const u8,
    subject: ?DescriptorV1,
    manifest: ?DescriptorV1,
    profile: ?[]const u8,
    config: ?DescriptorV1,
    payload: ?DescriptorV1,
    graph: GraphSummaryV1,
};

pub const ListTagsV1 = struct {
    schema: []const u8 = "wabt.oci.list-tags",
    schemaVersion: u32 = 1,
    repository: []const u8,
    tags: []const []const u8,
};

pub const PullV1 = struct {
    schema: []const u8 = "wabt.oci.pull",
    schemaVersion: u32 = 1,
    originalReference: []const u8,
    reference: []const u8,
    root: DescriptorV1,
    manifest: DescriptorV1,
    config: DescriptorV1,
    payload: DescriptorV1,
    profile: []const u8,
    output: []const u8,
    size: u64,
};

pub const PushV1 = struct {
    schema: []const u8 = "wabt.oci.push",
    schemaVersion: u32 = 1,
    originalReference: []const u8,
    reference: []const u8,
    profile: []const u8,
    created: []const u8,
    createdSource: []const u8,
    root: DescriptorV1,
    manifest: DescriptorV1,
    config: DescriptorV1,
    payload: DescriptorV1,
};

pub const CopyV1 = struct {
    schema: []const u8 = "wabt.oci.copy",
    schemaVersion: u32 = 1,
    sourceReference: []const u8,
    sourceRootReference: []const u8,
    destinationReference: []const u8,
    destinationRootReference: []const u8,
    root: DescriptorV1,
    transferred: u64,
    reused: u64,
    mounted: u64,
};

pub const ExecutionError = error{
    OutOfMemory,
    InvalidPayload,
    InvalidProfile,
    AuthenticationFailed,
    AuthorizationDenied,
    NotFound,
    Conflict,
    Corruption,
    UnsupportedContent,
    InvalidContent,
    TransportFailed,
    TlsValidationFailed,
    DeadlineExceeded,
    CertificateAuthorityFailed,
    UploadAmbiguous,
    LimitExceeded,
    OutputExists,
    LocalReadFailed,
    LocalWriteFailed,
    SecretInputFailed,
    StdoutWriteFailed,
    StderrWriteFailed,
    ProgressWriteFailed,
    CommittedButReportingFailed,
    UnexpectedFailure,
};

pub fn descriptor(value: anytype) DescriptorV1 {
    return .{
        .mediaType = value.mediaType,
        .digest = value.digest,
        .size = value.size,
    };
}

pub fn profileText(profile: anytype) []const u8 {
    return switch (profile) {
        .wasm_v0 => "wasm-v0",
        .oci_1_1 => "oci-1.1",
        .oci_1_0 => "oci-1.0",
    };
}

pub fn writeJson(
    runtime: *runtime_mod.Runtime,
    value: anytype,
) ExecutionError!void {
    const bytes = std.json.Stringify.valueAlloc(
        runtime.allocator,
        value,
        .{},
    ) catch |err| return mapExecutionError(err);
    defer runtime.allocator.free(bytes);
    const line = runtime.allocator.alloc(u8, bytes.len + 1) catch
        return error.OutOfMemory;
    defer runtime.allocator.free(line);
    @memcpy(line[0..bytes.len], bytes);
    line[bytes.len] = '\n';
    runtime.writeStdout(line) catch return error.StdoutWriteFailed;
}

pub fn writeText(
    runtime: *runtime_mod.Runtime,
    text: []const u8,
) ExecutionError!void {
    runtime.writeStdout(text) catch return error.StdoutWriteFailed;
}

pub fn writeProgress(
    runtime: *runtime_mod.Runtime,
    text: []const u8,
) ExecutionError!void {
    runtime.writeProgress(text) catch return error.ProgressWriteFailed;
}

pub fn writeDiagnostic(
    runtime: *runtime_mod.Runtime,
    command: ?[]const u8,
    err: anyerror,
) ExecutionError!void {
    var allocating: std.Io.Writer.Allocating = .init(runtime.allocator);
    defer allocating.deinit();
    const writer = &allocating.writer;
    if (command) |name| {
        writer.print(
            "error: wabt oci {s}: {s}\n",
            .{ name, diagnosticText(err) },
        ) catch return error.OutOfMemory;
    } else {
        writer.print(
            "error: wabt oci: {s}\n",
            .{diagnosticText(err)},
        ) catch return error.OutOfMemory;
    }
    const bytes = allocating.toOwnedSlice() catch return error.OutOfMemory;
    defer runtime.allocator.free(bytes);
    runtime.writeStderr(bytes) catch return error.StderrWriteFailed;
}

pub fn mapExecutionError(err: anyerror) ExecutionError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,

        error.AuthenticationFailed,
        error.CredentialNotFound,
        error.InvalidCredential,
        error.InvalidToken,
        error.InvalidAuthFile,
        error.AuthFileTooLarge,
        error.CredentialHelperFailed,
        error.InvalidCredentialHelperOutput,
        error.CredentialHelperOutputTooLarge,
        error.UnsupportedCredentialType,
        => error.AuthenticationFailed,

        error.AuthorizationDenied => error.AuthorizationDenied,

        error.ContentNotFound,
        error.RootNotFound,
        error.MissingBlob,
        error.FileNotFound,
        error.PathNotFound,
        => error.NotFound,

        error.UnsupportedContent,
        error.UnsupportedGraphNode,
        error.SubjectGraphUnsupported,
        error.UnsupportedDocumentMediaType,
        error.UnsupportedDescriptorMediaType,
        error.UnsupportedManifestMediaType,
        error.UnsupportedRootMediaType,
        error.UnsupportedLayerMediaType,
        error.UnsupportedProfile,
        error.DirectManifestRequired,
        error.ManifestSubjectUnsupported,
        error.InvalidLayerCount,
        => error.UnsupportedContent,

        error.InvalidContent,
        error.CorruptBlob,
        error.DescriptorMismatch,
        error.ConflictingDescriptor,
        error.DescriptorDocumentMismatch,
        error.RootDescriptorMismatch,
        error.SourceContractViolation,
        error.DigestMismatch,
        error.SizeMismatch,
        error.MalformedManifest,
        error.MalformedWasmV0Config,
        error.InvalidEmptyConfig,
        error.ArchitectureMismatch,
        error.OsMismatch,
        error.LayerDigestsMismatch,
        error.ComponentPresenceMismatch,
        error.ComponentImportsMismatch,
        error.ComponentExportsMismatch,
        error.DuplicateConfigExtern,
        error.InvalidConfigExtern,
        error.InvalidWasmMagic,
        error.UnsupportedWasmVersion,
        error.InvalidWasm,
        error.UnexpectedEndOfWasm,
        error.InvalidSourceRead,
        => error.InvalidContent,

        error.TransportFailed,
        error.RegistryFailed,
        error.PaginationFailed,
        error.RedirectRejected,
        error.RetryLimitExceeded,
        error.InsecureTransport,
        => error.TransportFailed,

        error.TlsValidationFailed => error.TlsValidationFailed,
        error.DeadlineExceeded, error.DeadlineOverflow => error.DeadlineExceeded,
        error.CertificateAuthorityLoadFailed => error.CertificateAuthorityFailed,

        error.LimitExceeded,
        error.MaximumDepthExceeded,
        error.MaximumDescriptorsExceeded,
        error.MaximumTotalBytesExceeded,
        error.TotalSizeOverflow,
        error.MaximumMetadataBytesExceeded,
        error.MaximumTotalMetadataBytesExceeded,
        error.MetadataTooLarge,
        error.PayloadTooLarge,
        error.ConfigTooLarge,
        error.ManifestTooLarge,
        => error.LimitExceeded,

        error.DestinationExists,
        error.DestinationChanged,
        error.DestinationIsDirectory,
        error.DestinationIsSymlink,
        error.UnsupportedDestinationType,
        => error.OutputExists,

        error.InvalidOutputPath,
        error.AccessDenied,
        error.NoSpaceLeft,
        error.DiskQuota,
        error.ReadOnlyFileSystem,
        error.StagedFileChanged,
        => error.LocalWriteFailed,

        error.EmptySecret,
        error.SecretTooLarge,
        error.SecretReadFailed,
        => error.SecretInputFailed,

        error.StdoutWriteFailed => error.StdoutWriteFailed,
        error.StderrWriteFailed => error.StderrWriteFailed,
        else => error.UnexpectedFailure,
    };
}

pub fn mapLocalWriteError(err: anyerror) ExecutionError {
    return switch (err) {
        error.InvalidOutputPath,
        error.AccessDenied,
        error.FileNotFound,
        error.PathNotFound,
        error.NoSpaceLeft,
        error.DiskQuota,
        error.ReadOnlyFileSystem,
        error.StagedFileChanged,
        => error.LocalWriteFailed,
        else => mapExecutionError(err),
    };
}

pub fn mapLocalReadError(err: anyerror) ExecutionError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.PayloadTooLarge => error.LimitExceeded,
        error.AccessDenied,
        error.FileNotFound,
        error.PathNotFound,
        error.IsDir,
        error.InputChanged,
        error.UnexpectedEndOfFile,
        error.ReadFailed,
        => error.LocalReadFailed,
        else => mapExecutionError(err),
    };
}

pub fn mapPushError(err: anyerror) ExecutionError {
    return switch (err) {
        error.InvalidWasmMagic,
        error.UnsupportedWasmVersion,
        error.InvalidWasm,
        error.UnexpectedEndOfWasm,
        error.ComponentMetadataTooLarge,
        => error.InvalidPayload,

        error.InvalidCreated,
        error.InvalidAuthor,
        error.UnsupportedProfile,
        => error.InvalidProfile,

        error.DestinationStateConflict,
        error.DestinationNotPrepared,
        error.DestinationNotStaged,
        error.DestinationNotCommitted,
        => error.Conflict,

        error.UploadAmbiguous,
        error.UploadIncomplete,
        error.PublicationUnconfirmed,
        => error.UploadAmbiguous,

        error.InjectedFailure => error.LocalWriteFailed,
        error.InvalidDestinationPath,
        error.AccessDenied,
        error.NoSpaceLeft,
        error.DiskQuota,
        error.ReadOnlyFileSystem,
        => error.LocalWriteFailed,

        else => mapExecutionError(err),
    };
}

pub fn mapCopyError(err: anyerror) ExecutionError {
    return switch (err) {
        error.DestinationStateConflict,
        error.DestinationNotPrepared,
        error.DestinationNotStaged,
        error.DestinationNotCommitted,
        error.RootNotStaged,
        => error.Conflict,

        error.CorruptBlob,
        error.DescriptorMismatch,
        error.ConflictingDescriptor,
        error.DescriptorDocumentMismatch,
        error.RootDescriptorMismatch,
        error.SourceContractViolation,
        error.DigestMismatch,
        error.SizeMismatch,
        error.InvalidLayout,
        error.InvalidLayoutVersion,
        error.InvalidIndex,
        => error.Corruption,

        error.UploadAmbiguous,
        error.UploadIncomplete,
        error.PublicationUnconfirmed,
        => error.UploadAmbiguous,

        error.InjectedFailure => error.LocalWriteFailed,
        error.InvalidDestinationPath,
        error.AccessDenied,
        error.NoSpaceLeft,
        error.DiskQuota,
        error.ReadOnlyFileSystem,
        => error.LocalWriteFailed,

        else => mapExecutionError(err),
    };
}

pub fn diagnosticText(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidPayload => "invalid or unsupported WebAssembly payload",
        error.InvalidProfile => "invalid artifact profile or profile metadata",
        error.AuthenticationFailed => "authentication failed",
        error.AuthorizationDenied => "authorization denied",
        error.NotFound => "content not found",
        error.Conflict => "destination state conflict",
        error.Corruption => "source or destination content is corrupt",
        error.UnsupportedContent => "unsupported OCI content",
        error.InvalidContent => "invalid or corrupt OCI content",
        error.TransportFailed => "registry transport failed",
        error.TlsValidationFailed => "TLS validation failed",
        error.DeadlineExceeded => "operation deadline exceeded",
        error.CertificateAuthorityFailed => "additional CA could not be loaded",
        error.UploadAmbiguous => "registry upload or publication could not be confirmed",
        error.LimitExceeded => "OCI operation limit exceeded",
        error.OutputExists => "output exists or cannot be replaced safely",
        error.LocalReadFailed => "local input file could not be read",
        error.LocalWriteFailed => "local file operation failed",
        error.SecretInputFailed => "secret input could not be read",
        error.StdoutWriteFailed => "failed to write stdout",
        error.StderrWriteFailed => "failed to write stderr",
        error.ProgressWriteFailed => "failed to write progress",
        error.CommittedButReportingFailed => "publication committed but reporting failed",
        error.OutOfMemory => "out of memory",
        error.UnexpectedFailure => "OCI operation failed",
        else => @errorName(err),
    };
}

test "version one DTO JSON is stable and newline terminated" {
    var output: [1024]u8 = undefined;
    var stdout_writer = std.Io.Writer.fixed(&output);
    var counters: runtime_mod.Counters = .{};
    var runtime = runtime_mod.Runtime.initForTest(
        std.testing.allocator,
        std.testing.io,
        &counters,
    );
    runtime.stdout = runtime_mod.OutputSink.fromWriter(&stdout_writer);

    try writeJson(&runtime, ResolveV1{
        .originalReference = "registry.example/repo:tag",
        .reference = "registry.example/repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .rootKind = "manifest",
        .rootMediaType = "application/vnd.oci.image.manifest.v1+json",
        .rootDigest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .rootSize = 12,
        .manifestMediaType = "application/vnd.oci.image.manifest.v1+json",
        .manifestDigest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .manifestSize = 12,
    });
    try std.testing.expectEqualStrings(
        "{\"schema\":\"wabt.oci.resolve\",\"schemaVersion\":1,\"originalReference\":\"registry.example/repo:tag\",\"reference\":\"registry.example/repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"rootKind\":\"manifest\",\"rootMediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"rootDigest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"rootSize\":12,\"manifestMediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"manifestDigest\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"manifestSize\":12}\n",
        output[0..stdout_writer.end],
    );
}

test "inspect and pull DTO JSON schemas are stable" {
    const descriptor_value: DescriptorV1 = .{
        .mediaType = "application/wasm",
        .digest = "sha256:abc",
        .size = 8,
    };
    var bytes: [2048]u8 = undefined;
    var stdout_writer = std.Io.Writer.fixed(&bytes);
    var counters: runtime_mod.Counters = .{};
    var runtime = runtime_mod.Runtime.initForTest(
        std.testing.allocator,
        std.testing.io,
        &counters,
    );
    runtime.stdout = runtime_mod.OutputSink.fromWriter(&stdout_writer);

    try writeJson(&runtime, InspectV1{
        .originalReference = "oci:layout",
        .reference = "oci:layout@sha256:abc",
        .root = descriptor_value,
        .documentKind = "manifest",
        .artifactType = null,
        .subject = null,
        .manifest = descriptor_value,
        .profile = "oci-1.0",
        .config = descriptor_value,
        .payload = descriptor_value,
        .graph = .{
            .documents = 1,
            .descriptors = 3,
            .totalSize = 24,
        },
    });
    try std.testing.expectEqualStrings(
        "{\"schema\":\"wabt.oci.inspect\",\"schemaVersion\":1,\"originalReference\":\"oci:layout\",\"reference\":\"oci:layout@sha256:abc\",\"root\":{\"mediaType\":\"application/wasm\",\"digest\":\"sha256:abc\",\"size\":8},\"documentKind\":\"manifest\",\"artifactType\":null,\"subject\":null,\"manifest\":{\"mediaType\":\"application/wasm\",\"digest\":\"sha256:abc\",\"size\":8},\"profile\":\"oci-1.0\",\"config\":{\"mediaType\":\"application/wasm\",\"digest\":\"sha256:abc\",\"size\":8},\"payload\":{\"mediaType\":\"application/wasm\",\"digest\":\"sha256:abc\",\"size\":8},\"graph\":{\"documents\":1,\"descriptors\":3,\"totalSize\":24}}\n",
        bytes[0..stdout_writer.end],
    );

    stdout_writer = std.Io.Writer.fixed(&bytes);
    try writeJson(&runtime, PullV1{
        .originalReference = "oci:layout",
        .reference = "oci:layout@sha256:abc",
        .root = descriptor_value,
        .manifest = descriptor_value,
        .config = descriptor_value,
        .payload = descriptor_value,
        .profile = "oci-1.0",
        .output = "app.wasm",
        .size = 8,
    });
    try std.testing.expectEqualStrings(
        "{\"schema\":\"wabt.oci.pull\",\"schemaVersion\":1,\"originalReference\":\"oci:layout\",\"reference\":\"oci:layout@sha256:abc\",\"root\":{\"mediaType\":\"application/wasm\",\"digest\":\"sha256:abc\",\"size\":8},\"manifest\":{\"mediaType\":\"application/wasm\",\"digest\":\"sha256:abc\",\"size\":8},\"config\":{\"mediaType\":\"application/wasm\",\"digest\":\"sha256:abc\",\"size\":8},\"payload\":{\"mediaType\":\"application/wasm\",\"digest\":\"sha256:abc\",\"size\":8},\"profile\":\"oci-1.0\",\"output\":\"app.wasm\",\"size\":8}\n",
        bytes[0..stdout_writer.end],
    );
}

test "push and copy DTO JSON schemas are stable" {
    const descriptor_value: DescriptorV1 = .{
        .mediaType = "application/vnd.oci.image.manifest.v1+json",
        .digest = "sha256:abc",
        .size = 8,
    };
    var bytes: [4096]u8 = undefined;
    var stdout_writer = std.Io.Writer.fixed(&bytes);
    var counters: runtime_mod.Counters = .{};
    var runtime = runtime_mod.Runtime.initForTest(
        std.testing.allocator,
        std.testing.io,
        &counters,
    );
    runtime.stdout = runtime_mod.OutputSink.fromWriter(&stdout_writer);

    try writeJson(&runtime, PushV1{
        .originalReference = "registry.example/repo:tag",
        .reference = "registry.example/repo@sha256:abc",
        .profile = "wasm-v0",
        .created = "2026-09-19T00:00:00Z",
        .createdSource = "explicit",
        .root = descriptor_value,
        .manifest = descriptor_value,
        .config = descriptor_value,
        .payload = descriptor_value,
    });
    try std.testing.expectEqualStrings(
        "{\"schema\":\"wabt.oci.push\",\"schemaVersion\":1,\"originalReference\":\"registry.example/repo:tag\",\"reference\":\"registry.example/repo@sha256:abc\",\"profile\":\"wasm-v0\",\"created\":\"2026-09-19T00:00:00Z\",\"createdSource\":\"explicit\",\"root\":{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"sha256:abc\",\"size\":8},\"manifest\":{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"sha256:abc\",\"size\":8},\"config\":{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"sha256:abc\",\"size\":8},\"payload\":{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"sha256:abc\",\"size\":8}}\n",
        bytes[0..stdout_writer.end],
    );

    stdout_writer = std.Io.Writer.fixed(&bytes);
    try writeJson(&runtime, CopyV1{
        .sourceReference = "oci:source:tag",
        .sourceRootReference = "oci:source@sha256:abc",
        .destinationReference = "registry.example/repo:tag",
        .destinationRootReference = "registry.example/repo@sha256:abc",
        .root = descriptor_value,
        .transferred = 3,
        .reused = 2,
        .mounted = 1,
    });
    try std.testing.expectEqualStrings(
        "{\"schema\":\"wabt.oci.copy\",\"schemaVersion\":1,\"sourceReference\":\"oci:source:tag\",\"sourceRootReference\":\"oci:source@sha256:abc\",\"destinationReference\":\"registry.example/repo:tag\",\"destinationRootReference\":\"registry.example/repo@sha256:abc\",\"root\":{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"sha256:abc\",\"size\":8},\"transferred\":3,\"reused\":2,\"mounted\":1}\n",
        bytes[0..stdout_writer.end],
    );
}

test "diagnostic writes are checked and execution categories stay distinct" {
    var counters: runtime_mod.Counters = .{};
    var runtime = runtime_mod.Runtime.initForTest(
        std.testing.allocator,
        std.testing.io,
        &counters,
    );
    var failing = std.Io.Writer.failing;
    runtime.stderr = runtime_mod.OutputSink.fromWriter(&failing);
    try std.testing.expectError(
        error.StderrWriteFailed,
        writeDiagnostic(&runtime, "resolve", error.AuthenticationFailed),
    );
    try std.testing.expectEqual(
        error.AuthenticationFailed,
        mapExecutionError(error.CredentialNotFound),
    );
    try std.testing.expectEqual(
        error.CertificateAuthorityFailed,
        mapExecutionError(error.CertificateAuthorityLoadFailed),
    );
    try std.testing.expectEqual(
        error.DeadlineExceeded,
        mapExecutionError(error.DeadlineOverflow),
    );
    try std.testing.expectEqual(
        error.LocalWriteFailed,
        mapLocalWriteError(error.FileNotFound),
    );
}
