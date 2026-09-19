//! Verified OCI Distribution registry reads and bounded destination preflight.
//!
//! Registry semantics are layered on the shared authentication and HTTP
//! policy modules. Initialization is explicit; importing this module performs
//! no credential discovery, file access, or network access.
//! Distribution read and destination state behavior was adapted from
//! cataggar/miz commit
//! 669a27982b376311f558e820b69e9a692735b0cd (MIT).
const std = @import("std");
const builtin = @import("builtin");
const auth = @import("auth.zig");
const content = @import("content.zig");
const copy_engine = @import("copy_engine.zig");
const graph = @import("graph.zig");
const layout = @import("layout.zig");
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
    TagRequired,
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
    DestinationNotPrepared,
    DestinationStateConflict,
    UploadIncomplete,
    UploadAmbiguous,
    PublicationUnconfirmed,
    DestinationNotStaged,
    DestinationNotCommitted,
} || Allocator.Error;

pub const Limits = struct {
    max_metadata_bytes: u64 = 16 * 1024 * 1024,
    max_preflight_body_bytes: usize = 4 * 1024,
    max_tag_page_bytes: usize = 16 * 1024 * 1024,
    max_tag_pages: usize = 128,
    max_tags: usize = 100_000,
    max_total_tag_bytes: u64 = 16 * 1024 * 1024,
    max_tag_length: usize = 128,
    max_link_bytes: usize = 16 * 1024,
    max_upload_chunks: u64 = 4096,

    pub fn validate(self: Limits) Error!void {
        if (self.max_metadata_bytes == 0 or
            self.max_metadata_bytes > std.math.maxInt(usize) or
            self.max_preflight_body_bytes == 0 or
            self.max_tag_page_bytes == 0 or
            self.max_tag_pages == 0 or
            self.max_tags == 0 or
            self.max_total_tag_bytes == 0 or
            self.max_tag_length == 0 or
            self.max_tag_length > 128 or
            self.max_link_bytes == 0 or
            self.max_upload_chunks == 0)
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

pub const MountPolicy = enum {
    disabled,
    same_origin,
};

pub const CopyOptions = copy_engine.Options;

/// Destination initialization is intentionally separate from source options
/// so pull and push credentials, token caches, deadlines, and CA policy cannot
/// be shared accidentally.
pub const DestinationOptions = struct {
    plain_http: bool = false,
    additional_ca: ?registry_http.AdditionalCa = null,
    credential_policy: auth.CredentialPolicy = .none,
    auth_context: auth.ResolutionContext,
    auth_limits: auth.Limits = .{},
    http_limits: registry_http.Limits = .{},
    timeouts: registry_http.Timeouts = .{},
    limits: Limits = .{},
    graph_limits: graph.Limits = .{},
    deadline: registry_http.Deadline,
    auth_context_id: u64 = 0,
    credential_generation: u64 = 0,
    mount_policy: MountPolicy = .same_origin,
    /// Null selects one monolithic upload PUT. A nonzero value selects
    /// PATCH chunks of at most this many bytes followed by an empty finalize
    /// PUT. The fixed transport buffer remains 64 KiB in both modes.
    upload_chunk_bytes: ?u64 = null,
    /// Directory used for exclusive private spool files. The current
    /// directory is used when omitted; every spool is removed on return.
    spool_directory: ?[]const u8 = null,

    fn sourceOptions(self: DestinationOptions) Options {
        return .{
            .plain_http = self.plain_http,
            .additional_ca = self.additional_ca,
            .credential_policy = self.credential_policy,
            .auth_context = self.auth_context,
            .auth_limits = self.auth_limits,
            .http_limits = self.http_limits,
            .timeouts = self.timeouts,
            .limits = self.limits,
            .deadline = self.deadline,
            .auth_context_id = self.auth_context_id,
            .credential_generation = self.credential_generation,
        };
    }
};

pub const Operation = enum {
    resolve,
    inspect,
    list_tags,
    read_metadata,
    read_manifest_metadata,
    copy_blob,
    destination_preflight,
    destination_probe,
    destination_mount,
    destination_upload_start,
    destination_upload_write,
    destination_upload_finalize,
    publish_manifest,
    stage_root,
    commit_root,
    finish,
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
        const content_type = singleHeader(response, "Content-Type") catch
            return error.InvalidResponse;
        if (content_type) |value| {
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

const DeadlineProcessRunner = struct {
    process: auth.ProcessRunner,
    clock: registry_http.Clock,
    deadline: registry_http.Deadline,

    fn boundary(self: *DeadlineProcessRunner) auth.ProcessRunner {
        return .{ .context = self, .run = run };
    }

    fn run(
        context: ?*anyopaque,
        allocator: Allocator,
        io: Io,
        argv: []const []const u8,
        stdin_data: []const u8,
        max_output: usize,
        timeout_ns: u64,
    ) auth.ProcessError!auth.ProcessResult {
        const self: *DeadlineProcessRunner = @ptrCast(@alignCast(context orelse
            return error.DeadlineExceeded));
        const now = self.clock.now();
        if (now >= self.deadline.at_ns) return error.DeadlineExceeded;
        const remaining_i128 = self.deadline.at_ns - now;
        const remaining_ns: u64 = @intCast(@min(
            remaining_i128,
            @as(i128, std.math.maxInt(u64)),
        ));
        return self.process.run(
            self.process.context,
            allocator,
            io,
            argv,
            stdin_data,
            max_output,
            @min(timeout_ns, remaining_ns),
        );
    }
};

pub const Source = struct {
    io: Io,
    allocator: Allocator,
    authority: []u8,
    repository: []u8,
    plain_http: bool,
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
        var validated_endpoint = registry_http.Endpoint.init(
            allocator,
            .{
                .authority = registry_reference.authority,
                .plain_http = options.plain_http,
                .additional_ca = options.additional_ca,
            },
            options.http_limits,
        ) catch |err| return mapInitHttpError(err);
        defer validated_endpoint.deinit();
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

        var deadline_process: DeadlineProcessRunner = .{
            .process = options.auth_context.process,
            .clock = clock,
            .deadline = options.deadline,
        };
        var effective_auth_context = options.auth_context;
        effective_auth_context.process = deadline_process.boundary();
        var credential = auth.resolveCredential(
            allocator,
            options.credential_policy,
            .{ .authority = authority, .repository = repository },
            effective_auth_context,
            effective_auth_limits,
        ) catch |err| {
            if (clock.now() >= options.deadline.at_ns) {
                return error.DeadlineExceeded;
            }
            return mapCredentialError(err);
        };
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
            .plain_http = options.plain_http,
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
        return transport.Source.initWithRegistryIdentity(self, .{
            .origin = self.client.endpoint.canonicalOrigin(),
            .authority = self.authority,
            .repository = self.repository,
            .plain_http = self.plain_http,
        });
    }

    /// Binds graph reads to a root that has already been resolved from a
    /// mutable selector. Root bytes are served from that immutable snapshot.
    pub fn resolvedSource(
        self: *Source,
        resolved: *const ResolvedRoot,
    ) ResolvedSource {
        return .{ .registry = self, .resolved = resolved };
    }

    /// Registry -> layout adapter over the shared complete-graph engine.
    /// Discovery finishes before the destination layout is created or opened.
    pub fn copyToLayout(
        self: *Source,
        source_reference: reference.RegistryReference,
        destination_reference: reference.LayoutReference,
        options: copy_engine.Options,
    ) !transport.Result {
        var resolved = try self.resolve(source_reference);
        defer resolved.deinit();
        var resolved_source = self.resolvedSource(&resolved);
        var plan = try graph.planCopy(
            self.allocator,
            resolved_source.asTransport(),
            .{
                .descriptor = resolved.descriptor,
                .descriptor_json = resolved.descriptor_json,
            },
            options.limits,
        );
        defer plan.deinit();

        var destination = try layout.Destination.init(
            self.io,
            self.allocator,
            destination_reference.path,
        );
        defer destination.deinit();
        destination.failure_point = options.failure_point;
        return copy_engine.executePlan(
            &plan,
            resolved_source.asTransport(),
            destination.asTransport(),
            destination_reference.selection,
        );
    }

    /// Registry -> registry adapter using independently initialized source and
    /// destination clients. Only credential-free source identity is exposed
    /// to destination mount eligibility.
    pub fn copyToDestination(
        self: *Source,
        source_reference: reference.RegistryReference,
        destination: *Destination,
        options: copy_engine.Options,
    ) !transport.Result {
        var resolved = try self.resolve(source_reference);
        defer resolved.deinit();
        var resolved_source = self.resolvedSource(&resolved);
        var plan = try graph.planCopy(
            self.allocator,
            resolved_source.asTransport(),
            .{
                .descriptor = resolved.descriptor,
                .descriptor_json = resolved.descriptor_json,
            },
            options.limits,
        );
        defer plan.deinit();
        return copy_engine.executePlan(
            &plan,
            resolved_source.asTransport(),
            destination.asTransport(),
            .{ .tag = destination.tag },
        );
    }

    pub const copyToRegistry = copyToDestination;

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

        try self.corroborateContentLength(
            response,
            @intCast(response.body.len),
            .resolve,
            expectedSelectionDigest(selection),
        );
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
    ) Error!InspectResult {
        var resolved = try self.resolve(registry_reference);
        defer resolved.deinit();
        return self.inspectResolved(&resolved, options);
    }

    pub fn inspectResolved(
        self: *Source,
        resolved: *const ResolvedRoot,
        options: InspectOptions,
    ) Error!InspectResult {
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
            if (self.last_diagnostic) |diagnostic| {
                return switch (diagnostic.category) {
                    .authentication => error.AuthenticationFailed,
                    .authorization => error.AuthorizationDenied,
                    .not_found => error.ContentNotFound,
                    .unsupported_content => error.UnsupportedContent,
                    .invalid_content => error.InvalidContent,
                    .transport => error.TransportFailed,
                    .tls => error.TlsValidationFailed,
                    .deadline => error.DeadlineExceeded,
                    .retry_limit => error.RetryLimitExceeded,
                    .insecure_transport => error.InsecureTransport,
                    .redirect => error.RedirectRejected,
                    .limit => error.LimitExceeded,
                    .pagination => error.PaginationFailed,
                    .registry => error.RegistryFailed,
                };
            }
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.MaximumDepthExceeded,
                error.MaximumDescriptorsExceeded,
                error.MaximumTotalBytesExceeded,
                error.TotalSizeOverflow,
                error.MaximumMetadataBytesExceeded,
                error.LimitExceeded,
                => self.fail(
                    error.LimitExceeded,
                    .inspect,
                    .limit,
                    null,
                    null,
                    resolved.descriptor.parsedDigest() catch null,
                ),
                else => self.fail(
                    error.InvalidContent,
                    .inspect,
                    .invalid_content,
                    null,
                    null,
                    resolved.descriptor.parsedDigest() catch null,
                ),
            };
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
        try self.corroborateContentLength(
            response,
            descriptor.size,
            operation,
            digest,
        );
        if (response.body.len != descriptor.size) {
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
                return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, digest);
            }
            var document = model.parseDocument(self.allocator, response.body) catch
                return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, digest);
            defer document.deinit();
            if (class.isDocument()) {
                if ((class.isIndex() and document.kind() != .index) or
                    (class.isManifest() and document.kind() != .manifest))
                {
                    return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, digest);
                }
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
        const digest_text = digest.format();
        const path = try std.fmt.allocPrint(
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

        var response = self.client.execute(.{
            .path_and_query = path,
            .class = .blob,
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
        try self.corroborateContentLength(
            response,
            descriptor.size,
            .copy_blob,
            digest,
        );
        try self.corroborateDigestHeader(response, digest, .copy_blob);
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
                return self.fail(error.InvalidContent, .list_tags, .invalid_content, response.status, null, null)) orelse
                return self.fail(error.InvalidContent, .list_tags, .invalid_content, response.status, null, null);
            if (!std.ascii.eqlIgnoreCase(base, "application/json")) {
                return self.fail(error.InvalidContent, .list_tags, .invalid_content, response.status, null, null);
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
        const Document = struct {
            name: []const u8,
            tags: std.json.Value,
        };
        var parsed = std.json.parseFromSlice(
            Document,
            self.allocator,
            response.body,
            .{
                .ignore_unknown_fields = true,
                .duplicate_field_behavior = .@"error",
            },
        ) catch return self.fail(error.InvalidContent, .list_tags, .invalid_content, response.status, null, null);
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.name, self.repository)) {
            return self.fail(error.InvalidContent, .list_tags, .invalid_content, response.status, null, null);
        }
        const tag_value = parsed.value.tags;
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
        var total_link_bytes: usize = 0;
        for (response.headers) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "Link")) continue;
            total_link_bytes = std.math.add(
                usize,
                total_link_bytes,
                header.value.len,
            ) catch return self.fail(error.PaginationFailed, .list_tags, .pagination, response.status, null, null);
            if (header.value.len == 0 or
                total_link_bytes > self.limits.max_link_bytes)
            {
                return self.fail(error.PaginationFailed, .list_tags, .pagination, response.status, null, null);
            }
            var parser: LinkParser = .{
                .input = header.value,
                .max_target_bytes = self.limits.max_link_bytes,
            };
            while (parser.next() catch
                return self.fail(error.PaginationFailed, .list_tags, .pagination, response.status, null, null)) |link|
            {
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
            return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, expected)) orelse
            return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, expected);
        if (!acceptedManifestMediaType(base)) {
            return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, expected);
        }
        return base;
    }

    fn corroborateContentLength(
        self: *Source,
        response: registry_http.Response,
        expected_size: u64,
        operation: Operation,
        expected: ?content.Digest,
    ) Error!void {
        const value = singleHeader(response, "Content-Length") catch
            return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, expected);
        const text = std.mem.trim(u8, value orelse return, " \t");
        if (text.len == 0) {
            return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, expected);
        }
        for (text) |byte| {
            if (!std.ascii.isDigit(byte)) {
                return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, expected);
            }
        }
        const actual = std.fmt.parseInt(u64, text, 10) catch
            return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, expected);
        if (actual != expected_size) {
            return self.fail(error.InvalidContent, operation, .invalid_content, response.status, null, expected);
        }
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
            error.ContentEncodingRejected => self.fail(error.InvalidContent, operation, .invalid_content, status, null, expected),
            error.BodySourceFailed,
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

pub const BlobState = enum {
    missing,
    verified,
};

pub const DestinationState = enum {
    initialized,
    prepared,
    staged,
    committed,
    finished,
    failed,
};

pub const UploadReason = enum {
    blob_missing,
    mount_declined,
    mount_not_permitted,
    initiation_ambiguous,
    write_ambiguous,
    finalize_ambiguous,
};

pub const ReplaySafety = struct {
    /// True only after the source bytes were spooled and independently
    /// verified against the descriptor.
    source_verified: bool = false,
    /// Mount/start POSTs and future body requests are never replay-safe.
    non_idempotent_replay_allowed: bool = false,
    /// The final digest must be probed before any later retry decision.
    probe_before_retry: bool = true,
};

/// Owned failure state for a remote upload that may remain for registry
/// garbage collection. Formatting never exposes the upload URL or a
/// provider-signed query.
pub const UploadSessionSummary = struct {
    origin: registry_http.Origin,
    authorization_stripped: bool,

    pub fn deinit(self: *UploadSessionSummary) void {
        self.origin.deinit();
        self.* = undefined;
    }
};

pub const UploadHandoff = struct {
    digest: content.Digest,
    size: u64,
    roles: transport.DescriptorRoles,
    reason: UploadReason,
    session: ?UploadSessionSummary = null,
    replay: ReplaySafety = .{},

    pub fn deinit(self: *UploadHandoff) void {
        if (self.session) |*session| session.deinit();
        self.* = undefined;
    }

    pub fn format(
        self: UploadHandoff,
        writer: *Io.Writer,
    ) Io.Writer.Error!void {
        const digest_text = self.digest.format();
        try writer.print(
            "upload-incomplete(digest={s}, size={d}, reason={s}",
            .{ &digest_text, self.size, @tagName(self.reason) },
        );
        if (self.session) |session| {
            try writer.print(
                ", origin={s}, authorization={s}",
                .{
                    session.origin.canonical,
                    if (session.authorization_stripped) "stripped" else "destination",
                },
            );
        }
        try writer.writeByte(')');
    }
};

const SeenDescriptor = struct {
    size: u64,
    media_type: []u8,
    roles: transport.DescriptorRoles,
    outcome: ?transport.DescriptorResult = null,
};

const MountOutcome = union(enum) {
    mounted,
    declined: UploadSession,
    fallback,
};

const UploadSession = struct {
    location: registry_http.ResolvedUploadLocation,
    uuid: ?[]u8 = null,
    offset: u64 = 0,

    fn deinit(self: *UploadSession, allocator: Allocator) void {
        self.location.deinit();
        if (self.uuid) |uuid| {
            @memset(uuid, 0);
            allocator.free(uuid);
        }
        self.* = undefined;
    }
};

/// Registry destination with verified blob upload, immutable child/root
/// staging, and a root-tag-last commit lifecycle.
pub const Destination = struct {
    allocator: Allocator,
    remote: Source,
    tag: []u8,
    graph_limits: graph.Limits,
    mount_policy: MountPolicy,
    upload_chunk_bytes: ?u64,
    spool_directory: []u8,
    state_value: DestinationState = .initialized,
    root_digest: ?content.Digest = null,
    seen: std.AutoHashMap(content.Digest, SeenDescriptor),
    total_declared_bytes: u64 = 0,
    pending_upload: ?UploadHandoff = null,

    pub fn init(
        io: Io,
        allocator: Allocator,
        destination: reference.RegistryReference,
        options: DestinationOptions,
    ) Error!Destination {
        const tag = try validateDestinationConfiguration(destination, options);
        var remote = try Source.init(
            io,
            allocator,
            destination,
            options.sourceOptions(),
        );
        errdefer remote.deinit();
        const owned_tag = try allocator.dupe(u8, tag);
        errdefer allocator.free(owned_tag);
        const spool_directory = try allocator.dupe(
            u8,
            options.spool_directory orelse ".",
        );
        return .{
            .allocator = allocator,
            .remote = remote,
            .tag = owned_tag,
            .graph_limits = options.graph_limits,
            .mount_policy = options.mount_policy,
            .upload_chunk_bytes = options.upload_chunk_bytes,
            .spool_directory = spool_directory,
            .seen = std.AutoHashMap(content.Digest, SeenDescriptor).init(allocator),
        };
    }

    /// Injectable initialization used by deterministic tests and embedders.
    /// Backend/runtime ownership remains with the caller.
    pub fn initWithBackend(
        io: Io,
        allocator: Allocator,
        destination: reference.RegistryReference,
        backend: registry_http.Backend,
        clock: registry_http.Clock,
        sleeper: registry_http.Sleeper,
        options: DestinationOptions,
    ) Error!Destination {
        const tag = try validateDestinationConfiguration(destination, options);
        var remote = try Source.initWithBackend(
            io,
            allocator,
            destination,
            backend,
            clock,
            sleeper,
            options.sourceOptions(),
        );
        errdefer remote.deinit();
        const owned_tag = try allocator.dupe(u8, tag);
        errdefer allocator.free(owned_tag);
        const spool_directory = try allocator.dupe(
            u8,
            options.spool_directory orelse ".",
        );
        return .{
            .allocator = allocator,
            .remote = remote,
            .tag = owned_tag,
            .graph_limits = options.graph_limits,
            .mount_policy = options.mount_policy,
            .upload_chunk_bytes = options.upload_chunk_bytes,
            .spool_directory = spool_directory,
            .seen = std.AutoHashMap(content.Digest, SeenDescriptor).init(allocator),
        };
    }

    pub fn deinit(self: *Destination) void {
        if (self.pending_upload) |*handoff| handoff.deinit();
        var iterator = self.seen.valueIterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.media_type);
        }
        self.seen.deinit();
        self.allocator.free(self.spool_directory);
        self.allocator.free(self.tag);
        self.remote.deinit();
        self.* = undefined;
    }

    pub fn asTransport(self: *Destination) transport.Destination {
        return transport.Destination.init(self);
    }

    /// Layout -> registry adapter. The source graph is fully resolved and
    /// validated before destination preflight performs a network request.
    pub fn copyFromLayout(
        self: *Destination,
        source_reference: reference.LayoutReference,
        options: copy_engine.Options,
    ) !transport.Result {
        var source = layout.Source.initWithMetadataLimit(
            self.remote.io,
            self.allocator,
            source_reference.path,
            options.limits.max_metadata_bytes,
        );
        var resolved = try source.resolve(source_reference);
        defer resolved.deinit();
        var plan = try graph.planCopy(
            self.allocator,
            source.asTransport(),
            .{
                .descriptor = resolved.descriptor,
                .descriptor_json = resolved.descriptor_json,
            },
            options.limits,
        );
        defer plan.deinit();
        return copy_engine.executePlan(
            &plan,
            source.asTransport(),
            self.asTransport(),
            .{ .tag = self.tag },
        );
    }

    pub fn state(self: *const Destination) DestinationState {
        return self.state_value;
    }

    pub fn pendingUpload(self: *const Destination) ?*const UploadHandoff {
        return if (self.pending_upload) |*handoff| handoff else null;
    }

    pub fn lastDiagnostic(self: *const Destination) ?*const Diagnostic {
        return self.remote.lastDiagnostic();
    }

    pub fn committed(self: *const Destination) bool {
        return self.state_value == .finished;
    }

    pub fn prepareRoot(
        self: *Destination,
        root: model.Descriptor,
        selection: ?reference.Selection,
    ) Error!void {
        if (self.state_value != .initialized) {
            return error.DestinationStateConflict;
        }
        self.prepareRootInner(root, selection) catch |err| {
            self.state_value = .failed;
            return err;
        };
        self.state_value = .prepared;
    }

    fn prepareRootInner(
        self: *Destination,
        root: model.Descriptor,
        selection: ?reference.Selection,
    ) Error!void {
        model.validateRootDescriptor(root) catch
            return self.remote.fail(
                error.InvalidContent,
                .destination_preflight,
                .invalid_content,
                null,
                null,
                null,
            );
        const digest = root.parsedDigest() catch
            return self.remote.fail(
                error.InvalidContent,
                .destination_preflight,
                .invalid_content,
                null,
                null,
                null,
            );
        const tag = switch (selection orelse
            return error.TagRequired) {
            .tag => |value| value,
            .digest => return error.TagRequired,
        };
        if (!std.mem.eql(u8, tag, self.tag)) return error.InvalidReference;
        if (root.size > self.graph_limits.max_metadata_bytes or
            root.size > self.graph_limits.max_total_bytes)
        {
            return self.remote.fail(
                error.LimitExceeded,
                .destination_preflight,
                .limit,
                null,
                null,
                digest,
            );
        }

        var response = self.remote.client.execute(.{
            .path_and_query = "/v2/",
            .class = .registry,
            .max_body_bytes = self.remote.limits.max_preflight_body_bytes,
            .deadline = self.remote.deadline,
        }) catch |err| return self.remote.mapHttpFailure(
            err,
            .destination_preflight,
            digest,
        );
        defer response.deinit();
        try self.remote.requireSuccess(
            response,
            .destination_preflight,
            digest,
        );

        _ = try self.registerDescriptor(
            root,
            transport.DescriptorRoles.init(.root),
        );
        self.root_digest = digest;
        self.remote.last_diagnostic = null;
    }

    pub fn ensureDescriptor(
        self: *Destination,
        transfer: transport.DescriptorTransfer,
    ) Error!transport.DescriptorResult {
        if (self.state_value != .prepared) {
            return error.DestinationNotPrepared;
        }
        return self.ensureDescriptorInner(transfer) catch |err| {
            self.state_value = .failed;
            return err;
        };
    }

    fn ensureDescriptorInner(
        self: *Destination,
        transfer: transport.DescriptorTransfer,
    ) Error!transport.DescriptorResult {
        const digest = model.validateDescriptor(transfer.descriptor) catch
            return self.remote.fail(
                error.InvalidContent,
                .destination_probe,
                .invalid_content,
                null,
                null,
                null,
            );
        const existing = try self.registerDescriptor(
            transfer.descriptor,
            transfer.roles,
        );
        if (existing) |result| return result;

        switch (transfer.data) {
            .exact_metadata => |bytes| {
                if (!transfer.roles.index_child or transfer.roles.root or
                    transfer.roles.config or transfer.roles.layer)
                {
                    return error.InvalidContent;
                }
                model.validateMediaType(transfer.descriptor.mediaType) catch
                    return error.InvalidContent;
                content.verifyBytes(
                    digest,
                    transfer.descriptor.size,
                    bytes,
                ) catch return error.InvalidContent;
                const outcome = try self.ensureManifest(
                    transfer.descriptor,
                    bytes,
                    .publish_manifest,
                );
                self.setOutcome(digest, outcome);
                return outcome;
            },
            .opaque_blob => |source| {
                if (transfer.roles.root or transfer.roles.index_child or
                    (!transfer.roles.config and !transfer.roles.layer) or
                    model.classifyMediaType(transfer.descriptor.mediaType).isDocument())
                {
                    return error.InvalidContent;
                }
                return self.ensureBlob(
                    source,
                    transfer.descriptor,
                    transfer.roles,
                );
            },
        }
    }

    fn ensureBlob(
        self: *Destination,
        source: transport.Source,
        descriptor: model.Descriptor,
        roles: transport.DescriptorRoles,
    ) Error!transport.DescriptorResult {
        const digest = model.validateDescriptor(descriptor) catch
            return error.InvalidContent;
        if (try self.blobState(descriptor) == .verified) {
            self.setOutcome(digest, .reused);
            return .reused;
        }

        var mount_session: ?UploadSession = null;
        defer if (mount_session) |*session| session.deinit(self.allocator);
        if (source.registry_identity) |identity| {
            if (try self.mountEligible(identity)) {
                switch (try self.tryMount(identity, descriptor)) {
                    .mounted => {
                        self.setOutcome(digest, .mounted);
                        return .mounted;
                    },
                    .declined => |session| {
                        mount_session = session;
                    },
                    .fallback => {},
                }
            }
        }
        if (mount_session) |*owned_session| {
            try self.trackPendingUpload(
                descriptor,
                roles,
                .mount_declined,
                owned_session,
                false,
            );
        }

        var spool = try self.spoolVerified(source, descriptor);
        defer spool.deinit(self.remote.io, self.allocator);

        const used_mount_session = mount_session != null;
        var session = if (mount_session) |owned_session| blk: {
            mount_session = null;
            break :blk @as(?UploadSession, owned_session);
        } else try self.beginUpload(descriptor, roles);
        if (session == null) {
            self.setOutcome(digest, .reused);
            self.clearPendingUpload();
            return .reused;
        }
        try self.trackPendingUpload(
            descriptor,
            roles,
            (if (source.registry_identity == null)
                .blob_missing
            else if (used_mount_session)
                .mount_declined
            else
                .mount_not_permitted),
            &session.?,
            true,
        );
        defer session.?.deinit(self.allocator);

        const completed = if (self.upload_chunk_bytes) |chunk_bytes|
            try self.uploadChunked(
                &session.?,
                spool.file,
                descriptor,
                roles,
                chunk_bytes,
            )
        else
            try self.uploadMonolithic(
                &session.?,
                spool.file,
                descriptor,
                roles,
            );
        if (!completed) return error.UploadIncomplete;
        self.setOutcome(digest, .transferred);
        self.clearPendingUpload();
        return .transferred;
    }

    fn clearPendingUpload(self: *Destination) void {
        if (self.pending_upload) |*handoff| handoff.deinit();
        self.pending_upload = null;
    }

    fn trackPendingUpload(
        self: *Destination,
        descriptor: model.Descriptor,
        roles: transport.DescriptorRoles,
        reason: UploadReason,
        session: ?*const UploadSession,
        source_verified: bool,
    ) Error!void {
        self.clearPendingUpload();
        const digest = model.validateDescriptor(descriptor) catch
            return error.InvalidContent;
        var summary: ?UploadSessionSummary = null;
        errdefer if (summary) |*value| value.deinit();
        if (session) |value| {
            const origin = value.location.origin.clone(self.allocator) catch |err|
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.InvalidContent,
                };
            summary = .{
                .origin = origin,
                .authorization_stripped = value.location.authorization_stripped,
            };
        }
        self.pending_upload = .{
            .digest = digest,
            .size = descriptor.size,
            .roles = roles,
            .reason = reason,
            .session = summary,
            .replay = .{ .source_verified = source_verified },
        };
    }

    fn spoolVerified(
        self: *Destination,
        source: transport.Source,
        descriptor: model.Descriptor,
    ) Error!SpoolFile {
        if (self.remote.client.clock.now() >= self.remote.deadline.at_ns) {
            return self.remote.fail(
                error.DeadlineExceeded,
                .destination_upload_write,
                .deadline,
                null,
                null,
                descriptor.parsedDigest() catch null,
            );
        }
        var dir = Io.Dir.cwd().openDir(
            self.remote.io,
            self.spool_directory,
            .{},
        ) catch return self.remote.fail(
            error.TransportFailed,
            .destination_upload_write,
            .transport,
            null,
            null,
            descriptor.parsedDigest() catch null,
        );
        var dir_owned = true;
        errdefer if (dir_owned) dir.close(self.remote.io);
        const temporary = createUniqueTempFile(
            self.remote.io,
            self.allocator,
            dir,
            "registry-upload",
        ) catch return self.remote.fail(
            error.TransportFailed,
            .destination_upload_write,
            .transport,
            null,
            null,
            descriptor.parsedDigest() catch null,
        );
        var spool: SpoolFile = .{
            .dir = dir,
            .name = temporary.name,
            .file = temporary.file,
        };
        dir_owned = false;
        errdefer spool.deinit(self.remote.io, self.allocator);

        source.copyVerifiedTo(descriptor, spool.file) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidDigest,
                error.UnsupportedDigestAlgorithm,
                error.SizeMismatch,
                error.DigestMismatch,
                error.SizeOverflow,
                error.VerifierFinished,
                error.SourceContractViolation,
                error.DescriptorUnavailable,
                => self.remote.fail(
                    error.InvalidContent,
                    .destination_upload_write,
                    .invalid_content,
                    null,
                    null,
                    descriptor.parsedDigest() catch null,
                ),
                else => self.remote.fail(
                    error.TransportFailed,
                    .destination_upload_write,
                    .transport,
                    null,
                    null,
                    descriptor.parsedDigest() catch null,
                ),
            };
        };
        spool.file.sync(self.remote.io) catch
            return self.remote.fail(
                error.TransportFailed,
                .destination_upload_write,
                .transport,
                null,
                null,
                descriptor.parsedDigest() catch null,
            );
        verifySpoolFile(
            self.remote.io,
            spool.file,
            descriptor,
        ) catch |err| return switch (err) {
            error.InvalidContent => self.remote.fail(
                error.InvalidContent,
                .destination_upload_write,
                .invalid_content,
                null,
                null,
                descriptor.parsedDigest() catch null,
            ),
            else => self.remote.fail(
                error.TransportFailed,
                .destination_upload_write,
                .transport,
                null,
                null,
                descriptor.parsedDigest() catch null,
            ),
        };
        if (self.remote.client.clock.now() >= self.remote.deadline.at_ns) {
            return self.remote.fail(
                error.DeadlineExceeded,
                .destination_upload_write,
                .deadline,
                null,
                null,
                descriptor.parsedDigest() catch null,
            );
        }
        return spool;
    }

    fn beginUpload(
        self: *Destination,
        descriptor: model.Descriptor,
        roles: transport.DescriptorRoles,
    ) Error!?UploadSession {
        const digest = model.validateDescriptor(descriptor) catch
            return error.InvalidContent;
        const path = try std.fmt.allocPrint(
            self.allocator,
            "/v2/{s}/blobs/uploads/",
            .{self.remote.repository},
        );
        defer self.allocator.free(path);

        var response = self.remote.client.execute(.{
            .method = .POST,
            .path_and_query = path,
            .class = .registry,
            .max_body_bytes = self.remote.limits.max_preflight_body_bytes,
            .allow_auth_replay = false,
            .deadline = self.remote.deadline,
        }) catch |err| {
            if (!isAmbiguousHttpFailure(err)) {
                return self.remote.mapHttpFailure(
                    err,
                    .destination_upload_start,
                    digest,
                );
            }
            return self.resolveAmbiguousInitiation(descriptor, roles);
        };
        defer response.deinit();
        if (registry_http.isRetryableStatus(response.status)) {
            return self.resolveAmbiguousInitiation(descriptor, roles);
        }
        if (response.status != 202) {
            return self.requireMutationStatus(
                response,
                .destination_upload_start,
                digest,
            );
        }
        const session = try self.sessionFromResponse(
            response,
            path,
            null,
            0,
            digest,
            .destination_upload_start,
        );
        self.remote.last_diagnostic = null;
        return session;
    }

    fn resolveAmbiguousInitiation(
        self: *Destination,
        descriptor: model.Descriptor,
        roles: transport.DescriptorRoles,
    ) Error!?UploadSession {
        const digest = model.validateDescriptor(descriptor) catch
            return error.InvalidContent;
        const blob_state = self.blobState(descriptor) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try self.trackPendingUpload(
                descriptor,
                roles,
                .initiation_ambiguous,
                null,
                true,
            );
            return self.remote.fail(
                error.UploadIncomplete,
                .destination_upload_start,
                .transport,
                null,
                null,
                digest,
            );
        };
        if (blob_state == .verified) return null;
        try self.trackPendingUpload(
            descriptor,
            roles,
            .initiation_ambiguous,
            null,
            true,
        );
        return self.remote.fail(
            error.UploadIncomplete,
            .destination_upload_start,
            .transport,
            null,
            null,
            digest,
        );
    }

    fn uploadMonolithic(
        self: *Destination,
        session: *UploadSession,
        file: Io.File,
        descriptor: model.Descriptor,
        roles: transport.DescriptorRoles,
    ) Error!bool {
        const digest = model.validateDescriptor(descriptor) catch
            return error.InvalidContent;
        const target = try appendDigestQueryAlloc(
            self.allocator,
            session.location.url,
            digest,
            self.remote.client.limits.max_location_bytes,
        );
        defer {
            @memset(target, 0);
            self.allocator.free(target);
        }
        var file_source: FileBodySource = .{
            .io = self.remote.io,
            .file = file,
            .start = 0,
            .length = descriptor.size,
        };
        const headers = [_]registry_http.Header{.{
            .name = "Content-Type",
            .value = "application/octet-stream",
        }};
        var response = self.remote.client.execute(.{
            .method = .PUT,
            .absolute_url = target,
            .authorization_stripped = session.location.authorization_stripped,
            .class = .registry,
            .headers = &headers,
            .max_body_bytes = self.remote.limits.max_preflight_body_bytes,
            .body_source = registry_http.BodySource.init(
                &file_source,
                descriptor.size,
            ),
            .allow_auth_replay = false,
            .deadline = self.remote.deadline,
        }) catch |err| return self.resolveAmbiguousBlobWrite(
            err,
            session,
            descriptor,
            roles,
            .write_ambiguous,
            .destination_upload_write,
        );
        defer response.deinit();
        if (registry_http.isRetryableStatus(response.status)) {
            return self.resolveAmbiguousBlobResponse(
                session,
                descriptor,
                roles,
                .write_ambiguous,
                .destination_upload_write,
            );
        }
        if (response.status != 201) {
            return self.requireMutationStatus(
                response,
                .destination_upload_write,
                digest,
            );
        }
        try self.validateBlobCompletion(
            response,
            target,
            descriptor,
            .destination_upload_write,
        );
        return true;
    }

    fn uploadChunked(
        self: *Destination,
        session: *UploadSession,
        file: Io.File,
        descriptor: model.Descriptor,
        roles: transport.DescriptorRoles,
        chunk_bytes: u64,
    ) Error!bool {
        if (chunk_bytes == 0) return error.InvalidConfiguration;
        const digest = model.validateDescriptor(descriptor) catch
            return error.InvalidContent;
        const chunks = if (descriptor.size == 0)
            0
        else
            std.math.divCeil(u64, descriptor.size, chunk_bytes) catch
                return error.LimitExceeded;
        if (chunks > self.remote.limits.max_upload_chunks) {
            return self.remote.fail(
                error.LimitExceeded,
                .destination_upload_write,
                .limit,
                null,
                null,
                digest,
            );
        }

        while (session.offset < descriptor.size) {
            const length = @min(
                chunk_bytes,
                descriptor.size - session.offset,
            );
            const end = std.math.add(u64, session.offset, length) catch
                return error.LimitExceeded;
            var file_source: FileBodySource = .{
                .io = self.remote.io,
                .file = file,
                .start = session.offset,
                .length = length,
            };
            var range_buffer: [96]u8 = undefined;
            const range = std.fmt.bufPrint(
                &range_buffer,
                "{d}-{d}",
                .{ session.offset, end - 1 },
            ) catch return error.LimitExceeded;
            const headers = [_]registry_http.Header{
                .{
                    .name = "Content-Type",
                    .value = "application/octet-stream",
                },
                .{ .name = "Content-Range", .value = range },
            };
            var response = self.remote.client.execute(.{
                .method = .PATCH,
                .absolute_url = session.location.url,
                .authorization_stripped = session.location.authorization_stripped,
                .class = .registry,
                .headers = &headers,
                .max_body_bytes = self.remote.limits.max_preflight_body_bytes,
                .body_source = registry_http.BodySource.init(
                    &file_source,
                    length,
                ),
                .allow_auth_replay = false,
                .deadline = self.remote.deadline,
            }) catch |err| return self.resolveAmbiguousBlobWrite(
                err,
                session,
                descriptor,
                roles,
                .write_ambiguous,
                .destination_upload_write,
            );
            defer response.deinit();
            if (registry_http.isRetryableStatus(response.status)) {
                return self.resolveAmbiguousBlobResponse(
                    session,
                    descriptor,
                    roles,
                    .write_ambiguous,
                    .destination_upload_write,
                );
            }
            if (response.status != 202) {
                return self.requireMutationStatus(
                    response,
                    .destination_upload_write,
                    digest,
                );
            }
            const next = try self.sessionFromResponse(
                response,
                session.location.url,
                session,
                end,
                digest,
                .destination_upload_write,
            );
            session.deinit(self.allocator);
            session.* = next;
        }

        const target = try appendDigestQueryAlloc(
            self.allocator,
            session.location.url,
            digest,
            self.remote.client.limits.max_location_bytes,
        );
        defer {
            @memset(target, 0);
            self.allocator.free(target);
        }
        var response = self.remote.client.execute(.{
            .method = .PUT,
            .absolute_url = target,
            .authorization_stripped = session.location.authorization_stripped,
            .class = .registry,
            .max_body_bytes = self.remote.limits.max_preflight_body_bytes,
            .allow_auth_replay = false,
            .deadline = self.remote.deadline,
        }) catch |err| return self.resolveAmbiguousBlobWrite(
            err,
            session,
            descriptor,
            roles,
            .finalize_ambiguous,
            .destination_upload_finalize,
        );
        defer response.deinit();
        if (registry_http.isRetryableStatus(response.status)) {
            return self.resolveAmbiguousBlobResponse(
                session,
                descriptor,
                roles,
                .finalize_ambiguous,
                .destination_upload_finalize,
            );
        }
        if (response.status != 201) {
            return self.requireMutationStatus(
                response,
                .destination_upload_finalize,
                digest,
            );
        }
        try self.validateBlobCompletion(
            response,
            target,
            descriptor,
            .destination_upload_finalize,
        );
        return true;
    }

    fn resolveAmbiguousBlobWrite(
        self: *Destination,
        err: registry_http.Error,
        session: *const UploadSession,
        descriptor: model.Descriptor,
        roles: transport.DescriptorRoles,
        reason: UploadReason,
        operation: Operation,
    ) Error!bool {
        if (!isAmbiguousHttpFailure(err)) {
            return self.remote.mapHttpFailure(
                err,
                operation,
                descriptor.parsedDigest() catch null,
            );
        }
        return self.resolveAmbiguousBlobResponse(
            session,
            descriptor,
            roles,
            reason,
            operation,
        );
    }

    fn resolveAmbiguousBlobResponse(
        self: *Destination,
        session: *const UploadSession,
        descriptor: model.Descriptor,
        roles: transport.DescriptorRoles,
        reason: UploadReason,
        operation: Operation,
    ) Error!bool {
        const digest = model.validateDescriptor(descriptor) catch
            return error.InvalidContent;
        const blob_state = self.blobState(descriptor) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try self.trackPendingUpload(
                descriptor,
                roles,
                reason,
                session,
                true,
            );
            return self.remote.fail(
                error.UploadAmbiguous,
                operation,
                .transport,
                null,
                null,
                digest,
            );
        };
        if (blob_state == .verified) {
            self.remote.last_diagnostic = null;
            return true;
        }
        try self.trackPendingUpload(
            descriptor,
            roles,
            reason,
            session,
            true,
        );
        return self.remote.fail(
            error.UploadAmbiguous,
            operation,
            .transport,
            null,
            null,
            digest,
        );
    }

    fn validateBlobCompletion(
        self: *Destination,
        response: registry_http.Response,
        current_target: []const u8,
        descriptor: model.Descriptor,
        operation: Operation,
    ) Error!void {
        const digest = model.validateDescriptor(descriptor) catch
            return error.InvalidContent;
        try self.remote.corroborateDigestHeader(
            response,
            digest,
            operation,
        );
        const location = (singleHeader(response, "Location") catch
            return self.remote.fail(
                error.InvalidContent,
                operation,
                .invalid_content,
                response.status,
                null,
                digest,
            )) orelse return self.remote.fail(
            error.InvalidContent,
            operation,
            .invalid_content,
            response.status,
            null,
            digest,
        );
        var completed = registry_http.resolveUploadLocationAlloc(
            self.allocator,
            self.remote.client.endpoint,
            current_target,
            location,
            self.remote.client.limits.max_location_bytes,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => self.remote.fail(
                error.RedirectRejected,
                operation,
                .redirect,
                response.status,
                null,
                digest,
            ),
        };
        completed.deinit();
        const blob_state = self.blobState(descriptor) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.remote.fail(
                error.UploadIncomplete,
                operation,
                .transport,
                response.status,
                null,
                digest,
            );
        };
        if (blob_state != .verified) {
            return self.remote.fail(
                error.InvalidContent,
                operation,
                .invalid_content,
                response.status,
                null,
                digest,
            );
        }
        self.remote.last_diagnostic = null;
    }

    /// A 404 HEAD is missing. Unsupported or successful HEAD responses are
    /// followed by a bounded verified GET before reuse is reported.
    fn blobState(
        self: *Destination,
        descriptor: model.Descriptor,
    ) Error!BlobState {
        const digest = model.validateDescriptor(descriptor) catch
            return self.remote.fail(
                error.InvalidContent,
                .destination_probe,
                .invalid_content,
                null,
                null,
                null,
            );
        const digest_text = digest.format();
        const path = try std.fmt.allocPrint(
            self.allocator,
            "/v2/{s}/blobs/{s}",
            .{ self.remote.repository, &digest_text },
        );
        defer self.allocator.free(path);

        var head = self.remote.client.execute(.{
            .method = .HEAD,
            .path_and_query = path,
            .class = .blob,
            .max_body_bytes = 0,
            .deadline = self.remote.deadline,
        }) catch |err| return self.remote.mapHttpFailure(
            err,
            .destination_probe,
            digest,
        );
        defer head.deinit();

        var head_reported_present = false;
        switch (head.status) {
            404 => return .missing,
            405, 501 => {},
            200 => {
                head_reported_present = true;
                try self.verifyHeadHeaders(head, descriptor, digest);
            },
            else => try self.remote.requireSuccess(
                head,
                .destination_probe,
                digest,
            ),
        }

        var sink: VerifySink = .{
            .digest = digest,
            .size = descriptor.size,
        };
        var response = self.remote.client.execute(.{
            .path_and_query = path,
            .class = .blob,
            .max_body_bytes = descriptor.size,
            .body_sink = registry_http.BodySink.init(&sink),
            .deadline = self.remote.deadline,
        }) catch |err| {
            if (err == error.BodySinkFailed) {
                return self.remote.fail(
                    error.InvalidContent,
                    .destination_probe,
                    .invalid_content,
                    null,
                    null,
                    digest,
                );
            }
            return self.remote.mapHttpFailure(
                err,
                .destination_probe,
                digest,
            );
        };
        defer response.deinit();
        if (response.status == 404) {
            if (!head_reported_present) return .missing;
            return self.remote.fail(
                error.InvalidContent,
                .destination_probe,
                .invalid_content,
                response.status,
                null,
                digest,
            );
        }
        try self.remote.requireSuccess(
            response,
            .destination_probe,
            digest,
        );
        try self.remote.corroborateContentLength(
            response,
            descriptor.size,
            .destination_probe,
            digest,
        );
        try self.remote.corroborateDigestHeader(
            response,
            digest,
            .destination_probe,
        );
        if (singleHeader(response, "Content-Type") catch
            return self.remote.fail(
                error.InvalidContent,
                .destination_probe,
                .invalid_content,
                response.status,
                null,
                digest,
            )) |value|
        {
            const base = mediaTypeBase(value) orelse
                return self.remote.fail(
                    error.InvalidContent,
                    .destination_probe,
                    .invalid_content,
                    response.status,
                    null,
                    digest,
                );
            model.validateMediaType(base) catch
                return self.remote.fail(
                    error.InvalidContent,
                    .destination_probe,
                    .invalid_content,
                    response.status,
                    null,
                    digest,
                );
        }
        self.remote.last_diagnostic = null;
        return .verified;
    }

    fn verifyHeadHeaders(
        self: *Destination,
        response: registry_http.Response,
        descriptor: model.Descriptor,
        digest: content.Digest,
    ) Error!void {
        if (singleHeader(response, "Content-Length") catch
            return self.remote.fail(
                error.InvalidContent,
                .destination_probe,
                .invalid_content,
                response.status,
                null,
                digest,
            )) |value|
        {
            const actual = std.fmt.parseInt(
                u64,
                std.mem.trim(u8, value, " \t"),
                10,
            ) catch return self.remote.fail(
                error.InvalidContent,
                .destination_probe,
                .invalid_content,
                response.status,
                null,
                digest,
            );
            if (actual != descriptor.size) {
                return self.remote.fail(
                    error.InvalidContent,
                    .destination_probe,
                    .invalid_content,
                    response.status,
                    null,
                    digest,
                );
            }
        }
        try self.remote.corroborateDigestHeader(
            response,
            digest,
            .destination_probe,
        );
    }

    fn mountEligible(
        self: *Destination,
        identity: transport.RegistryIdentity,
    ) Error!bool {
        if (self.mount_policy == .disabled or
            std.mem.eql(u8, identity.repository, self.remote.repository))
        {
            return false;
        }
        if (!std.mem.eql(
            u8,
            identity.origin,
            self.remote.client.endpoint.canonicalOrigin(),
        )) {
            return false;
        }
        var endpoint = registry_http.Endpoint.init(
            self.allocator,
            .{
                .authority = identity.authority,
                .plain_http = identity.plain_http,
            },
            self.remote.client.limits,
        ) catch return error.InvalidReference;
        defer endpoint.deinit();
        if (!std.mem.eql(u8, endpoint.canonicalOrigin(), identity.origin)) {
            return error.InvalidReference;
        }
        try validateRepositoryBinding(
            self.allocator,
            identity.authority,
            identity.repository,
        );
        return true;
    }

    fn tryMount(
        self: *Destination,
        identity: transport.RegistryIdentity,
        descriptor: model.Descriptor,
    ) Error!MountOutcome {
        const digest = model.validateDescriptor(descriptor) catch
            return error.InvalidContent;
        const digest_text = digest.format();
        const encoded_digest = try percentEncodeQueryAlloc(
            self.allocator,
            &digest_text,
        );
        defer self.allocator.free(encoded_digest);
        const encoded_source = try percentEncodeQueryAlloc(
            self.allocator,
            identity.repository,
        );
        defer self.allocator.free(encoded_source);
        const path = try std.fmt.allocPrint(
            self.allocator,
            "/v2/{s}/blobs/uploads/?mount={s}&from={s}",
            .{ self.remote.repository, encoded_digest, encoded_source },
        );
        defer self.allocator.free(path);

        var response = self.remote.client.execute(.{
            .method = .POST,
            .path_and_query = path,
            .class = .registry,
            .max_body_bytes = self.remote.limits.max_preflight_body_bytes,
            .allow_auth_replay = false,
            .deadline = self.remote.deadline,
        }) catch |err| {
            if (!isAmbiguousHttpFailure(err)) {
                return self.remote.mapHttpFailure(
                    err,
                    .destination_mount,
                    digest,
                );
            }
            if (try self.blobState(descriptor) == .verified) return .mounted;
            self.remote.last_diagnostic = null;
            return .fallback;
        };
        defer response.deinit();

        switch (response.status) {
            201 => {
                try self.remote.corroborateDigestHeader(
                    response,
                    digest,
                    .destination_mount,
                );
                if (singleHeader(response, "Location") catch
                    return self.remote.fail(
                        error.InvalidContent,
                        .destination_mount,
                        .invalid_content,
                        response.status,
                        null,
                        digest,
                    )) |location|
                {
                    var completed = registry_http.resolveUploadLocationAlloc(
                        self.allocator,
                        self.remote.client.endpoint,
                        path,
                        location,
                        self.remote.client.limits.max_location_bytes,
                    ) catch |err| return switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => self.remote.fail(
                            error.RedirectRejected,
                            .destination_mount,
                            .redirect,
                            response.status,
                            null,
                            digest,
                        ),
                    };
                    completed.deinit();
                }
                if (try self.blobState(descriptor) != .verified) {
                    return self.remote.fail(
                        error.InvalidContent,
                        .destination_mount,
                        .invalid_content,
                        response.status,
                        null,
                        digest,
                    );
                }
                self.remote.last_diagnostic = null;
                return .mounted;
            },
            202 => {
                try self.remote.corroborateDigestHeader(
                    response,
                    digest,
                    .destination_mount,
                );
                const session = try self.sessionFromResponse(
                    response,
                    path,
                    null,
                    0,
                    digest,
                    .destination_mount,
                );
                self.remote.last_diagnostic = null;
                return .{ .declined = session };
            },
            else => {
                try self.remote.requireSuccess(
                    response,
                    .destination_mount,
                    digest,
                );
                return self.remote.fail(
                    error.RegistryFailed,
                    .destination_mount,
                    .registry,
                    response.status,
                    null,
                    digest,
                );
            },
        }
    }

    fn sessionFromResponse(
        self: *Destination,
        response: registry_http.Response,
        current_target: []const u8,
        previous: ?*const UploadSession,
        expected_offset: u64,
        digest: content.Digest,
        operation: Operation,
    ) Error!UploadSession {
        const location = (singleHeader(response, "Location") catch
            return self.remote.fail(
                error.InvalidContent,
                operation,
                .invalid_content,
                response.status,
                null,
                digest,
            )) orelse return self.remote.fail(
            error.InvalidContent,
            operation,
            .invalid_content,
            response.status,
            null,
            digest,
        );
        var resolved = registry_http.resolveUploadLocationAlloc(
            self.allocator,
            self.remote.client.endpoint,
            current_target,
            location,
            self.remote.client.limits.max_location_bytes,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => self.remote.fail(
                error.RedirectRejected,
                operation,
                .redirect,
                response.status,
                null,
                digest,
            ),
        };
        errdefer resolved.deinit();
        if (previous) |prior| {
            if (!prior.location.origin.eql(resolved.origin) or
                prior.location.authorization_stripped !=
                    resolved.authorization_stripped or
                !uploadLocationPathEqual(
                    prior.location.url,
                    resolved.url,
                ))
            {
                return self.remote.fail(
                    error.InvalidContent,
                    operation,
                    .invalid_content,
                    response.status,
                    null,
                    digest,
                );
            }
        }

        const uuid_header = singleHeader(
            response,
            "Docker-Upload-UUID",
        ) catch return self.remote.fail(
            error.InvalidContent,
            operation,
            .invalid_content,
            response.status,
            null,
            digest,
        );
        var uuid: ?[]u8 = null;
        errdefer if (uuid) |value| {
            @memset(value, 0);
            self.allocator.free(value);
        };
        if (uuid_header) |value| {
            if (!validUploadUuid(
                value,
                self.remote.client.limits.max_location_bytes,
            )) {
                return self.remote.fail(
                    error.InvalidContent,
                    operation,
                    .invalid_content,
                    response.status,
                    null,
                    digest,
                );
            }
            if (previous) |prior| {
                if (prior.uuid) |expected| {
                    if (!std.mem.eql(u8, expected, value)) {
                        return self.remote.fail(
                            error.InvalidContent,
                            operation,
                            .invalid_content,
                            response.status,
                            null,
                            digest,
                        );
                    }
                }
            }
            uuid = try self.allocator.dupe(u8, value);
        } else if (previous) |prior| {
            if (prior.uuid != null) {
                return self.remote.fail(
                    error.InvalidContent,
                    operation,
                    .invalid_content,
                    response.status,
                    null,
                    digest,
                );
            }
        }

        const range_header = singleHeader(response, "Range") catch
            return self.remote.fail(
                error.InvalidContent,
                operation,
                .invalid_content,
                response.status,
                null,
                digest,
            );
        if (range_header) |value| {
            if (!validUploadRange(value, expected_offset)) {
                return self.remote.fail(
                    error.InvalidContent,
                    operation,
                    .invalid_content,
                    response.status,
                    null,
                    digest,
                );
            }
        } else if (previous != null and expected_offset != 0) {
            return self.remote.fail(
                error.InvalidContent,
                operation,
                .invalid_content,
                response.status,
                null,
                digest,
            );
        }
        return .{
            .location = resolved,
            .uuid = uuid,
            .offset = expected_offset,
        };
    }

    fn requireMutationStatus(
        self: *Destination,
        response: registry_http.Response,
        operation: Operation,
        digest: content.Digest,
    ) Error {
        return switch (response.status) {
            401 => self.remote.fail(
                error.AuthenticationFailed,
                operation,
                .authentication,
                response.status,
                null,
                digest,
            ),
            403 => self.remote.fail(
                error.AuthorizationDenied,
                operation,
                .authorization,
                response.status,
                null,
                digest,
            ),
            404 => self.remote.fail(
                error.ContentNotFound,
                operation,
                .not_found,
                response.status,
                null,
                digest,
            ),
            413, 429 => self.remote.fail(
                error.LimitExceeded,
                operation,
                .limit,
                response.status,
                null,
                digest,
            ),
            else => self.remote.fail(
                error.RegistryFailed,
                operation,
                .registry,
                response.status,
                null,
                digest,
            ),
        };
    }

    fn ensureManifest(
        self: *Destination,
        descriptor: model.Descriptor,
        bytes: []const u8,
        operation: Operation,
    ) Error!transport.DescriptorResult {
        const digest = model.validateDescriptor(descriptor) catch
            return error.InvalidContent;
        model.validateMediaType(descriptor.mediaType) catch
            return error.InvalidContent;
        content.verifyBytes(digest, descriptor.size, bytes) catch
            return error.InvalidContent;
        const digest_text = digest.format();
        if (try self.manifestState(descriptor, &digest_text, operation) ==
            .verified)
        {
            return .reused;
        }
        try self.putManifest(
            descriptor,
            bytes,
            &digest_text,
            operation,
            false,
        );
        return .transferred;
    }

    fn manifestState(
        self: *Destination,
        descriptor: model.Descriptor,
        selector: []const u8,
        operation: Operation,
    ) Error!BlobState {
        const digest = model.validateDescriptor(descriptor) catch
            return error.InvalidContent;
        const path = try std.fmt.allocPrint(
            self.allocator,
            "/v2/{s}/manifests/{s}",
            .{ self.remote.repository, selector },
        );
        defer self.allocator.free(path);
        var sink: VerifySink = .{
            .digest = digest,
            .size = descriptor.size,
        };
        var response = self.remote.client.execute(.{
            .path_and_query = path,
            .class = .registry,
            .headers = &.{.{
                .name = "Accept",
                .value = manifest_accept,
            }},
            .max_body_bytes = descriptor.size,
            .body_sink = registry_http.BodySink.init(&sink),
            .deadline = self.remote.deadline,
        }) catch |err| {
            if (err == error.BodySinkFailed) {
                return self.remote.fail(
                    error.InvalidContent,
                    operation,
                    .invalid_content,
                    null,
                    null,
                    digest,
                );
            }
            return self.remote.mapHttpFailure(err, operation, digest);
        };
        defer response.deinit();
        if (response.status == 404) return .missing;
        if (response.status != 200) {
            return self.requireMutationStatus(response, operation, digest);
        }
        try self.remote.corroborateContentLength(
            response,
            descriptor.size,
            operation,
            digest,
        );
        try self.remote.corroborateDigestHeader(
            response,
            digest,
            operation,
        );
        const content_type_header = singleHeader(
            response,
            "Content-Type",
        ) catch return self.remote.fail(
            error.InvalidContent,
            operation,
            .invalid_content,
            response.status,
            null,
            digest,
        );
        const content_type = mediaTypeBase(content_type_header orelse
            return self.remote.fail(
                error.InvalidContent,
                operation,
                .invalid_content,
                response.status,
                null,
                digest,
            )) orelse return self.remote.fail(
            error.InvalidContent,
            operation,
            .invalid_content,
            response.status,
            null,
            digest,
        );
        model.validateMediaType(content_type) catch
            return self.remote.fail(
                error.InvalidContent,
                operation,
                .invalid_content,
                response.status,
                null,
                digest,
            );
        if (!std.mem.eql(u8, content_type, descriptor.mediaType)) {
            return self.remote.fail(
                error.InvalidContent,
                operation,
                .invalid_content,
                response.status,
                null,
                digest,
            );
        }
        self.remote.last_diagnostic = null;
        return .verified;
    }

    fn putManifest(
        self: *Destination,
        descriptor: model.Descriptor,
        bytes: []const u8,
        selector: []const u8,
        operation: Operation,
        confirm_tag_and_digest: bool,
    ) Error!void {
        const digest = model.validateDescriptor(descriptor) catch
            return error.InvalidContent;
        content.verifyBytes(digest, descriptor.size, bytes) catch
            return error.InvalidContent;
        const path = try std.fmt.allocPrint(
            self.allocator,
            "/v2/{s}/manifests/{s}",
            .{ self.remote.repository, selector },
        );
        defer self.allocator.free(path);
        var bytes_source: BytesBodySource = .{ .bytes = bytes };
        const headers = [_]registry_http.Header{.{
            .name = "Content-Type",
            .value = descriptor.mediaType,
        }};
        var response = self.remote.client.execute(.{
            .method = .PUT,
            .path_and_query = path,
            .class = .registry,
            .headers = &headers,
            .max_body_bytes = self.remote.limits.max_preflight_body_bytes,
            .body_source = registry_http.BodySource.init(
                &bytes_source,
                descriptor.size,
            ),
            .allow_auth_replay = false,
            .deadline = self.remote.deadline,
        }) catch |err| {
            if (!isAmbiguousHttpFailure(err)) {
                return self.remote.mapHttpFailure(err, operation, digest);
            }
            return self.confirmManifestWrite(
                descriptor,
                selector,
                operation,
                confirm_tag_and_digest,
                true,
            );
        };
        defer response.deinit();
        if (registry_http.isRetryableStatus(response.status)) {
            return self.confirmManifestWrite(
                descriptor,
                selector,
                operation,
                confirm_tag_and_digest,
                true,
            );
        }
        if (response.status != 201) {
            return self.requireMutationStatus(response, operation, digest);
        }
        try self.remote.corroborateDigestHeader(
            response,
            digest,
            operation,
        );
        if (singleHeader(response, "Location") catch
            return self.remote.fail(
                error.InvalidContent,
                operation,
                .invalid_content,
                response.status,
                null,
                digest,
            )) |location|
        {
            var resolved = registry_http.resolveUploadLocationAlloc(
                self.allocator,
                self.remote.client.endpoint,
                path,
                location,
                self.remote.client.limits.max_location_bytes,
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => self.remote.fail(
                    error.RedirectRejected,
                    operation,
                    .redirect,
                    response.status,
                    null,
                    digest,
                ),
            };
            resolved.deinit();
        }
        try self.confirmManifestWrite(
            descriptor,
            selector,
            operation,
            confirm_tag_and_digest,
            false,
        );
    }

    fn confirmManifestWrite(
        self: *Destination,
        descriptor: model.Descriptor,
        selector: []const u8,
        operation: Operation,
        confirm_tag_and_digest: bool,
        ambiguous: bool,
    ) Error!void {
        const digest = model.validateDescriptor(descriptor) catch
            return error.InvalidContent;
        const selected = self.manifestState(
            descriptor,
            selector,
            operation,
        ) catch |err| {
            if (ambiguous and err != error.OutOfMemory) {
                return self.remote.fail(
                    error.PublicationUnconfirmed,
                    operation,
                    .registry,
                    null,
                    null,
                    digest,
                );
            }
            return err;
        };
        if (selected != .verified) {
            return self.remote.fail(
                error.PublicationUnconfirmed,
                operation,
                .registry,
                null,
                null,
                digest,
            );
        }
        if (confirm_tag_and_digest) {
            const digest_text = digest.format();
            const immutable = self.manifestState(
                descriptor,
                &digest_text,
                operation,
            ) catch |err| {
                if (ambiguous and err != error.OutOfMemory) {
                    return self.remote.fail(
                        error.PublicationUnconfirmed,
                        operation,
                        .registry,
                        null,
                        null,
                        digest,
                    );
                }
                return err;
            };
            if (immutable != .verified) {
                return self.remote.fail(
                    error.PublicationUnconfirmed,
                    operation,
                    .registry,
                    null,
                    null,
                    digest,
                );
            }
        }
        self.remote.last_diagnostic = null;
    }

    pub fn stageRoot(
        self: *Destination,
        publication: transport.RootPublication,
    ) Error!transport.DescriptorResult {
        if (self.state_value != .prepared) {
            return error.DestinationNotPrepared;
        }
        const result = blk: {
            self.validatePublication(publication, null) catch |err| {
                self.state_value = .failed;
                return err;
            };
            break :blk self.ensureManifest(
                publication.descriptor,
                publication.exact_bytes,
                .stage_root,
            ) catch |err| {
                self.state_value = .failed;
                return err;
            };
        };
        const digest = model.validateDescriptor(publication.descriptor) catch {
            self.state_value = .failed;
            return error.InvalidContent;
        };
        self.setOutcome(digest, result);
        self.state_value = .staged;
        return result;
    }

    pub fn commitRoot(
        self: *Destination,
        publication: transport.RootPublication,
        selection: ?reference.Selection,
    ) Error!transport.CommitResult {
        if (self.state_value != .staged) {
            return error.DestinationNotStaged;
        }
        if (selection == null) {
            self.state_value = .failed;
            return error.TagRequired;
        }
        self.validatePublication(publication, selection) catch |err| {
            self.state_value = .failed;
            return err;
        };
        self.putManifest(
            publication.descriptor,
            publication.exact_bytes,
            self.tag,
            .commit_root,
            true,
        ) catch |err| {
            self.state_value = .failed;
            return err;
        };
        self.state_value = .committed;
        return .published;
    }

    pub fn finish(self: *Destination) Error!void {
        if (self.state_value != .committed) {
            return error.DestinationNotCommitted;
        }
        // commitRoot already confirmed both the mutable tag and immutable
        // digest. No fallible work may follow that final visibility change.
        self.state_value = .finished;
    }

    fn registerDescriptor(
        self: *Destination,
        descriptor: model.Descriptor,
        roles: transport.DescriptorRoles,
    ) Error!?transport.DescriptorResult {
        const digest = model.validateDescriptor(descriptor) catch
            return error.InvalidContent;
        if (!roles.root and !roles.index_child and !roles.config and !roles.layer) {
            return error.InvalidContent;
        }
        if (self.seen.getPtr(digest)) |existing| {
            if (existing.size != descriptor.size or
                !std.mem.eql(u8, existing.media_type, descriptor.mediaType))
            {
                return error.InvalidContent;
            }
            if (existing.roles.root != roles.root and
                (existing.roles.root or roles.root))
            {
                return error.InvalidContent;
            }
            existing.roles.root = existing.roles.root or roles.root;
            existing.roles.index_child =
                existing.roles.index_child or roles.index_child;
            existing.roles.config = existing.roles.config or roles.config;
            existing.roles.layer = existing.roles.layer or roles.layer;
            return existing.outcome;
        }
        if (@as(u64, @intCast(self.seen.count())) >=
            self.graph_limits.max_nodes)
        {
            return error.LimitExceeded;
        }
        const total = std.math.add(
            u64,
            self.total_declared_bytes,
            descriptor.size,
        ) catch return error.LimitExceeded;
        if (total > self.graph_limits.max_total_bytes) {
            return error.LimitExceeded;
        }
        const media_type = try self.allocator.dupe(u8, descriptor.mediaType);
        errdefer self.allocator.free(media_type);
        try self.seen.put(digest, .{
            .size = descriptor.size,
            .media_type = media_type,
            .roles = roles,
        });
        self.total_declared_bytes = total;
        return null;
    }

    fn validatePublication(
        self: *Destination,
        publication: transport.RootPublication,
        selection: ?reference.Selection,
    ) Error!void {
        const digest = model.validateDescriptor(publication.descriptor) catch
            return error.InvalidContent;
        if (self.root_digest == null or !digest.eql(self.root_digest.?)) {
            return error.InvalidContent;
        }
        content.verifyBytes(
            digest,
            publication.descriptor.size,
            publication.exact_bytes,
        ) catch return error.InvalidContent;
        if (selection) |selected| {
            const tag = switch (selected) {
                .tag => |value| value,
                .digest => return error.TagRequired,
            };
            if (!std.mem.eql(u8, tag, self.tag)) {
                return error.InvalidReference;
            }
        }
    }

    fn setOutcome(
        self: *Destination,
        digest: content.Digest,
        outcome: transport.DescriptorResult,
    ) void {
        self.seen.getPtr(digest).?.outcome = outcome;
    }
};

const TempFile = struct {
    name: []u8,
    file: Io.File,
};

const SpoolFile = struct {
    dir: Io.Dir,
    name: []u8,
    file: Io.File,

    fn deinit(
        self: *SpoolFile,
        io: Io,
        allocator: Allocator,
    ) void {
        self.file.close(io);
        self.dir.deleteFile(io, self.name) catch {};
        self.dir.close(io);
        allocator.free(self.name);
        self.* = undefined;
    }
};

const FileBodySource = struct {
    io: Io,
    file: Io.File,
    start: u64,
    length: u64,

    pub fn read(
        self: *FileBodySource,
        offset: u64,
        buffer: []u8,
    ) registry_http.BodySourceError!usize {
        if (offset >= self.length) return 0;
        const remaining: usize = @intCast(@min(
            self.length - offset,
            buffer.len,
        ));
        const position = std.math.add(u64, self.start, offset) catch
            return error.SourceFailed;
        return self.file.readPositional(
            self.io,
            &.{buffer[0..remaining]},
            position,
        ) catch error.SourceFailed;
    }
};

const BytesBodySource = struct {
    bytes: []const u8,

    pub fn read(
        self: *BytesBodySource,
        offset: u64,
        buffer: []u8,
    ) registry_http.BodySourceError!usize {
        const start = std.math.cast(usize, offset) orelse
            return error.SourceFailed;
        if (start >= self.bytes.len) return 0;
        const count = @min(buffer.len, self.bytes.len - start);
        @memcpy(buffer[0..count], self.bytes[start..][0..count]);
        return count;
    }
};

fn verifySpoolFile(
    io: Io,
    file: Io.File,
    descriptor: model.Descriptor,
) !void {
    const digest = model.validateDescriptor(descriptor) catch
        return error.InvalidContent;
    const length = file.length(io) catch return error.TransportFailed;
    if (length != descriptor.size) {
        return error.InvalidContent;
    }
    var verifier = content.Verifier.init(digest, descriptor.size);
    var buffer: [transport.copy_buffer_size]u8 = undefined;
    var offset: u64 = 0;
    while (offset < descriptor.size) {
        const remaining: usize = @intCast(@min(
            descriptor.size - offset,
            buffer.len,
        ));
        const count = file.readPositional(
            io,
            &.{buffer[0..remaining]},
            offset,
        ) catch return error.TransportFailed;
        if (count == 0) return error.InvalidContent;
        verifier.update(buffer[0..count]) catch
            return error.InvalidContent;
        offset = std.math.add(u64, offset, count) catch
            return error.InvalidContent;
    }
    verifier.finish() catch return error.InvalidContent;
}

fn createUniqueTempFile(
    io: Io,
    allocator: Allocator,
    dir: Io.Dir,
    kind: []const u8,
) !TempFile {
    var random: [16]u8 = undefined;
    for (0..64) |_| {
        try io.randomSecure(&random);
        const suffix = std.fmt.bytesToHex(random, .lower);
        const name = try std.fmt.allocPrint(
            allocator,
            ".wabt-oci-{s}-{s}.tmp",
            .{ kind, suffix },
        );
        const file = dir.createFile(io, name, .{
            .exclusive = true,
            .read = true,
            .permissions = privateFilePermissions(),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(name);
                continue;
            },
            else => {
                allocator.free(name);
                return err;
            },
        };
        return .{ .name = name, .file = file };
    }
    return error.PathAlreadyExists;
}

fn privateFilePermissions() Io.File.Permissions {
    return switch (builtin.os.tag) {
        .windows => .default_file,
        else => .fromMode(0o600),
    };
}

fn appendDigestQueryAlloc(
    allocator: Allocator,
    base: []const u8,
    digest: content.Digest,
    max_bytes: usize,
) Error![]u8 {
    const digest_text = digest.format();
    const encoded = try percentEncodeQueryAlloc(allocator, &digest_text);
    defer allocator.free(encoded);
    const separator: []const u8 = if (std.mem.indexOfScalar(
        u8,
        base,
        '?',
    ) == null) "?" else if (std.mem.endsWith(u8, base, "?") or
        std.mem.endsWith(u8, base, "&")) "" else "&";
    const required = std.math.add(usize, base.len, separator.len) catch
        return error.LimitExceeded;
    const with_name = std.math.add(usize, required, "digest=".len) catch
        return error.LimitExceeded;
    const total = std.math.add(usize, with_name, encoded.len) catch
        return error.LimitExceeded;
    if (total > max_bytes) return error.LimitExceeded;
    return std.fmt.allocPrint(
        allocator,
        "{s}{s}digest={s}",
        .{ base, separator, encoded },
    );
}

fn uploadLocationPathEqual(
    left: []const u8,
    right: []const u8,
) bool {
    return std.mem.eql(u8, uploadLocationPath(left), uploadLocationPath(right));
}

fn uploadLocationPath(url: []const u8) []const u8 {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return &.{};
    const authority_start = scheme + 3;
    const path_start = std.mem.indexOfScalarPos(
        u8,
        url,
        authority_start,
        '/',
    ) orelse return "/";
    const query = std.mem.indexOfScalarPos(
        u8,
        url,
        path_start,
        '?',
    ) orelse url.len;
    return url[path_start..query];
}

fn validUploadUuid(value: []const u8, max_bytes: usize) bool {
    if (value.len == 0 or value.len > max_bytes) return false;
    for (value) |byte| {
        if (byte <= 0x20 or byte == 0x7f or byte == '/' or
            byte == '?' or byte == '#')
        {
            return false;
        }
    }
    return true;
}

fn validUploadRange(value: []const u8, expected_offset: u64) bool {
    const trimmed = std.mem.trim(u8, value, " \t");
    const text = if (std.mem.startsWith(u8, trimmed, "bytes="))
        trimmed["bytes=".len..]
    else
        trimmed;
    const dash = std.mem.indexOfScalar(u8, text, '-') orelse return false;
    if (std.mem.indexOfScalarPos(u8, text, dash + 1, '-') != null) {
        return false;
    }
    const start = std.fmt.parseInt(u64, text[0..dash], 10) catch
        return false;
    const end = std.fmt.parseInt(u64, text[dash + 1 ..], 10) catch
        return false;
    if (start != 0) return false;
    if (expected_offset == 0) return end == 0;
    return end == expected_offset - 1;
}

fn isAmbiguousHttpFailure(err: registry_http.Error) bool {
    return err == error.TransportFailed or
        err == error.BodySourceFailed or
        err == error.DeadlineExceeded or
        err == error.RetryLimitExceeded;
}

const VerifySink = struct {
    digest: content.Digest,
    size: u64,
    verifier: ?content.Verifier = null,

    pub fn begin(
        self: *VerifySink,
        content_length: ?u64,
    ) registry_http.BodySinkError!void {
        if (content_length) |length| {
            if (length != self.size) return error.SinkFailed;
        }
        self.verifier = content.Verifier.init(self.digest, self.size);
    }

    pub fn write(
        self: *VerifySink,
        bytes: []const u8,
    ) registry_http.BodySinkError!void {
        self.verifier.?.update(bytes) catch return error.SinkFailed;
    }

    pub fn finish(self: *VerifySink) registry_http.BodySinkError!void {
        self.verifier.?.finish() catch return error.SinkFailed;
    }
};

pub const ResolvedSource = struct {
    registry: *Source,
    resolved: *const ResolvedRoot,

    pub fn asTransport(self: *ResolvedSource) transport.Source {
        return transport.Source.initWithRegistryIdentity(self, .{
            .origin = self.registry.client.endpoint.canonicalOrigin(),
            .authority = self.registry.authority,
            .repository = self.registry.repository,
            .plain_http = self.registry.plain_http,
        });
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
        if (content_length) |length| {
            if (length == self.size) return;
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
        var saw_rel = false;
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
                if (saw_rel) return error.PaginationFailed;
                saw_rel = true;
                var relations = std.mem.tokenizeAny(u8, value, " \t");
                var relation_count: usize = 0;
                var next_count: usize = 0;
                while (relations.next()) |relation| {
                    relation_count += 1;
                    if (std.ascii.eqlIgnoreCase(relation, "next")) next_count += 1;
                }
                if (relation_count == 0 or next_count > 1) {
                    return error.PaginationFailed;
                }
                is_next = next_count == 1;
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

fn validateDestinationConfiguration(
    destination: reference.RegistryReference,
    options: DestinationOptions,
) Error![]const u8 {
    const tag = switch (destination.selection orelse
        return error.TagRequired) {
        .tag => |value| value,
        .digest => return error.TagRequired,
    };
    if (!validTag(tag, options.limits.max_tag_length)) {
        return error.InvalidReference;
    }
    try options.limits.validate();
    options.auth_limits.validate() catch return error.InvalidConfiguration;
    options.http_limits.validate() catch return error.InvalidConfiguration;
    options.timeouts.validate() catch return error.InvalidConfiguration;
    if (options.graph_limits.max_depth == 0 or
        options.graph_limits.max_nodes == 0 or
        options.graph_limits.max_total_bytes == 0 or
        options.graph_limits.max_metadata_bytes == 0)
    {
        return error.InvalidConfiguration;
    }
    if (options.upload_chunk_bytes) |value| {
        if (value == 0) return error.InvalidConfiguration;
    }
    if (options.spool_directory) |path| {
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) {
            return error.InvalidConfiguration;
        }
    }
    return tag;
}

fn percentEncodeQueryAlloc(
    allocator: Allocator,
    value: []const u8,
) Allocator.Error![]u8 {
    var required: usize = 0;
    for (value) |byte| {
        const amount: usize = if (std.ascii.isAlphanumeric(byte) or
            byte == '-' or byte == '.' or byte == '_' or byte == '~')
            1
        else
            3;
        required = std.math.add(usize, required, amount) catch
            return error.OutOfMemory;
    }
    const output = try allocator.alloc(u8, required);
    var index: usize = 0;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or
            byte == '_' or byte == '~')
        {
            output[index] = byte;
            index += 1;
        } else {
            output[index] = '%';
            const encoded = std.fmt.bytesToHex([_]u8{byte}, .upper);
            output[index + 1] = encoded[0];
            output[index + 2] = encoded[1];
            index += 3;
        }
    }
    return output;
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
