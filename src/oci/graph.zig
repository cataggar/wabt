//! Bounded, role-aware discovery and planning for complete OCI graphs.
const std = @import("std");
const content = @import("content.zig");
const model = @import("model.zig");
const transport = @import("transport.zig");

pub const Limits = struct {
    max_depth: u64 = 32,
    max_nodes: u64 = 10_000,
    max_total_bytes: u64 = 64 * 1024 * 1024 * 1024,
    max_metadata_bytes: u64 = 16 * 1024 * 1024,
};

pub const Error = error{
    MaximumDepthExceeded,
    MaximumDescriptorsExceeded,
    MaximumTotalBytesExceeded,
    TotalSizeOverflow,
    MaximumMetadataBytesExceeded,
    SourceContractViolation,
    CycleDetected,
    ConflictingDescriptor,
    UnsupportedGraphNode,
    SubjectGraphUnsupported,
    DescriptorDocumentMismatch,
    RootDescriptorMismatch,
};

pub const Root = struct {
    descriptor: model.Descriptor,
    /// Exact selected-root descriptor JSON, when available.
    descriptor_json: ?[]const u8 = null,
};

pub const Dependency = struct {
    descriptor: model.Descriptor,
    role: transport.DescriptorRole,
};

pub const NodeView = union(model.DocumentKind) {
    index: model.Index,
    manifest: model.Manifest,
};

pub const Node = struct {
    descriptor: model.Descriptor,
    exact_bytes: []const u8,
    dependencies: []const Dependency,
    subject: ?model.Descriptor,
    view: NodeView,

    pub fn kind(self: Node) model.DocumentKind {
        return std.meta.activeTag(self.view);
    }
};

pub const ExactMetadata = struct {
    bytes: []const u8,
    kind: model.DocumentKind,
    node_index: usize,
};

pub const EntryData = union(enum) {
    exact_metadata: ExactMetadata,
    opaque_blob,
};

pub const Entry = struct {
    descriptor: model.Descriptor,
    roles: transport.DescriptorRoles,
    data: EntryData,

    pub fn transfer(
        self: Entry,
        source: transport.Source,
    ) transport.DescriptorTransfer {
        return .{
            .descriptor = self.descriptor,
            .roles = self.roles,
            .data = switch (self.data) {
                .exact_metadata => |metadata| .{
                    .exact_metadata = metadata.bytes,
                },
                .opaque_blob => .{ .opaque_blob = source },
            },
        };
    }
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    storage: std.heap.ArenaAllocator,
    records: []Record,

    entries: []Entry,
    nodes: []Node,
    root_entry_index: usize,
    total_bytes: u64,

    root_descriptor_json: ?[]const u8,
    root_descriptor_value: ?std.json.Parsed(std.json.Value),

    pub fn deinit(self: *Plan) void {
        if (self.root_descriptor_value) |*value| value.deinit();
        self.allocator.free(self.nodes);
        self.allocator.free(self.entries);
        for (self.records) |*record| record.deinit();
        self.allocator.free(self.records);
        self.storage.deinit();
        self.* = undefined;
    }

    pub fn rootEntry(self: *const Plan) *const Entry {
        return &self.entries[self.root_entry_index];
    }

    pub fn rootNode(self: *const Plan) *const Node {
        const metadata = self.rootEntry().data.exact_metadata;
        return &self.nodes[metadata.node_index];
    }

    pub fn dependencyEntries(self: *const Plan) []const Entry {
        return self.entries[0..self.root_entry_index];
    }

    pub fn rootPublication(self: *const Plan) transport.RootPublication {
        return .{
            .descriptor = self.rootEntry().descriptor,
            .descriptor_json = self.root_descriptor_json,
            .exact_bytes = self.rootEntry().data.exact_metadata.bytes,
        };
    }
};

const RecordState = enum {
    active,
    completed,
};

const Edge = struct {
    target: usize,
    role: transport.DescriptorRole,
};

const Record = struct {
    descriptor: model.Descriptor,
    digest: content.Digest,
    roles: transport.DescriptorRoles,
    state: RecordState,
    dependencies: std.array_list.Managed(Edge),
    metadata: ?transport.Metadata = null,
    document: ?model.ParsedDocument = null,

    fn deinit(self: *Record) void {
        if (self.document) |*document| document.deinit();
        if (self.metadata) |*metadata| metadata.deinit();
        self.dependencies.deinit();
        self.* = undefined;
    }
};

const Context = struct {
    allocator: std.mem.Allocator,
    source: transport.Source,
    limits: Limits,
    records: std.array_list.Managed(Record),
    by_digest: std.AutoHashMap(content.Digest, usize),
    total_bytes: u64 = 0,

    fn init(
        allocator: std.mem.Allocator,
        source: transport.Source,
        limits: Limits,
    ) Context {
        return .{
            .allocator = allocator,
            .source = source,
            .limits = limits,
            .records = std.array_list.Managed(Record).init(allocator),
            .by_digest = std.AutoHashMap(content.Digest, usize).init(allocator),
        };
    }

    fn deinit(self: *Context) void {
        for (self.records.items) |*record| record.deinit();
        self.records.deinit();
        self.by_digest.deinit();
    }

    fn visit(
        self: *Context,
        descriptor: model.Descriptor,
        role: transport.DescriptorRole,
        depth: u64,
    ) anyerror!usize {
        if (depth > self.limits.max_depth) return error.MaximumDepthExceeded;

        const digest = try model.validateDescriptor(descriptor);
        const requires_document = role == .root or role == .index_child;
        if (requires_document and
            !model.classifyMediaType(descriptor.mediaType).isDocument())
        {
            return error.UnsupportedGraphNode;
        }
        if (requires_document and
            descriptor.size > self.limits.max_metadata_bytes)
        {
            return error.MaximumMetadataBytesExceeded;
        }

        if (self.by_digest.get(digest)) |index| {
            const previous = self.records.items[index].descriptor;
            if (previous.size != descriptor.size or
                !std.mem.eql(u8, previous.mediaType, descriptor.mediaType))
            {
                return error.ConflictingDescriptor;
            }

            self.records.items[index].roles.add(role);
            if (self.records.items[index].state == .active) {
                return error.CycleDetected;
            }
            if (requires_document and self.records.items[index].document == null) {
                self.records.items[index].state = .active;
                try self.discoverDocument(index, descriptor, depth);
            }
            return index;
        }

        const node_count: u64 = @intCast(self.records.items.len);
        if (node_count >= self.limits.max_nodes) {
            return error.MaximumDescriptorsExceeded;
        }
        const new_total = std.math.add(
            u64,
            self.total_bytes,
            descriptor.size,
        ) catch return error.TotalSizeOverflow;
        if (new_total > self.limits.max_total_bytes) {
            return error.MaximumTotalBytesExceeded;
        }

        const index = self.records.items.len;
        try self.records.append(.{
            .descriptor = descriptor,
            .digest = digest,
            .roles = transport.DescriptorRoles.init(role),
            .state = if (requires_document) .active else .completed,
            .dependencies = std.array_list.Managed(Edge).init(self.allocator),
        });
        self.by_digest.put(digest, index) catch |err| {
            self.records.items[index].dependencies.deinit();
            self.records.items.len = index;
            return err;
        };
        self.total_bytes = new_total;

        if (requires_document) {
            try self.discoverDocument(index, descriptor, depth);
        }
        return index;
    }

    fn discoverDocument(
        self: *Context,
        index: usize,
        descriptor: model.Descriptor,
        depth: u64,
    ) anyerror!void {
        if (descriptor.size > self.limits.max_metadata_bytes) {
            return error.MaximumMetadataBytesExceeded;
        }

        var metadata = try self.source.readMetadata(
            self.allocator,
            descriptor,
            self.limits.max_metadata_bytes,
        );
        var metadata_owned = true;
        defer if (metadata_owned) metadata.deinit();

        const actual_size = try content.checkedSize(metadata.bytes.len);
        if (actual_size > self.limits.max_metadata_bytes) {
            return error.SourceContractViolation;
        }
        try content.verifyBytes(
            self.records.items[index].digest,
            descriptor.size,
            metadata.bytes,
        );

        var document = try model.parseDocument(self.allocator, metadata.bytes);
        var document_owned = true;
        defer if (document_owned) document.deinit();

        const descriptor_class = model.classifyMediaType(descriptor.mediaType);
        if ((descriptor_class.isIndex() and document.kind() != .index) or
            (descriptor_class.isManifest() and document.kind() != .manifest))
        {
            return error.DescriptorDocumentMismatch;
        }
        const document_media_type = switch (document.value) {
            .index => |parsed| parsed.value.mediaType,
            .manifest => |parsed| parsed.value.mediaType,
        };
        if (document_media_type) |actual| {
            if (!std.mem.eql(u8, actual, descriptor.mediaType)) {
                return error.DescriptorDocumentMismatch;
            }
        }

        const subject = switch (document.value) {
            .index => |parsed| parsed.value.subject,
            .manifest => |parsed| parsed.value.subject,
        };
        if (subject != null) return error.SubjectGraphUnsupported;

        const child_depth = std.math.add(u64, depth, 1) catch
            return error.MaximumDepthExceeded;
        switch (document.value) {
            .index => |parsed| {
                for (parsed.value.manifests) |child| {
                    const child_index = try self.visit(
                        child,
                        .index_child,
                        child_depth,
                    );
                    try self.records.items[index].dependencies.append(.{
                        .target = child_index,
                        .role = .index_child,
                    });
                }
            },
            .manifest => |parsed| {
                const config_index = try self.visit(
                    parsed.value.config,
                    .config,
                    child_depth,
                );
                try self.records.items[index].dependencies.append(.{
                    .target = config_index,
                    .role = .config,
                });
                for (parsed.value.layers) |layer| {
                    const layer_index = try self.visit(
                        layer,
                        .layer,
                        child_depth,
                    );
                    try self.records.items[index].dependencies.append(.{
                        .target = layer_index,
                        .role = .layer,
                    });
                }
            },
        }

        self.records.items[index].metadata = metadata;
        metadata_owned = false;
        self.records.items[index].document = document;
        document_owned = false;
        self.records.items[index].state = .completed;
    }

    fn finish(
        self: *Context,
        root_index: usize,
        root_descriptor_json: ?[]const u8,
    ) !Plan {
        var storage = std.heap.ArenaAllocator.init(self.allocator);
        errdefer storage.deinit();
        const storage_allocator = storage.allocator();

        var descriptor_json_copy: ?[]const u8 = null;
        var descriptor_value: ?std.json.Parsed(std.json.Value) = null;
        errdefer if (descriptor_value) |*value| value.deinit();

        if (root_descriptor_json) |json| {
            descriptor_json_copy = try storage_allocator.dupe(u8, json);
            var parsed_descriptor = try std.json.parseFromSlice(
                model.Descriptor,
                self.allocator,
                json,
                .{ .ignore_unknown_fields = true },
            );
            defer parsed_descriptor.deinit();
            _ = try model.validateDescriptor(parsed_descriptor.value);
            if (!descriptorIdentityEqual(
                parsed_descriptor.value,
                self.records.items[root_index].descriptor,
            )) {
                return error.RootDescriptorMismatch;
            }
            self.records.items[root_index].descriptor = try cloneDescriptor(
                storage_allocator,
                parsed_descriptor.value,
            );
            descriptor_value = try std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                descriptor_json_copy.?,
                .{},
            );
            if (descriptor_value.?.value != .object) {
                return error.RootDescriptorMismatch;
            }
        } else {
            self.records.items[root_index].descriptor = try cloneDescriptor(
                storage_allocator,
                self.records.items[root_index].descriptor,
            );
        }

        const order = try topologicalOrder(
            self.allocator,
            self.records.items,
            root_index,
        );
        defer self.allocator.free(order);

        var node_count: usize = 0;
        for (self.records.items) |record| {
            if (record.document != null) node_count += 1;
        }
        const nodes = try self.allocator.alloc(Node, node_count);
        errdefer self.allocator.free(nodes);
        const node_for_record = try self.allocator.alloc(
            ?usize,
            self.records.items.len,
        );
        defer self.allocator.free(node_for_record);
        @memset(node_for_record, null);

        var next_node: usize = 0;
        for (self.records.items, 0..) |record, record_index| {
            const document = record.document orelse continue;
            const dependencies = try storage_allocator.alloc(
                Dependency,
                record.dependencies.items.len,
            );
            for (record.dependencies.items, 0..) |edge, dependency_index| {
                dependencies[dependency_index] = .{
                    .descriptor = self.records.items[edge.target].descriptor,
                    .role = edge.role,
                };
            }

            const view: NodeView = switch (document.value) {
                .index => |parsed| .{ .index = parsed.value },
                .manifest => |parsed| .{ .manifest = parsed.value },
            };
            const subject = switch (view) {
                .index => |index_view| index_view.subject,
                .manifest => |manifest_view| manifest_view.subject,
            };
            nodes[next_node] = .{
                .descriptor = record.descriptor,
                .exact_bytes = record.metadata.?.bytes,
                .dependencies = dependencies,
                .subject = subject,
                .view = view,
            };
            node_for_record[record_index] = next_node;
            next_node += 1;
        }

        const entries = try self.allocator.alloc(Entry, order.len);
        errdefer self.allocator.free(entries);
        for (order, 0..) |record_index, entry_index| {
            const record = self.records.items[record_index];
            entries[entry_index] = .{
                .descriptor = record.descriptor,
                .roles = record.roles,
                .data = if (record.document) |document|
                    .{ .exact_metadata = .{
                        .bytes = record.metadata.?.bytes,
                        .kind = document.kind(),
                        .node_index = node_for_record[record_index].?,
                    } }
                else
                    .opaque_blob,
            };
        }
        if (order.len == 0 or order[order.len - 1] != root_index) {
            return error.CycleDetected;
        }

        const records = try self.records.toOwnedSlice();
        return .{
            .allocator = self.allocator,
            .storage = storage,
            .records = records,
            .entries = entries,
            .nodes = nodes,
            .root_entry_index = entries.len - 1,
            .total_bytes = self.total_bytes,
            .root_descriptor_json = descriptor_json_copy,
            .root_descriptor_value = descriptor_value,
        };
    }
};

pub fn planCopy(
    allocator: std.mem.Allocator,
    source: transport.Source,
    root: Root,
    limits: Limits,
) !Plan {
    var context = Context.init(allocator, source, limits);
    defer context.deinit();

    const root_index = try context.visit(root.descriptor, .root, 0);
    return context.finish(root_index, root.descriptor_json);
}

fn descriptorIdentityEqual(a: model.Descriptor, b: model.Descriptor) bool {
    return a.size == b.size and
        std.mem.eql(u8, a.mediaType, b.mediaType) and
        std.mem.eql(u8, a.digest, b.digest);
}

fn cloneDescriptor(
    allocator: std.mem.Allocator,
    descriptor: model.Descriptor,
) !model.Descriptor {
    return .{
        .mediaType = try allocator.dupe(u8, descriptor.mediaType),
        .digest = try allocator.dupe(u8, descriptor.digest),
        .size = descriptor.size,
        .urls = try cloneOptionalStrings(allocator, descriptor.urls),
        .annotations = if (descriptor.annotations) |annotations|
            try cloneAnnotations(allocator, annotations)
        else
            null,
        .data = if (descriptor.data) |data|
            try allocator.dupe(u8, data)
        else
            null,
        .artifactType = if (descriptor.artifactType) |artifact_type|
            try allocator.dupe(u8, artifact_type)
        else
            null,
        .platform = if (descriptor.platform) |platform|
            try clonePlatform(allocator, platform)
        else
            null,
    };
}

fn cloneOptionalStrings(
    allocator: std.mem.Allocator,
    values: ?[]const []const u8,
) !?[]const []const u8 {
    const source = values orelse return null;
    const result = try allocator.alloc([]const u8, source.len);
    for (source, 0..) |value, index| {
        result[index] = try allocator.dupe(u8, value);
    }
    return result;
}

fn cloneAnnotations(
    allocator: std.mem.Allocator,
    annotations: model.Annotations,
) !model.Annotations {
    const source = annotations.object;
    var result: std.json.ObjectMap = .{};
    var iterator = source.iterator();
    while (iterator.next()) |entry| {
        try result.put(
            allocator,
            try allocator.dupe(u8, entry.key_ptr.*),
            .{ .string = try allocator.dupe(u8, entry.value_ptr.string) },
        );
    }
    return .{ .object = result };
}

fn clonePlatform(
    allocator: std.mem.Allocator,
    platform: model.Platform,
) !model.Platform {
    return .{
        .architecture = try allocator.dupe(u8, platform.architecture),
        .os = try allocator.dupe(u8, platform.os),
        .@"os.version" = if (platform.@"os.version") |version|
            try allocator.dupe(u8, version)
        else
            null,
        .@"os.features" = try cloneOptionalStrings(
            allocator,
            platform.@"os.features",
        ),
        .variant = if (platform.variant) |variant|
            try allocator.dupe(u8, variant)
        else
            null,
        .features = try cloneOptionalStrings(allocator, platform.features),
    };
}

const VisitState = enum {
    unvisited,
    active,
    completed,
};

fn topologicalOrder(
    allocator: std.mem.Allocator,
    records: []const Record,
    root_index: usize,
) ![]usize {
    const states = try allocator.alloc(VisitState, records.len);
    defer allocator.free(states);
    @memset(states, .unvisited);

    var order = std.array_list.Managed(usize).init(allocator);
    errdefer order.deinit();
    try appendTopological(records, root_index, states, &order);
    return order.toOwnedSlice();
}

fn appendTopological(
    records: []const Record,
    index: usize,
    states: []VisitState,
    order: *std.array_list.Managed(usize),
) !void {
    switch (states[index]) {
        .completed => return,
        .active => return error.CycleDetected,
        .unvisited => {},
    }
    states[index] = .active;
    for (records[index].dependencies.items) |edge| {
        try appendTopological(records, edge.target, states, order);
    }
    states[index] = .completed;
    try order.append(index);
}

test "default graph limits are concrete and safe" {
    const limits: Limits = .{};
    try std.testing.expectEqual(@as(u64, 32), limits.max_depth);
    try std.testing.expectEqual(@as(u64, 10_000), limits.max_nodes);
    try std.testing.expectEqual(
        @as(u64, 64 * 1024 * 1024 * 1024),
        limits.max_total_bytes,
    );
    try std.testing.expectEqual(
        @as(u64, 16 * 1024 * 1024),
        limits.max_metadata_bytes,
    );
}

const TestDocument = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    digest_text: [content.digest_text_size]u8,
    media_type: []const u8,

    fn init(
        allocator: std.mem.Allocator,
        bytes: []u8,
        media_type: []const u8,
    ) TestDocument {
        return .{
            .allocator = allocator,
            .bytes = bytes,
            .digest_text = content.digestBytes(bytes).format(),
            .media_type = media_type,
        };
    }

    fn descriptor(self: *const TestDocument) model.Descriptor {
        return .{
            .mediaType = self.media_type,
            .digest = &self.digest_text,
            .size = @intCast(self.bytes.len),
        };
    }

    fn mapping(self: *const TestDocument) TestMapping {
        return .{ .digest = &self.digest_text, .bytes = self.bytes };
    }

    fn deinit(self: *TestDocument) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

const TestBlob = struct {
    digest_text: [content.digest_text_size]u8,
    media_type: []const u8,
    size: u64,

    fn init(seed: []const u8, media_type: []const u8, size: u64) TestBlob {
        return .{
            .digest_text = content.digestBytes(seed).format(),
            .media_type = media_type,
            .size = size,
        };
    }

    fn descriptor(self: *const TestBlob) model.Descriptor {
        return .{
            .mediaType = self.media_type,
            .digest = &self.digest_text,
            .size = self.size,
        };
    }
};

const TestMapping = struct {
    digest: []const u8,
    bytes: []const u8,
};

const FakeSource = struct {
    mappings: []const TestMapping,
    metadata_calls: usize = 0,
    copy_calls: usize = 0,
    largest_requested: u64 = 0,
    ignore_limit: bool = false,

    pub fn readMetadata(
        self: *FakeSource,
        allocator: std.mem.Allocator,
        descriptor: model.Descriptor,
        max_bytes: u64,
    ) !transport.Metadata {
        self.metadata_calls += 1;
        self.largest_requested = @max(self.largest_requested, max_bytes);
        for (self.mappings) |mapping| {
            if (!std.mem.eql(u8, mapping.digest, descriptor.digest)) continue;
            if (!self.ignore_limit and mapping.bytes.len > max_bytes) {
                return error.MetadataTooLarge;
            }
            return transport.Metadata.copy(allocator, mapping.bytes);
        }
        return error.DescriptorNotFound;
    }

    pub fn copyVerifiedTo(
        self: *FakeSource,
        _: model.Descriptor,
        _: std.Io.File,
    ) !void {
        self.copy_calls += 1;
    }
};

fn writeTestDescriptor(
    writer: *std.Io.Writer,
    descriptor: model.Descriptor,
) !void {
    try writer.print(
        "{{\"mediaType\":\"{s}\",\"digest\":\"{s}\",\"size\":{d}",
        .{ descriptor.mediaType, descriptor.digest, descriptor.size },
    );
    if (descriptor.platform) |platform| {
        try writer.print(
            ",\"platform\":{{\"architecture\":\"{s}\",\"os\":\"{s}\"",
            .{ platform.architecture, platform.os },
        );
        if (platform.variant) |variant| {
            try writer.print(",\"variant\":\"{s}\"", .{variant});
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("}");
}

fn makeManifest(
    allocator: std.mem.Allocator,
    config: model.Descriptor,
    layers: []const model.Descriptor,
    subject: ?model.Descriptor,
) !TestDocument {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    try writer.print(
        "{{\"schemaVersion\":2,\"mediaType\":\"{s}\",\"config\":",
        .{model.media_type_oci_manifest},
    );
    try writeTestDescriptor(writer, config);
    try writer.writeAll(",\"layers\":[");
    for (layers, 0..) |layer, index| {
        if (index != 0) try writer.writeAll(",");
        try writeTestDescriptor(writer, layer);
    }
    try writer.writeAll("]");
    if (subject) |subject_descriptor| {
        try writer.writeAll(",\"subject\":");
        try writeTestDescriptor(writer, subject_descriptor);
    }
    try writer.writeAll("}");
    return TestDocument.init(
        allocator,
        try output.toOwnedSlice(),
        model.media_type_oci_manifest,
    );
}

fn makeIndex(
    allocator: std.mem.Allocator,
    manifests: []const model.Descriptor,
    subject: ?model.Descriptor,
) !TestDocument {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    try writer.print(
        "{{\"schemaVersion\":2,\"mediaType\":\"{s}\",\"manifests\":[",
        .{model.media_type_oci_index},
    );
    for (manifests, 0..) |manifest, index| {
        if (index != 0) try writer.writeAll(",");
        try writeTestDescriptor(writer, manifest);
    }
    try writer.writeAll("]");
    if (subject) |subject_descriptor| {
        try writer.writeAll(",\"subject\":");
        try writeTestDescriptor(writer, subject_descriptor);
    }
    try writer.writeAll("}");
    return TestDocument.init(
        allocator,
        try output.toOwnedSlice(),
        model.media_type_oci_index,
    );
}

fn planTestGraph(
    allocator: std.mem.Allocator,
    fake: *FakeSource,
    root: Root,
    limits: Limits,
) !Plan {
    return planCopy(allocator, transport.Source.init(fake), root, limits);
}

fn expectEntryDigest(entry: Entry, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, entry.descriptor.digest);
}

fn makeIndexChain(
    allocator: std.mem.Allocator,
    edge_count: usize,
) ![]TestDocument {
    var documents = std.array_list.Managed(TestDocument).init(allocator);
    errdefer {
        for (documents.items) |*document| document.deinit();
        documents.deinit();
    }
    try documents.append(try makeIndex(allocator, &.{}, null));
    var remaining = edge_count;
    while (remaining != 0) : (remaining -= 1) {
        const child = documents.items[documents.items.len - 1].descriptor();
        try documents.append(try makeIndex(allocator, &.{child}, null));
    }
    return documents.toOwnedSlice();
}

fn mappingsForDocuments(
    allocator: std.mem.Allocator,
    documents: []const TestDocument,
) ![]TestMapping {
    const mappings = try allocator.alloc(TestMapping, documents.len);
    for (documents, 0..) |*document, index| {
        mappings[index] = document.mapping();
    }
    return mappings;
}

fn deinitDocuments(
    allocator: std.mem.Allocator,
    documents: []TestDocument,
) void {
    for (documents) |*document| document.deinit();
    allocator.free(documents);
}

test "manifest and nested index plans are deterministic and dependency first" {
    const allocator = std.testing.allocator;
    const config = TestBlob.init(
        "config",
        model.media_type_oci_empty_config,
        7,
    );
    const layer_a = TestBlob.init("layer-a", "application/wasm", 11);
    const layer_b = TestBlob.init(
        "layer-b",
        "application/vnd.example.payload",
        13,
    );
    var manifest = try makeManifest(
        allocator,
        config.descriptor(),
        &.{ layer_a.descriptor(), layer_b.descriptor() },
        null,
    );
    defer manifest.deinit();
    var nested = try makeIndex(allocator, &.{manifest.descriptor()}, null);
    defer nested.deinit();
    var root = try makeIndex(allocator, &.{nested.descriptor()}, null);
    defer root.deinit();

    const mappings = [_]TestMapping{
        root.mapping(),
        nested.mapping(),
        manifest.mapping(),
    };
    var fake: FakeSource = .{ .mappings = &mappings };
    var plan = try planTestGraph(
        allocator,
        &fake,
        .{ .descriptor = root.descriptor() },
        .{},
    );
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 6), plan.entries.len);
    try expectEntryDigest(plan.entries[0], &config.digest_text);
    try expectEntryDigest(plan.entries[1], &layer_a.digest_text);
    try expectEntryDigest(plan.entries[2], &layer_b.digest_text);
    try expectEntryDigest(plan.entries[3], &manifest.digest_text);
    try expectEntryDigest(plan.entries[4], &nested.digest_text);
    try expectEntryDigest(plan.entries[5], &root.digest_text);
    try std.testing.expect(plan.entries[0].data == .opaque_blob);
    try std.testing.expect(plan.entries[3].data == .exact_metadata);
    try std.testing.expectEqual(@as(usize, 3), fake.metadata_calls);
    try std.testing.expectEqual(@as(usize, 3), plan.nodes.len);
}

test "shared descriptors are deduplicated while retaining every role" {
    const allocator = std.testing.allocator;
    const shared = TestBlob.init("shared", "application/wasm", 99);
    var first = try makeManifest(
        allocator,
        shared.descriptor(),
        &.{},
        null,
    );
    defer first.deinit();
    var second = try makeManifest(
        allocator,
        shared.descriptor(),
        &.{shared.descriptor()},
        null,
    );
    defer second.deinit();
    var root = try makeIndex(
        allocator,
        &.{ first.descriptor(), second.descriptor() },
        null,
    );
    defer root.deinit();

    const mappings = [_]TestMapping{
        root.mapping(),
        first.mapping(),
        second.mapping(),
    };
    var fake: FakeSource = .{ .mappings = &mappings };
    var plan = try planTestGraph(
        allocator,
        &fake,
        .{ .descriptor = root.descriptor() },
        .{},
    );
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 4), plan.entries.len);
    try expectEntryDigest(plan.entries[0], &shared.digest_text);
    try std.testing.expect(plan.entries[0].roles.contains(.config));
    try std.testing.expect(plan.entries[0].roles.contains(.layer));
    try expectEntryDigest(plan.entries[1], &first.digest_text);
    try expectEntryDigest(plan.entries[2], &second.digest_text);
    try expectEntryDigest(plan.entries[3], &root.digest_text);
    try std.testing.expectEqual(
        shared.size +
            @as(u64, @intCast(first.bytes.len)) +
            @as(u64, @intCast(second.bytes.len)) +
            @as(u64, @intCast(root.bytes.len)),
        plan.total_bytes,
    );
}

test "depth limit accepts exactly 32 edges and rejects 33" {
    const allocator = std.testing.allocator;
    var exact = try makeIndexChain(allocator, 32);
    defer deinitDocuments(allocator, exact);
    const exact_mappings = try mappingsForDocuments(allocator, exact);
    defer allocator.free(exact_mappings);
    var exact_source: FakeSource = .{ .mappings = exact_mappings };
    var exact_plan = try planTestGraph(
        allocator,
        &exact_source,
        .{ .descriptor = exact[exact.len - 1].descriptor() },
        .{},
    );
    defer exact_plan.deinit();
    try std.testing.expectEqual(@as(usize, 33), exact_plan.entries.len);

    var over = try makeIndexChain(allocator, 33);
    defer deinitDocuments(allocator, over);
    const over_mappings = try mappingsForDocuments(allocator, over);
    defer allocator.free(over_mappings);
    var over_source: FakeSource = .{ .mappings = over_mappings };
    try std.testing.expectError(
        error.MaximumDepthExceeded,
        planTestGraph(
            allocator,
            &over_source,
            .{ .descriptor = over[over.len - 1].descriptor() },
            .{},
        ),
    );
}

test "node and total byte bounds accept exact values and reject one over" {
    const allocator = std.testing.allocator;
    const config = TestBlob.init("count-config", "application/wasm", 5);
    const layer_a = TestBlob.init("count-a", "application/example", 7);
    const layer_b = TestBlob.init("count-b", "application/example", 9);
    var root = try makeManifest(
        allocator,
        config.descriptor(),
        &.{ layer_a.descriptor(), layer_b.descriptor() },
        null,
    );
    defer root.deinit();
    const mappings = [_]TestMapping{root.mapping()};

    const total = @as(u64, @intCast(root.bytes.len)) + 5 + 7 + 9;
    var exact_source: FakeSource = .{ .mappings = &mappings };
    var exact_plan = try planTestGraph(
        allocator,
        &exact_source,
        .{ .descriptor = root.descriptor() },
        .{
            .max_nodes = 4,
            .max_total_bytes = total,
        },
    );
    defer exact_plan.deinit();
    try std.testing.expectEqual(@as(usize, 4), exact_plan.entries.len);
    try std.testing.expectEqual(total, exact_plan.total_bytes);

    var node_source: FakeSource = .{ .mappings = &mappings };
    try std.testing.expectError(
        error.MaximumDescriptorsExceeded,
        planTestGraph(
            allocator,
            &node_source,
            .{ .descriptor = root.descriptor() },
            .{
                .max_nodes = 3,
                .max_total_bytes = total,
            },
        ),
    );

    var byte_source: FakeSource = .{ .mappings = &mappings };
    try std.testing.expectError(
        error.MaximumTotalBytesExceeded,
        planTestGraph(
            allocator,
            &byte_source,
            .{ .descriptor = root.descriptor() },
            .{
                .max_nodes = 4,
                .max_total_bytes = total - 1,
            },
        ),
    );
}

test "total size arithmetic overflow is distinct from configured limit" {
    const allocator = std.testing.allocator;
    const enormous = TestBlob.init(
        "enormous",
        "application/example",
        std.math.maxInt(u64),
    );
    var root = try makeManifest(
        allocator,
        enormous.descriptor(),
        &.{},
        null,
    );
    defer root.deinit();
    const mappings = [_]TestMapping{root.mapping()};
    var fake: FakeSource = .{ .mappings = &mappings };
    try std.testing.expectError(
        error.TotalSizeOverflow,
        planTestGraph(
            allocator,
            &fake,
            .{ .descriptor = root.descriptor() },
            .{ .max_total_bytes = std.math.maxInt(u64) },
        ),
    );
}

test "oversized metadata is rejected before asking the source to allocate" {
    const descriptor: model.Descriptor = .{
        .mediaType = model.media_type_oci_index,
        .digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .size = 17,
    };
    var fake: FakeSource = .{ .mappings = &.{} };
    try std.testing.expectError(
        error.MaximumMetadataBytesExceeded,
        planTestGraph(
            std.testing.allocator,
            &fake,
            .{ .descriptor = descriptor },
            .{ .max_metadata_bytes = 16 },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.metadata_calls);
}

test "topological cycle detection rejects active digest loops" {
    const allocator = std.testing.allocator;
    const descriptor_a: model.Descriptor = .{
        .mediaType = model.media_type_oci_index,
        .digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .size = 1,
    };
    const descriptor_b: model.Descriptor = .{
        .mediaType = model.media_type_oci_index,
        .digest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .size = 1,
    };
    var records = [_]Record{
        .{
            .descriptor = descriptor_a,
            .digest = try content.Digest.parse(descriptor_a.digest),
            .roles = transport.DescriptorRoles.init(.root),
            .state = .completed,
            .dependencies = std.array_list.Managed(Edge).init(allocator),
        },
        .{
            .descriptor = descriptor_b,
            .digest = try content.Digest.parse(descriptor_b.digest),
            .roles = transport.DescriptorRoles.init(.index_child),
            .state = .completed,
            .dependencies = std.array_list.Managed(Edge).init(allocator),
        },
    };
    defer for (&records) |*record| record.deinit();
    try records[0].dependencies.append(.{ .target = 1, .role = .index_child });
    try records[1].dependencies.append(.{ .target = 0, .role = .index_child });
    try std.testing.expectError(
        error.CycleDetected,
        topologicalOrder(allocator, &records, 0),
    );

    var fake: FakeSource = .{ .mappings = &.{} };
    var context = Context.init(
        allocator,
        transport.Source.init(&fake),
        .{},
    );
    defer context.deinit();
    try context.records.append(.{
        .descriptor = descriptor_a,
        .digest = try content.Digest.parse(descriptor_a.digest),
        .roles = transport.DescriptorRoles.init(.root),
        .state = .active,
        .dependencies = std.array_list.Managed(Edge).init(allocator),
    });
    try context.by_digest.put(
        try content.Digest.parse(descriptor_a.digest),
        0,
    );
    try std.testing.expectError(
        error.CycleDetected,
        context.visit(descriptor_a, .index_child, 1),
    );
}

test "same digest descriptor conflicts reject size and media type changes" {
    const allocator = std.testing.allocator;
    const base = TestBlob.init("conflict", "application/wasm", 4);

    var size_conflict = base.descriptor();
    size_conflict.size = 5;
    var size_root = try makeManifest(
        allocator,
        base.descriptor(),
        &.{size_conflict},
        null,
    );
    defer size_root.deinit();
    const size_mappings = [_]TestMapping{size_root.mapping()};
    var size_source: FakeSource = .{ .mappings = &size_mappings };
    try std.testing.expectError(
        error.ConflictingDescriptor,
        planTestGraph(
            allocator,
            &size_source,
            .{ .descriptor = size_root.descriptor() },
            .{},
        ),
    );

    var media_conflict = base.descriptor();
    media_conflict.mediaType = "application/vnd.example.other";
    var media_root = try makeManifest(
        allocator,
        base.descriptor(),
        &.{media_conflict},
        null,
    );
    defer media_root.deinit();
    const media_mappings = [_]TestMapping{media_root.mapping()};
    var media_source: FakeSource = .{ .mappings = &media_mappings };
    try std.testing.expectError(
        error.ConflictingDescriptor,
        planTestGraph(
            allocator,
            &media_source,
            .{ .descriptor = media_root.descriptor() },
            .{},
        ),
    );
}

test "metadata digest and declared size are independently verified" {
    const allocator = std.testing.allocator;
    var root = try makeIndex(allocator, &.{}, null);
    defer root.deinit();

    const wrong_digest = content.digestBytes("different").format();
    var digest_descriptor = root.descriptor();
    digest_descriptor.digest = &wrong_digest;
    const digest_mappings = [_]TestMapping{.{
        .digest = &wrong_digest,
        .bytes = root.bytes,
    }};
    var digest_source: FakeSource = .{ .mappings = &digest_mappings };
    try std.testing.expectError(
        error.DigestMismatch,
        planTestGraph(
            allocator,
            &digest_source,
            .{ .descriptor = digest_descriptor },
            .{},
        ),
    );

    var size_descriptor = root.descriptor();
    size_descriptor.size += 1;
    const size_mappings = [_]TestMapping{.{
        .digest = size_descriptor.digest,
        .bytes = root.bytes,
    }};
    var size_source: FakeSource = .{ .mappings = &size_mappings };
    try std.testing.expectError(
        error.SizeMismatch,
        planTestGraph(
            allocator,
            &size_source,
            .{ .descriptor = size_descriptor },
            .{},
        ),
    );
}

test "unsupported root and index child formats have a dedicated error" {
    const allocator = std.testing.allocator;
    const unknown = TestBlob.init(
        "unknown-document",
        "application/vnd.example.unknown+json",
        10,
    );
    var root_source: FakeSource = .{ .mappings = &.{} };
    try std.testing.expectError(
        error.UnsupportedGraphNode,
        planTestGraph(
            allocator,
            &root_source,
            .{ .descriptor = unknown.descriptor() },
            .{},
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), root_source.metadata_calls);

    var index = try makeIndex(allocator, &.{unknown.descriptor()}, null);
    defer index.deinit();
    const mappings = [_]TestMapping{index.mapping()};
    var child_source: FakeSource = .{ .mappings = &mappings };
    try std.testing.expectError(
        error.UnsupportedGraphNode,
        planTestGraph(
            allocator,
            &child_source,
            .{ .descriptor = index.descriptor() },
            .{},
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), child_source.metadata_calls);
}

test "opaque artifact config and layers are accepted without image validation" {
    const allocator = std.testing.allocator;
    const config = TestBlob.init(
        "empty-json",
        model.media_type_oci_empty_config,
        2,
    );
    const layer = TestBlob.init("module", "application/wasm", 123);
    var root = try makeManifest(
        allocator,
        config.descriptor(),
        &.{layer.descriptor()},
        null,
    );
    defer root.deinit();
    const mappings = [_]TestMapping{root.mapping()};
    var fake: FakeSource = .{ .mappings = &mappings };
    var plan = try planTestGraph(
        allocator,
        &fake,
        .{ .descriptor = root.descriptor() },
        .{},
    );
    defer plan.deinit();

    const manifest = plan.rootNode().view.manifest;
    try model.validateArtifactManifest(manifest);
    try std.testing.expectError(
        error.UnsupportedConfigMediaType,
        model.validateImageManifest(manifest),
    );
    try std.testing.expectEqual(@as(usize, 3), plan.entries.len);
    try std.testing.expect(plan.entries[0].data == .opaque_blob);
    try std.testing.expect(plan.entries[1].data == .opaque_blob);
}

test "root and nested subjects are rejected" {
    const allocator = std.testing.allocator;
    const subject = TestBlob.init(
        "subject",
        model.media_type_oci_manifest,
        42,
    );
    var subject_root = try makeIndex(
        allocator,
        &.{},
        subject.descriptor(),
    );
    defer subject_root.deinit();
    const root_mappings = [_]TestMapping{subject_root.mapping()};
    var root_source: FakeSource = .{ .mappings = &root_mappings };
    try std.testing.expectError(
        error.SubjectGraphUnsupported,
        planTestGraph(
            allocator,
            &root_source,
            .{ .descriptor = subject_root.descriptor() },
            .{},
        ),
    );

    const config = TestBlob.init("nested-config", "application/wasm", 1);
    var child = try makeManifest(
        allocator,
        config.descriptor(),
        &.{},
        subject.descriptor(),
    );
    defer child.deinit();
    var index = try makeIndex(allocator, &.{child.descriptor()}, null);
    defer index.deinit();
    const nested_mappings = [_]TestMapping{
        index.mapping(),
        child.mapping(),
    };
    var nested_source: FakeSource = .{ .mappings = &nested_mappings };
    try std.testing.expectError(
        error.SubjectGraphUnsupported,
        planTestGraph(
            allocator,
            &nested_source,
            .{ .descriptor = index.descriptor() },
            .{},
        ),
    );
}

test "exact metadata and original root descriptor JSON are retained" {
    const allocator = std.testing.allocator;
    const raw =
        "{ \n \"schemaVersion\" : 2, \"mediaType\" : " ++
        "\"application/vnd.oci.image.index.v1+json\", \"manifests\" : [] }\n";
    var root = TestDocument.init(
        allocator,
        try allocator.dupe(u8, raw),
        model.media_type_oci_index,
    );
    defer root.deinit();
    const descriptor = root.descriptor();
    const descriptor_json = try std.fmt.allocPrint(
        allocator,
        "{{\"mediaType\":\"{s}\",\"digest\":\"{s}\",\"size\":{d},\"x-root\":true}}",
        .{ descriptor.mediaType, descriptor.digest, descriptor.size },
    );
    defer allocator.free(descriptor_json);
    const mappings = [_]TestMapping{root.mapping()};
    var fake: FakeSource = .{ .mappings = &mappings };
    var plan = try planTestGraph(
        allocator,
        &fake,
        .{
            .descriptor = descriptor,
            .descriptor_json = descriptor_json,
        },
        .{ .max_metadata_bytes = @intCast(root.bytes.len) },
    );
    defer plan.deinit();

    try std.testing.expectEqualStrings(
        raw,
        plan.rootEntry().data.exact_metadata.bytes,
    );
    try std.testing.expectEqualStrings(
        descriptor_json,
        plan.root_descriptor_json.?,
    );
    const extension = plan.root_descriptor_value.?.value.object.get("x-root").?;
    try std.testing.expect(extension.bool);
}

test "all index children are planned without host platform filtering" {
    const allocator = std.testing.allocator;
    const first_config = TestBlob.init("linux-config", "application/wasm", 1);
    const second_config = TestBlob.init("windows-config", "application/wasm", 1);
    var first = try makeManifest(
        allocator,
        first_config.descriptor(),
        &.{},
        null,
    );
    defer first.deinit();
    var second = try makeManifest(
        allocator,
        second_config.descriptor(),
        &.{},
        null,
    );
    defer second.deinit();
    var first_descriptor = first.descriptor();
    first_descriptor.platform = .{
        .architecture = "arm64",
        .os = "linux",
    };
    var second_descriptor = second.descriptor();
    second_descriptor.platform = .{
        .architecture = "amd64",
        .os = "windows",
    };
    var root = try makeIndex(
        allocator,
        &.{ first_descriptor, second_descriptor },
        null,
    );
    defer root.deinit();
    const mappings = [_]TestMapping{
        root.mapping(),
        first.mapping(),
        second.mapping(),
    };
    var fake: FakeSource = .{ .mappings = &mappings };
    var plan = try planTestGraph(
        allocator,
        &fake,
        .{ .descriptor = root.descriptor() },
        .{},
    );
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 5), plan.entries.len);
    try expectEntryDigest(plan.entries[1], &first.digest_text);
    try expectEntryDigest(plan.entries[3], &second.digest_text);
    try std.testing.expectEqual(@as(usize, 3), fake.metadata_calls);
}

test "Docker schema two manifest lists and manifests are complete graph nodes" {
    const allocator = std.testing.allocator;
    const config = TestBlob.init("docker-config", "application/wasm", 2);
    const manifest_bytes = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":2,\"mediaType\":\"{s}\",\"config\":{{\"mediaType\":\"{s}\",\"digest\":\"{s}\",\"size\":{d}}},\"layers\":[]}}",
        .{
            model.media_type_docker_manifest,
            config.media_type,
            &config.digest_text,
            config.size,
        },
    );
    var manifest = TestDocument.init(
        allocator,
        manifest_bytes,
        model.media_type_docker_manifest,
    );
    defer manifest.deinit();
    const index_bytes = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":2,\"mediaType\":\"{s}\",\"manifests\":[{{\"mediaType\":\"{s}\",\"digest\":\"{s}\",\"size\":{d}}}]}}",
        .{
            model.media_type_docker_manifest_list,
            manifest.media_type,
            &manifest.digest_text,
            manifest.bytes.len,
        },
    );
    var root = TestDocument.init(
        allocator,
        index_bytes,
        model.media_type_docker_manifest_list,
    );
    defer root.deinit();
    const mappings = [_]TestMapping{
        root.mapping(),
        manifest.mapping(),
    };
    var fake: FakeSource = .{ .mappings = &mappings };
    var plan = try planTestGraph(
        allocator,
        &fake,
        .{ .descriptor = root.descriptor() },
        .{},
    );
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 3), plan.entries.len);
    try std.testing.expectEqual(model.DocumentKind.index, plan.rootNode().kind());
    try std.testing.expectEqual(
        model.DocumentKind.manifest,
        plan.nodes[1].kind(),
    );
}

test "source metadata responses cannot exceed the requested bound" {
    const descriptor: model.Descriptor = .{
        .mediaType = model.media_type_oci_index,
        .digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .size = 8,
    };
    const mapping = [_]TestMapping{.{
        .digest = descriptor.digest,
        .bytes = "0123456789abcdef0",
    }};
    var fake: FakeSource = .{
        .mappings = &mapping,
        .ignore_limit = true,
    };
    try std.testing.expectError(
        error.SourceContractViolation,
        planTestGraph(
            std.testing.allocator,
            &fake,
            .{ .descriptor = descriptor },
            .{ .max_metadata_bytes = 16 },
        ),
    );
}

test "plan entries adapt directly to transfer and root lifecycle contracts" {
    const allocator = std.testing.allocator;
    const config = TestBlob.init("lifecycle-config", "application/wasm", 1);
    var root = try makeManifest(
        allocator,
        config.descriptor(),
        &.{},
        null,
    );
    defer root.deinit();
    const mappings = [_]TestMapping{root.mapping()};
    var fake: FakeSource = .{ .mappings = &mappings };
    const source = transport.Source.init(&fake);
    var plan = try planCopy(
        allocator,
        source,
        .{ .descriptor = root.descriptor() },
        .{},
    );
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 1), plan.dependencyEntries().len);
    const opaque_transfer = plan.dependencyEntries()[0].transfer(source);
    try std.testing.expect(opaque_transfer.data == .opaque_blob);
    const publication = plan.rootPublication();
    try std.testing.expectEqualStrings(root.bytes, publication.exact_bytes);
    const metadata_transfer = plan.rootEntry().transfer(source);
    try std.testing.expect(metadata_transfer.data == .exact_metadata);
}
