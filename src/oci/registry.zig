//! Verified OCI Distribution registry reads.
//!
//! Registry semantics are layered on the shared authentication and HTTP
//! policy modules. Initialization is explicit; importing this module performs
//! no credential discovery, file access, or network access.
//! Distribution read behavior was adapted from cataggar/miz commit
//! 669a27982b376311f558e820b69e9a692735b0cd (MIT).
const std = @import("std");
const auth = @import("auth.zig");
const content = @import("content.zig");
const graph = @import("graph.zig");
const model = @import("model.zig");
const reference = @import("reference.zig");
const registry_http = @import("registry_http.zig");
const transport = @import("transport.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const manifest_accept =
    model.media_type_oci_manifest ++ ", " ++
    model.media_type_oci_index ++ ", " ++
    model.media_type_docker_manifest ++ ", " ++
    model.media_type_docker_manifest_list;

pub const Error = error{
    InvalidConfiguration,
    InvalidReference,
    AuthenticationFailed,
    AuthorizationDenied,
    ContentNotFound,
    UnsupportedContent,
    InvalidContent,
    TransportFailed,
    TlsValidationFailed,
    DeadlineExceeded,
    RetryLimitExceeded,
    InsecureTransport,
    RedirectRejected,
    LimitExceeded,
    PaginationFailed,
    RegistryFailed,
    UnsupportedCredentialType,
    CertificateAuthorityLoadFailed,
} || Allocator.Error;

pub const Limits = struct {
    max_metadata_bytes: u64 = 16 * 1024 * 1024,
    max_tag_page_bytes: usize = 16 * 1024 * 1024,
    max_tag_pages: usize = 128,
    max_tags: usize = 100_000,
    max_total_tag_bytes: u64 = 16 * 1024 * 1024,
    max_tag_length: usize = 128,
    max_link_bytes: usize = 16 * 1024,

    pub fn validate(self: Limits) Error!void {
        if (self.max_metadata_bytes == 0 or
            self.max_metadata_bytes > std.math.maxInt(usize) or
            self.max_tag_page_bytes == 0 or
            self.max_tag_pages == 0 or
            self.max_tags == 0 or
            self.max_total_tag_bytes == 0 or
            self.max_tag_length == 0 or
            self.max_tag_length > 128 or
            self.max_link_bytes == 0)
        {
            return error.InvalidConfiguration;
        }
    }
};

pub const Options = struct {
    plain_http: bool = false,
    additional_ca: ?registry_http.AdditionalCa = null,
    credential_policy: auth.CredentialPolicy = .none,
    auth_context: auth.ResolutionContext,
    auth_limits: auth.Limits = .{},
    http_limits: registry_http.Limits = .{},
    timeouts: registry_http.Timeouts = .{},
    limits: Limits = .{},
    deadline: registry_http.Deadline,
    auth_context_id: u64 = 0,
    credential_generation: u64 = 0,
};

pub const Operation = enum {
    resolve,
    inspect,
    list_tags,
    read_metadata,
    read_manifest_metadata,
    copy_blob,
};

pub const Category = enum {
    authentication,
    authorization,
    not_found,
    unsupported_content,
    invalid_content,
    transport,
    tls,
    deadline,
    retry_limit,
    insecure_transport,
    redirect,
    limit,
    pagination,
    registry,
};

const diagnostic_authority_capacity = 256;
const diagnostic_repository_capacity = 256;
const diagnostic_code_capacity = 64;

pub const Diagnostic = struct {
    operation: Operation,
    category: Category,
    status: ?u16 = null,
    authority_buffer: [diagnostic_authority_capacity]u8 = undefined,
    authority_len: usize = 0,
    repository_buffer: [diagnostic_repository_capacity]u8 = undefined,
    repository_len: usize = 0,
    code_buffer: [diagnostic_code_capacity]u8 = undefined,
    code_len: usize = 0,
    expected_digest: ?[content.digest_text_size]u8 = null,

    fn init(
        operation: Operation,
        category: Category,
        status: ?u16,
        authority_text: []const u8,
        repository_text: []const u8,
        code: ?[]const u8,
        expected: ?content.Digest,
    ) Diagnostic {
        var result: Diagnostic = .{
            .operation = operation,
            .category = category,
            .status = status,
            .expected_digest = if (expected) |digest| digest.format() else null,
        };
        result.authority_len = @min(authority_text.len, result.authority_buffer.len);
        @memcpy(
            result.authority_buffer[0..result.authority_len],
            authority_text[0..result.authority_len],
        );
        result.repository_len = @min(repository_text.len, result.repository_buffer.len);
        @memcpy(
            result.repository_buffer[0..result.repository_len],
            repository_text[0..result.repository_len],
        );
        if (code) |value| {
            if (validDistributionCode(value)) {
                result.code_len = @min(value.len, result.code_buffer.len);
                @memcpy(result.code_buffer[0..result.code_len], value[0..result.code_len]);
            }
        }
        return result;
    }

    pub fn authority(self: *const Diagnostic) []const u8 {
        return self.authority_buffer[0..self.authority_len];
    }

    pub fn repository(self: *const Diagnostic) []const u8 {
        return self.repository_buffer[0..self.repository_len];
    }

    pub fn distributionCode(self: *const Diagnostic) ?[]const u8 {
        return if (self.code_len == 0) null else self.code_buffer[0..self.code_len];
    }

    pub fn format(self: Diagnostic, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print(
            "registry(category={s}, operation={s}, authority={s}, repository={s}",
            .{
                @tagName(self.category),
                @tagName(self.operation),
                self.authority(),
                self.repository(),
            },
        );
        if (self.status) |status| try writer.print(", status={d}", .{status});
        if (self.distributionCode()) |code| try writer.print(", code={s}", .{code});
        if (self.expected_digest) |digest| {
            try writer.print(", expected={s}", .{&digest});
        }
        try writer.writeByte(')');
    }
};

pub const ResolvedRoot = struct {
    allocator: Allocator,
    descriptor: model.Descriptor,
    descriptor_json: []const u8,
    descriptor_parsed: std.json.Parsed(model.Descriptor),
    bytes: []const u8,
    canonical_reference: []const u8,
    requested_tag: ?[]const u8,

    pub fn deinit(self: *ResolvedRoot) void {
        if (self.requested_tag) |tag| self.allocator.free(tag);
        self.allocator.free(self.canonical_reference);
        self.allocator.free(self.bytes);
        self.descriptor_parsed.deinit();
        self.allocator.free(self.descriptor_json);
        self.* = undefined;
    }
};

pub const TagList = struct {
    allocator: Allocator,
    tags: [][]u8,

    pub fn deinit(self: *TagList) void {
        for (self.tags) |tag| self.allocator.free(tag);
        self.allocator.free(self.tags);
        self.* = undefined;
    }
};

pub const InspectOptions = struct {
    limits: graph.Limits = .{},
};

pub const InspectResult = struct {
    allocator: Allocator,
    canonical_reference: []const u8,
    requested_tag: ?[]const u8,
    plan: graph.Plan,

    pub fn deinit(self: *InspectResult) void {
        self.plan.deinit();
        if (self.requested_tag) |tag| self.allocator.free(tag);
        self.allocator.free(self.canonical_reference);
        self.* = undefined;
    }
};

const TokenContext = struct {
    backend: registry_http.Backend,
    clock: registry_http.Clock,
    sleeper: registry_http.Sleeper,
    plain_http_allowed: bool,
    http_limits: registry_http.Limits,
    timeouts: registry_http.Timeouts,
    auth_limits: auth.Limits,
    basic: ?auth.BasicCredential,

    fn acquirer(self: *TokenContext) registry_http.TokenAcquirer {
        return .{ .context = self, .acquire = acquire };
    }

    fn acquire(
        context: ?*anyopaque,
        allocator: Allocator,
        request: registry_http.TokenAcquisitionRequest,
    ) auth.TokenAcquisitionError!auth.Token {
        const self: *TokenContext = @ptrCast(@alignCast(context orelse
            return error.AuthenticationFailed));
        const token_url = auth.buildBearerTokenUrlAlloc(
            allocator,
            request.key.realm,
            request.key.service,
            request.key.scopes,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.AuthenticationFailed,
        };
        defer allocator.free(token_url);

        var target = AbsoluteTarget.parse(allocator, token_url) catch |err|
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.AuthenticationFailed,
            };
        defer target.deinit();
        if (target.plain_http and !self.plain_http_allowed) {
            return error.AuthenticationFailed;
        }

        var client = registry_http.Client.init(
            allocator,
            self.backend,
            self.clock,
            self.sleeper,
            .{
                .endpoint = .{
                    .authority = target.authority,
                    .plain_http = target.plain_http,
                },
                .limits = self.http_limits,
                .timeouts = self.timeouts,
                .authorization = if (self.basic) |basic|
                    .{ .basic = basic }
                else
                    .none,
                .auth_limits = self.auth_limits,
            },
        ) catch |err| return mapTokenClientError(err);
        defer client.deinit();

        var response = client.execute(.{
            .path_and_query = target.path_and_query,
            .class = .token,
            .headers = &.{.{ .name = "Accept", .value = "application/json" }},
            .max_body_bytes = self.auth_limits.max_token_response_bytes,
            .deadline = .{ .at_ns = request.absolute_deadline_ns },
        }) catch |err| return mapTokenClientError(err);
        defer response.deinit();
        if (response.status != 200) {
            return error.AuthenticationFailed;
        }
        if (response.header("Content-Type")) |value| {
            const media_type = mediaTypeBase(value) orelse
                return error.InvalidResponse;
            if (!std.ascii.eqlIgnoreCase(media_type, "application/json")) {
                return error.InvalidResponse;
            }
        }
        return auth.parseTokenResponse(
            allocator,
            response.body,
            self.auth_limits,
        ) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidResponse,
        };
    }
};

const AbsoluteTarget = struct {
    allocator: Allocator,
    authority: []u8,
    path_and_query: []u8,
    plain_http: bool,

    fn parse(allocator: Allocator, url: []const u8) Error!AbsoluteTarget {
        const uri = std.Uri.parse(url) catch return error.InvalidReference;
        if (uri.host == null or uri.user != null or uri.password != null or
            uri.fragment != null)
        {
            return error.InvalidReference;
        }
        const plain_http = if (std.ascii.eqlIgnoreCase(uri.scheme, "http"))
            true
        else if (std.ascii.eqlIgnoreCase(uri.scheme, "https"))
            false
        else
            return error.InvalidReference;
        const scheme_end = std.mem.indexOf(u8, url, "://") orelse
            return error.InvalidReference;
        const authority_start = scheme_end + 3;
        const suffix_index = std.mem.indexOfAnyPos(
            u8,
            url,
            authority_start,
            "/?",
        );
        const authority_end = suffix_index orelse url.len;
        if (authority_end == authority_start) return error.InvalidReference;
        const authority = try allocator.dupe(u8, url[authority_start..authority_end]);
        errdefer allocator.free(authority);
        const path_and_query = if (suffix_index) |index|
            if (url[index] == '/')
                try allocator.dupe(u8, url[index..])
            else
                try std.fmt.allocPrint(allocator, "/{s}", .{url[index..]})
        else
            try allocator.dupe(u8, "/");
        return .{
            .allocator = allocator,
            .authority = authority,
            .path_and_query = path_and_query,
            .plain_http = plain_http,
        };
    }

    fn deinit(self: *AbsoluteTarget) void {
        self.allocator.free(self.authority);
        self.allocator.free(self.path_and_query);
        self.* = undefined;
    }
};

pub const Source = struct {
    io: Io,
    allocator: Allocator,
    authority: []u8,
    repository: []u8,
    limits: Limits,
    deadline: registry_http.Deadline,
    client: registry_http.Client,
    credential: ?auth.ResolvedCredential,
    token_context: *TokenContext,
    owned_backend: ?*registry_http.StdBackend = null,
    owned_runtime: ?*registry_http.SystemRuntime = null,
    last_diagnostic: ?Diagnostic = null,

    /// Initializes the production backend. System trust and hostname
    /// verification remain enabled; an additional CA extends system trust.
    pub fn init(
        io: Io,
        allocator: Allocator,
        registry_reference: reference.RegistryReference,
        options: Options,
    ) Error!Source {
        const normalized_authority = auth.normalizeAuthorityAlloc(
            allocator,
            registry_reference.authority,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidReference,
        };
        defer allocator.free(normalized_authority);
        try validateRepositoryBinding(
            allocator,
            normalized_authority,
            registry_reference.repository,
        );
        const normalized_reference: reference.RegistryReference = .{
            .authority = normalized_authority,
            .repository = registry_reference.repository,
            .selection = registry_reference.selection,
        };
        const runtime = try allocator.create(registry_http.SystemRuntime);
        errdefer allocator.destroy(runtime);
        runtime.* = .{ .io = io };
        if (runtime.now() >= options.deadline.at_ns) {
            return error.DeadlineExceeded;
        }
        const backend = try allocator.create(registry_http.StdBackend);
        errdefer allocator.destroy(backend);
        backend.* = registry_http.StdBackend.init(
            allocator,
            io,
            .{
                .authority = normalized_authority,
                .plain_http = options.plain_http,
                .additional_ca = options.additional_ca,
            },
            options.http_limits,
        ) catch |err| return mapInitHttpError(err);
        errdefer backend.deinit();
        if (runtime.now() >= options.deadline.at_ns) {
            return error.DeadlineExceeded;
        }

        var result = try initWithBackend(
            io,
            allocator,
            normalized_reference,
            backend.backend(),
            runtime.clock(),
            runtime.sleeper(),
            options,
        );
        result.owned_backend = backend;
        result.owned_runtime = runtime;
        return result;
    }

    /// Injectable initialization used by deterministic tests and embedders.
    /// The backend, clock, and sleeper remain caller-owned.
    pub fn initWithBackend(
        io: Io,
        allocator: Allocator,
        registry_reference: reference.RegistryReference,
        backend: registry_http.Backend,
        clock: registry_http.Clock,
        sleeper: registry_http.Sleeper,
        options: Options,
    ) Error!Source {
        try options.limits.validate();
        options.auth_limits.validate() catch return error.InvalidConfiguration;
        options.http_limits.validate() catch return error.InvalidConfiguration;
        options.timeouts.validate() catch return error.InvalidConfiguration;
        const initialization_now = clock.now();
        if (initialization_now >= options.deadline.at_ns) return error.DeadlineExceeded;
        const remaining_i128 = options.deadline.at_ns - initialization_now;
        const remaining_ns: u64 = @intCast(@min(
            remaining_i128,
            @as(i128, std.math.maxInt(u64)),
        ));
        var effective_auth_limits = options.auth_limits;
        effective_auth_limits.helper_timeout_ns = @min(
            effective_auth_limits.helper_timeout_ns,
            remaining_ns,
        );

        const authority = auth.normalizeAuthorityAlloc(
            allocator,
            registry_reference.authority,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidReference,
        };
        errdefer allocator.free(authority);
        try validateRepositoryBinding(
            allocator,
            authority,
            registry_reference.repository,
        );
        const repository = try allocator.dupe(u8, registry_reference.repository);
        errdefer allocator.free(repository);

        var credential = auth.resolveCredential(
            allocator,
            options.credential_policy,
            .{ .authority = authority, .repository = repository },
            options.auth_context,
            effective_auth_limits,
        ) catch |err| return mapCredentialError(err);
        errdefer if (credential) |*value| value.deinit(allocator);
        if (clock.now() >= options.deadline.at_ns) return error.DeadlineExceeded;

        const token_context = try allocator.create(TokenContext);
        errdefer allocator.destroy(token_context);
        token_context.* = .{
            .backend = backend,
            .clock = clock,
            .sleeper = sleeper,
            .plain_http_allowed = options.plain_http,
            .http_limits = options.http_limits,
            .timeouts = options.timeouts,
            .auth_limits = effective_auth_limits,
            .basic = if (credential) |resolved| switch (resolved.credential) {
                .basic => |basic| basic.borrowed(),
                .bearer_token => null,
            } else null,
        };

        const authorization: registry_http.AuthorizationConfig =
            if (credential) |resolved| switch (resolved.credential) {
                .basic => |basic| .{ .basic = basic.borrowed() },
                .bearer_token => |token| .{ .bearer = token },
            } else .none;
        var client = registry_http.Client.init(
            allocator,
            backend,
            clock,
            sleeper,
            .{
                .endpoint = .{
                    .authority = authority,
                    .plain_http = options.plain_http,
                    .additional_ca = options.additional_ca,
                },
                .limits = options.http_limits,
                .timeouts = options.timeouts,
                .authorization = authorization,
                .token_acquirer = token_context.acquirer(),
                .auth_limits = effective_auth_limits,
                .auth_context_id = options.auth_context_id,
                .credential_generation = options.credential_generation,
            },
        ) catch |err| return mapInitHttpError(err);
        errdefer client.deinit();

        return .{
            .io = io,
            .allocator = allocator,
            .authority = authority,
            .repository = repository,
            .limits = options.limits,
            .deadline = options.deadline,
            .client = client,
            .credential = credential,
            .token_context = token_context,
        };
    }

    pub fn deinit(self: *Source) void {
        self.client.deinit();
        if (self.credential) |*credential| credential.deinit(self.allocator);
        self.allocator.destroy(self.token_context);
        if (self.owned_backend) |backend| {
            backend.deinit();
            self.allocator.destroy(backend);
        }
        if (self.owned_runtime) |runtime| self.allocator.destroy(runtime);
        self.allocator.free(self.authority);
        self.allocator.free(self.repository);
        self.* = undefined;
    }

    pub fn asTransport(self: *Source) transport.Source {
        return transport.Source.init(self);
    }

    pub fn lastDiagnostic(self: *const Source) ?*const Diagnostic {
        return if (self.last_diagnostic) |*diagnostic| diagnostic else null;
    }

    pub fn resolve(
        self: *Source,
        registry_reference: reference.RegistryReference,
    ) Error!ResolvedRoot {
        self.last_diagnostic = null;
        try self.requireBoundReference(registry_reference, true, .resolve);
        const selection = registry_reference.selection orelse
            return self.fail(error.InvalidReference, .resolve, .invalid_content, null, null, null);

        var selector_buffer: [content.digest_text_size]u8 = undefined;
        const selector = switch (selection) {
            .tag => |tag| tag,
            .digest => |digest| blk: {
                selector_buffer = digest.format();
                break :blk &selector_buffer;
            },
        };
        const path = try std.fmt.allocPrint(
            self.allocator,
            "/v2/{s}/manifests/{s}",
            .{ self.repository, selector },
        );
        defer self.allocator.free(path);

        var response = self.client.execute(.{
            .path_and_query = path,
            .class = .registry,
            .headers = &.{.{ .name = "Accept", .value = manifest_accept }},
            .max_body_bytes = self.limits.max_metadata_bytes,
            .deadline = self.deadline,
        }) catch |err| return self.mapHttpFailure(err, .resolve, expectedSelectionDigest(selection));
        defer response.deinit();
        try self.requireSuccess(response, .resolve, expectedSelectionDigest(selection));

        if (response.header("Content-Length")) |_| {
            const length = try self.contentLength(response, .resolve, expectedSelectionDigest(selection));
            if (length != response.body.len) {
                return self.fail(error.InvalidContent, .resolve, .invalid_content, response.status, null, expectedSelectionDigest(selection));
            }
        }
        const response_media_type = try self.manifestContentType(
            response,
            .resolve,
            expectedSelectionDigest(selection),
        );
        const description = content.describeBytes(response.body) catch
            return self.fail(error.InvalidContent, .resolve, .invalid_content, response.status, null, expectedSelectionDigest(selection));
        if (selection == .digest and !selection.digest.eql(description.digest)) {
            return self.fail(error.InvalidContent, .resolve, .invalid_content, response.status, null, selection.digest);
        }
        try self.corroborateDigestHeader(
            response,
            description.digest,
            .resolve,
        );

        var document = model.parseDocument(self.allocator, response.body) catch
            return self.fail(error.InvalidContent, .resolve, .invalid_content, response.status, null, description.digest);
        defer document.deinit();
        const response_class = model.classifyMediaType(response_media_type);
        if ((response_class.isIndex() and document.kind() != .index) or
            (response_class.isManifest() and document.kind() != .manifest))
        {
            return self.fail(error.InvalidContent, .resolve, .invalid_content, response.status, null, description.digest);
        }
        const document_media_type = switch (document.value) {
            .index => |parsed| parsed.value.mediaType,
            .manifest => |parsed| parsed.value.mediaType,
        };
        if (document_media_type) |actual| {
            if (!std.mem.eql(u8, actual, response_media_type)) {
                return self.fail(error.InvalidContent, .resolve, .invalid_content, response.status, null, description.digest);
            }
        }

        const digest_text = description.digest.format();
        const descriptor_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"mediaType\":\"{s}\",\"digest\":\"{s}\",\"size\":{d}}}",
            .{ response_media_type, &digest_text, description.size },
        );
        errdefer self.allocator.free(descriptor_json);
        var descriptor_parsed = std.json.parseFromSlice(
            model.Descriptor,
            self.allocator,
            descriptor_json,
            .{ .ignore_unknown_fields = true },
        ) catch return self.fail(error.InvalidContent, .resolve, .invalid_content, response.status, null, description.digest);
        errdefer descriptor_parsed.deinit();
        model.validateRootDescriptor(descriptor_parsed.value) catch
            return self.fail(error.InvalidContent, .resolve, .invalid_content, response.status, null, description.digest);

        const bytes = try self.allocator.dupe(u8, response.body);
        errdefer self.allocator.free(bytes);
        const canonical_reference = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}@{s}",
            .{ self.authority, self.repository, &digest_text },
        );
        errdefer self.allocator.free(canonical_reference);
        const requested_tag = switch (selection) {
            .tag => |tag| try self.allocator.dupe(u8, tag),
            .digest => null,
        };
        self.last_diagnostic = null;
        return .{
            .allocator = self.allocator,
            .descriptor = descriptor_parsed.value,
            .descriptor_json = descriptor_json,
            .descriptor_parsed = descriptor_parsed,
            .bytes = bytes,
            .canonical_reference = canonical_reference,
            .requested_tag = requested_tag,
        };
    }

    pub fn inspect(
        self: *Source,
        registry_reference: reference.RegistryReference,
        options: InspectOptions,
    ) !InspectResult {
        var resolved = try self.resolve(registry_reference);
        defer resolved.deinit();
        return self.inspectResolved(&resolved, options);
    }

    pub fn inspectResolved(
        self: *Source,
        resolved: *const ResolvedRoot,
        options: InspectOptions,
    ) !InspectResult {
        self.last_diagnostic = null;
        var resolved_source: ResolvedSource = .{
            .registry = self,
            .resolved = resolved,
        };
        var plan = graph.planCopy(
            self.allocator,
            resolved_source.asTransport(),
            .{
                .descriptor = resolved.descriptor,
                .descriptor_json = resolved.descriptor_json,
            },
            options.limits,
        ) catch |err| {
            if (self.last_diagnostic == null) {
                self.last_diagnostic = Diagnostic.init(
                    .inspect,
                    .invalid_content,
                    null,
                    self.authority,
                    self.repository,
                    null,
                    resolved.descriptor.parsedDigest() catch null,
                );
            }
            return err;
        };
        errdefer plan.deinit();
        const canonical_reference = try self.allocator.dupe(
            u8,
            resolved.canonical_reference,
        );
        errdefer self.allocator.free(canonical_reference);
        const requested_tag = if (resolved.requested_tag) |tag|
            try self.allocator.dupe(u8, tag)
        else
            null;
        return .{
            .allocator = self.allocator,
            .canonical_reference = canonical_reference,
            .requested_tag = requested_tag,
            .plan = plan,
        };
    }

    /// Implements `transport.Source.readMetadata`.
    pub fn readMetadata(
        self: *Source,
        allocator: Allocator,
        descriptor: model.Descriptor,
        max_bytes: u64,
    ) Error!transport.Metadata {
        return self.readMetadataFrom(
            allocator,
            descriptor,
            max_bytes,
            false,
        );
    }

    /// Forces an index child through the manifest endpoint even when its media
    /// type is an extension unknown to this implementation.
    pub fn readManifestMetadata(
        self: *Source,
        allocator: Allocator,
        descriptor: model.Descriptor,
        max_bytes: u64,
    ) Error!transport.Metadata {
        return self.readMetadataFrom(
            allocator,
            descriptor,
            max_bytes,
            true,
        );
    }

    fn readMetadataFrom(
        self: *Source,
        allocator: Allocator,
        descriptor: model.Descriptor,
        max_bytes: u64,
        force_manifest: bool,
    ) Error!transport.Metadata {
        self.last_diagnostic = null;
        const operation: Operation = if (force_manifest)
            .read_manifest_metadata
        else
            .read_metadata;
        const digest = model.validateDescriptor(descriptor) catch
            return self.fail(error.InvalidContent, operation, .invalid_content, null, null, null);
        if (descriptor.size > max_bytes or
            descriptor.size > self.limits.max_metadata_bytes or
            descriptor.size > std.math.maxInt(usize))
        {
            return self.fail(error.LimitExceeded, operation, .limit, null, null, digest);
        }
        const class = model.classifyMediaType(descriptor.mediaType);
        const is_manifest = force_manifest or class.isDocument();
        const digest_text = digest.format();
        const path = if (is_manifest)
            try std.fmt.allocPrint(
                self.allocator,
                "/v2/{s}/manifests/{s}",
                .{ self.repository, &digest_text },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "/v2/{s}/blobs/{s}",
                .{ self.repository, &digest_text },
            );
        defer self.allocator.free(path);
        const headers: []const registry_http.Header = if (is_manifest)
            &.{.{ .name = "Accept", .value = descriptor.mediaType }}
        else
            &.{};
        var response = self.client.execute(.{
            .path_and_query = path,
            .class = if (is_manifest) .registry else .blob,
            .headers = headers,
            .max_body_bytes = @max(descriptor.size, 1),
            .deadline = self.deadline,
        }) catch |err| return self.mapHttpFailure(err, operation, digest);
        defer response.deinit();
        try self.requireSuccess(response, operation, digest);
        const length = try self.contentLength(response, operation, digest);
        if (length != descriptor.size or length != response.body.len) {
            return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, digest);
        }
        content.verifyBytes(digest, descriptor.size, response.body) catch
            return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, digest);
        try self.corroborateDigestHeader(response, digest, operation);
        if (is_manifest) {
            const response_media_type = singleHeader(response, "Content-Type") catch
                return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, digest);
            const base = mediaTypeBase(response_media_type orelse
                return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, digest)) orelse
                return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, digest);
            if (!std.mem.eql(u8, base, descriptor.mediaType)) {
                return self.fail(error.UnsupportedContent, operation, .unsupported_content, response.status, null, digest);
            }
            if (class.isDocument()) {
                var document = model.parseDocument(self.allocator, response.body) catch
                    return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, digest);
                defer document.deinit();
                if ((class.isIndex() and document.kind() != .index) or
                    (class.isManifest() and document.kind() != .manifest))
                {
                    return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, digest);
                }
                const document_media_type = switch (document.value) {
                    .index => |parsed| parsed.value.mediaType,
                    .manifest => |parsed| parsed.value.mediaType,
                };
                if (document_media_type) |actual| {
                    if (!std.mem.eql(u8, actual, descriptor.mediaType)) {
                        return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, digest);
                    }
                }
            }
        } else if (singleHeader(response, "Content-Type") catch
            return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, digest)) |value|
        {
            const base = mediaTypeBase(value) orelse
                return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, digest);
            model.validateMediaType(base) catch
                return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, digest);
        }
        const bytes = try allocator.dupe(u8, response.body);
        self.last_diagnostic = null;
        return .{ .allocator = allocator, .bytes = bytes };
    }

    /// Implements `transport.Source.copyVerifiedTo`.
    pub fn copyVerifiedTo(
        self: *Source,
        descriptor: model.Descriptor,
        destination: Io.File,
    ) Error!void {
        self.last_diagnostic = null;
        const digest = model.validateDescriptor(descriptor) catch
            return self.fail(error.InvalidContent, .copy_blob, .invalid_content, null, null, null);
        const class = model.classifyMediaType(descriptor.mediaType);
        const is_manifest = class.isDocument();
        const digest_text = digest.format();
        const path = if (is_manifest)
            try std.fmt.allocPrint(
                self.allocator,
                "/v2/{s}/manifests/{s}",
                .{ self.repository, &digest_text },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "/v2/{s}/blobs/{s}",
                .{ self.repository, &digest_text },
            );
        defer self.allocator.free(path);

        var sink_state: VerifiedFileSink = .{
            .io = self.io,
            .file = destination,
            .digest = digest,
            .size = descriptor.size,
        };
        sink_state.reset() catch
            return self.fail(error.TransportFailed, .copy_blob, .transport, null, null, digest);
        var success = false;
        defer if (!success) sink_state.cleanup();

        const headers: []const registry_http.Header = if (is_manifest)
            &.{.{ .name = "Accept", .value = descriptor.mediaType }}
        else
            &.{};
        var response = self.client.execute(.{
            .path_and_query = path,
            .class = if (is_manifest) .registry else .blob,
            .headers = headers,
            .max_body_bytes = descriptor.size,
            .body_sink = registry_http.BodySink.init(&sink_state),
            .deadline = self.deadline,
        }) catch |err| {
            if (err == error.BodySinkFailed) {
                const sink_error = sink_state.failure orelse error.TransportFailed;
                return self.fail(
                    sink_error,
                    .copy_blob,
                    if (sink_error == error.InvalidContent)
                        .invalid_content
                    else
                        .transport,
                    null,
                    null,
                    digest,
                );
            }
            return self.mapHttpFailure(err, .copy_blob, digest);
        };
        defer response.deinit();
        try self.requireSuccess(response, .copy_blob, digest);
        const length = try self.contentLength(response, .copy_blob, digest);
        if (length != descriptor.size) {
            return self.fail(error.InvalidContent, .copy_blob, .invalid_content, response.status, null, digest);
        }
        try self.corroborateDigestHeader(response, digest, .copy_blob);
        if (is_manifest) {
            const response_media_type = try self.manifestContentType(
                response,
                .copy_blob,
                digest,
            );
            if (!std.mem.eql(u8, response_media_type, descriptor.mediaType)) {
                return self.fail(error.UnsupportedContent, .copy_blob, .unsupported_content, response.status, null, digest);
            }
        }
        success = true;
        self.last_diagnostic = null;
    }

    pub fn listTags(
        self: *Source,
        registry_reference: reference.RegistryReference,
    ) Error!TagList {
        self.last_diagnostic = null;
        try self.requireBoundReference(registry_reference, false, .list_tags);
        var tags = std.array_list.Managed([]u8).init(self.allocator);
        errdefer {
            for (tags.items) |tag| self.allocator.free(tag);
            tags.deinit();
        }
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();
        var visited = std.StringHashMap(void).init(self.allocator);
        defer {
            var iterator = visited.keyIterator();
            while (iterator.next()) |key| self.allocator.free(key.*);
            visited.deinit();
        }
        var current = try std.fmt.allocPrint(
            self.allocator,
            "/v2/{s}/tags/list",
            .{self.repository},
        );
        defer self.allocator.free(current);
        var total_bytes: u64 = 0;
        var pages: usize = 0;
        while (true) {
            if (pages >= self.limits.max_tag_pages) {
                return self.fail(error.LimitExceeded, .list_tags, .limit, null, null, null);
            }
            const visited_key = try self.allocator.dupe(u8, current);
            if (visited.contains(visited_key)) {
                self.allocator.free(visited_key);
                return self.fail(error.PaginationFailed, .list_tags, .pagination, null, null, null);
            }
            visited.put(visited_key, {}) catch |err| {
                self.allocator.free(visited_key);
                return err;
            };
            pages += 1;

            var response = self.client.execute(.{
                .path_and_query = current,
                .class = .registry,
                .headers = &.{.{ .name = "Accept", .value = "application/json" }},
                .max_body_bytes = self.limits.max_tag_page_bytes,
                .deadline = self.deadline,
            }) catch |err| return self.mapHttpFailure(err, .list_tags, null);
            defer response.deinit();
            try self.requireSuccess(response, .list_tags, null);
            total_bytes = std.math.add(u64, total_bytes, response.body.len) catch
                return self.fail(error.LimitExceeded, .list_tags, .limit, response.status, null, null);
            if (total_bytes > self.limits.max_total_tag_bytes) {
                return self.fail(error.LimitExceeded, .list_tags, .limit, response.status, null, null);
            }
            const content_type = singleHeader(response, "Content-Type") catch
                return self.fail(error.InvalidContent, .list_tags, .invalid_content, response.status, null, null);
            const base = mediaTypeBase(content_type orelse
                return self.fail(error.UnsupportedContent, .list_tags, .unsupported_content, response.status, null, null)) orelse
                return self.fail(error.InvalidContent, .list_tags, .invalid_content, response.status, null, null);
            if (!std.ascii.eqlIgnoreCase(base, "application/json")) {
                return self.fail(error.UnsupportedContent, .list_tags, .unsupported_content, response.status, null, null);
            }
            try self.appendTagPage(response, &tags, &seen);

            const next = try self.nextLink(response);
            if (next == null) break;
            defer self.allocator.free(next.?);
            const resolved = registry_http.resolveSameOriginPathAlloc(
                self.allocator,
                self.client.endpoint,
                current,
                next.?,
                self.limits.max_link_bytes,
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => self.fail(error.PaginationFailed, .list_tags, .pagination, response.status, null, null),
            };
            self.allocator.free(current);
            current = resolved;
        }
        std.mem.sort([]u8, tags.items, {}, lessThanString);
        self.last_diagnostic = null;
        return .{
            .allocator = self.allocator,
            .tags = try tags.toOwnedSlice(),
        };
    }

    fn appendTagPage(
        self: *Source,
        response: registry_http.Response,
        tags: *std.array_list.Managed([]u8),
        seen: *std.StringHashMap(void),
    ) Error!void {
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            response.body,
            .{},
        ) catch return self.fail(error.InvalidContent, .list_tags, .invalid_content, response.status, null, null);
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => return self.fail(error.InvalidContent, .list_tags, .invalid_content, response.status, null, null),
        };
        const name = object.get("name") orelse
            return self.fail(error.InvalidContent, .list_tags, .invalid_content, response.status, null, null);
        if (name != .string or !std.mem.eql(u8, name.string, self.repository)) {
            return self.fail(error.InvalidContent, .list_tags, .invalid_content, response.status, null, null);
        }
        const tag_value = object.get("tags") orelse
            return self.fail(error.InvalidContent, .list_tags, .invalid_content, response.status, null, null);
        if (tag_value == .null) return;
        if (tag_value != .array) {
            return self.fail(error.InvalidContent, .list_tags, .invalid_content, response.status, null, null);
        }
        for (tag_value.array.items) |value| {
            if (value != .string or
                !validTag(value.string, self.limits.max_tag_length))
            {
                return self.fail(error.InvalidContent, .list_tags, .invalid_content, response.status, null, null);
            }
            if (seen.contains(value.string)) continue;
            if (tags.items.len >= self.limits.max_tags) {
                return self.fail(error.LimitExceeded, .list_tags, .limit, response.status, null, null);
            }
            const copy = try self.allocator.dupe(u8, value.string);
            errdefer self.allocator.free(copy);
            try seen.put(copy, {});
            tags.append(copy) catch |err| {
                _ = seen.remove(copy);
                return err;
            };
        }
        var total_tag_bytes: u64 = 0;
        for (tags.items) |tag| {
            total_tag_bytes = std.math.add(u64, total_tag_bytes, tag.len) catch
                return self.fail(error.LimitExceeded, .list_tags, .limit, response.status, null, null);
        }
        if (total_tag_bytes > self.limits.max_total_tag_bytes) {
            return self.fail(error.LimitExceeded, .list_tags, .limit, response.status, null, null);
        }
    }

    fn nextLink(
        self: *Source,
        response: registry_http.Response,
    ) Error!?[]u8 {
        var found: ?[]u8 = null;
        errdefer if (found) |value| self.allocator.free(value);
        for (response.headers) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "Link")) continue;
            if (header.value.len == 0 or header.value.len > self.limits.max_link_bytes) {
                return self.fail(error.PaginationFailed, .list_tags, .pagination, response.status, null, null);
            }
            var parser: LinkParser = .{
                .input = header.value,
                .max_target_bytes = self.limits.max_link_bytes,
            };
            while (try parser.next()) |link| {
                if (!link.next) continue;
                if (found != null) {
                    return self.fail(error.PaginationFailed, .list_tags, .pagination, response.status, null, null);
                }
                found = try self.allocator.dupe(u8, link.target);
            }
        }
        return found;
    }

    fn manifestContentType(
        self: *Source,
        response: registry_http.Response,
        operation: Operation,
        expected: ?content.Digest,
    ) Error![]const u8 {
        const value = singleHeader(response, "Content-Type") catch
            return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, expected);
        const base = mediaTypeBase(value orelse
            return self.fail(error.UnsupportedContent, operation, .unsupported_content, response.status, null, expected)) orelse
            return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, expected);
        if (!acceptedManifestMediaType(base)) {
            return self.fail(error.UnsupportedContent, operation, .unsupported_content, response.status, null, expected);
        }
        return base;
    }

    fn contentLength(
        self: *Source,
        response: registry_http.Response,
        operation: Operation,
        expected: ?content.Digest,
    ) Error!u64 {
        const value = singleHeader(response, "Content-Length") catch
            return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, expected);
        const text = std.mem.trim(u8, value orelse
            return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, expected), " \t");
        if (text.len == 0) {
            return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, expected);
        }
        for (text) |byte| {
            if (!std.ascii.isDigit(byte)) {
                return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, expected);
            }
        }
        return std.fmt.parseInt(u64, text, 10) catch
            return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, expected);
    }

    fn corroborateDigestHeader(
        self: *Source,
        response: registry_http.Response,
        expected: content.Digest,
        operation: Operation,
    ) Error!void {
        const value = singleHeader(response, "Docker-Content-Digest") catch
            return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, expected);
        if (value) |text| {
            const actual = content.Digest.parse(std.mem.trim(u8, text, " \t")) catch
                return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, expected);
            if (!actual.eql(expected)) {
                return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, expected);
            }
        }
    }

    fn requireBoundReference(
        self: *Source,
        registry_reference: reference.RegistryReference,
        selection_required: bool,
        operation: Operation,
    ) Error!void {
        const normalized = auth.normalizeAuthorityAlloc(
            self.allocator,
            registry_reference.authority,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => self.fail(error.InvalidReference, operation, .invalid_content, null, null, null),
        };
        defer self.allocator.free(normalized);
        if (!std.mem.eql(u8, normalized, self.authority) or
            !std.mem.eql(u8, registry_reference.repository, self.repository) or
            (selection_required and registry_reference.selection == null) or
            (!selection_required and registry_reference.selection != null))
        {
            return self.fail(error.InvalidReference, operation, .invalid_content, null, null, null);
        }
        if (registry_reference.selection) |selection| {
            switch (selection) {
                .tag => |tag| if (!validTag(tag, self.limits.max_tag_length)) {
                    return self.fail(error.InvalidReference, operation, .invalid_content, null, null, null);
                },
                .digest => {},
            }
        }
    }

    fn requireSuccess(
        self: *Source,
        response: registry_http.Response,
        operation: Operation,
        expected: ?content.Digest,
    ) Error!void {
        if (response.status == 200) return;
        const parsed_code = distributionCode(self.allocator, response.body);
        const code = if (parsed_code) |*value| value.slice() else null;
        if (response.status == 401 or codeEql(code, "UNAUTHORIZED")) {
            return self.fail(error.AuthenticationFailed, operation, .authentication, response.status, code, expected);
        }
        if (response.status == 403 or codeEql(code, "DENIED")) {
            return self.fail(error.AuthorizationDenied, operation, .authorization, response.status, code, expected);
        }
        if (response.status == 404 or codeEql(code, "MANIFEST_UNKNOWN") or
            codeEql(code, "BLOB_UNKNOWN") or codeEql(code, "NAME_UNKNOWN"))
        {
            return self.fail(error.ContentNotFound, operation, .not_found, response.status, code, expected);
        }
        if (response.status == 415 or codeEql(code, "UNSUPPORTED")) {
            return self.fail(error.UnsupportedContent, operation, .unsupported_content, response.status, code, expected);
        }
        return self.fail(error.RegistryFailed, operation, .registry, response.status, code, expected);
    }

    fn mapHttpFailure(
        self: *Source,
        err: registry_http.Error,
        operation: Operation,
        expected: ?content.Digest,
    ) Error {
        const diagnostic = self.client.lastDiagnostic();
        const status = if (diagnostic) |value| value.status else null;
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.AuthenticationFailed => self.fail(error.AuthenticationFailed, operation, .authentication, status, null, expected),
            error.DeadlineExceeded => self.fail(error.DeadlineExceeded, operation, .deadline, status, null, expected),
            error.RetryLimitExceeded => self.fail(error.RetryLimitExceeded, operation, .retry_limit, status, null, expected),
            error.InsecureTransport => self.fail(error.InsecureTransport, operation, .insecure_transport, status, null, expected),
            error.RedirectRejected,
            error.RedirectLoop,
            error.RedirectLimitExceeded,
            => self.fail(error.RedirectRejected, operation, .redirect, status, null, expected),
            error.LimitExceeded => self.fail(error.LimitExceeded, operation, .limit, status, null, expected),
            error.TlsValidationFailed => self.fail(error.TlsValidationFailed, operation, .tls, status, null, expected),
            error.TransportFailed => self.fail(error.TransportFailed, operation, .transport, status, null, expected),
            error.CertificateAuthorityLoadFailed => self.fail(error.CertificateAuthorityLoadFailed, operation, .tls, status, null, expected),
            error.BodySinkFailed,
            error.InvalidLimits,
            error.InvalidEndpoint,
            error.InvalidRequest,
            error.UnsupportedScheme,
            error.ProtocolError,
            => self.fail(error.TransportFailed, operation, .transport, status, null, expected),
        };
    }

    fn fail(
        self: *Source,
        err: Error,
        operation: Operation,
        category: Category,
        status: ?u16,
        code: ?[]const u8,
        expected: ?content.Digest,
    ) Error {
        self.last_diagnostic = Diagnostic.init(
            operation,
            category,
            status,
            self.authority,
            self.repository,
            code,
            expected,
        );
        return err;
    }
};

const ResolvedSource = struct {
    registry: *Source,
    resolved: *const ResolvedRoot,

    fn asTransport(self: *ResolvedSource) transport.Source {
        return transport.Source.init(self);
    }

    pub fn readMetadata(
        self: *ResolvedSource,
        allocator: Allocator,
        descriptor: model.Descriptor,
        max_bytes: u64,
    ) !transport.Metadata {
        if (descriptorIdentityEqual(descriptor, self.resolved.descriptor)) {
            if (descriptor.size > max_bytes) return error.LimitExceeded;
            return transport.Metadata.copy(allocator, self.resolved.bytes);
        }
        return self.registry.readMetadata(allocator, descriptor, max_bytes);
    }

    pub fn readManifestMetadata(
        self: *ResolvedSource,
        allocator: Allocator,
        descriptor: model.Descriptor,
        max_bytes: u64,
    ) !transport.Metadata {
        if (descriptorIdentityEqual(descriptor, self.resolved.descriptor)) {
            if (descriptor.size > max_bytes) return error.LimitExceeded;
            return transport.Metadata.copy(allocator, self.resolved.bytes);
        }
        return self.registry.readManifestMetadata(allocator, descriptor, max_bytes);
    }

    pub fn copyVerifiedTo(
        self: *ResolvedSource,
        descriptor: model.Descriptor,
        destination: Io.File,
    ) !void {
        return self.registry.copyVerifiedTo(descriptor, destination);
    }
};

const VerifiedFileSink = struct {
    io: Io,
    file: Io.File,
    digest: content.Digest,
    size: u64,
    offset: u64 = 0,
    verifier: ?content.Verifier = null,
    failure: ?Error = null,

    fn reset(self: *VerifiedFileSink) !void {
        try self.file.setLength(self.io, 0);
        self.offset = 0;
        self.verifier = content.Verifier.init(self.digest, self.size);
        self.failure = null;
    }

    fn cleanup(self: *VerifiedFileSink) void {
        self.file.setLength(self.io, 0) catch {};
        self.offset = 0;
        self.verifier = null;
    }

    pub fn begin(
        self: *VerifiedFileSink,
        content_length: ?u64,
    ) registry_http.BodySinkError!void {
        self.reset() catch {
            self.failure = error.TransportFailed;
            return error.SinkFailed;
        };
        if (content_length == null or content_length.? != self.size) {
            self.failure = error.InvalidContent;
            return error.SinkFailed;
        }
    }

    pub fn write(
        self: *VerifiedFileSink,
        bytes: []const u8,
    ) registry_http.BodySinkError!void {
        self.verifier.?.update(bytes) catch {
            self.failure = error.InvalidContent;
            return error.SinkFailed;
        };
        self.file.writePositionalAll(self.io, bytes, self.offset) catch {
            self.failure = error.TransportFailed;
            return error.SinkFailed;
        };
        self.offset = std.math.add(u64, self.offset, bytes.len) catch {
            self.failure = error.InvalidContent;
            return error.SinkFailed;
        };
    }

    pub fn finish(self: *VerifiedFileSink) registry_http.BodySinkError!void {
        self.verifier.?.finish() catch {
            self.failure = error.InvalidContent;
            return error.SinkFailed;
        };
        const length = self.file.length(self.io) catch {
            self.failure = error.TransportFailed;
            return error.SinkFailed;
        };
        if (length != self.size) {
            self.failure = error.InvalidContent;
            return error.SinkFailed;
        }
    }
};

const Link = struct {
    target: []const u8,
    next: bool,
};

const LinkParser = struct {
    input: []const u8,
    max_target_bytes: usize,
    index: usize = 0,

    fn next(self: *LinkParser) Error!?Link {
        self.skipOws();
        if (self.index == self.input.len) return null;
        if (self.input[self.index] != '<') return error.PaginationFailed;
        self.index += 1;
        const target_start = self.index;
        while (self.index < self.input.len and self.input[self.index] != '>') : (self.index += 1) {
            const byte = self.input[self.index];
            if (byte < 0x20 or byte == 0x7f or byte == '<' or byte == '"') {
                return error.PaginationFailed;
            }
        }
        if (self.index == self.input.len or self.index == target_start or
            self.index - target_start > self.max_target_bytes)
        {
            return error.PaginationFailed;
        }
        const target = self.input[target_start..self.index];
        self.index += 1;
        var is_next = false;
        while (true) {
            self.skipOws();
            if (self.index == self.input.len or self.input[self.index] == ',') break;
            if (self.input[self.index] != ';') return error.PaginationFailed;
            self.index += 1;
            self.skipOws();
            const name = try self.token();
            self.skipOws();
            if (self.index == self.input.len or self.input[self.index] != '=') {
                return error.PaginationFailed;
            }
            self.index += 1;
            self.skipOws();
            const value = if (self.index < self.input.len and self.input[self.index] == '"')
                try self.quoted()
            else
                try self.token();
            if (std.ascii.eqlIgnoreCase(name, "rel")) {
                var relations = std.mem.tokenizeAny(u8, value, " \t");
                while (relations.next()) |relation| {
                    if (std.ascii.eqlIgnoreCase(relation, "next")) is_next = true;
                }
            }
        }
        if (self.index < self.input.len) {
            self.index += 1;
            self.skipOws();
            if (self.index == self.input.len) return error.PaginationFailed;
        }
        return .{ .target = target, .next = is_next };
    }

    fn skipOws(self: *LinkParser) void {
        while (self.index < self.input.len and
            (self.input[self.index] == ' ' or self.input[self.index] == '\t')) : (self.index += 1)
        {}
    }

    fn token(self: *LinkParser) Error![]const u8 {
        const start = self.index;
        while (self.index < self.input.len and isTokenByte(self.input[self.index])) {
            self.index += 1;
        }
        if (self.index == start) return error.PaginationFailed;
        return self.input[start..self.index];
    }

    fn quoted(self: *LinkParser) Error![]const u8 {
        self.index += 1;
        const start = self.index;
        var escaped = false;
        while (self.index < self.input.len) : (self.index += 1) {
            const byte = self.input[self.index];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (byte == '\\') {
                escaped = true;
                continue;
            }
            if (byte == '"') {
                const value = self.input[start..self.index];
                self.index += 1;
                return value;
            }
            if (byte < 0x20 and byte != '\t') return error.PaginationFailed;
        }
        return error.PaginationFailed;
    }
};

fn mapCredentialError(err: auth.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedCredentialType => error.UnsupportedCredentialType,
        else => error.AuthenticationFailed,
    };
}

fn mapInitHttpError(err: registry_http.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InsecureTransport => error.InsecureTransport,
        error.CertificateAuthorityLoadFailed => error.CertificateAuthorityLoadFailed,
        error.TlsValidationFailed => error.TlsValidationFailed,
        error.DeadlineExceeded => error.DeadlineExceeded,
        else => error.InvalidConfiguration,
    };
}

fn mapTokenClientError(err: registry_http.Error) auth.TokenAcquisitionError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DeadlineExceeded => error.DeadlineExceeded,
        error.AuthenticationFailed => error.AuthenticationFailed,
        else => error.InvalidResponse,
    };
}

fn expectedSelectionDigest(selection: reference.Selection) ?content.Digest {
    return switch (selection) {
        .tag => null,
        .digest => |digest| digest,
    };
}

fn validateRepositoryBinding(
    allocator: Allocator,
    authority: []const u8,
    repository: []const u8,
) Error!void {
    const text = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ authority, repository },
    );
    defer allocator.free(text);
    const parsed = reference.parse(text, .list_tags) catch
        return error.InvalidReference;
    switch (parsed) {
        .registry => {},
        else => return error.InvalidReference,
    }
}

fn descriptorIdentityEqual(
    left: model.Descriptor,
    right: model.Descriptor,
) bool {
    return left.size == right.size and
        std.mem.eql(u8, left.digest, right.digest) and
        std.mem.eql(u8, left.mediaType, right.mediaType);
}

fn singleHeader(
    response: registry_http.Response,
    name: []const u8,
) error{DuplicateHeader}!?[]const u8 {
    var found: ?[]const u8 = null;
    for (response.headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, name)) continue;
        if (found != null) return error.DuplicateHeader;
        found = header.value;
    }
    return found;
}

fn mediaTypeBase(value: []const u8) ?[]const u8 {
    if (value.len == 0) return null;
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) return null;
    }
    const separator = std.mem.indexOfScalar(u8, value, ';');
    const base = std.mem.trim(u8, if (separator) |index| value[0..index] else value, " \t");
    if (base.len == 0) return null;
    return base;
}

fn acceptedManifestMediaType(value: []const u8) bool {
    return std.mem.eql(u8, value, model.media_type_oci_manifest) or
        std.mem.eql(u8, value, model.media_type_oci_index) or
        std.mem.eql(u8, value, model.media_type_docker_manifest) or
        std.mem.eql(u8, value, model.media_type_docker_manifest_list);
}

fn validTag(value: []const u8, limit: usize) bool {
    if (value.len == 0 or value.len > limit or
        (!std.ascii.isAlphanumeric(value[0]) and value[0] != '_'))
    {
        return false;
    }
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and
            byte != '.' and byte != '-')
        {
            return false;
        }
    }
    return true;
}

fn lessThanString(_: void, left: []u8, right: []u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

const DistributionCode = struct {
    buffer: [diagnostic_code_capacity]u8 = undefined,
    length: usize = 0,

    fn slice(self: *const DistributionCode) []const u8 {
        return self.buffer[0..self.length];
    }
};

fn distributionCode(
    allocator: Allocator,
    body: []const u8,
) ?DistributionCode {
    const Document = struct {
        errors: ?[]const struct {
            code: ?[]const u8 = null,
        } = null,
    };
    var parsed = std.json.parseFromSlice(
        Document,
        allocator,
        body,
        .{ .ignore_unknown_fields = true },
    ) catch return null;
    defer parsed.deinit();
    const errors = parsed.value.errors orelse return null;
    if (errors.len == 0) return null;
    const code = errors[0].code orelse return null;
    if (!validDistributionCode(code)) return null;
    var result: DistributionCode = .{};
    result.length = @min(code.len, result.buffer.len);
    @memcpy(result.buffer[0..result.length], code[0..result.length]);
    return result;
}

fn validDistributionCode(value: []const u8) bool {
    if (value.len == 0 or value.len > diagnostic_code_capacity) return false;
    for (value) |byte| {
        if (!std.ascii.isUpper(byte) and !std.ascii.isDigit(byte) and byte != '_') {
            return false;
        }
    }
    return true;
}

fn codeEql(value: ?[]const u8, expected: []const u8) bool {
    return if (value) |code| std.mem.eql(u8, code, expected) else false;
}

fn isTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

test {
    std.testing.refAllDecls(@This());
}
