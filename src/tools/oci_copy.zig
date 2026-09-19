const std = @import("std");
const wabt = @import("wabt");
const options = @import("oci_options.zig");
const output = @import("oci_output.zig");
const runtime_mod = @import("oci_runtime.zig");

pub const usage =
    "Usage: wabt oci copy SOURCE DESTINATION [options]\n" ++
    "\n" ++
    "Copy one complete bounded OCI graph without platform selection.\n" ++
    "Registry destinations require an explicit tag. Registry and oci: layout\n" ++
    "endpoints are instantiated independently; layout-only copies stay offline.\n" ++
    "\n" ++
    "Options:\n" ++
    "  --json                            Emit the versioned JSON result\n" ++
    options.copy_endpoint_help;

pub const Options = struct {
    source_text: []const u8,
    source: wabt.oci.Reference,
    destination_text: []const u8,
    destination: wabt.oci.Reference,
    source_endpoint: ?options.EndpointOptions,
    destination_endpoint: ?options.EndpointOptions,
    json: bool = false,

    pub fn stdinRequests(self: Options) StdinRequests {
        var result: StdinRequests = .{ .values = undefined, .len = 0 };
        options.appendStdinRequests(
            self.source_endpoint,
            .source,
            &result.values,
            &result.len,
        );
        options.appendStdinRequests(
            self.destination_endpoint,
            .destination,
            &result.values,
            &result.len,
        );
        return result;
    }
};

pub const StdinRequests = struct {
    values: [2]options.SecretRequest,
    len: usize,
};

pub const Error = options.Error || wabt.oci.reference.Error ||
    output.ExecutionError || error{
    MissingSource,
    MissingDestination,
    UnexpectedArgument,
    DestinationTagRequired,
};

pub fn parseArgs(args: []const []const u8) Error!Options {
    var source_builder: options.EndpointBuilder = .{};
    var destination_builder: options.EndpointBuilder = .{};
    var positionals: [2]?[]const u8 = .{ null, null };
    var positional_count: usize = 0;
    var json = false;
    var json_seen = false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (try source_builder.consume(args, &index, .source)) continue;
        if (try destination_builder.consume(args, &index, .destination)) continue;
        if (std.mem.eql(u8, arg, "--json")) {
            try options.markOnce(&json_seen);
            json = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return if (options.isPlaintextSecretOption(arg))
                error.PlaintextSecretOption
            else
                error.UnknownOption;
        } else {
            if (positional_count == positionals.len) return error.UnexpectedArgument;
            positionals[positional_count] = arg;
            positional_count += 1;
        }
    }

    if (positional_count == 0) return error.MissingSource;
    if (positional_count == 1) return error.MissingDestination;

    const source = try wabt.oci.parseReference(positionals[0].?, .source);
    const destination = try wabt.oci.parseReference(positionals[1].?, .destination);
    if (destination == .registry) {
        const selection = destination.registry.selection orelse
            return error.DestinationTagRequired;
        if (selection != .tag) return error.DestinationTagRequired;
    }
    return .{
        .source_text = positionals[0].?,
        .source = source,
        .destination_text = positionals[1].?,
        .destination = destination,
        .source_endpoint = try source_builder.finish(source),
        .destination_endpoint = try destination_builder.finish(destination),
        .json = json,
    };
}

pub fn execute(
    args: []const []const u8,
    runtime: *runtime_mod.Runtime,
) Error!void {
    const parsed = try parseArgs(args);
    const start = std.fmt.allocPrint(
        runtime.allocator,
        "copying {s} to {s}\n",
        .{ parsed.source_text, parsed.destination_text },
    ) catch return error.OutOfMemory;
    defer runtime.allocator.free(start);
    try output.writeProgress(runtime, start);

    switch (parsed.source) {
        .registry => |reference| {
            var source = runtime.openRegistrySource(
                reference,
                parsed.source_endpoint.?,
            ) catch |err| return output.mapCopyError(err);
            defer source.deinit();
            var resolved = source.resolve(reference) catch |err|
                return output.mapCopyError(err);
            defer resolved.deinit();
            var immutable_source = source.resolvedSource(&resolved);
            try copyResolved(
                runtime,
                parsed,
                resolved.canonical_reference,
                immutable_source.asTransport(),
                resolved.descriptor,
                resolved.descriptor_json,
            );
        },
        .layout => |reference| {
            var source = wabt.oci.LayoutSource.init(
                runtime.io,
                runtime.allocator,
                reference.path,
            );
            var resolved = source.resolve(reference) catch |err|
                return output.mapCopyError(err);
            defer resolved.deinit();
            const canonical = immutableLayoutReferenceAlloc(
                runtime.allocator,
                reference.path,
                resolved.descriptor.digest,
            ) catch return error.OutOfMemory;
            defer runtime.allocator.free(canonical);
            try copyResolved(
                runtime,
                parsed,
                canonical,
                source.asTransport(),
                resolved.descriptor,
                resolved.descriptor_json,
            );
        },
    }
}

fn copyResolved(
    runtime: *runtime_mod.Runtime,
    parsed: Options,
    source_canonical: []const u8,
    source: wabt.oci.Source,
    root_descriptor: wabt.oci.Descriptor,
    root_descriptor_json: ?[]const u8,
) output.ExecutionError!void {
    var plan = wabt.oci.planGraphCopy(
        runtime.allocator,
        source,
        .{
            .descriptor = root_descriptor,
            .descriptor_json = root_descriptor_json,
        },
        runtime.graph_limits,
    ) catch |err| return output.mapCopyError(err);
    defer plan.deinit();

    const result = switch (parsed.destination) {
        .registry => |reference| blk: {
            var destination = runtime.openRegistryDestination(
                reference,
                parsed.destination_endpoint.?,
            ) catch |err| return output.mapCopyError(err);
            defer destination.deinit();
            break :blk wabt.oci.copyPlannedGraph(
                &plan,
                source,
                destination.asTransport(),
                reference.selection,
            ) catch |err| return output.mapCopyError(err);
        },
        .layout => |reference| blk: {
            var destination = wabt.oci.LayoutDestination.init(
                runtime.io,
                runtime.allocator,
                reference.path,
            ) catch |err| return output.mapCopyError(err);
            defer destination.deinit();
            destination.failure_point = runtime.layout_failure_point;
            break :blk wabt.oci.copyPlannedGraph(
                &plan,
                source,
                destination.asTransport(),
                reference.selection,
            ) catch |err| return output.mapCopyError(err);
        },
    };

    const destination_canonical = switch (parsed.destination) {
        .registry => |reference| immutableRegistryReferenceAlloc(
            runtime.allocator,
            reference,
            root_descriptor.digest,
        ),
        .layout => |reference| immutableLayoutReferenceAlloc(
            runtime.allocator,
            reference.path,
            root_descriptor.digest,
        ),
    } catch return error.CommittedButReportingFailed;
    defer runtime.allocator.free(destination_canonical);

    const completed = std.fmt.allocPrint(
        runtime.allocator,
        "committed {s}\n",
        .{destination_canonical},
    ) catch return error.CommittedButReportingFailed;
    defer runtime.allocator.free(completed);
    output.writeProgress(runtime, completed) catch
        return error.CommittedButReportingFailed;

    emit(
        runtime,
        parsed,
        source_canonical,
        destination_canonical,
        root_descriptor,
        result,
    ) catch return error.CommittedButReportingFailed;
}

fn immutableRegistryReferenceAlloc(
    allocator: std.mem.Allocator,
    reference: wabt.oci.RegistryReference,
    digest: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/{s}@{s}",
        .{ reference.authority, reference.repository, digest },
    );
}

fn immutableLayoutReferenceAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    digest: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "oci:{s}@{s}",
        .{ path, digest },
    );
}

fn emit(
    runtime: *runtime_mod.Runtime,
    parsed: Options,
    source_canonical: []const u8,
    destination_canonical: []const u8,
    root_descriptor: wabt.oci.Descriptor,
    result: wabt.oci.TransferResult,
) output.ExecutionError!void {
    if (parsed.json) {
        return output.writeJson(runtime, output.CopyV1{
            .sourceReference = parsed.source_text,
            .sourceRootReference = source_canonical,
            .destinationReference = parsed.destination_text,
            .destinationRootReference = destination_canonical,
            .root = output.descriptor(root_descriptor),
            .transferred = result.counts.transferred,
            .reused = result.counts.reused,
            .mounted = result.counts.mounted,
        });
    }
    const digest_text = result.root.format();
    const line = std.fmt.allocPrint(
        runtime.allocator,
        "{s}\n",
        .{&digest_text},
    ) catch return error.OutOfMemory;
    defer runtime.allocator.free(line);
    return output.writeText(runtime, line);
}

test "copy parses every endpoint pairing and keeps endpoint options separate" {
    const cases = [_][2][]const u8{
        .{ "registry.example/team/source:tag", "registry.example/team/dest:tag" },
        .{ "registry.example/team/source:tag", "oci:layout:dest" },
        .{ "oci:layout:source", "registry.example/team/dest:tag" },
        .{ "oci:source-layout", "oci:destination-layout" },
    };
    for (cases) |case| {
        _ = try parseArgs(&.{ case[0], case[1] });
    }

    const separated = try parseArgs(&.{
        "localhost:5000/team/source:tag",
        "localhost:6000/team/dest:tag",
        "--source-username",
        "source-user",
        "--source-password-stdin",
        "--source-ca-file",
        "source-ca.pem",
        "--source-deadline",
        "3s",
        "--source-plain-http",
        "--destination-token-stdin",
        "--destination-ca-file",
        "destination-ca.pem",
        "--destination-deadline",
        "5s",
        "--destination-plain-http",
        "--json",
    });
    try std.testing.expect(separated.source_endpoint.?.credentials == .basic);
    try std.testing.expect(separated.destination_endpoint.?.credentials == .bearer);
    try std.testing.expectEqualStrings(
        "source-ca.pem",
        separated.source_endpoint.?.additional_ca_file.?,
    );
    try std.testing.expectEqualStrings(
        "destination-ca.pem",
        separated.destination_endpoint.?.additional_ca_file.?,
    );
    const requests = separated.stdinRequests();
    try std.testing.expectEqual(@as(usize, 2), requests.len);
    try std.testing.expectEqual(options.EndpointRole.source, requests.values[0].role);
    try std.testing.expectEqual(options.SecretKind.password, requests.values[0].kind);
    try std.testing.expectEqual(options.EndpointRole.destination, requests.values[1].role);
    try std.testing.expectEqual(options.SecretKind.token, requests.values[1].kind);
}

test "copy rejects registry options on layouts and unprefixed endpoint options" {
    try std.testing.expectError(
        error.RegistryOptionForLayout,
        parseArgs(&.{
            "oci:source-layout",
            "oci:destination-layout",
            "--source-auth-file",
            "auth.json",
        }),
    );
    try std.testing.expectError(
        error.UnknownOption,
        parseArgs(&.{
            "registry.example/team/source:tag",
            "registry.example/team/dest:tag",
            "--auth-file",
            "auth.json",
        }),
    );
    try std.testing.expectError(
        error.DuplicateOption,
        parseArgs(&.{
            "registry.example/team/source:tag",
            "registry.example/team/dest:tag",
            "--source-deadline",
            "1s",
            "--source-deadline",
            "2s",
        }),
    );
    try std.testing.expectError(
        error.MissingSelection,
        parseArgs(&.{
            "registry.example/team/source",
            "registry.example/team/dest:tag",
        }),
    );
    try std.testing.expectError(
        error.UnexpectedArgument,
        parseArgs(&.{ "oci:a", "oci:b", "extra" }),
    );
    try std.testing.expectError(
        error.DestinationTagRequired,
        parseArgs(&.{
            "oci:a",
            "registry.example/team/dest@" ++
                "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        }),
    );
}
