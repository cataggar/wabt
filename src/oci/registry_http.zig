//! Bounded HTTP(S) transport policy for OCI Distribution clients.
//!
//! This module owns endpoint, origin, redirect, deadline, retry, and
//! authorization-header policy. It deliberately does not implement registry
//! resolve, tag, manifest, or blob semantics.
//! Redirect, retry, and CA-bundle behavior was adapted from cataggar/miz
//! commit 669a27982b376311f558e820b69e9a692735b0cd (MIT).
const std = @import("std");
const auth = @import("auth.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Error = error{
    OutOfMemory,
    InvalidLimits,
    InvalidEndpoint,
    InvalidRequest,
    InsecureTransport,
    UnsupportedScheme,
    CertificateAuthorityLoadFailed,
    RedirectRejected,
    RedirectLoop,
    RedirectLimitExceeded,
    DeadlineExceeded,
    RetryLimitExceeded,
    LimitExceeded,
    AuthenticationFailed,
    TransportFailed,
    TlsValidationFailed,
    ProtocolError,
    ContentEncodingRejected,
    BodySinkFailed,
};

pub const Limits = struct {
    max_response_header_bytes: usize = 64 * 1024,
    max_metadata_body_bytes: usize = 16 * 1024 * 1024,
    max_error_body_bytes: usize = 64 * 1024,
    max_location_bytes: usize = 16 * 1024,
    max_additional_ca_bytes: usize = 1024 * 1024,
    max_request_headers: usize = 64,
    max_redirects: u16 = 5,
    max_attempts: u16 = 3,
    max_retry_delay_ns: u64 = 60 * std.time.ns_per_s,
    base_retry_delay_ns: u64 = 100 * std.time.ns_per_ms,

    pub fn validate(self: Limits) Error!void {
        if (self.max_response_header_bytes == 0 or
            self.max_metadata_body_bytes == 0 or
            self.max_error_body_bytes == 0 or
            self.max_location_bytes == 0 or
            self.max_additional_ca_bytes == 0 or
            self.max_request_headers == 0 or
            self.max_request_headers > max_request_headers_absolute or
            self.max_attempts == 0 or
            self.max_retry_delay_ns == 0 or
            self.base_retry_delay_ns == 0 or
            self.base_retry_delay_ns > self.max_retry_delay_ns)
        {
            return error.InvalidLimits;
        }
    }
};

pub const Timeouts = struct {
    per_attempt_ns: u64 = 30 * std.time.ns_per_s,
    body_idle_ns: u64 = 30 * std.time.ns_per_s,

    pub fn validate(self: Timeouts) Error!void {
        if (self.per_attempt_ns == 0 or self.body_idle_ns == 0) {
            return error.InvalidLimits;
        }
    }
};

pub const AdditionalCa = union(enum) {
    file_path: []const u8,
    pem_data: []const u8,
};

pub const EndpointOptions = struct {
    authority: []const u8,
    plain_http: bool = false,
    additional_ca: ?AdditionalCa = null,
};

pub const Scheme = enum {
    http,
    https,

    fn text(self: Scheme) []const u8 {
        return @tagName(self);
    }

    fn defaultPort(self: Scheme) u16 {
        return switch (self) {
            .http => 80,
            .https => 443,
        };
    }
};

pub const Origin = struct {
    allocator: Allocator,
    scheme: Scheme,
    host: []u8,
    port: u16,
    ipv6: bool,
    canonical: []u8,

    pub fn deinit(self: *Origin) void {
        self.allocator.free(self.host);
        self.allocator.free(self.canonical);
        self.* = undefined;
    }

    pub fn clone(self: Origin, allocator: Allocator) Error!Origin {
        const host = try allocator.dupe(u8, self.host);
        errdefer allocator.free(host);
        return .{
            .allocator = allocator,
            .scheme = self.scheme,
            .host = host,
            .port = self.port,
            .ipv6 = self.ipv6,
            .canonical = try allocator.dupe(u8, self.canonical),
        };
    }

    pub fn eql(left: Origin, right: Origin) bool {
        return left.scheme == right.scheme and
            left.port == right.port and
            std.mem.eql(u8, left.host, right.host);
    }

    pub fn format(self: Origin, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll(self.canonical);
    }
};

const OwnedAdditionalCa = union(enum) {
    file_path: []u8,
    pem_data: []u8,

    fn deinit(self: *OwnedAdditionalCa, allocator: Allocator) void {
        switch (self.*) {
            .file_path => |value| allocator.free(value),
            .pem_data => |value| allocator.free(value),
        }
        self.* = undefined;
    }
};

/// Immutable after initialization. Every client owns its own copies of the
/// authority, normalized origin, and optional CA material.
pub const Endpoint = struct {
    allocator: Allocator,
    authority: []u8,
    origin: Origin,
    allow_loopback_http: bool,
    additional_ca: ?OwnedAdditionalCa,

    pub fn init(
        allocator: Allocator,
        options: EndpointOptions,
        limits: Limits,
    ) Error!Endpoint {
        try limits.validate();
        if (options.authority.len == 0 or
            containsUnsafeUriByte(options.authority) or
            !hasValidPercentEncoding(options.authority))
        {
            return error.InvalidEndpoint;
        }

        const scheme: Scheme = if (options.plain_http) .http else .https;
        const url = try std.fmt.allocPrint(
            allocator,
            "{s}://{s}/",
            .{ scheme.text(), options.authority },
        );
        defer allocator.free(url);

        var origin = try parseOrigin(allocator, url);
        errdefer origin.deinit();
        if (origin.scheme != scheme) return error.InvalidEndpoint;
        const uri = std.Uri.parse(url) catch return error.InvalidEndpoint;
        if (uri.user != null or uri.password != null or uri.fragment != null or
            uri.query != null or !componentEquals(uri.path, "/"))
        {
            return error.InvalidEndpoint;
        }
        if (scheme == .http and !isLoopbackOrigin(origin)) {
            return error.InsecureTransport;
        }

        const authority = try allocator.dupe(u8, options.authority);
        errdefer allocator.free(authority);
        var additional_ca: ?OwnedAdditionalCa = null;
        errdefer if (additional_ca) |*value| value.deinit(allocator);
        if (options.additional_ca) |value| {
            additional_ca = switch (value) {
                .file_path => |path| blk: {
                    if (path.len == 0 or path.len > limits.max_additional_ca_bytes or
                        containsControl(path))
                    {
                        return error.CertificateAuthorityLoadFailed;
                    }
                    break :blk .{ .file_path = try allocator.dupe(u8, path) };
                },
                .pem_data => |data| blk: {
                    if (data.len == 0 or data.len > limits.max_additional_ca_bytes) {
                        return error.CertificateAuthorityLoadFailed;
                    }
                    break :blk .{ .pem_data = try allocator.dupe(u8, data) };
                },
            };
        }

        return .{
            .allocator = allocator,
            .authority = authority,
            .origin = origin,
            .allow_loopback_http = options.plain_http,
            .additional_ca = additional_ca,
        };
    }

    pub fn deinit(self: *Endpoint) void {
        self.allocator.free(self.authority);
        self.origin.deinit();
        if (self.additional_ca) |*value| value.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn urlAlloc(self: Endpoint, path_and_query: []const u8) Error![]u8 {
        if (path_and_query.len == 0 or path_and_query[0] != '/' or
            containsUnsafeUriByte(path_and_query) or
            !hasValidPercentEncoding(path_and_query) or
            std.mem.indexOfScalar(u8, path_and_query, '#') != null)
        {
            return error.InvalidRequest;
        }
        return std.fmt.allocPrint(
            self.allocator,
            "{s}://{s}{s}",
            .{ self.origin.scheme.text(), self.authority, path_and_query },
        ) catch error.OutOfMemory;
    }

    pub fn canonicalOrigin(self: Endpoint) []const u8 {
        return self.origin.canonical;
    }

    pub fn additionalCa(self: Endpoint) ?AdditionalCa {
        const value = self.additional_ca orelse return null;
        return switch (value) {
            .file_path => |path| .{ .file_path = path },
            .pem_data => |data| .{ .pem_data = data },
        };
    }
};

pub const HeaderSensitivity = enum {
    public,
    secret,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
    sensitivity: HeaderSensitivity = .public,
};

pub const OwnedHeader = struct {
    name: []u8,
    value: []u8,

    fn deinit(self: *OwnedHeader, allocator: Allocator) void {
        allocator.free(self.name);
        @memset(self.value, 0);
        allocator.free(self.value);
        self.* = undefined;
    }
};

pub const Response = struct {
    allocator: Allocator,
    status: u16,
    headers: []OwnedHeader,
    body: []u8,
    origin: ?[]u8 = null,

    pub fn initCopy(
        allocator: Allocator,
        status: u16,
        headers: []const Header,
        body: []const u8,
    ) Error!Response {
        const owned_headers = try allocator.alloc(OwnedHeader, headers.len);
        var initialized: usize = 0;
        errdefer {
            for (owned_headers[0..initialized]) |*owned_header| owned_header.deinit(allocator);
            allocator.free(owned_headers);
        }
        for (headers, 0..) |source_header, index| {
            const name = try allocator.dupe(u8, source_header.name);
            errdefer allocator.free(name);
            const value = try allocator.dupe(u8, source_header.value);
            owned_headers[index] = .{ .name = name, .value = value };
            initialized += 1;
        }
        return .{
            .allocator = allocator,
            .status = status,
            .headers = owned_headers,
            .body = try allocator.dupe(u8, body),
        };
    }

    pub fn deinit(self: *Response) void {
        for (self.headers) |*owned_header| owned_header.deinit(self.allocator);
        self.allocator.free(self.headers);
        @memset(self.body, 0);
        self.allocator.free(self.body);
        if (self.origin) |value| self.allocator.free(value);
        self.* = undefined;
    }

    pub fn header(self: Response, name: []const u8) ?[]const u8 {
        for (self.headers) |item| {
            if (std.ascii.eqlIgnoreCase(item.name, name)) return item.value;
        }
        return null;
    }
};

pub const RequestClass = enum {
    registry,
    token,
    blob,
};

pub const BodySinkError = error{SinkFailed};

/// A retry-aware streaming response destination. Backends call `begin`
/// before every successful response body attempt, so implementations can
/// discard a partial prior attempt before accepting replayed bytes.
pub const BodySink = struct {
    context: *anyopaque,
    begin_fn: *const fn (*anyopaque, ?u64) BodySinkError!void,
    write_fn: *const fn (*anyopaque, []const u8) BodySinkError!void,
    finish_fn: *const fn (*anyopaque) BodySinkError!void,

    pub fn init(pointer: anytype) BodySink {
        const Pointer = @TypeOf(pointer);
        const Adapter = struct {
            fn begin(context: *anyopaque, content_length: ?u64) BodySinkError!void {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                return implementation.begin(content_length);
            }

            fn write(context: *anyopaque, bytes: []const u8) BodySinkError!void {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                return implementation.write(bytes);
            }

            fn finish(context: *anyopaque) BodySinkError!void {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                return implementation.finish();
            }
        };
        return .{
            .context = pointer,
            .begin_fn = Adapter.begin,
            .write_fn = Adapter.write,
            .finish_fn = Adapter.finish,
        };
    }

    pub fn begin(self: BodySink, content_length: ?u64) BodySinkError!void {
        return self.begin_fn(self.context, content_length);
    }

    pub fn write(self: BodySink, bytes: []const u8) BodySinkError!void {
        return self.write_fn(self.context, bytes);
    }

    pub fn finish(self: BodySink) BodySinkError!void {
        return self.finish_fn(self.context);
    }
};

pub const BackendCapabilities = struct {
    absolute_deadline: bool = false,
    dns_timeout: bool = false,
    connect_timeout: bool = false,
    tls_handshake_timeout: bool = false,
    write_timeout: bool = false,
    response_head_timeout: bool = false,
    body_idle_timeout: bool = false,
};

pub const BackendRequest = struct {
    method: std.http.Method,
    url: []const u8,
    class: RequestClass,
    headers: []const Header,
    authorization: ?[]const u8,
    response_header_limit: usize,
    body_limit: u64,
    error_body_limit: usize = 64 * 1024,
    body_sink: ?BodySink = null,
    absolute_deadline_ns: i128,
    attempt_timeout_ns: u64,
    body_idle_timeout_ns: u64,

    pub fn format(self: BackendRequest, writer: *Io.Writer) Io.Writer.Error!void {
        const uri = std.Uri.parse(self.url) catch {
            try writer.writeAll("http-request(<invalid-url>)");
            return;
        };
        const origin = originTextNoAlloc(uri) orelse "<invalid-origin>";
        try writer.print(
            "http-request(method={s}, class={s}, origin={s}, authorization={s})",
            .{
                @tagName(self.method),
                @tagName(self.class),
                origin,
                if (self.authorization == null) "none" else "<redacted>",
            },
        );
    }
};

pub const BackendError = error{
    OutOfMemory,
    DnsFailure,
    ConnectionRefused,
    ConnectionReset,
    NetworkUnreachable,
    TlsFailure,
    ReadFailed,
    WriteFailed,
    Timeout,
    HeaderLimitExceeded,
    BodyLimitExceeded,
    BodySinkFailed,
    TransportFailure,
    ProtocolFailure,
};

pub const Backend = struct {
    context: *anyopaque,
    request_fn: *const fn (*anyopaque, Allocator, BackendRequest) BackendError!Response,
    capabilities: BackendCapabilities,

    pub fn init(pointer: anytype, capabilities: BackendCapabilities) Backend {
        const Pointer = @TypeOf(pointer);
        const Adapter = struct {
            fn request(
                context: *anyopaque,
                allocator: Allocator,
                options: BackendRequest,
            ) BackendError!Response {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                return implementation.request(allocator, options);
            }
        };
        return .{
            .context = pointer,
            .request_fn = Adapter.request,
            .capabilities = capabilities,
        };
    }

    pub fn request(
        self: Backend,
        allocator: Allocator,
        options: BackendRequest,
    ) BackendError!Response {
        return self.request_fn(self.context, allocator, options);
    }
};

pub const Clock = struct {
    context: *anyopaque,
    now_fn: *const fn (*anyopaque) i128,
    unix_seconds_fn: ?*const fn (*anyopaque) i64 = null,

    pub fn init(pointer: anytype) Clock {
        const Pointer = @TypeOf(pointer);
        const Adapter = struct {
            fn now(context: *anyopaque) i128 {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                return implementation.now();
            }
        };
        return .{ .context = pointer, .now_fn = Adapter.now };
    }

    pub fn initWithUnixSeconds(pointer: anytype) Clock {
        const Pointer = @TypeOf(pointer);
        const Adapter = struct {
            fn now(context: *anyopaque) i128 {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                return implementation.now();
            }

            fn unixSeconds(context: *anyopaque) i64 {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                return implementation.unixSeconds();
            }
        };
        return .{
            .context = pointer,
            .now_fn = Adapter.now,
            .unix_seconds_fn = Adapter.unixSeconds,
        };
    }

    pub fn now(self: Clock) i128 {
        return self.now_fn(self.context);
    }

    pub fn unixSeconds(self: Clock) ?i64 {
        const unix_seconds_fn = self.unix_seconds_fn orelse return null;
        return unix_seconds_fn(self.context);
    }
};

pub const SleepError = error{SleepFailed};

pub const Sleeper = struct {
    context: *anyopaque,
    sleep_fn: *const fn (*anyopaque, u64) SleepError!void,

    pub fn init(pointer: anytype) Sleeper {
        const Pointer = @TypeOf(pointer);
        const Adapter = struct {
            fn sleep(context: *anyopaque, duration_ns: u64) SleepError!void {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                return implementation.sleep(duration_ns);
            }
        };
        return .{ .context = pointer, .sleep_fn = Adapter.sleep };
    }

    pub fn sleep(self: Sleeper, duration_ns: u64) SleepError!void {
        return self.sleep_fn(self.context, duration_ns);
    }
};

pub const SystemRuntime = struct {
    io: Io,

    pub fn clock(self: *SystemRuntime) Clock {
        return Clock.initWithUnixSeconds(self);
    }

    pub fn sleeper(self: *SystemRuntime) Sleeper {
        return Sleeper.init(self);
    }

    pub fn now(self: *SystemRuntime) i128 {
        return Io.Clock.awake.now(self.io).toNanoseconds();
    }

    pub fn unixSeconds(self: *SystemRuntime) i64 {
        return Io.Clock.real.now(self.io).toSeconds();
    }

    pub fn sleep(self: *SystemRuntime, duration_ns: u64) SleepError!void {
        Io.sleep(
            self.io,
            .fromNanoseconds(@intCast(duration_ns)),
            .awake,
        ) catch return error.SleepFailed;
    }
};

pub const Deadline = struct {
    at_ns: i128,

    pub fn after(clock: Clock, duration_ns: u64) Deadline {
        return .{
            .at_ns = std.math.add(i128, clock.now(), duration_ns) catch
                std.math.maxInt(i128),
        };
    }
};

pub const AuthorizationConfig = union(enum) {
    none,
    basic: auth.BasicCredential,
    bearer: []const u8,
};

pub const TokenAcquisitionRequest = struct {
    key: auth.TokenCacheKey,
    absolute_deadline_ns: i128,
};

/// Injected boundary for the next increment's token-service HTTP exchange.
/// Implementations receive the same absolute operation deadline used by the
/// registry request; this module never discovers credentials or performs a
/// token-service request on its own.
pub const TokenAcquirer = struct {
    context: ?*anyopaque = null,
    acquire: *const fn (
        context: ?*anyopaque,
        allocator: Allocator,
        request: TokenAcquisitionRequest,
    ) auth.TokenAcquisitionError!auth.Token,
};

pub const ClientOptions = struct {
    endpoint: EndpointOptions,
    limits: Limits = .{},
    timeouts: Timeouts = .{},
    authorization: AuthorizationConfig = .none,
    token_acquirer: ?TokenAcquirer = null,
    auth_limits: auth.Limits = .{},
    auth_context_id: u64 = 0,
    credential_generation: u64 = 0,
};

pub const RequestOptions = struct {
    method: std.http.Method = .GET,
    path_and_query: []const u8,
    class: RequestClass = .registry,
    headers: []const Header = &.{},
    max_body_bytes: ?u64 = null,
    body_sink: ?BodySink = null,
    /// Authentication challenge handling can replay a request. Mutating
    /// registry operations disable it and surface 401 instead.
    allow_auth_replay: bool = true,
    deadline: Deadline,
};

pub const DiagnosticCategory = enum {
    insecure_transport,
    redirect,
    deadline,
    retry_limit,
    limit,
    authentication,
    tls,
    transport,
    protocol,
};

pub const Diagnostic = struct {
    category: DiagnosticCategory,
    request_class: RequestClass,
    status: ?u16 = null,
    origin_buffer: [diagnostic_origin_capacity]u8 = undefined,
    origin_len: usize = 0,

    fn init(
        category: DiagnosticCategory,
        request_class: RequestClass,
        status: ?u16,
        origin_text: []const u8,
    ) Diagnostic {
        var result: Diagnostic = .{
            .category = category,
            .request_class = request_class,
            .status = status,
        };
        result.origin_len = @min(origin_text.len, result.origin_buffer.len);
        @memcpy(
            result.origin_buffer[0..result.origin_len],
            origin_text[0..result.origin_len],
        );
        return result;
    }

    pub fn origin(self: *const Diagnostic) []const u8 {
        return self.origin_buffer[0..self.origin_len];
    }

    pub fn format(self: Diagnostic, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print(
            "registry-http(category={s}, class={s}, origin={s}",
            .{ @tagName(self.category), @tagName(self.request_class), self.origin() },
        );
        if (self.status) |status| try writer.print(", status={d}", .{status});
        try writer.writeByte(')');
    }
};

pub const Client = struct {
    allocator: Allocator,
    endpoint: Endpoint,
    backend: Backend,
    clock: Clock,
    sleeper: Sleeper,
    limits: Limits,
    timeouts: Timeouts,
    auth_limits: auth.Limits,
    token_acquirer: ?TokenAcquirer,
    token_cache: auth.TokenCache,
    auth_context_id: u64,
    credential_generation: u64,
    base_authorization: ?auth.Authorization = null,
    last_diagnostic: ?Diagnostic = null,

    pub fn init(
        allocator: Allocator,
        backend: Backend,
        clock: Clock,
        sleeper: Sleeper,
        options: ClientOptions,
    ) Error!Client {
        try options.limits.validate();
        try options.timeouts.validate();
        options.auth_limits.validate() catch return error.InvalidLimits;

        var endpoint = try Endpoint.init(allocator, options.endpoint, options.limits);
        errdefer endpoint.deinit();
        var token_cache = auth.TokenCache.init(allocator, options.auth_limits) catch |err|
            return mapAuthError(err);
        errdefer token_cache.deinit();

        var base_authorization: ?auth.Authorization = null;
        errdefer if (base_authorization) |*value| value.deinit(allocator);
        switch (options.authorization) {
            .none => {},
            .basic => |credential| blk: {
                base_authorization = auth.basicAuthorizationAlloc(
                    allocator,
                    credential,
                    options.auth_limits,
                ) catch |err| return mapAuthError(err);
                break :blk;
            },
            .bearer => |token| blk: {
                base_authorization = auth.bearerAuthorizationAlloc(
                    allocator,
                    token,
                    options.auth_limits,
                ) catch |err| return mapAuthError(err);
                break :blk;
            },
        }

        return .{
            .allocator = allocator,
            .endpoint = endpoint,
            .backend = backend,
            .clock = clock,
            .sleeper = sleeper,
            .limits = options.limits,
            .timeouts = options.timeouts,
            .auth_limits = options.auth_limits,
            .token_acquirer = options.token_acquirer,
            .token_cache = token_cache,
            .auth_context_id = options.auth_context_id,
            .credential_generation = options.credential_generation,
            .base_authorization = base_authorization,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.base_authorization) |*value| value.deinit(self.allocator);
        self.token_cache.deinit();
        self.endpoint.deinit();
        self.* = undefined;
    }

    pub fn backendCapabilities(self: Client) BackendCapabilities {
        return self.backend.capabilities;
    }

    pub fn lastDiagnostic(self: *const Client) ?*const Diagnostic {
        return if (self.last_diagnostic) |*value| value else null;
    }

    pub fn execute(self: *Client, options: RequestOptions) Error!Response {
        self.last_diagnostic = null;
        if (options.headers.len > self.limits.max_request_headers or
            options.headers.len > max_request_headers_absolute)
        {
            return self.fail(error.LimitExceeded, .limit, options.class, null, self.endpoint.origin.canonical);
        }
        for (options.headers) |header| {
            if (!validHeader(header) or isReservedRequestHeader(header.name)) {
                return self.fail(error.InvalidRequest, .protocol, options.class, null, self.endpoint.origin.canonical);
            }
        }
        if (!isSupportedMethod(options.method)) {
            return self.fail(error.InvalidRequest, .protocol, options.class, null, self.endpoint.origin.canonical);
        }
        const body_limit = options.max_body_bytes orelse self.limits.max_metadata_body_bytes;
        if ((body_limit == 0 and options.method != .HEAD and options.body_sink == null) or
            (options.body_sink == null and body_limit > self.limits.max_metadata_body_bytes))
        {
            return self.fail(error.LimitExceeded, .limit, options.class, null, self.endpoint.origin.canonical);
        }
        try self.checkDeadline(options.deadline, options.class, self.endpoint.origin.canonical);

        var current_url = try self.endpoint.urlAlloc(options.path_and_query);
        defer self.allocator.free(current_url);
        var current_origin = try self.endpoint.origin.clone(self.allocator);
        defer current_origin.deinit();

        var visited = std.array_list.Managed([32]u8).init(self.allocator);
        defer visited.deinit();
        try visited.append(hashUrl(current_url));

        var redirects: u16 = 0;
        var retry_attempts: u16 = 0;
        var authorization_stripped = false;
        var bearer_attempts: u8 = 0;
        var dynamic_authorization: ?auth.Authorization = null;
        defer if (dynamic_authorization) |*value| value.deinit(self.allocator);

        while (true) {
            try self.checkDeadline(options.deadline, options.class, current_origin.canonical);
            const remaining = remainingNs(self.clock, options.deadline) orelse
                return self.fail(error.DeadlineExceeded, .deadline, options.class, null, current_origin.canonical);
            const attempt_timeout = @min(remaining, self.timeouts.per_attempt_ns);
            const body_idle_timeout = @min(remaining, self.timeouts.body_idle_ns);

            var effective_headers: [max_request_headers_absolute]Header = undefined;
            var effective_count: usize = 0;
            for (options.headers) |header| {
                if (authorization_stripped and headerIsSecret(header)) continue;
                effective_headers[effective_count] = header;
                effective_count += 1;
            }
            const authorization: ?[]const u8 = if (authorization_stripped)
                null
            else if (dynamic_authorization) |value|
                value.bytes
            else if (self.base_authorization) |value|
                value.bytes
            else
                null;

            var response = self.backend.request(self.allocator, .{
                .method = options.method,
                .url = current_url,
                .class = options.class,
                .headers = effective_headers[0..effective_count],
                .authorization = authorization,
                .response_header_limit = self.limits.max_response_header_bytes,
                .body_limit = body_limit,
                .error_body_limit = self.limits.max_error_body_bytes,
                .body_sink = options.body_sink,
                .absolute_deadline_ns = options.deadline.at_ns,
                .attempt_timeout_ns = attempt_timeout,
                .body_idle_timeout_ns = body_idle_timeout,
            }) catch |err| {
                if (self.clock.now() >= options.deadline.at_ns) {
                    return self.fail(error.DeadlineExceeded, .deadline, options.class, null, current_origin.canonical);
                }
                if (isRetryableBackendError(err) and isReplaySafe(options.method)) {
                    if (retry_attempts + 1 >= self.limits.max_attempts) {
                        return self.fail(error.RetryLimitExceeded, .retry_limit, options.class, null, current_origin.canonical);
                    }
                    try self.sleepBeforeRetry(
                        retryDelay(self.limits, retry_attempts),
                        options.deadline,
                        options.class,
                        current_origin.canonical,
                    );
                    retry_attempts += 1;
                    continue;
                }
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.TlsFailure => self.fail(error.TlsValidationFailed, .tls, options.class, null, current_origin.canonical),
                    error.Timeout => self.fail(error.DeadlineExceeded, .deadline, options.class, null, current_origin.canonical),
                    error.HeaderLimitExceeded, error.BodyLimitExceeded => self.fail(error.LimitExceeded, .limit, options.class, null, current_origin.canonical),
                    error.BodySinkFailed => self.fail(error.BodySinkFailed, .protocol, options.class, null, current_origin.canonical),
                    error.ProtocolFailure => self.fail(error.ProtocolError, .protocol, options.class, null, current_origin.canonical),
                    error.DnsFailure,
                    error.ConnectionRefused,
                    error.ConnectionReset,
                    error.NetworkUnreachable,
                    error.ReadFailed,
                    error.WriteFailed,
                    error.TransportFailure,
                    => self.fail(error.TransportFailed, .transport, options.class, null, current_origin.canonical),
                };
            };

            if (self.clock.now() >= options.deadline.at_ns) {
                response.deinit();
                return self.fail(error.DeadlineExceeded, .deadline, options.class, null, current_origin.canonical);
            }
            validateResponseLimits(
                response,
                self.limits.max_response_header_bytes,
                if (response.status >= 200 and response.status < 300)
                    body_limit
                else
                    @as(u64, @intCast(self.limits.max_error_body_bytes)),
            ) catch |err| {
                response.deinit();
                return self.fail(err, .limit, options.class, null, current_origin.canonical);
            };
            validateIdentityContentEncoding(response) catch |err| {
                response.deinit();
                return self.fail(err, .protocol, options.class, response.status, current_origin.canonical);
            };

            if (isRedirectStatus(response.status)) {
                const redirect_status = response.status;
                if (!isReplaySafe(options.method)) {
                    response.deinit();
                    return self.fail(error.RedirectRejected, .redirect, options.class, redirect_status, current_origin.canonical);
                }
                const location = singleHeader(response, "Location") catch {
                    response.deinit();
                    return self.fail(error.RedirectRejected, .redirect, options.class, redirect_status, current_origin.canonical);
                } orelse {
                    response.deinit();
                    return self.fail(error.RedirectRejected, .redirect, options.class, redirect_status, current_origin.canonical);
                };
                if (location.len == 0 or location.len > self.limits.max_location_bytes or
                    containsUnsafeUriByte(location) or
                    !hasValidPercentEncoding(location))
                {
                    response.deinit();
                    return self.fail(error.RedirectRejected, .redirect, options.class, redirect_status, current_origin.canonical);
                }
                if (redirects >= self.limits.max_redirects) {
                    response.deinit();
                    return self.fail(error.RedirectLimitExceeded, .redirect, options.class, redirect_status, current_origin.canonical);
                }

                const next_url = resolveRedirectAlloc(
                    self.allocator,
                    current_url,
                    location,
                    self.limits.max_location_bytes,
                ) catch |err| {
                    response.deinit();
                    return switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => self.fail(error.RedirectRejected, .redirect, options.class, redirect_status, current_origin.canonical),
                    };
                };
                var next_origin = parseOrigin(self.allocator, next_url) catch |err| {
                    self.allocator.free(next_url);
                    response.deinit();
                    return switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => self.fail(error.RedirectRejected, .redirect, options.class, redirect_status, current_origin.canonical),
                    };
                };
                const policy_result = validateHopPolicy(
                    self.endpoint.allow_loopback_http,
                    current_origin,
                    next_origin,
                    options.class,
                );
                if (policy_result) |_| {} else |err| {
                    const category: DiagnosticCategory = if (err == error.InsecureTransport)
                        .insecure_transport
                    else
                        .redirect;
                    next_origin.deinit();
                    self.allocator.free(next_url);
                    response.deinit();
                    return self.fail(err, category, options.class, redirect_status, current_origin.canonical);
                }

                const next_hash = hashUrl(next_url);
                for (visited.items) |prior| {
                    if (std.mem.eql(u8, &prior, &next_hash)) {
                        next_origin.deinit();
                        self.allocator.free(next_url);
                        response.deinit();
                        return self.fail(error.RedirectLoop, .redirect, options.class, redirect_status, current_origin.canonical);
                    }
                }
                visited.append(next_hash) catch {
                    next_origin.deinit();
                    self.allocator.free(next_url);
                    response.deinit();
                    return error.OutOfMemory;
                };

                const same_origin = current_origin.eql(next_origin);
                if (!same_origin) {
                    authorization_stripped = true;
                    if (dynamic_authorization) |*value| value.deinit(self.allocator);
                    dynamic_authorization = null;
                }
                response.deinit();
                self.allocator.free(current_url);
                current_url = next_url;
                current_origin.deinit();
                current_origin = next_origin;
                redirects += 1;
                continue;
            }

            if (isRetryableStatus(response.status) and isReplaySafe(options.method)) {
                if (retry_attempts + 1 >= self.limits.max_attempts) {
                    const status = response.status;
                    response.deinit();
                    return self.fail(error.RetryLimitExceeded, .retry_limit, options.class, status, current_origin.canonical);
                }
                const delay = retryAfterNs(
                    response,
                    self.limits.max_retry_delay_ns,
                    self.clock.unixSeconds(),
                ) orelse
                    retryDelay(self.limits, retry_attempts);
                response.deinit();
                try self.sleepBeforeRetry(
                    delay,
                    options.deadline,
                    options.class,
                    current_origin.canonical,
                );
                retry_attempts += 1;
                continue;
            }

            if (response.status == 401 and options.class != .token) {
                if (authorization_stripped) {
                    response.deinit();
                    return self.fail(error.AuthenticationFailed, .authentication, options.class, 401, current_origin.canonical);
                }
                if (!options.allow_auth_replay) {
                    response.deinit();
                    return self.fail(error.AuthenticationFailed, .authentication, options.class, 401, current_origin.canonical);
                }
                var challenge = parseDistributionChallenge(
                    self.allocator,
                    response,
                    self.auth_limits,
                ) catch |err| {
                    response.deinit();
                    return self.fail(err, .authentication, options.class, 401, current_origin.canonical);
                } orelse {
                    response.deinit();
                    return self.fail(error.AuthenticationFailed, .authentication, options.class, 401, current_origin.canonical);
                };
                response.deinit();
                defer challenge.deinit();

                switch (challenge) {
                    .basic => {
                        // Basic credentials are sent preemptively. Replaying the
                        // identical rejected credential cannot succeed and must
                        // not create an authentication loop.
                        return self.fail(error.AuthenticationFailed, .authentication, options.class, 401, current_origin.canonical);
                    },
                    .bearer => |bearer| {
                        if (bearer_attempts >= 2) {
                            return self.fail(error.AuthenticationFailed, .authentication, options.class, 401, current_origin.canonical);
                        }
                        var realm_origin = parseOrigin(self.allocator, bearer.realm) catch |err| {
                            return switch (err) {
                                error.OutOfMemory => error.OutOfMemory,
                                else => self.fail(error.AuthenticationFailed, .authentication, options.class, 401, current_origin.canonical),
                            };
                        };
                        defer realm_origin.deinit();
                        validateStandalonePolicy(
                            self.endpoint.allow_loopback_http,
                            realm_origin,
                        ) catch |err| {
                            const category: DiagnosticCategory = if (err == error.InsecureTransport)
                                .insecure_transport
                            else
                                .authentication;
                            return self.fail(err, category, options.class, 401, current_origin.canonical);
                        };

                        const acquirer = self.token_acquirer orelse
                            return self.fail(error.AuthenticationFailed, .authentication, options.class, 401, current_origin.canonical);
                        const key: auth.TokenCacheKey = .{
                            .context_id = self.auth_context_id,
                            .registry_origin = self.endpoint.origin.canonical,
                            .realm = bearer.realm,
                            .service = bearer.service,
                            .scopes = bearer.scopes,
                            .credential_generation = self.credential_generation,
                        };
                        if (bearer_attempts != 0) self.token_cache.invalidate(key);
                        const now_seconds = nanosecondsToSecondsSaturated(self.clock.now());
                        const token = self.token_cache.get(now_seconds, key) orelse token: {
                            try self.checkDeadline(
                                options.deadline,
                                options.class,
                                current_origin.canonical,
                            );
                            var acquired = acquirer.acquire(
                                acquirer.context,
                                self.allocator,
                                .{
                                    .key = key,
                                    .absolute_deadline_ns = options.deadline.at_ns,
                                },
                            ) catch |err| {
                                const mapped = mapTokenAcquisitionError(err);
                                return self.fail(
                                    mapped,
                                    if (mapped == error.DeadlineExceeded)
                                        .deadline
                                    else
                                        .authentication,
                                    options.class,
                                    401,
                                    current_origin.canonical,
                                );
                            };
                            defer acquired.deinit(self.allocator);
                            try self.checkDeadline(
                                options.deadline,
                                options.class,
                                current_origin.canonical,
                            );
                            break :token self.token_cache.put(
                                now_seconds,
                                key,
                                acquired,
                                self.auth_limits,
                            ) catch |err| return self.fail(
                                mapAuthError(err),
                                .authentication,
                                options.class,
                                401,
                                current_origin.canonical,
                            );
                        };
                        const next_authorization = auth.bearerAuthorizationAlloc(
                            self.allocator,
                            token,
                            self.auth_limits,
                        ) catch |err| return self.fail(
                            mapAuthError(err),
                            .authentication,
                            options.class,
                            401,
                            current_origin.canonical,
                        );
                        if (dynamic_authorization) |*value| value.deinit(self.allocator);
                        dynamic_authorization = next_authorization;
                        bearer_attempts += 1;
                    },
                }
                continue;
            }

            response.origin = self.allocator.dupe(u8, current_origin.canonical) catch {
                response.deinit();
                return error.OutOfMemory;
            };
            self.last_diagnostic = null;
            return response;
        }
    }

    fn checkDeadline(
        self: *Client,
        deadline: Deadline,
        class: RequestClass,
        origin: []const u8,
    ) Error!void {
        if (self.clock.now() >= deadline.at_ns) {
            return self.fail(error.DeadlineExceeded, .deadline, class, null, origin);
        }
    }

    fn sleepBeforeRetry(
        self: *Client,
        delay_ns: u64,
        deadline: Deadline,
        class: RequestClass,
        origin: []const u8,
    ) Error!void {
        try self.checkDeadline(deadline, class, origin);
        const remaining = remainingNs(self.clock, deadline) orelse
            return self.fail(error.DeadlineExceeded, .deadline, class, null, origin);
        if (delay_ns >= remaining) {
            return self.fail(error.DeadlineExceeded, .deadline, class, null, origin);
        }
        if (delay_ns != 0) self.sleeper.sleep(delay_ns) catch
            return self.fail(error.TransportFailed, .transport, class, null, origin);
        try self.checkDeadline(deadline, class, origin);
    }

    fn fail(
        self: *Client,
        err: Error,
        category: DiagnosticCategory,
        class: RequestClass,
        status: ?u16,
        origin: []const u8,
    ) Error {
        self.last_diagnostic = Diagnostic.init(category, class, status, origin);
        return err;
    }
};

/// Production backend. Zig 0.16's `std.http.Client` validates hostnames and
/// chains against `ca_bundle`; this backend never exposes a verification
/// bypass. The standard client does not expose DNS, connect, TLS-handshake,
/// write, response-head, or body-idle timeout controls through `request`, so
/// all capability fields are deliberately false. The absolute deadline is
/// still checked immediately before and after this backend by `Client`.
pub const StdBackend = struct {
    allocator: Allocator,
    io: Io,
    client: std.http.Client,
    limits: Limits,

    pub const capabilities: BackendCapabilities = .{};

    pub fn init(
        allocator: Allocator,
        io: Io,
        endpoint_options: EndpointOptions,
        limits: Limits,
    ) Error!StdBackend {
        try limits.validate();
        var endpoint = try Endpoint.init(allocator, endpoint_options, limits);
        defer endpoint.deinit();

        var result: StdBackend = .{
            .allocator = allocator,
            .io = io,
            .client = .{
                .allocator = allocator,
                .io = io,
                .read_buffer_size = limits.max_response_header_bytes,
            },
            .limits = limits,
        };
        errdefer result.client.deinit();
        if (endpoint.additional_ca) |additional| {
            try result.loadAdditionalCa(additional);
        }
        return result;
    }

    pub fn deinit(self: *StdBackend) void {
        self.client.deinit();
        self.* = undefined;
    }

    pub fn backend(self: *StdBackend) Backend {
        return Backend.init(self, capabilities);
    }

    pub fn request(
        self: *StdBackend,
        allocator: Allocator,
        options: BackendRequest,
    ) BackendError!Response {
        const uri = std.Uri.parse(options.url) catch return error.ProtocolFailure;
        if (uri.user != null or uri.password != null or uri.fragment != null) {
            return error.ProtocolFailure;
        }

        var extra_headers: [max_request_headers_absolute]std.http.Header = undefined;
        if (options.headers.len > extra_headers.len) return error.HeaderLimitExceeded;
        for (options.headers, 0..) |header, index| {
            extra_headers[index] = .{ .name = header.name, .value = header.value };
        }
        var std_request = self.client.request(options.method, uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .headers = .{
                .authorization = if (options.authorization) |value|
                    .{ .override = value }
                else
                    .omit,
                .accept_encoding = .{ .override = "identity" },
            },
            .extra_headers = extra_headers[0..options.headers.len],
        }) catch |err| return mapStdBackendError(err);
        defer std_request.deinit();
        if (options.method.requestHasBody()) {
            std_request.sendBodyComplete(&.{}) catch |err|
                return mapStdBackendError(err);
        } else {
            std_request.sendBodiless() catch |err| return mapStdBackendError(err);
        }
        var std_response = std_request.receiveHead(&.{}) catch |err|
            return mapStdBackendError(err);

        var headers = std.array_list.Managed(OwnedHeader).init(allocator);
        errdefer {
            for (headers.items) |*header| header.deinit(allocator);
            headers.deinit();
        }
        var header_bytes: usize = 0;
        var iterator = std_response.head.iterateHeaders();
        while (iterator.next()) |header| {
            header_bytes = std.math.add(usize, header_bytes, header.name.len) catch
                return error.HeaderLimitExceeded;
            header_bytes = std.math.add(usize, header_bytes, header.value.len) catch
                return error.HeaderLimitExceeded;
            header_bytes = std.math.add(usize, header_bytes, 4) catch
                return error.HeaderLimitExceeded;
            if (header_bytes > options.response_header_limit) return error.HeaderLimitExceeded;
            const name = allocator.dupe(u8, header.name) catch return error.OutOfMemory;
            errdefer allocator.free(name);
            const value = allocator.dupe(u8, header.value) catch return error.OutOfMemory;
            headers.append(.{ .name = name, .value = value }) catch {
                allocator.free(name);
                allocator.free(value);
                return error.OutOfMemory;
            };
        }

        var body = std.array_list.Managed(u8).init(allocator);
        errdefer body.deinit();
        if (options.method.responseHasBody()) {
            var reader_buffer: [16 * 1024]u8 = undefined;
            var transfer_buffer: [64 * 1024]u8 = undefined;
            const reader = std_response.reader(&reader_buffer);
            const status: u16 = @intFromEnum(std_response.head.status);
            if (status >= 200 and status < 300) {
                if (std_response.head.content_length) |length| {
                    if (length > options.body_limit) return error.BodyLimitExceeded;
                }
                if (options.body_sink) |sink| {
                    sink.begin(std_response.head.content_length) catch
                        return error.BodySinkFailed;
                    var total: u64 = 0;
                    while (true) {
                        const count = reader.readSliceShort(&transfer_buffer) catch
                            return error.ReadFailed;
                        if (count == 0) break;
                        total = std.math.add(u64, total, count) catch
                            return error.BodyLimitExceeded;
                        if (total > options.body_limit) return error.BodyLimitExceeded;
                        sink.write(transfer_buffer[0..count]) catch
                            return error.BodySinkFailed;
                    }
                    sink.finish() catch return error.BodySinkFailed;
                } else {
                    while (true) {
                        const count = reader.readSliceShort(&transfer_buffer) catch
                            return error.ReadFailed;
                        if (count == 0) break;
                        const current: u64 = @intCast(body.items.len);
                        if (@as(u64, count) > options.body_limit -| current) {
                            return error.BodyLimitExceeded;
                        }
                        body.appendSlice(transfer_buffer[0..count]) catch
                            return error.OutOfMemory;
                    }
                }
            } else {
                while (true) {
                    const count = reader.readSliceShort(&transfer_buffer) catch
                        return error.ReadFailed;
                    if (count == 0) break;
                    if (count > options.error_body_limit -| body.items.len) {
                        return error.BodyLimitExceeded;
                    }
                    body.appendSlice(transfer_buffer[0..count]) catch
                        return error.OutOfMemory;
                }
            }
        }
        return .{
            .allocator = allocator,
            .status = @intFromEnum(std_response.head.status),
            .headers = headers.toOwnedSlice() catch return error.OutOfMemory,
            .body = body.toOwnedSlice() catch return error.OutOfMemory,
        };
    }

    fn loadAdditionalCa(
        self: *StdBackend,
        additional: OwnedAdditionalCa,
    ) Error!void {
        if (comptime std.http.Client.disable_tls) {
            return error.CertificateAuthorityLoadFailed;
        }
        const now = Io.Clock.real.now(self.io);
        self.client.ca_bundle.rescan(self.allocator, self.io, now) catch
            return error.CertificateAuthorityLoadFailed;
        const count_before = self.client.ca_bundle.map.count();
        switch (additional) {
            .file_path => |path| {
                var file = if (std.fs.path.isAbsolute(path))
                    Io.Dir.openFileAbsolute(self.io, path, .{}) catch
                        return error.CertificateAuthorityLoadFailed
                else
                    Io.Dir.cwd().openFile(self.io, path, .{}) catch
                        return error.CertificateAuthorityLoadFailed;
                defer file.close(self.io);
                const size = file.length(self.io) catch
                    return error.CertificateAuthorityLoadFailed;
                if (size == 0 or size > self.limits.max_additional_ca_bytes) {
                    return error.CertificateAuthorityLoadFailed;
                }
                var reader = file.reader(self.io, &.{});
                self.client.ca_bundle.addCertsFromFile(
                    self.allocator,
                    &reader,
                    now.toSeconds(),
                ) catch return error.CertificateAuthorityLoadFailed;
            },
            .pem_data => |data| appendCaPemData(
                &self.client.ca_bundle,
                self.allocator,
                data,
                now.toSeconds(),
            ) catch return error.CertificateAuthorityLoadFailed,
        }
        if (self.client.ca_bundle.map.count() <= count_before) {
            return error.CertificateAuthorityLoadFailed;
        }
        self.client.now = now;
    }
};

fn parseOrigin(allocator: Allocator, url: []const u8) Error!Origin {
    if (url.len == 0 or
        containsUnsafeUriByte(url) or
        !hasValidPercentEncoding(url))
    {
        return error.InvalidEndpoint;
    }
    const uri = std.Uri.parse(url) catch return error.InvalidEndpoint;
    const scheme: Scheme = if (std.ascii.eqlIgnoreCase(uri.scheme, "https"))
        .https
    else if (std.ascii.eqlIgnoreCase(uri.scheme, "http"))
        .http
    else
        return error.UnsupportedScheme;
    if (uri.host == null or uri.user != null or uri.password != null or uri.fragment != null) {
        return error.InvalidEndpoint;
    }
    if (componentContainsPercent(uri.host.?)) return error.InvalidEndpoint;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const raw_host = (uri.getHost(&host_buffer) catch return error.InvalidEndpoint).bytes;
    const normalized = try normalizeHostAlloc(allocator, raw_host);
    errdefer allocator.free(normalized.host);
    const port = uri.port orelse scheme.defaultPort();
    if (port == 0) return error.InvalidEndpoint;
    const canonical = (if (normalized.ipv6)
        std.fmt.allocPrint(
            allocator,
            "{s}://[{s}]:{d}",
            .{ scheme.text(), normalized.host, port },
        )
    else
        std.fmt.allocPrint(
            allocator,
            "{s}://{s}:{d}",
            .{ scheme.text(), normalized.host, port },
        )) catch return error.OutOfMemory;
    return .{
        .allocator = allocator,
        .scheme = scheme,
        .host = normalized.host,
        .port = port,
        .ipv6 = normalized.ipv6,
        .canonical = canonical,
    };
}

const NormalizedHost = struct {
    host: []u8,
    ipv6: bool,
};

fn normalizeHostAlloc(allocator: Allocator, raw_host: []const u8) Error!NormalizedHost {
    if (raw_host.len == 0 or raw_host.len > std.Io.net.HostName.max_len or
        containsControl(raw_host))
    {
        return error.InvalidEndpoint;
    }
    if (raw_host[0] == '[') {
        if (raw_host.len < 3 or raw_host[raw_host.len - 1] != ']') {
            return error.InvalidEndpoint;
        }
        const parsed = std.Io.net.IpAddress.parseIp6(raw_host[1 .. raw_host.len - 1], 0) catch
            return error.InvalidEndpoint;
        const ip6 = parsed.ip6;
        const formatted = std.fmt.allocPrint(allocator, "{f}", .{ip6}) catch
            return error.OutOfMemory;
        defer allocator.free(formatted);
        if (formatted.len < 4 or formatted[0] != '[' or
            !std.mem.endsWith(u8, formatted, "]:0"))
        {
            return error.InvalidEndpoint;
        }
        return .{
            .host = try allocator.dupe(u8, formatted[1 .. formatted.len - 3]),
            .ipv6 = true,
        };
    }
    if (std.mem.indexOfScalar(u8, raw_host, ':') != null or
        std.mem.indexOfAny(u8, raw_host, "[]%") != null)
    {
        return error.InvalidEndpoint;
    }
    if (std.Io.net.IpAddress.parseIp4(raw_host, 0)) |parsed| {
        const bytes = parsed.ip4.bytes;
        return .{
            .host = std.fmt.allocPrint(
                allocator,
                "{d}.{d}.{d}.{d}",
                .{ bytes[0], bytes[1], bytes[2], bytes[3] },
            ) catch return error.OutOfMemory,
            .ipv6 = false,
        };
    } else |_| {}

    if (raw_host.len > 253 or raw_host[0] == '.' or raw_host[raw_host.len - 1] == '.') {
        return error.InvalidEndpoint;
    }
    const host = try allocator.alloc(u8, raw_host.len);
    errdefer allocator.free(host);
    for (raw_host, 0..) |byte, index| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '.') {
            return error.InvalidEndpoint;
        }
        host[index] = std.ascii.toLower(byte);
    }
    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or
            label[label.len - 1] == '-')
        {
            return error.InvalidEndpoint;
        }
    }
    return .{ .host = host, .ipv6 = false };
}

fn isLoopbackOrigin(origin: Origin) bool {
    if (std.mem.eql(u8, origin.host, "localhost")) return true;
    if (origin.ipv6) {
        const parsed = std.Io.net.IpAddress.parseIp6(origin.host, 0) catch return false;
        return std.mem.eql(
            u8,
            &parsed.ip6.bytes,
            &std.Io.net.Ip6Address.loopback(0).bytes,
        );
    }
    const parsed = std.Io.net.IpAddress.parseIp4(origin.host, 0) catch return false;
    return parsed.ip4.bytes[0] == 127;
}

fn validateStandalonePolicy(allow_loopback_http: bool, origin: Origin) Error!void {
    if (origin.scheme == .http and
        (!allow_loopback_http or !isLoopbackOrigin(origin)))
    {
        return error.InsecureTransport;
    }
}

fn validateHopPolicy(
    allow_loopback_http: bool,
    current: Origin,
    next: Origin,
    class: RequestClass,
) Error!void {
    if (current.scheme == .https and next.scheme == .http) {
        return error.RedirectRejected;
    }
    try validateStandalonePolicy(allow_loopback_http, next);
    if (!current.eql(next) and class != .blob) return error.RedirectRejected;
}

fn resolveRedirectAlloc(
    allocator: Allocator,
    current_url: []const u8,
    location: []const u8,
    max_result_bytes: usize,
) Error![]u8 {
    const base = std.Uri.parse(current_url) catch return error.RedirectRejected;
    const twice_location = std.math.mul(usize, location.len, 2) catch
        return error.RedirectRejected;
    const capacity = std.math.add(usize, current_url.len, twice_location + 16) catch
        return error.RedirectRejected;
    const buffer = try allocator.alloc(u8, capacity);
    defer allocator.free(buffer);
    @memcpy(buffer[0..location.len], location);
    var available = buffer;
    const resolved = base.resolveInPlace(location.len, &available) catch
        return error.RedirectRejected;
    if (resolved.user != null or resolved.password != null or resolved.fragment != null or
        resolved.host == null)
    {
        return error.RedirectRejected;
    }
    if (!std.ascii.eqlIgnoreCase(resolved.scheme, "http") and
        !std.ascii.eqlIgnoreCase(resolved.scheme, "https"))
    {
        return error.UnsupportedScheme;
    }
    var output = Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    resolved.format(&output.writer) catch return error.OutOfMemory;
    const result = output.toOwnedSlice() catch return error.OutOfMemory;
    if (result.len > max_result_bytes) {
        allocator.free(result);
        return error.RedirectRejected;
    }
    return result;
}

/// Resolves an RFC Link target against an endpoint-relative request and
/// returns another endpoint-relative target only when the normalized origin
/// is unchanged. The returned value never contains userinfo or a fragment.
pub fn resolveSameOriginPathAlloc(
    allocator: Allocator,
    endpoint: Endpoint,
    current_path_and_query: []const u8,
    location: []const u8,
    max_result_bytes: usize,
) Error![]u8 {
    if (max_result_bytes == 0 or location.len == 0 or
        location.len > max_result_bytes or containsUnsafeUriByte(location) or
        !hasValidPercentEncoding(location))
    {
        return error.RedirectRejected;
    }
    const current_url = try endpoint.urlAlloc(current_path_and_query);
    defer endpoint.allocator.free(current_url);
    const absolute_limit = std.math.add(
        usize,
        max_result_bytes,
        current_url.len,
    ) catch return error.RedirectRejected;
    const resolved_url = try resolveRedirectAlloc(
        allocator,
        current_url,
        location,
        absolute_limit,
    );
    defer allocator.free(resolved_url);
    var resolved_origin = try parseOrigin(allocator, resolved_url);
    defer resolved_origin.deinit();
    if (!endpoint.origin.eql(resolved_origin)) return error.RedirectRejected;

    const scheme_end = std.mem.indexOf(u8, resolved_url, "://") orelse
        return error.RedirectRejected;
    const authority_start = scheme_end + 3;
    const suffix_index = std.mem.indexOfAnyPos(
        u8,
        resolved_url,
        authority_start,
        "/?",
    ) orelse return allocator.dupe(u8, "/") catch error.OutOfMemory;
    const suffix = resolved_url[suffix_index..];
    if (suffix[0] == '/') {
        if (suffix.len > max_result_bytes) return error.RedirectRejected;
        return allocator.dupe(u8, suffix) catch error.OutOfMemory;
    }
    if (suffix.len + 1 > max_result_bytes) return error.RedirectRejected;
    return std.fmt.allocPrint(allocator, "/{s}", .{suffix}) catch error.OutOfMemory;
}

/// Owned, validated upload-session location. The URL may retain an opaque
/// provider-signed query; formatting deliberately exposes only the origin.
pub const ResolvedUploadLocation = struct {
    allocator: Allocator,
    url: []u8,
    origin: Origin,
    authorization_stripped: bool,

    pub fn deinit(self: *ResolvedUploadLocation) void {
        self.allocator.free(self.url);
        self.origin.deinit();
        self.* = undefined;
    }

    pub fn format(
        self: ResolvedUploadLocation,
        writer: *Io.Writer,
    ) Io.Writer.Error!void {
        try writer.print(
            "upload-location(origin={s}, authorization={s})",
            .{
                self.origin.canonical,
                if (self.authorization_stripped) "stripped" else "destination",
            },
        );
    }
};

/// Resolves one Distribution upload Location without following it. Absolute
/// locations preserve their exact query bytes. Userinfo, fragments, HTTPS
/// downgrade, and cross-origin cleartext locations are rejected.
pub fn resolveUploadLocationAlloc(
    allocator: Allocator,
    endpoint: Endpoint,
    current_path_and_query: []const u8,
    location: []const u8,
    max_result_bytes: usize,
) Error!ResolvedUploadLocation {
    if (max_result_bytes == 0 or location.len == 0 or
        location.len > max_result_bytes or containsUnsafeUriByte(location) or
        !hasValidPercentEncoding(location))
    {
        return error.RedirectRejected;
    }

    const current_url = try endpoint.urlAlloc(current_path_and_query);
    defer endpoint.allocator.free(current_url);
    const absolute = hasUriScheme(location);
    const url = if (absolute)
        try duplicateAbsoluteLocationAlloc(allocator, location)
    else
        try resolveRedirectAlloc(
            allocator,
            current_url,
            location,
            std.math.add(usize, current_url.len, max_result_bytes) catch
                return error.RedirectRejected,
        );
    errdefer allocator.free(url);
    if (url.len > max_result_bytes and absolute) return error.RedirectRejected;

    var origin = try parseOrigin(allocator, url);
    errdefer origin.deinit();
    const same_origin = endpoint.origin.eql(origin);
    if (endpoint.origin.scheme == .https and origin.scheme == .http) {
        return error.RedirectRejected;
    }
    if (!same_origin and origin.scheme != .https) {
        return error.RedirectRejected;
    }
    return .{
        .allocator = allocator,
        .url = url,
        .origin = origin,
        .authorization_stripped = !same_origin,
    };
}

fn duplicateAbsoluteLocationAlloc(
    allocator: Allocator,
    location: []const u8,
) Error![]u8 {
    const uri = std.Uri.parse(location) catch return error.RedirectRejected;
    if (uri.host == null or uri.user != null or uri.password != null or
        uri.fragment != null or
        (!std.ascii.eqlIgnoreCase(uri.scheme, "https") and
            !std.ascii.eqlIgnoreCase(uri.scheme, "http")))
    {
        return error.RedirectRejected;
    }
    return allocator.dupe(u8, location) catch error.OutOfMemory;
}

fn hasUriScheme(value: []const u8) bool {
    if (value.len == 0 or !std.ascii.isAlphabetic(value[0])) return false;
    for (value[1..]) |byte| {
        if (byte == ':') return true;
        if (!std.ascii.isAlphanumeric(byte) and byte != '+' and
            byte != '-' and byte != '.')
        {
            return false;
        }
    }
    return false;
}

fn parseDistributionChallenge(
    allocator: Allocator,
    response: Response,
    limits: auth.Limits,
) Error!?auth.DistributionChallenge {
    var values = std.array_list.Managed([]const u8).init(allocator);
    defer values.deinit();
    for (response.headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "WWW-Authenticate")) continue;
        if (values.items.len >= limits.max_challenges) {
            return error.AuthenticationFailed;
        }
        values.append(header.value) catch return error.OutOfMemory;
    }
    if (values.items.len == 0) return null;
    var parsed = auth.parseChallenges(allocator, values.items, limits) catch |err|
        return mapAuthError(err);
    defer parsed.deinit();
    return auth.selectDistributionChallenge(allocator, parsed) catch |err|
        return mapAuthError(err);
}

fn mapAuthError(err: auth.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.AuthenticationFailed,
    };
}

fn mapTokenAcquisitionError(err: auth.TokenAcquisitionError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DeadlineExceeded => error.DeadlineExceeded,
        error.AuthenticationFailed, error.InvalidResponse => error.AuthenticationFailed,
    };
}

fn validateResponseLimits(
    response: Response,
    header_limit: usize,
    body_limit: u64,
) Error!void {
    var total: usize = 0;
    for (response.headers) |header| {
        total = std.math.add(usize, total, header.name.len) catch
            return error.LimitExceeded;
        total = std.math.add(usize, total, header.value.len) catch
            return error.LimitExceeded;
        total = std.math.add(usize, total, 4) catch
            return error.LimitExceeded;
        if (total > header_limit) return error.LimitExceeded;
    }
    if (@as(u64, @intCast(response.body.len)) > body_limit) {
        return error.LimitExceeded;
    }
}

fn validateIdentityContentEncoding(response: Response) Error!void {
    var value: ?[]const u8 = null;
    for (response.headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "Content-Encoding")) continue;
        if (value != null) return error.ContentEncodingRejected;
        value = header.value;
    }
    const encoding = std.mem.trim(u8, value orelse return, " \t");
    if (!std.ascii.eqlIgnoreCase(encoding, "identity")) {
        return error.ContentEncodingRejected;
    }
}

fn singleHeader(response: Response, name: []const u8) Error!?[]const u8 {
    var value: ?[]const u8 = null;
    for (response.headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, name)) continue;
        if (value != null) return error.ProtocolError;
        value = header.value;
    }
    return value;
}

fn isRedirectStatus(status: u16) bool {
    return switch (status) {
        301, 302, 303, 307, 308 => true,
        else => false,
    };
}

pub fn isRetryableStatus(status: u16) bool {
    return switch (status) {
        408, 429, 500, 502, 503, 504 => true,
        else => false,
    };
}

pub fn isRetryableBackendError(err: BackendError) bool {
    return switch (err) {
        error.DnsFailure => false,
        error.ConnectionRefused,
        error.ConnectionReset,
        error.NetworkUnreachable,
        error.ReadFailed,
        error.WriteFailed,
        error.Timeout,
        => true,
        error.OutOfMemory,
        error.TlsFailure,
        error.HeaderLimitExceeded,
        error.BodyLimitExceeded,
        error.BodySinkFailed,
        error.TransportFailure,
        error.ProtocolFailure,
        => false,
    };
}

fn isReplaySafe(method: std.http.Method) bool {
    return method == .GET or method == .HEAD;
}

fn isSupportedMethod(method: std.http.Method) bool {
    return switch (method) {
        .GET, .HEAD, .POST, .PUT, .PATCH, .DELETE => true,
        else => false,
    };
}

fn retryDelay(limits: Limits, retry_index: u16) u64 {
    const shift: u6 = @intCast(@min(retry_index, 63));
    const multiplier = @as(u64, 1) << shift;
    return @min(
        std.math.mul(u64, limits.base_retry_delay_ns, multiplier) catch
            limits.max_retry_delay_ns,
        limits.max_retry_delay_ns,
    );
}

fn retryAfterNs(response: Response, maximum: u64, unix_seconds: ?i64) ?u64 {
    var header_value: ?[]const u8 = null;
    for (response.headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "Retry-After")) continue;
        if (header_value != null) return null;
        header_value = header.value;
    }
    const value = header_value orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t");
    const seconds = std.fmt.parseInt(u64, trimmed, 10) catch seconds: {
        const now = unix_seconds orelse return null;
        const retry_at = parseHttpDate(trimmed) orelse return null;
        break :seconds if (retry_at <= now) 0 else @as(u64, @intCast(retry_at - now));
    };
    return @min(
        std.math.mul(u64, seconds, std.time.ns_per_s) catch maximum,
        maximum,
    );
}

/// Parses the IMF-fixdate form required for HTTP dates. Obsolete date formats
/// are ignored and deterministic exponential backoff is used instead.
fn parseHttpDate(value: []const u8) ?i64 {
    if (value.len != 29 or value[3] != ',' or value[4] != ' ' or
        value[7] != ' ' or value[11] != ' ' or value[16] != ' ' or
        value[19] != ':' or value[22] != ':' or value[25] != ' ' or
        !validWeekday(value[0..3]) or
        !std.mem.eql(u8, value[26..], "GMT"))
    {
        return null;
    }
    const day = parseTwoDigits(value[5..7]) orelse return null;
    const month = monthNumber(value[8..11]) orelse return null;
    for (value[12..16]) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    const year = std.fmt.parseInt(i64, value[12..16], 10) catch return null;
    const hour = parseTwoDigits(value[17..19]) orelse return null;
    const minute = parseTwoDigits(value[20..22]) orelse return null;
    const second = parseTwoDigits(value[23..25]) orelse return null;
    if (day == 0 or day > daysInMonth(year, month) or
        hour > 23 or minute > 59 or second > 59)
    {
        return null;
    }
    const days = daysFromCivil(year, month, day);
    return days * 86_400 +
        @as(i64, hour) * 3600 +
        @as(i64, minute) * 60 +
        second;
}

fn validWeekday(value: []const u8) bool {
    const names = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
    for (names) |name| {
        if (std.mem.eql(u8, value, name)) return true;
    }
    return false;
}

fn parseTwoDigits(value: []const u8) ?u8 {
    if (value.len != 2 or
        !std.ascii.isDigit(value[0]) or
        !std.ascii.isDigit(value[1]))
    {
        return null;
    }
    return (value[0] - '0') * 10 + (value[1] - '0');
}

fn monthNumber(value: []const u8) ?u8 {
    const names = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    for (names, 1..) |name, index| {
        if (std.mem.eql(u8, value, name)) return @intCast(index);
    }
    return null;
}

fn daysInMonth(year: i64, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: i64) bool {
    return @mod(year, 4) == 0 and
        (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn daysFromCivil(year_input: i64, month_input: u8, day: u8) i64 {
    var year = year_input;
    const month: i64 = month_input;
    year -= @intFromBool(month <= 2);
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const adjusted_month: i64 = if (month > 2) -3 else 9;
    const day_of_year = @divFloor(
        153 * (month + adjusted_month) + 2,
        5,
    ) + @as(i64, day) - 1;
    const day_of_era = year_of_era * 365 +
        @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) +
        day_of_year;
    return era * 146097 + day_of_era - 719468;
}

fn remainingNs(clock: Clock, deadline: Deadline) ?u64 {
    const now = clock.now();
    if (now >= deadline.at_ns) return null;
    return @intCast(@min(
        deadline.at_ns - now,
        @as(i128, std.math.maxInt(u64)),
    ));
}

fn nanosecondsToSecondsSaturated(value: i128) i64 {
    const seconds = @divTrunc(value, std.time.ns_per_s);
    return @intCast(std.math.clamp(
        seconds,
        @as(i128, std.math.minInt(i64)),
        @as(i128, std.math.maxInt(i64)),
    ));
}

fn validHeader(header: Header) bool {
    if (header.name.len == 0 or containsControl(header.name) or
        containsControl(header.value) or std.mem.indexOfScalar(u8, header.name, ':') != null)
    {
        return false;
    }
    for (header.name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') {
            return false;
        }
    }
    return true;
}

fn isReservedRequestHeader(name: []const u8) bool {
    const reserved = [_][]const u8{
        "Authorization",
        "Proxy-Authorization",
        "Host",
        "Connection",
        "Keep-Alive",
        "Proxy-Connection",
        "Proxy-Authenticate",
        "Accept-Encoding",
        "Content-Length",
        "Expect",
        "TE",
        "Transfer-Encoding",
        "Trailer",
        "Upgrade",
    };
    for (reserved) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    return false;
}

fn headerIsSecret(header: Header) bool {
    return header.sensitivity == .secret or
        isAuthorizationHeader(header.name) or
        std.ascii.eqlIgnoreCase(header.name, "Proxy-Authorization") or
        std.ascii.eqlIgnoreCase(header.name, "Cookie");
}

fn isAuthorizationHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "Authorization");
}

fn containsControl(value: []const u8) bool {
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) return true;
    }
    return false;
}

fn containsUnsafeUriByte(value: []const u8) bool {
    for (value) |byte| {
        if (byte <= 0x20 or byte >= 0x7f) return true;
    }
    return false;
}

fn hasValidPercentEncoding(value: []const u8) bool {
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        if (value[index] != '%') continue;
        if (value.len - index < 3 or
            !std.ascii.isHex(value[index + 1]) or
            !std.ascii.isHex(value[index + 2]))
        {
            return false;
        }
        index += 2;
    }
    return true;
}

fn componentContainsPercent(component: std.Uri.Component) bool {
    return switch (component) {
        .raw, .percent_encoded => |value| std.mem.indexOfScalar(u8, value, '%') != null,
    };
}

fn componentEquals(component: std.Uri.Component, expected: []const u8) bool {
    return switch (component) {
        .raw, .percent_encoded => |value| std.mem.eql(u8, value, expected),
    };
}

fn hashUrl(url: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &result, .{});
    return result;
}

fn originTextNoAlloc(uri: std.Uri) ?[]const u8 {
    const host = uri.host orelse return null;
    return switch (host) {
        .raw, .percent_encoded => |value| value,
    };
}

fn mapStdBackendError(err: anyerror) BackendError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ConnectionRefused => error.ConnectionRefused,
        error.ConnectionResetByPeer, error.BrokenPipe => error.ConnectionReset,
        error.HostUnreachable, error.NetworkUnreachable => error.NetworkUnreachable,
        error.UnknownHostName,
        error.ResolvConfParseFailed,
        error.InvalidDnsARecord,
        error.InvalidDnsAAAARecord,
        error.InvalidDnsCnameRecord,
        error.NameServerFailure,
        error.NoAddressReturned,
        error.DetectingNetworkConfigurationFailed,
        => error.DnsFailure,
        error.TlsInitializationFailed, error.CertificateBundleLoadFailure => error.TlsFailure,
        error.ReadFailed, error.EndOfStream, error.HttpChunkTruncated => error.ReadFailed,
        error.WriteFailed => error.WriteFailed,
        error.Timeout, error.Canceled => error.Timeout,
        error.HttpHeadersOversize => error.HeaderLimitExceeded,
        error.UnsupportedUriScheme,
        error.UriMissingHost,
        error.HttpHeadersInvalid,
        error.HttpRedirectLocationInvalid,
        error.HttpContentEncodingUnsupported,
        error.HttpChunkInvalid,
        => error.ProtocolFailure,
        else => error.TransportFailure,
    };
}

fn appendCaPemData(
    bundle: *std.crypto.Certificate.Bundle,
    allocator: Allocator,
    data: []const u8,
    now_seconds: i64,
) !void {
    const begin_marker = "-----BEGIN CERTIFICATE-----";
    const end_marker = "-----END CERTIFICATE-----";
    const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
    var position: usize = 0;
    var found = false;
    while (std.mem.indexOfPos(u8, data, position, begin_marker)) |begin| {
        const encoded_start = begin + begin_marker.len;
        const encoded_end = std.mem.indexOfPos(
            u8,
            data,
            encoded_start,
            end_marker,
        ) orelse return error.InvalidCertificate;
        position = encoded_end + end_marker.len;
        const encoded = std.mem.trim(u8, data[encoded_start..encoded_end], " \t\r\n");
        const decoded = try allocator.alloc(
            u8,
            decoder.calcSizeUpperBound(encoded.len),
        );
        defer allocator.free(decoded);
        const decoded_len = decoder.decode(decoded, encoded) catch
            return error.InvalidCertificate;
        const decoded_start: u32 = std.math.cast(u32, bundle.bytes.items.len) orelse
            return error.CertificateAuthorityBundleTooBig;
        try bundle.bytes.appendSlice(allocator, decoded[0..decoded_len]);
        bundle.parseCert(allocator, decoded_start, now_seconds) catch
            return error.InvalidCertificate;
        found = true;
    }
    if (!found) return error.InvalidCertificate;
}

const diagnostic_origin_capacity = 320;
const max_request_headers_absolute = 64;

test {
    std.testing.refAllDecls(@This());
}

const FakeRuntime = struct {
    now_ns: i128 = 0,
    unix_epoch_seconds: i64 = 0,
    sleeps: [16]u64 = @splat(0),
    sleep_count: usize = 0,
    fail_sleep: bool = false,
    sleep_extra_ns: u64 = 0,

    fn clock(self: *FakeRuntime) Clock {
        return Clock.initWithUnixSeconds(self);
    }

    fn sleeper(self: *FakeRuntime) Sleeper {
        return Sleeper.init(self);
    }

    fn now(self: *FakeRuntime) i128 {
        return self.now_ns;
    }

    fn unixSeconds(self: *FakeRuntime) i64 {
        return std.math.add(
            i64,
            self.unix_epoch_seconds,
            nanosecondsToSecondsSaturated(self.now_ns),
        ) catch if (self.now_ns < 0)
            std.math.minInt(i64)
        else
            std.math.maxInt(i64);
    }

    fn sleep(self: *FakeRuntime, duration_ns: u64) SleepError!void {
        if (self.fail_sleep) return error.SleepFailed;
        self.sleeps[self.sleep_count] = duration_ns;
        self.sleep_count += 1;
        self.now_ns += duration_ns + self.sleep_extra_ns;
    }
};

const FakeResponse = struct {
    status: u16,
    headers: []const Header = &.{},
    body: []const u8 = "",
};

const FakeOutcome = union(enum) {
    response: FakeResponse,
    failure: BackendError,
};

const FakeStep = struct {
    outcome: FakeOutcome,
    advance_ns: u64 = 0,
};

const FakeBackend = struct {
    runtime: *FakeRuntime,
    steps: []const FakeStep,
    index: usize = 0,
    urls: [32][1024]u8 = undefined,
    url_lengths: [32]usize = @splat(0),
    authorizations: [32][512]u8 = undefined,
    authorization_lengths: [32]usize = @splat(0),
    secret_header_seen: [32]bool = @splat(false),
    attempt_timeouts: [32]u64 = @splat(0),

    fn boundary(self: *FakeBackend) Backend {
        return Backend.init(self, .{
            .absolute_deadline = true,
            .dns_timeout = true,
            .connect_timeout = true,
            .tls_handshake_timeout = true,
            .write_timeout = true,
            .response_head_timeout = true,
            .body_idle_timeout = true,
        });
    }

    fn request(
        self: *FakeBackend,
        allocator: Allocator,
        request_options: BackendRequest,
    ) BackendError!Response {
        const current = self.index;
        if (current >= self.steps.len) return error.ProtocolFailure;
        if (request_options.url.len > self.urls[current].len) return error.ProtocolFailure;
        @memcpy(self.urls[current][0..request_options.url.len], request_options.url);
        self.url_lengths[current] = request_options.url.len;
        if (request_options.authorization) |value| {
            if (value.len > self.authorizations[current].len) return error.ProtocolFailure;
            @memcpy(self.authorizations[current][0..value.len], value);
            self.authorization_lengths[current] = value.len;
        }
        for (request_options.headers) |header| {
            if (headerIsSecret(header)) self.secret_header_seen[current] = true;
        }
        self.attempt_timeouts[current] = request_options.attempt_timeout_ns;
        self.index += 1;
        self.runtime.now_ns += self.steps[current].advance_ns;
        return switch (self.steps[current].outcome) {
            .failure => |err| err,
            .response => |response| response: {
                if (request_options.body_sink) |sink| {
                    if (response.status >= 200 and response.status < 300) {
                        if (response.body.len > request_options.body_limit) {
                            return error.BodyLimitExceeded;
                        }
                        sink.begin(response.body.len) catch return error.BodySinkFailed;
                        sink.write(response.body) catch return error.BodySinkFailed;
                        sink.finish() catch return error.BodySinkFailed;
                        break :response Response.initCopy(
                            allocator,
                            response.status,
                            response.headers,
                            "",
                        ) catch error.OutOfMemory;
                    }
                }
                break :response Response.initCopy(
                    allocator,
                    response.status,
                    response.headers,
                    response.body,
                ) catch error.OutOfMemory;
            },
        };
    }

    fn url(self: *const FakeBackend, index: usize) []const u8 {
        return self.urls[index][0..self.url_lengths[index]];
    }

    fn authorization(self: *const FakeBackend, index: usize) ?[]const u8 {
        const length = self.authorization_lengths[index];
        return if (length == 0) null else self.authorizations[index][0..length];
    }
};

fn initFakeClient(
    allocator: Allocator,
    fake: *FakeBackend,
    runtime: *FakeRuntime,
    options: ClientOptions,
) Error!Client {
    return Client.init(
        allocator,
        fake.boundary(),
        runtime.clock(),
        runtime.sleeper(),
        options,
    );
}

test "HTTPS is the default and additional CA configuration is owned" {
    var runtime: FakeRuntime = .{};
    const steps = [_]FakeStep{
        .{ .outcome = .{ .response = .{ .status = 200 } } },
    };
    var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
    var ca_data = [_]u8{ 'p', 'e', 'm' };
    var client = try initFakeClient(
        std.testing.allocator,
        &fake,
        &runtime,
        .{
            .endpoint = .{
                .authority = "Registry.Example:443",
                .additional_ca = .{ .pem_data = &ca_data },
            },
        },
    );
    defer client.deinit();
    ca_data[0] = 'X';

    var response = try client.execute(.{
        .path_and_query = "/v2/",
        .deadline = .after(runtime.clock(), std.time.ns_per_s),
    });
    defer response.deinit();
    try std.testing.expectEqualStrings("https://Registry.Example:443/v2/", fake.url(0));
    try std.testing.expectEqualStrings(
        "https://registry.example:443",
        client.endpoint.canonicalOrigin(),
    );
    try std.testing.expectEqualStrings(
        "pem",
        client.endpoint.additionalCa().?.pem_data,
    );
    try std.testing.expect(!@hasField(EndpointOptions, "insecure_skip_verify"));
    try std.testing.expect(!@hasField(EndpointOptions, "skip_verify"));
}

test "plain HTTP accepts every loopback form and rejects all other hosts" {
    const accepted = [_][]const u8{
        "localhost",
        "LOCALHOST:5000",
        "127.0.0.1",
        "127.1.2.3:80",
        "127.255.255.254:65535",
        "[::1]",
        "[0:0:0:0:0:0:0:1]:5000",
    };
    for (accepted) |authority| {
        var endpoint = try Endpoint.init(
            std.testing.allocator,
            .{ .authority = authority, .plain_http = true },
            .{},
        );
        endpoint.deinit();
    }

    const rejected = [_][]const u8{
        "example.com",
        "0.0.0.0",
        "126.255.255.255",
        "128.0.0.1",
        "[::]",
        "[::2]",
        "[::ffff:127.0.0.1]",
    };
    for (rejected) |authority| {
        try std.testing.expectError(
            error.InsecureTransport,
            Endpoint.init(
                std.testing.allocator,
                .{ .authority = authority, .plain_http = true },
                .{},
            ),
        );
    }

    const disguised = [_][]const u8{
        "127.0.0.01",
        "127.1",
        "localhost.example",
    };
    for (disguised) |authority| {
        try std.testing.expectError(
            error.InsecureTransport,
            Endpoint.init(
                std.testing.allocator,
                .{ .authority = authority, .plain_http = true },
                .{},
            ),
        );
    }

    const malformed = [_][]const u8{
        "local%68ost",
        "[::1%25lo]",
        "user@localhost",
        "localhost?query",
        "localhost#fragment",
        "http://localhost",
    };
    for (malformed) |authority| {
        try std.testing.expectError(
            error.InvalidEndpoint,
            Endpoint.init(
                std.testing.allocator,
                .{ .authority = authority, .plain_http = true },
                .{},
            ),
        );
    }
}

test "origin normalization includes scheme normalized host and effective port" {
    var first = try parseOrigin(std.testing.allocator, "HTTPS://EXAMPLE.com/path");
    defer first.deinit();
    var second = try parseOrigin(std.testing.allocator, "https://example.COM:443/other");
    defer second.deinit();
    var third = try parseOrigin(std.testing.allocator, "https://example.com:444/");
    defer third.deinit();
    var ip6_a = try parseOrigin(std.testing.allocator, "http://[::1]/");
    defer ip6_a.deinit();
    var ip6_b = try parseOrigin(std.testing.allocator, "http://[0:0:0:0:0:0:0:1]:80/");
    defer ip6_b.deinit();

    try std.testing.expect(first.eql(second));
    try std.testing.expect(!first.eql(third));
    try std.testing.expect(ip6_a.eql(ip6_b));
    try std.testing.expectEqualStrings("https://example.com:443", first.canonical);
    try std.testing.expectEqualStrings("http://[::1]:80", ip6_a.canonical);
}

test "request targets and managed headers reject ambiguous wire syntax" {
    var runtime: FakeRuntime = .{};
    const steps = [_]FakeStep{};
    var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
    var client = try initFakeClient(
        std.testing.allocator,
        &fake,
        &runtime,
        .{ .endpoint = .{ .authority = "registry.example" } },
    );
    defer client.deinit();

    const invalid_targets = [_][]const u8{
        "/v2/a b",
        "/v2/%",
        "/v2/%0",
        "/v2/%zz",
        "/v2/\x7f",
    };
    for (invalid_targets) |target| {
        try std.testing.expectError(
            error.InvalidRequest,
            client.execute(.{
                .path_and_query = target,
                .deadline = .after(runtime.clock(), std.time.ns_per_s),
            }),
        );
    }

    const reserved_headers = [_][]const u8{
        "Authorization",
        "Proxy-Authorization",
        "Host",
        "Connection",
        "Keep-Alive",
        "Accept-Encoding",
        "Content-Length",
        "TE",
        "Transfer-Encoding",
    };
    for (reserved_headers) |name| {
        try std.testing.expectError(
            error.InvalidRequest,
            client.execute(.{
                .path_and_query = "/v2/",
                .headers = &.{.{ .name = name, .value = "ambiguous" }},
                .deadline = .after(runtime.clock(), std.time.ns_per_s),
            }),
        );
    }
    try std.testing.expectEqual(@as(usize, 0), fake.index);
}

test "same-origin redirects retain authorization and cross-origin blob redirects strip secrets" {
    const secret_header = Header{
        .name = "X-Registry-Secret",
        .value = "secondary-secret",
        .sensitivity = .secret,
    };
    {
        var runtime: FakeRuntime = .{};
        const steps = [_]FakeStep{
            .{ .outcome = .{ .response = .{
                .status = 302,
                .headers = &.{.{ .name = "Location", .value = "/v2/next" }},
            } } },
            .{ .outcome = .{ .response = .{ .status = 200 } } },
        };
        var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
        var client = try initFakeClient(
            std.testing.allocator,
            &fake,
            &runtime,
            .{
                .endpoint = .{ .authority = "registry.example" },
                .authorization = .{ .bearer = "same-origin-token" },
            },
        );
        defer client.deinit();
        var response = try client.execute(.{
            .path_and_query = "/v2/start",
            .class = .blob,
            .headers = &.{secret_header},
            .deadline = .after(runtime.clock(), std.time.ns_per_s),
        });
        defer response.deinit();
        try std.testing.expectEqualStrings(
            "Bearer same-origin-token",
            fake.authorization(1).?,
        );
        try std.testing.expect(fake.secret_header_seen[1]);
    }

    {
        var runtime: FakeRuntime = .{};
        const steps = [_]FakeStep{
            .{ .outcome = .{ .response = .{
                .status = 307,
                .headers = &.{.{ .name = "Location", .value = "https://cdn.example/blob?sig=private" }},
            } } },
            .{ .outcome = .{ .response = .{ .status = 200 } } },
        };
        var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
        var client = try initFakeClient(
            std.testing.allocator,
            &fake,
            &runtime,
            .{
                .endpoint = .{ .authority = "registry.example" },
                .authorization = .{ .bearer = "cross-origin-token" },
            },
        );
        defer client.deinit();
        var response = try client.execute(.{
            .path_and_query = "/v2/start",
            .class = .blob,
            .headers = &.{secret_header},
            .deadline = .after(runtime.clock(), std.time.ns_per_s),
        });
        defer response.deinit();
        try std.testing.expect(fake.authorization(1) == null);
        try std.testing.expect(!fake.secret_header_seen[1]);
        try std.testing.expectEqualStrings(
            "https://cdn.example:443",
            response.origin.?,
        );
    }
}

test "redirects reject downgrade cross-origin registry userinfo fragments and unsupported schemes" {
    const locations = [_][]const u8{
        "http://localhost/clear",
        "https://other.example/v2/",
        "https://user:password@registry.example/v2/",
        "https://registry.example/v2/#fragment",
        "https://registry.example/v2/a b",
        "https://registry.example/v2/%zz",
        "file:///etc/passwd",
    };
    for (locations) |location| {
        var runtime: FakeRuntime = .{};
        const steps = [_]FakeStep{
            .{ .outcome = .{ .response = .{
                .status = 302,
                .headers = &.{.{ .name = "Location", .value = location }},
            } } },
        };
        var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
        var client = try initFakeClient(
            std.testing.allocator,
            &fake,
            &runtime,
            .{ .endpoint = .{ .authority = "registry.example" } },
        );
        defer client.deinit();
        try std.testing.expectError(
            error.RedirectRejected,
            client.execute(.{
                .path_and_query = "/v2/start",
                .deadline = .after(runtime.clock(), std.time.ns_per_s),
            }),
        );
    }
}

test "relative redirects resolve dot segments without changing signed query bytes" {
    var runtime: FakeRuntime = .{};
    const steps = [_]FakeStep{
        .{ .outcome = .{ .response = .{
            .status = 302,
            .headers = &.{.{ .name = "Location", .value = "../blobs/value?sig=a%2Fb&x=1" }},
        } } },
        .{ .outcome = .{ .response = .{ .status = 200 } } },
    };
    var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
    var client = try initFakeClient(
        std.testing.allocator,
        &fake,
        &runtime,
        .{ .endpoint = .{ .authority = "registry.example" } },
    );
    defer client.deinit();
    var response = try client.execute(.{
        .path_and_query = "/v2/repo/manifests/latest",
        .deadline = .after(runtime.clock(), std.time.ns_per_s),
    });
    defer response.deinit();
    try std.testing.expectEqualStrings(
        "https://registry.example/v2/repo/blobs/value?sig=a%2Fb&x=1",
        fake.url(1),
    );
}

test "relative redirect resolution cannot grow beyond the location bound" {
    var runtime: FakeRuntime = .{};
    const steps = [_]FakeStep{
        .{ .outcome = .{ .response = .{
            .status = 302,
            .headers = &.{.{
                .name = "Location",
                .value = "/0123456789012345678901234567890123456789",
            }},
        } } },
    };
    var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
    var client = try initFakeClient(
        std.testing.allocator,
        &fake,
        &runtime,
        .{
            .endpoint = .{ .authority = "registry.example" },
            .limits = .{ .max_location_bytes = 48 },
        },
    );
    defer client.deinit();
    try std.testing.expectError(
        error.RedirectRejected,
        client.execute(.{
            .path_and_query = "/v2/start",
            .deadline = .after(runtime.clock(), std.time.ns_per_s),
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.index);
}

test "endpoint transport policy is rerun for every cleartext redirect hop" {
    var runtime: FakeRuntime = .{};
    const steps = [_]FakeStep{
        .{ .outcome = .{ .response = .{
            .status = 302,
            .headers = &.{.{ .name = "Location", .value = "http://example.com/v2/" }},
        } } },
    };
    var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
    var client = try initFakeClient(
        std.testing.allocator,
        &fake,
        &runtime,
        .{ .endpoint = .{ .authority = "127.0.0.1:5000", .plain_http = true } },
    );
    defer client.deinit();
    try std.testing.expectError(
        error.InsecureTransport,
        client.execute(.{
            .path_and_query = "/v2/",
            .class = .blob,
            .deadline = .after(runtime.clock(), std.time.ns_per_s),
        }),
    );
}

test "redirect loops and redirect limits are distinct" {
    {
        var runtime: FakeRuntime = .{};
        const steps = [_]FakeStep{
            .{ .outcome = .{ .response = .{
                .status = 302,
                .headers = &.{.{ .name = "Location", .value = "/b" }},
            } } },
            .{ .outcome = .{ .response = .{
                .status = 302,
                .headers = &.{.{ .name = "Location", .value = "/a" }},
            } } },
        };
        var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
        var client = try initFakeClient(
            std.testing.allocator,
            &fake,
            &runtime,
            .{ .endpoint = .{ .authority = "registry.example" } },
        );
        defer client.deinit();
        try std.testing.expectError(
            error.RedirectLoop,
            client.execute(.{
                .path_and_query = "/a",
                .deadline = .after(runtime.clock(), std.time.ns_per_s),
            }),
        );
    }
    {
        var runtime: FakeRuntime = .{};
        const steps = [_]FakeStep{
            .{ .outcome = .{ .response = .{
                .status = 302,
                .headers = &.{.{ .name = "Location", .value = "/b" }},
            } } },
            .{ .outcome = .{ .response = .{
                .status = 302,
                .headers = &.{.{ .name = "Location", .value = "/c" }},
            } } },
        };
        var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
        var client = try initFakeClient(
            std.testing.allocator,
            &fake,
            &runtime,
            .{
                .endpoint = .{ .authority = "registry.example" },
                .limits = .{ .max_redirects = 1 },
            },
        );
        defer client.deinit();
        try std.testing.expectError(
            error.RedirectLimitExceeded,
            client.execute(.{
                .path_and_query = "/a",
                .deadline = .after(runtime.clock(), std.time.ns_per_s),
            }),
        );
    }
    {
        var runtime: FakeRuntime = .{};
        const steps = [_]FakeStep{
            .{ .outcome = .{ .response = .{
                .status = 302,
                .headers = &.{.{ .name = "Location", .value = "/b" }},
            } } },
        };
        var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
        var client = try initFakeClient(
            std.testing.allocator,
            &fake,
            &runtime,
            .{
                .endpoint = .{ .authority = "registry.example" },
                .limits = .{ .max_redirects = 0 },
            },
        );
        defer client.deinit();
        try std.testing.expectError(
            error.RedirectLimitExceeded,
            client.execute(.{
                .path_and_query = "/a",
                .deadline = .after(runtime.clock(), std.time.ns_per_s),
            }),
        );
    }
}

test "absolute deadline is checked before request after backend and at retry sleep boundaries" {
    {
        var runtime: FakeRuntime = .{ .now_ns = 10 };
        const steps = [_]FakeStep{};
        var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
        var client = try initFakeClient(
            std.testing.allocator,
            &fake,
            &runtime,
            .{ .endpoint = .{ .authority = "registry.example" } },
        );
        defer client.deinit();
        try std.testing.expectError(
            error.DeadlineExceeded,
            client.execute(.{
                .path_and_query = "/v2/",
                .deadline = .{ .at_ns = 10 },
            }),
        );
        try std.testing.expectEqual(@as(usize, 0), fake.index);
    }
    {
        var runtime: FakeRuntime = .{};
        const steps = [_]FakeStep{
            .{
                .outcome = .{ .failure = error.ConnectionReset },
                .advance_ns = 1_000,
            },
        };
        var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
        var client = try initFakeClient(
            std.testing.allocator,
            &fake,
            &runtime,
            .{ .endpoint = .{ .authority = "registry.example" } },
        );
        defer client.deinit();
        try std.testing.expectError(
            error.DeadlineExceeded,
            client.execute(.{
                .path_and_query = "/v2/",
                .deadline = .{ .at_ns = 500 },
            }),
        );
        try std.testing.expectEqual(@as(usize, 0), runtime.sleep_count);
    }
    {
        var runtime: FakeRuntime = .{};
        const steps = [_]FakeStep{
            .{ .outcome = .{ .response = .{
                .status = 503,
                .headers = &.{.{ .name = "Retry-After", .value = "1" }},
            } } },
        };
        var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
        var client = try initFakeClient(
            std.testing.allocator,
            &fake,
            &runtime,
            .{ .endpoint = .{ .authority = "registry.example" } },
        );
        defer client.deinit();
        try std.testing.expectError(
            error.DeadlineExceeded,
            client.execute(.{
                .path_and_query = "/v2/",
                .deadline = .{ .at_ns = std.time.ns_per_s },
            }),
        );
        try std.testing.expectEqual(@as(usize, 0), runtime.sleep_count);
    }
    {
        var runtime: FakeRuntime = .{ .sleep_extra_ns = 100 };
        const steps = [_]FakeStep{
            .{ .outcome = .{ .failure = error.ConnectionReset } },
        };
        var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
        var client = try initFakeClient(
            std.testing.allocator,
            &fake,
            &runtime,
            .{
                .endpoint = .{ .authority = "registry.example" },
                .limits = .{ .base_retry_delay_ns = 100 },
            },
        );
        defer client.deinit();
        try std.testing.expectError(
            error.DeadlineExceeded,
            client.execute(.{
                .path_and_query = "/v2/",
                .deadline = .{ .at_ns = 150 },
            }),
        );
        try std.testing.expectEqual(@as(usize, 1), runtime.sleep_count);
        try std.testing.expectEqual(@as(usize, 1), fake.index);
    }
}

test "retry policy is limited to idempotent reads and narrow statuses and errors" {
    const statuses = [_]u16{ 408, 429, 500, 502, 503, 504 };
    for (statuses) |status| try std.testing.expect(isRetryableStatus(status));
    for ([_]u16{ 400, 401, 403, 404, 409, 501, 505 }) |status| {
        try std.testing.expect(!isRetryableStatus(status));
    }
    try std.testing.expect(isRetryableBackendError(error.ConnectionReset));
    try std.testing.expect(isRetryableBackendError(error.ReadFailed));
    try std.testing.expect(!isRetryableBackendError(error.DnsFailure));
    try std.testing.expect(!isRetryableBackendError(error.TlsFailure));
    try std.testing.expect(!isRetryableBackendError(error.ProtocolFailure));

    {
        var runtime: FakeRuntime = .{};
        const steps = [_]FakeStep{
            .{ .outcome = .{ .response = .{ .status = 503 } } },
            .{ .outcome = .{ .failure = error.ConnectionReset } },
            .{ .outcome = .{ .response = .{ .status = 200, .body = "ok" } } },
        };
        var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
        var client = try initFakeClient(
            std.testing.allocator,
            &fake,
            &runtime,
            .{ .endpoint = .{ .authority = "registry.example" } },
        );
        defer client.deinit();
        var response = try client.execute(.{
            .path_and_query = "/v2/",
            .deadline = .after(runtime.clock(), 10 * std.time.ns_per_s),
        });
        defer response.deinit();
        try std.testing.expectEqual(@as(usize, 3), fake.index);
        try std.testing.expectEqual(@as(usize, 2), runtime.sleep_count);
        try std.testing.expectEqual(@as(u64, 100 * std.time.ns_per_ms), runtime.sleeps[0]);
        try std.testing.expectEqual(@as(u64, 200 * std.time.ns_per_ms), runtime.sleeps[1]);
        try std.testing.expectEqualStrings("ok", response.body);
    }
    {
        var runtime: FakeRuntime = .{};
        const steps = [_]FakeStep{
            .{ .outcome = .{ .response = .{ .status = 503 } } },
        };
        var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
        var client = try initFakeClient(
            std.testing.allocator,
            &fake,
            &runtime,
            .{ .endpoint = .{ .authority = "registry.example" } },
        );
        defer client.deinit();
        var response = try client.execute(.{
            .method = .POST,
            .path_and_query = "/v2/upload",
            .deadline = .after(runtime.clock(), std.time.ns_per_s),
        });
        defer response.deinit();
        try std.testing.expectEqual(@as(u16, 503), response.status);
        try std.testing.expectEqual(@as(usize, 1), fake.index);
    }
    {
        var runtime: FakeRuntime = .{};
        const steps = [_]FakeStep{
            .{ .outcome = .{ .response = .{
                .status = 307,
                .headers = &.{.{ .name = "Location", .value = "/v2/replay" }},
            } } },
        };
        var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
        var client = try initFakeClient(
            std.testing.allocator,
            &fake,
            &runtime,
            .{ .endpoint = .{ .authority = "registry.example" } },
        );
        defer client.deinit();
        try std.testing.expectError(
            error.RedirectRejected,
            client.execute(.{
                .method = .PUT,
                .path_and_query = "/v2/upload",
                .deadline = .after(runtime.clock(), std.time.ns_per_s),
            }),
        );
        try std.testing.expectEqual(@as(usize, 1), fake.index);
    }
    {
        var runtime: FakeRuntime = .{};
        const steps = [_]FakeStep{
            .{ .outcome = .{ .failure = error.TlsFailure } },
        };
        var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
        var client = try initFakeClient(
            std.testing.allocator,
            &fake,
            &runtime,
            .{ .endpoint = .{ .authority = "registry.example" } },
        );
        defer client.deinit();
        try std.testing.expectError(
            error.TlsValidationFailed,
            client.execute(.{
                .path_and_query = "/v2/",
                .deadline = .after(runtime.clock(), std.time.ns_per_s),
            }),
        );
        try std.testing.expectEqual(@as(usize, 1), fake.index);
        try std.testing.expectEqual(@as(usize, 0), runtime.sleep_count);
    }
    {
        var runtime: FakeRuntime = .{};
        const steps = [_]FakeStep{
            .{ .outcome = .{ .response = .{ .status = 503 } } },
            .{ .outcome = .{ .response = .{ .status = 503 } } },
            .{ .outcome = .{ .response = .{ .status = 503 } } },
        };
        var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
        var client = try initFakeClient(
            std.testing.allocator,
            &fake,
            &runtime,
            .{ .endpoint = .{ .authority = "registry.example" } },
        );
        defer client.deinit();
        try std.testing.expectError(
            error.RetryLimitExceeded,
            client.execute(.{
                .path_and_query = "/v2/",
                .deadline = .after(runtime.clock(), 10 * std.time.ns_per_s),
            }),
        );
        try std.testing.expectEqual(@as(usize, 3), fake.index);
        try std.testing.expectEqual(@as(usize, 2), runtime.sleep_count);
    }
    {
        var runtime: FakeRuntime = .{};
        const steps = [_]FakeStep{
            .{ .outcome = .{ .response = .{
                .status = 429,
                .headers = &.{.{ .name = "Retry-After", .value = "999999" }},
            } } },
            .{ .outcome = .{ .response = .{ .status = 200 } } },
        };
        var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
        var client = try initFakeClient(
            std.testing.allocator,
            &fake,
            &runtime,
            .{ .endpoint = .{ .authority = "registry.example" } },
        );
        defer client.deinit();
        var response = try client.execute(.{
            .path_and_query = "/v2/",
            .deadline = .after(runtime.clock(), 61 * std.time.ns_per_s),
        });
        defer response.deinit();
        try std.testing.expectEqual(@as(usize, 1), runtime.sleep_count);
        try std.testing.expectEqual(@as(u64, 60 * std.time.ns_per_s), runtime.sleeps[0]);
    }
    {
        var runtime: FakeRuntime = .{ .unix_epoch_seconds = 0 };
        const steps = [_]FakeStep{
            .{ .outcome = .{ .response = .{
                .status = 503,
                .headers = &.{.{
                    .name = "Retry-After",
                    .value = "Thu, 01 Jan 1970 00:00:05 GMT",
                }},
            } } },
            .{ .outcome = .{ .response = .{ .status = 200 } } },
        };
        var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
        var client = try initFakeClient(
            std.testing.allocator,
            &fake,
            &runtime,
            .{ .endpoint = .{ .authority = "registry.example" } },
        );
        defer client.deinit();
        var response = try client.execute(.{
            .path_and_query = "/v2/",
            .deadline = .after(runtime.clock(), 6 * std.time.ns_per_s),
        });
        defer response.deinit();
        try std.testing.expectEqual(@as(usize, 1), runtime.sleep_count);
        try std.testing.expectEqual(@as(u64, 5 * std.time.ns_per_s), runtime.sleeps[0]);
    }
}

test "response headers and bodies are bounded independently" {
    {
        var runtime: FakeRuntime = .{};
        const steps = [_]FakeStep{
            .{ .outcome = .{ .response = .{
                .status = 200,
                .headers = &.{.{ .name = "X-Large", .value = "0123456789" }},
            } } },
        };
        var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
        var client = try initFakeClient(
            std.testing.allocator,
            &fake,
            &runtime,
            .{
                .endpoint = .{ .authority = "registry.example" },
                .limits = .{ .max_response_header_bytes = 8 },
            },
        );
        defer client.deinit();
        try std.testing.expectError(
            error.LimitExceeded,
            client.execute(.{
                .path_and_query = "/v2/",
                .deadline = .after(runtime.clock(), std.time.ns_per_s),
            }),
        );
    }
    {
        var runtime: FakeRuntime = .{};
        const steps = [_]FakeStep{
            .{ .outcome = .{ .response = .{ .status = 200, .body = "12345" } } },
        };
        var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
        var client = try initFakeClient(
            std.testing.allocator,
            &fake,
            &runtime,
            .{ .endpoint = .{ .authority = "registry.example" } },
        );
        defer client.deinit();
        try std.testing.expectError(
            error.LimitExceeded,
            client.execute(.{
                .path_and_query = "/v2/",
                .max_body_bytes = 4,
                .deadline = .after(runtime.clock(), std.time.ns_per_s),
            }),
        );
    }
}

test "source and destination authorization contexts remain independently owned" {
    var source_runtime: FakeRuntime = .{};
    var destination_runtime: FakeRuntime = .{};
    const source_steps = [_]FakeStep{
        .{ .outcome = .{ .response = .{ .status = 200 } } },
    };
    const destination_steps = [_]FakeStep{
        .{ .outcome = .{ .response = .{ .status = 200 } } },
    };
    var source_fake: FakeBackend = .{
        .runtime = &source_runtime,
        .steps = &source_steps,
    };
    var destination_fake: FakeBackend = .{
        .runtime = &destination_runtime,
        .steps = &destination_steps,
    };
    var source_secret = [_]u8{ 'p', 'u', 'l', 'l' };
    var destination_secret = [_]u8{ 'p', 'u', 's', 'h' };
    var source = try initFakeClient(
        std.testing.allocator,
        &source_fake,
        &source_runtime,
        .{
            .endpoint = .{ .authority = "registry.example" },
            .authorization = .{ .basic = .{
                .username = "source",
                .secret = &source_secret,
            } },
            .auth_context_id = 1,
        },
    );
    defer source.deinit();
    var destination = try initFakeClient(
        std.testing.allocator,
        &destination_fake,
        &destination_runtime,
        .{
            .endpoint = .{ .authority = "registry.example" },
            .authorization = .{ .basic = .{
                .username = "destination",
                .secret = &destination_secret,
            } },
            .auth_context_id = 2,
        },
    );
    defer destination.deinit();
    @memset(&source_secret, 'x');
    @memset(&destination_secret, 'y');

    var source_response = try source.execute(.{
        .path_and_query = "/v2/source",
        .deadline = .after(source_runtime.clock(), std.time.ns_per_s),
    });
    defer source_response.deinit();
    var destination_response = try destination.execute(.{
        .path_and_query = "/v2/destination",
        .deadline = .after(destination_runtime.clock(), std.time.ns_per_s),
    });
    defer destination_response.deinit();

    try std.testing.expectEqualStrings(
        "Basic c291cmNlOnB1bGw=",
        source_fake.authorization(0).?,
    );
    try std.testing.expectEqualStrings(
        "Basic ZGVzdGluYXRpb246cHVzaA==",
        destination_fake.authorization(0).?,
    );
}

const TestTokenAcquirer = struct {
    count: usize = 0,
    last_deadline_ns: i128 = 0,
    runtime: ?*FakeRuntime = null,
    advance_ns: u64 = 0,

    fn boundary(self: *TestTokenAcquirer) TokenAcquirer {
        return .{ .context = self, .acquire = acquire };
    }

    fn acquire(
        context: ?*anyopaque,
        allocator: Allocator,
        request: TokenAcquisitionRequest,
    ) auth.TokenAcquisitionError!auth.Token {
        const self: *TestTokenAcquirer = @ptrCast(@alignCast(context.?));
        self.count += 1;
        self.last_deadline_ns = request.absolute_deadline_ns;
        _ = request.key;
        if (self.runtime) |runtime| runtime.now_ns += self.advance_ns;
        const value = try std.fmt.allocPrint(
            allocator,
            "token-{d}",
            .{self.count},
        );
        return .{ .value = value, .expires_in = 3600 };
    }
};

test "Basic and Bearer challenge state is explicit bounded and scope-exact" {
    {
        var runtime: FakeRuntime = .{};
        const steps = [_]FakeStep{
            .{ .outcome = .{ .response = .{
                .status = 401,
                .headers = &.{.{ .name = "WWW-Authenticate", .value = "Basic realm=\"registry\"" }},
            } } },
        };
        var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
        var client = try initFakeClient(
            std.testing.allocator,
            &fake,
            &runtime,
            .{
                .endpoint = .{ .authority = "registry.example" },
                .authorization = .{ .basic = .{
                    .username = "user",
                    .secret = "secret",
                } },
            },
        );
        defer client.deinit();
        try std.testing.expectError(
            error.AuthenticationFailed,
            client.execute(.{
                .path_and_query = "/v2/",
                .deadline = .after(runtime.clock(), std.time.ns_per_s),
            }),
        );
        try std.testing.expectEqualStrings(
            "Basic dXNlcjpzZWNyZXQ=",
            fake.authorization(0).?,
        );
        try std.testing.expectEqual(@as(usize, 1), fake.index);
    }

    {
        var runtime: FakeRuntime = .{};
        const challenge =
            "Bearer realm=\"https://token.example/auth?signed=hidden\", " ++
            "service=\"registry.example\", scope=\"repository:repo:pull\"";
        const other_scope_challenge =
            "Bearer realm=\"https://token.example/auth?signed=hidden\", " ++
            "service=\"registry.example\", scope=\"repository:other:pull\"";
        const steps = [_]FakeStep{
            .{ .outcome = .{ .response = .{
                .status = 401,
                .headers = &.{.{ .name = "WWW-Authenticate", .value = challenge }},
            } } },
            .{ .outcome = .{ .response = .{ .status = 200 } } },
            .{ .outcome = .{ .response = .{
                .status = 401,
                .headers = &.{.{ .name = "WWW-Authenticate", .value = challenge }},
            } } },
            .{ .outcome = .{ .response = .{ .status = 200 } } },
            .{ .outcome = .{ .response = .{
                .status = 401,
                .headers = &.{.{ .name = "WWW-Authenticate", .value = other_scope_challenge }},
            } } },
            .{ .outcome = .{ .response = .{ .status = 200 } } },
        };
        var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
        var token_acquirer: TestTokenAcquirer = .{};
        var client = try initFakeClient(
            std.testing.allocator,
            &fake,
            &runtime,
            .{
                .endpoint = .{ .authority = "registry.example" },
                .token_acquirer = token_acquirer.boundary(),
                .auth_context_id = 44,
                .credential_generation = 7,
            },
        );
        defer client.deinit();
        var first = try client.execute(.{
            .path_and_query = "/v2/first",
            .deadline = .after(runtime.clock(), std.time.ns_per_s),
        });
        first.deinit();
        var second = try client.execute(.{
            .path_and_query = "/v2/second",
            .deadline = .after(runtime.clock(), std.time.ns_per_s),
        });
        second.deinit();
        var third = try client.execute(.{
            .path_and_query = "/v2/third",
            .deadline = .after(runtime.clock(), std.time.ns_per_s),
        });
        third.deinit();
        try std.testing.expectEqual(@as(usize, 2), token_acquirer.count);
        try std.testing.expectEqual(@as(i128, std.time.ns_per_s), token_acquirer.last_deadline_ns);
        try std.testing.expectEqualStrings(
            "Bearer token-1",
            fake.authorization(3).?,
        );
        try std.testing.expectEqualStrings(
            "Bearer token-2",
            fake.authorization(5).?,
        );
    }
}

test "token acquisition consumes the same absolute deadline" {
    var runtime: FakeRuntime = .{};
    const steps = [_]FakeStep{
        .{ .outcome = .{ .response = .{
            .status = 401,
            .headers = &.{.{ .name = "WWW-Authenticate", .value = "Bearer realm=\"https://token.example\", scope=\"repository:repo:pull\"" }},
        } } },
    };
    var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
    var token_acquirer: TestTokenAcquirer = .{
        .runtime = &runtime,
        .advance_ns = 100,
    };
    var client = try initFakeClient(
        std.testing.allocator,
        &fake,
        &runtime,
        .{
            .endpoint = .{ .authority = "registry.example" },
            .token_acquirer = token_acquirer.boundary(),
        },
    );
    defer client.deinit();
    try std.testing.expectError(
        error.DeadlineExceeded,
        client.execute(.{
            .path_and_query = "/v2/",
            .deadline = .{ .at_ns = 100 },
        }),
    );
    try std.testing.expectEqual(@as(i128, 100), token_acquirer.last_deadline_ns);
    try std.testing.expectEqual(@as(usize, 1), fake.index);
}

test "cross-origin redirect cannot reacquire authorization after stripping" {
    var runtime: FakeRuntime = .{};
    const steps = [_]FakeStep{
        .{ .outcome = .{ .response = .{
            .status = 307,
            .headers = &.{.{ .name = "Location", .value = "https://cdn.example/blob" }},
        } } },
        .{ .outcome = .{ .response = .{
            .status = 401,
            .headers = &.{.{ .name = "WWW-Authenticate", .value = "Bearer realm=\"https://token.example\"" }},
        } } },
    };
    var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
    var token_acquirer: TestTokenAcquirer = .{};
    var client = try initFakeClient(
        std.testing.allocator,
        &fake,
        &runtime,
        .{
            .endpoint = .{ .authority = "registry.example" },
            .authorization = .{ .bearer = "registry-token" },
            .token_acquirer = token_acquirer.boundary(),
        },
    );
    defer client.deinit();
    try std.testing.expectError(
        error.AuthenticationFailed,
        client.execute(.{
            .path_and_query = "/v2/blob",
            .class = .blob,
            .deadline = .after(runtime.clock(), std.time.ns_per_s),
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), token_acquirer.count);
}

test "signed URLs and authorization never appear in diagnostics or formatting" {
    var runtime: FakeRuntime = .{};
    const steps = [_]FakeStep{
        .{ .outcome = .{ .response = .{
            .status = 307,
            .headers = &.{.{ .name = "Location", .value = "https://cdn.example/blob?sig=SIGNED-SECRET" }},
        } } },
        .{ .outcome = .{ .failure = error.TlsFailure } },
    };
    var fake: FakeBackend = .{ .runtime = &runtime, .steps = &steps };
    var client = try initFakeClient(
        std.testing.allocator,
        &fake,
        &runtime,
        .{
            .endpoint = .{ .authority = "registry.example" },
            .authorization = .{ .bearer = "AUTHORIZATION-SECRET" },
        },
    );
    defer client.deinit();
    try std.testing.expectError(
        error.TlsValidationFailed,
        client.execute(.{
            .path_and_query = "/v2/blob",
            .class = .blob,
            .deadline = .after(runtime.clock(), std.time.ns_per_s),
        }),
    );

    var buffer: [512]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try writer.print("{f}", .{client.lastDiagnostic().?.*});
    const diagnostic_text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, diagnostic_text, "SIGNED-SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic_text, "AUTHORIZATION-SECRET") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, diagnostic_text, '?') == null);
    try std.testing.expectEqualStrings(
        "https://cdn.example:443",
        client.lastDiagnostic().?.origin(),
    );

    var request_writer = Io.Writer.fixed(&buffer);
    const request: BackendRequest = .{
        .method = .GET,
        .url = "https://cdn.example/blob?sig=SIGNED-SECRET",
        .class = .blob,
        .headers = &.{},
        .authorization = "Bearer AUTHORIZATION-SECRET",
        .response_header_limit = 1,
        .body_limit = 1,
        .absolute_deadline_ns = 1,
        .attempt_timeout_ns = 1,
        .body_idle_timeout_ns = 1,
    };
    try request_writer.print("{f}", .{request});
    const request_text = request_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, request_text, "SIGNED-SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, request_text, "AUTHORIZATION-SECRET") == null);
}

test "production backend declares honest Zig 0.16 timeout limitations and rejects malformed CA data" {
    try std.testing.expect(!StdBackend.capabilities.absolute_deadline);
    try std.testing.expect(!StdBackend.capabilities.dns_timeout);
    try std.testing.expect(!StdBackend.capabilities.connect_timeout);
    try std.testing.expect(!StdBackend.capabilities.tls_handshake_timeout);
    try std.testing.expect(!StdBackend.capabilities.write_timeout);
    try std.testing.expect(!StdBackend.capabilities.response_head_timeout);
    try std.testing.expect(!StdBackend.capabilities.body_idle_timeout);

    try std.testing.expectError(
        error.CertificateAuthorityLoadFailed,
        StdBackend.init(
            std.testing.allocator,
            std.testing.io,
            .{
                .authority = "registry.example",
                .additional_ca = .{ .pem_data = "not a certificate" },
            },
            .{},
        ),
    );
}

const test_ca_pem =
    \\-----BEGIN CERTIFICATE-----
    \\MIIDMTCCAhmgAwIBAgIUJSBdXkCZfcgscHaSlp1ecd7o1VAwDQYJKoZIhvcNAQEL
    \\BQAwIDEeMBwGA1UEAwwVV0FCVCBPQ0kgSFRUUCBUZXN0IENBMB4XDTI2MDkxOTA4
    \\MDQ1NVoXDTM2MDkxNjA4MDQ1NVowIDEeMBwGA1UEAwwVV0FCVCBPQ0kgSFRUUCBU
    \\ZXN0IENBMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAvofkguStWywB
    \\m9txqWGKmL5vbuQNxE7ZLhIMk5jKdRORQy9B0NBoOQLpGTrXJw2Mq+8lfeIqJSl7
    \\N9vH2tPkOLcPtdZ8/wzrY4JV4dkYjo3xSF82Hc42SRa5oUv03AgPOZNfzmgoFaCc
    \\V3kr6zdXBVivRVjCBEbLa5F3em6c99zBi60dfH3uru7UQFBXTaj9QkgPR1bhVhsi
    \\IJ75iSpYoMdg04yQyKMXJ3WTZsxPYgaawrcybLa5gGSzcp7pEdO8rOzBFqu31eXU
    \\0ZFsRVtXnOVduxKN1c26S9hTsVs8ZeKr7qYbUhbVGUtpaNI3MRNjyCx6Oo/3AWE3
    \\7LAFu+FFNQIDAQABo2MwYTAdBgNVHQ4EFgQU73Q0dF5PhGm6KETMUX3qreh9PtYw
    \\HwYDVR0jBBgwFoAU73Q0dF5PhGm6KETMUX3qreh9PtYwDwYDVR0TAQH/BAUwAwEB
    \\/zAOBgNVHQ8BAf8EBAMCAQYwDQYJKoZIhvcNAQELBQADggEBABKNdccCebkvFiEZ
    \\j7cFDd4P91WUSJ7F5y+B/t/Rw0pfA8IpA4a/aEW6Fp7CNQXS40XKKxAdIi+O3q9Y
    \\+zfFYmMdsNp86B54p77oA+sZ7p2orHhFhQ2bZDpQdmD3W3wam0HXZ1Yyc3/QlvJD
    \\Z/GnD5D8vN4ErdQjrj31ogy5hBbuDZOFtFJ/f9m5/a3z+d24uNrnuxzijGti3Nc5
    \\MAaivfteG4+zTF7UUR5YJFx50nNjOjoXR0EVPRiS96h31Zhg4wc2fRBbfJLj2MwU
    \\IoQKB6/GNnJrkUxgH7ZKQug0cURSXtZTiL/njRLOmNoSAsCfQEEiQWPougd5l/Ft
    \\vbT3/SM=
    \\-----END CERTIFICATE-----
;

test "additional PEM CA extends rather than replaces system trust" {
    var system_bundle: std.crypto.Certificate.Bundle = .empty;
    defer system_bundle.deinit(std.testing.allocator);
    const now = Io.Clock.real.now(std.testing.io);
    try system_bundle.rescan(std.testing.allocator, std.testing.io, now);
    const system_count = system_bundle.map.count();

    var backend = try StdBackend.init(
        std.testing.allocator,
        std.testing.io,
        .{
            .authority = "registry.example",
            .additional_ca = .{ .pem_data = test_ca_pem },
        },
        .{},
    );
    defer backend.deinit();
    try std.testing.expect(backend.client.ca_bundle.map.count() > system_count);
    try std.testing.expect(backend.client.now != null);
}
