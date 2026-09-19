//! Pure OCI Distribution authentication and credential-policy primitives.
//!
//! This module performs no HTTP requests and has no ambient side effects.
//! Credential discovery, file reads, helper execution, time, and token
//! acquisition happen only through explicit caller-provided inputs.
const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const native_os = @import("builtin").os.tag;

pub const default_token_ttl_seconds: u64 = 60;
pub const max_token_ttl_seconds: u64 = 24 * 60 * 60;
pub const token_expiry_skew_seconds: i64 = 10;

pub const Limits = struct {
    max_challenge_bytes: usize = 64 * 1024,
    max_challenges: usize = 64,
    max_parameters_per_challenge: usize = 64,
    max_parameter_name_bytes: usize = 256,
    max_parameter_value_bytes: usize = 16 * 1024,
    max_auth_file_bytes: usize = 1024 * 1024,
    max_decoded_credential_bytes: usize = 64 * 1024,
    max_helper_name_bytes: usize = 128,
    max_helper_input_bytes: usize = 4096,
    max_helper_output_bytes: usize = 64 * 1024,
    max_path_bytes: usize = 32 * 1024,
    max_token_response_bytes: usize = 1024 * 1024,
    max_token_bytes: usize = 16 * 1024,
    max_token_cache_entries: usize = 64,
    helper_timeout_ns: u64 = 15 * std.time.ns_per_s,

    pub fn validate(self: Limits) Error!void {
        if (self.max_challenge_bytes == 0 or
            self.max_challenges == 0 or
            self.max_parameters_per_challenge == 0 or
            self.max_parameter_name_bytes == 0 or
            self.max_parameter_value_bytes == 0 or
            self.max_auth_file_bytes == 0 or
            self.max_decoded_credential_bytes == 0 or
            self.max_helper_name_bytes == 0 or
            self.max_helper_input_bytes == 0 or
            self.max_helper_output_bytes == 0 or
            self.max_path_bytes == 0 or
            self.max_token_response_bytes == 0 or
            self.max_token_bytes == 0 or
            self.max_token_cache_entries == 0 or
            self.helper_timeout_ns == 0)
        {
            return error.InvalidLimits;
        }
    }
};

pub const Error = error{
    InvalidLimits,
    ChallengeTooLarge,
    MalformedChallenge,
    TooManyChallenges,
    TooManyChallengeParameters,
    ChallengeParameterTooLarge,
    DuplicateChallengeParameter,
    MissingBearerRealm,
    ConflictingBearerChallenges,
    InvalidTokenRealm,
    InvalidTokenResponse,
    TokenResponseTooLarge,
    InvalidToken,
    TokenAcquisitionFailed,
    InvalidAuthority,
    InvalidRepository,
    InvalidCredential,
    CredentialNotFound,
    AuthFileNotFound,
    AuthFileTooLarge,
    InvalidAuthFile,
    UnsupportedCredentialType,
    InvalidCredentialHelperName,
    CredentialHelperInputTooLarge,
    CredentialHelperOutputTooLarge,
    InvalidCredentialHelperOutput,
    CredentialHelperFailed,
    CredentialHelperDeadlineExceeded,
    PathTooLong,
} || Allocator.Error;

pub const Parameter = struct {
    name: []u8,
    value: []u8,

    fn deinit(self: *Parameter, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
        self.* = undefined;
    }
};

/// An owned RFC 9110 authentication challenge.
pub const Challenge = struct {
    scheme: []u8,
    token68: ?[]u8,
    parameters: []Parameter,

    pub fn deinit(self: *Challenge, allocator: Allocator) void {
        allocator.free(self.scheme);
        if (self.token68) |value| allocator.free(value);
        for (self.parameters) |*item| item.deinit(allocator);
        allocator.free(self.parameters);
        self.* = undefined;
    }

    pub fn parameter(self: Challenge, name: []const u8) ?[]const u8 {
        for (self.parameters) |item| {
            if (std.ascii.eqlIgnoreCase(item.name, name)) return item.value;
        }
        return null;
    }

    pub fn isScheme(self: Challenge, name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.scheme, name);
    }
};

pub const ChallengeSet = struct {
    allocator: Allocator,
    challenges: []Challenge,

    pub fn deinit(self: *ChallengeSet) void {
        for (self.challenges) |*challenge| challenge.deinit(self.allocator);
        self.allocator.free(self.challenges);
        self.* = undefined;
    }

    pub fn first(self: ChallengeSet, scheme: []const u8) ?Challenge {
        for (self.challenges) |challenge| {
            if (challenge.isScheme(scheme)) return challenge;
        }
        return null;
    }
};

/// Parses repeated WWW-Authenticate fields with cumulative and per-parameter
/// bounds. Parameter names and scheme names are matched case-insensitively.
/// Repeated Bearer `scope` parameters are the only permitted duplicate name.
pub fn parseChallenges(
    allocator: Allocator,
    values: []const []const u8,
    limits: Limits,
) Error!ChallengeSet {
    try limits.validate();
    var total_bytes: usize = 0;
    for (values) |value| {
        total_bytes = std.math.add(usize, total_bytes, value.len) catch return error.ChallengeTooLarge;
        if (total_bytes > limits.max_challenge_bytes) return error.ChallengeTooLarge;
    }

    var challenges = std.array_list.Managed(Challenge).init(allocator);
    errdefer {
        for (challenges.items) |*challenge| challenge.deinit(allocator);
        challenges.deinit();
    }

    for (values) |value| {
        var parser = ChallengeParser{ .input = value, .limits = limits };
        while (true) {
            parser.skipListWhitespace();
            if (parser.done()) break;
            if (challenges.items.len >= limits.max_challenges) return error.TooManyChallenges;
            {
                var challenge = try parser.parseOne(allocator);
                errdefer challenge.deinit(allocator);
                try challenges.append(challenge);
            }
        }
    }

    return .{
        .allocator = allocator,
        .challenges = try challenges.toOwnedSlice(),
    };
}

pub fn parseWwwAuthenticate(
    allocator: Allocator,
    values: []const []const u8,
) Error!ChallengeSet {
    return parseChallenges(allocator, values, .{});
}

const ChallengeParser = struct {
    input: []const u8,
    limits: Limits,
    index: usize = 0,

    fn done(self: ChallengeParser) bool {
        return self.index == self.input.len;
    }

    fn skipWhitespace(self: *ChallengeParser) bool {
        const start = self.index;
        while (self.index < self.input.len and isOws(self.input[self.index])) : (self.index += 1) {}
        return self.index != start;
    }

    fn skipListWhitespace(self: *ChallengeParser) void {
        while (true) {
            _ = self.skipWhitespace();
            if (self.index == self.input.len or self.input[self.index] != ',') return;
            self.index += 1;
        }
    }

    fn parseOne(self: *ChallengeParser, allocator: Allocator) Error!Challenge {
        const scheme = try self.takeTokenAlloc(allocator, self.limits.max_parameter_name_bytes);
        errdefer allocator.free(scheme);

        const had_whitespace = self.skipWhitespace();
        if (self.done() or self.input[self.index] == ',') {
            return .{
                .scheme = scheme,
                .token68 = null,
                .parameters = try allocator.alloc(Parameter, 0),
            };
        }
        if (!had_whitespace) return error.MalformedChallenge;

        const start = self.index;
        _ = self.takeTokenSlice() catch return error.MalformedChallenge;
        _ = self.skipWhitespace();
        if (self.index < self.input.len and
            self.input[self.index] == '=' and
            !self.token68At(start))
        {
            self.index = start;
            return .{
                .scheme = scheme,
                .token68 = null,
                .parameters = try self.parseParameters(allocator, scheme),
            };
        }

        self.index = start;
        const token68 = try self.takeToken68Alloc(allocator);
        errdefer allocator.free(token68);
        _ = self.skipWhitespace();
        if (!self.done() and self.input[self.index] != ',') return error.MalformedChallenge;
        return .{
            .scheme = scheme,
            .token68 = token68,
            .parameters = try allocator.alloc(Parameter, 0),
        };
    }

    fn token68At(self: *const ChallengeParser, start: usize) bool {
        var end = start;
        while (end < self.input.len and isToken68(self.input[end])) : (end += 1) {}
        if (end == start or
            (end < self.input.len and !isOws(self.input[end]) and self.input[end] != ','))
        {
            return false;
        }
        const candidate = self.input[start..end];
        const padding = std.mem.indexOfScalar(u8, candidate, '=') orelse return false;
        for (candidate[padding..]) |byte| {
            if (byte != '=') return false;
        }
        return true;
    }

    fn parseParameters(
        self: *ChallengeParser,
        allocator: Allocator,
        scheme: []const u8,
    ) Error![]Parameter {
        var parameters = std.array_list.Managed(Parameter).init(allocator);
        errdefer {
            for (parameters.items) |*parameter| parameter.deinit(allocator);
            parameters.deinit();
        }

        while (true) {
            if (parameters.items.len >= self.limits.max_parameters_per_challenge) {
                return error.TooManyChallengeParameters;
            }
            const name = try self.takeTokenAlloc(allocator, self.limits.max_parameter_name_bytes);
            var name_transferred = false;
            defer if (!name_transferred) allocator.free(name);
            for (parameters.items) |parameter| {
                if (!std.ascii.eqlIgnoreCase(parameter.name, name)) continue;
                if (!std.ascii.eqlIgnoreCase(scheme, "Bearer") or
                    !std.ascii.eqlIgnoreCase(name, "scope"))
                {
                    return error.DuplicateChallengeParameter;
                }
            }

            _ = self.skipWhitespace();
            if (self.index == self.input.len or self.input[self.index] != '=') {
                return error.MalformedChallenge;
            }
            self.index += 1;
            _ = self.skipWhitespace();
            const value = try self.takeParameterValueAlloc(allocator);
            var value_transferred = false;
            defer if (!value_transferred) allocator.free(value);
            try parameters.append(.{ .name = name, .value = value });
            name_transferred = true;
            value_transferred = true;

            _ = self.skipWhitespace();
            if (self.done()) break;
            if (self.input[self.index] != ',') return error.MalformedChallenge;
            self.index += 1;
            _ = self.skipWhitespace();
            if (self.done()) break;

            const next = self.index;
            _ = self.takeTokenSlice() catch return error.MalformedChallenge;
            _ = self.skipWhitespace();
            if (self.index < self.input.len and self.input[self.index] == '=') {
                self.index = next;
                continue;
            }
            self.index = next;
            break;
        }

        return parameters.toOwnedSlice();
    }

    fn takeParameterValueAlloc(self: *ChallengeParser, allocator: Allocator) Error![]u8 {
        if (self.index == self.input.len) return error.MalformedChallenge;
        if (self.input[self.index] != '"') {
            return self.takeTokenAlloc(allocator, self.limits.max_parameter_value_bytes);
        }

        self.index += 1;
        var output = std.array_list.Managed(u8).init(allocator);
        errdefer output.deinit();
        while (self.index < self.input.len) {
            const byte = self.input[self.index];
            self.index += 1;
            switch (byte) {
                '"' => return output.toOwnedSlice(),
                '\\' => {
                    if (self.index == self.input.len) return error.MalformedChallenge;
                    const escaped = self.input[self.index];
                    self.index += 1;
                    if (!isQuotedPairByte(escaped)) return error.MalformedChallenge;
                    if (output.items.len >= self.limits.max_parameter_value_bytes) {
                        return error.ChallengeParameterTooLarge;
                    }
                    try output.append(escaped);
                },
                else => {
                    if (!isQdText(byte)) return error.MalformedChallenge;
                    if (output.items.len >= self.limits.max_parameter_value_bytes) {
                        return error.ChallengeParameterTooLarge;
                    }
                    try output.append(byte);
                },
            }
        }
        return error.MalformedChallenge;
    }

    fn takeTokenAlloc(
        self: *ChallengeParser,
        allocator: Allocator,
        limit: usize,
    ) Error![]u8 {
        const value = try self.takeTokenSlice();
        if (value.len > limit) return error.ChallengeParameterTooLarge;
        return allocator.dupe(u8, value);
    }

    fn takeTokenSlice(self: *ChallengeParser) Error![]const u8 {
        const start = self.index;
        while (self.index < self.input.len and isToken(self.input[self.index])) : (self.index += 1) {}
        if (self.index == start) return error.MalformedChallenge;
        return self.input[start..self.index];
    }

    fn takeToken68Alloc(self: *ChallengeParser, allocator: Allocator) Error![]u8 {
        const start = self.index;
        while (self.index < self.input.len and isToken68(self.input[self.index])) : (self.index += 1) {}
        if (self.index == start) return error.MalformedChallenge;
        if (self.index - start > self.limits.max_parameter_value_bytes) {
            return error.ChallengeParameterTooLarge;
        }
        return allocator.dupe(u8, self.input[start..self.index]);
    }
};

fn isOws(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn isToken(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn isToken68(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '-', '.', '_', '~', '+', '/', '=' => true,
        else => false,
    };
}

fn isQdText(byte: u8) bool {
    return byte == '\t' or byte == ' ' or byte == '!' or
        (byte >= '#' and byte <= '[') or
        (byte >= ']' and byte <= '~') or
        byte >= 0x80;
}

fn isQuotedPairByte(byte: u8) bool {
    return byte == '\t' or byte == ' ' or (byte >= 0x21 and byte <= 0x7e) or byte >= 0x80;
}

pub const BearerChallenge = struct {
    allocator: Allocator,
    realm: []u8,
    service: ?[]u8,
    scopes: [][]u8,

    pub fn deinit(self: *BearerChallenge) void {
        self.allocator.free(self.realm);
        if (self.service) |service| self.allocator.free(service);
        for (self.scopes) |scope| self.allocator.free(scope);
        self.allocator.free(self.scopes);
        self.* = undefined;
    }
};

pub const BasicChallenge = struct {
    allocator: Allocator,
    realm: ?[]u8,

    pub fn deinit(self: *BasicChallenge) void {
        if (self.realm) |realm| self.allocator.free(realm);
        self.* = undefined;
    }
};

pub const DistributionChallenge = union(enum) {
    bearer: BearerChallenge,
    basic: BasicChallenge,

    pub fn deinit(self: *DistributionChallenge) void {
        switch (self.*) {
            .bearer => |*bearer| bearer.deinit(),
            .basic => |*basic| basic.deinit(),
        }
        self.* = undefined;
    }
};

/// Selects the Distribution authentication mode. Any offered Bearer
/// challenge is validated before Basic is considered, so malformed or
/// inconsistent Bearer challenges never silently downgrade to Basic.
pub fn selectDistributionChallenge(
    allocator: Allocator,
    set: ChallengeSet,
) Error!?DistributionChallenge {
    var bearer_count: usize = 0;
    for (set.challenges) |challenge| {
        if (challenge.isScheme("Bearer")) bearer_count += 1;
    }
    if (bearer_count != 0) return .{ .bearer = try mergeBearerChallenges(allocator, set) };

    for (set.challenges) |challenge| {
        if (!challenge.isScheme("Basic")) continue;
        if (challenge.token68 != null) return error.MalformedChallenge;
        return .{ .basic = .{
            .allocator = allocator,
            .realm = if (challenge.parameter("realm")) |realm|
                try allocator.dupe(u8, realm)
            else
                null,
        } };
    }
    return null;
}

fn mergeBearerChallenges(allocator: Allocator, set: ChallengeSet) Error!BearerChallenge {
    var realm_value: ?[]const u8 = null;
    var service_value: ?[]const u8 = null;
    var service_presence: ?bool = null;
    var scopes = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (scopes.items) |scope| allocator.free(scope);
        scopes.deinit();
    }

    for (set.challenges) |challenge| {
        if (!challenge.isScheme("Bearer")) continue;
        if (challenge.token68 != null) return error.MalformedChallenge;
        const realm = challenge.parameter("realm") orelse return error.MissingBearerRealm;
        if (realm.len == 0) return error.MissingBearerRealm;
        try validateTokenRealm(realm);
        if (realm_value) |existing| {
            if (!std.mem.eql(u8, existing, realm)) return error.ConflictingBearerChallenges;
        } else {
            realm_value = realm;
        }

        const service = challenge.parameter("service");
        if (service_presence) |present| {
            if (present != (service != null)) return error.ConflictingBearerChallenges;
        } else {
            service_presence = service != null;
        }
        if (service) |value| {
            if (value.len == 0 or containsControl(value)) return error.MalformedChallenge;
            if (service_value) |existing| {
                if (!std.mem.eql(u8, existing, value)) return error.ConflictingBearerChallenges;
            } else {
                service_value = value;
            }
        }
        for (challenge.parameters) |parameter| {
            if (std.ascii.eqlIgnoreCase(parameter.name, "realm") or
                std.ascii.eqlIgnoreCase(parameter.name, "service") or
                std.ascii.eqlIgnoreCase(parameter.name, "error"))
            {
                continue;
            }
            if (!std.ascii.eqlIgnoreCase(parameter.name, "scope")) continue;
            if (parameter.value.len == 0 or containsControl(parameter.value)) {
                return error.MalformedChallenge;
            }
            var duplicate = false;
            for (scopes.items) |scope| {
                if (std.mem.eql(u8, scope, parameter.value)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) {
                const scope = try allocator.dupe(u8, parameter.value);
                errdefer allocator.free(scope);
                try scopes.append(scope);
            }
        }
    }

    std.mem.sort([]u8, scopes.items, {}, scopeLessThan);
    const realm = try allocator.dupe(u8, realm_value.?);
    errdefer allocator.free(realm);
    const service = if (service_value) |value| try allocator.dupe(u8, value) else null;
    errdefer if (service) |value| allocator.free(value);
    return .{
        .allocator = allocator,
        .realm = realm,
        .service = service,
        .scopes = try scopes.toOwnedSlice(),
    };
}

fn scopeLessThan(_: void, left: []u8, right: []u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

pub const BasicCredential = struct {
    username: []const u8,
    secret: []const u8,

    pub fn format(_: BasicCredential, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("<basic-credential:redacted>");
    }
};

/// Caller-owned input. The module borrows these bytes only for the resolving
/// call and copies any retained credential into wipe-on-free storage.
pub const SuppliedCredential = union(enum) {
    basic: BasicCredential,
    bearer_token: []const u8,

    pub fn format(_: SuppliedCredential, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("<supplied-credential:redacted>");
    }
};

pub const OwnedBasicCredential = struct {
    username: []u8,
    secret: []u8,

    pub fn deinit(self: *OwnedBasicCredential, allocator: Allocator) void {
        secureFree(allocator, self.username);
        secureFree(allocator, self.secret);
        self.* = undefined;
    }

    pub fn borrowed(self: OwnedBasicCredential) BasicCredential {
        return .{ .username = self.username, .secret = self.secret };
    }

    pub fn format(_: OwnedBasicCredential, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("<basic-credential:redacted>");
    }
};

pub const OwnedCredential = union(enum) {
    basic: OwnedBasicCredential,
    bearer_token: []u8,

    pub fn deinit(self: *OwnedCredential, allocator: Allocator) void {
        switch (self.*) {
            .basic => |*basic| basic.deinit(allocator),
            .bearer_token => |token| secureFree(allocator, token),
        }
        self.* = undefined;
    }

    pub fn format(_: OwnedCredential, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("<credential:redacted>");
    }
};

pub const CredentialSource = enum {
    supplied,
    explicit_auth_file,
    registry_auth_file,
    containers_runtime,
    containers_config,
    docker_config,
    legacy_dockercfg,
};

pub const ResolvedCredential = struct {
    source: CredentialSource,
    credential: OwnedCredential,

    pub fn deinit(self: *ResolvedCredential, allocator: Allocator) void {
        self.credential.deinit(allocator);
        self.* = undefined;
    }

    pub fn format(self: ResolvedCredential, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("credential(source={s}, value=<redacted>)", .{@tagName(self.source)});
    }
};

pub const CredentialPolicy = union(enum) {
    none,
    supplied: SuppliedCredential,
    auth_file: []const u8,
    discover,
};

pub const Authorization = struct {
    bytes: []u8,

    pub fn deinit(self: *Authorization, allocator: Allocator) void {
        secureFree(allocator, self.bytes);
        self.* = undefined;
    }

    pub fn format(_: Authorization, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("<authorization:redacted>");
    }
};

pub fn basicAuthorizationAlloc(
    allocator: Allocator,
    credential: BasicCredential,
    limits: Limits,
) Error!Authorization {
    try validateBasicCredential(credential, limits);
    const raw_len = std.math.add(usize, credential.username.len, credential.secret.len) catch
        return error.InvalidCredential;
    const raw = try allocator.alloc(u8, std.math.add(usize, raw_len, 1) catch
        return error.InvalidCredential);
    defer secureFree(allocator, raw);
    @memcpy(raw[0..credential.username.len], credential.username);
    raw[credential.username.len] = ':';
    @memcpy(raw[credential.username.len + 1 ..], credential.secret);

    const encoded_len = std.base64.standard.Encoder.calcSize(raw.len);
    const bytes = try allocator.alloc(u8, std.math.add(usize, "Basic ".len, encoded_len) catch
        return error.InvalidCredential);
    errdefer secureFree(allocator, bytes);
    @memcpy(bytes[0.."Basic ".len], "Basic ");
    _ = std.base64.standard.Encoder.encode(bytes["Basic ".len..], raw);
    return .{ .bytes = bytes };
}

pub fn bearerAuthorizationAlloc(
    allocator: Allocator,
    token: []const u8,
    limits: Limits,
) Error!Authorization {
    if (!validBearerToken(token, limits.max_token_bytes)) return error.InvalidToken;
    const bytes = try allocator.alloc(u8, std.math.add(usize, "Bearer ".len, token.len) catch
        return error.InvalidToken);
    errdefer secureFree(allocator, bytes);
    @memcpy(bytes[0.."Bearer ".len], "Bearer ");
    @memcpy(bytes["Bearer ".len..], token);
    return .{ .bytes = bytes };
}

fn validateBasicCredential(credential: BasicCredential, limits: Limits) Error!void {
    if (credential.username.len == 0 or
        credential.username.len > limits.max_decoded_credential_bytes or
        credential.secret.len > limits.max_decoded_credential_bytes or
        std.mem.indexOfScalar(u8, credential.username, ':') != null or
        containsUnsafeText(credential.username) or
        containsUnsafeText(credential.secret))
    {
        return error.InvalidCredential;
    }
}

fn copySuppliedCredential(
    allocator: Allocator,
    supplied: SuppliedCredential,
    limits: Limits,
) Error!OwnedCredential {
    switch (supplied) {
        .basic => |basic| {
            try validateBasicCredential(basic, limits);
            const username = try allocator.dupe(u8, basic.username);
            errdefer secureFree(allocator, username);
            const secret = try allocator.dupe(u8, basic.secret);
            return .{ .basic = .{ .username = username, .secret = secret } };
        },
        .bearer_token => |token| {
            if (!validBearerToken(token, limits.max_token_bytes)) return error.InvalidToken;
            return .{ .bearer_token = try allocator.dupe(u8, token) };
        },
    }
}

pub const Token = struct {
    value: []u8,
    expires_in: ?u64,

    pub fn deinit(self: *Token, allocator: Allocator) void {
        secureFree(allocator, self.value);
        self.* = undefined;
    }

    pub fn format(_: Token, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.writeAll("<token:redacted>");
    }
};

pub fn parseTokenResponse(
    allocator: Allocator,
    bytes: []const u8,
    limits: Limits,
) Error!Token {
    try limits.validate();
    if (bytes.len > limits.max_token_response_bytes) return error.TokenResponseTooLarge;
    const Document = struct {
        token: ?[]const u8 = null,
        access_token: ?[]const u8 = null,
        expires_in: ?u64 = null,
    };
    var parsed = std.json.parseFromSlice(Document, allocator, bytes, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidTokenResponse;
    defer parsed.deinit();

    const value = if (parsed.value.token) |token| blk: {
        if (parsed.value.access_token) |access_token| {
            if (!std.mem.eql(u8, token, access_token)) return error.InvalidTokenResponse;
        }
        break :blk token;
    } else parsed.value.access_token orelse return error.InvalidTokenResponse;
    if (!validBearerToken(value, limits.max_token_bytes)) return error.InvalidTokenResponse;
    return .{
        .value = try allocator.dupe(u8, value),
        .expires_in = parsed.value.expires_in,
    };
}

fn validBearerToken(value: []const u8, limit: usize) bool {
    if (value.len == 0 or value.len > limit) return false;
    var padded = false;
    for (value) |byte| {
        if (byte == '=') {
            padded = true;
            continue;
        }
        if (padded) return false;
        if (!std.ascii.isAlphanumeric(byte) and
            byte != '-' and byte != '.' and byte != '_' and byte != '~' and
            byte != '+' and byte != '/')
        {
            return false;
        }
    }
    return !padded or value[0] != '=';
}

/// Builds the token-service URL while preserving every canonical scope.
pub fn buildBearerTokenUrlAlloc(
    allocator: Allocator,
    realm: []const u8,
    service: ?[]const u8,
    scopes: []const []const u8,
) Error![]u8 {
    try validateTokenRealm(realm);
    const uri = std.Uri.parse(realm) catch unreachable;

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    output.writer.writeAll(realm) catch return error.OutOfMemory;
    var needs_separator = uri.query == null;
    if (service) |value| {
        appendQueryParameter(&output.writer, &needs_separator, "service", value) catch
            return error.OutOfMemory;
    }
    for (scopes) |scope| {
        appendQueryParameter(&output.writer, &needs_separator, "scope", scope) catch
            return error.OutOfMemory;
    }
    return output.toOwnedSlice() catch return error.OutOfMemory;
}

fn validateTokenRealm(realm: []const u8) Error!void {
    const uri = std.Uri.parse(realm) catch return error.InvalidTokenRealm;
    if ((!std.ascii.eqlIgnoreCase(uri.scheme, "https") and
        !std.ascii.eqlIgnoreCase(uri.scheme, "http")) or
        uri.host == null or uri.user != null or uri.password != null or
        uri.fragment != null or containsControl(realm))
    {
        return error.InvalidTokenRealm;
    }
}

fn appendQueryParameter(
    writer: *Io.Writer,
    needs_separator: *bool,
    name: []const u8,
    value: []const u8,
) Io.Writer.Error!void {
    try writer.writeByte(if (needs_separator.*) '?' else '&');
    needs_separator.* = false;
    try writeQueryComponent(writer, name);
    try writer.writeByte('=');
    try writeQueryComponent(writer, value);
}

fn writeQueryComponent(writer: *Io.Writer, value: []const u8) Io.Writer.Error!void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or
            byte == '_' or byte == '~')
        {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        }
    }
}

fn secureFree(allocator: Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    allocator.free(bytes);
}

fn containsControl(value: []const u8) bool {
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) return true;
    }
    return false;
}

fn containsUnsafeText(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, 0) != null or
        std.mem.indexOfScalar(u8, value, '\r') != null or
        std.mem.indexOfScalar(u8, value, '\n') != null;
}

pub const CredentialTarget = struct {
    authority: []const u8,
    repository: []const u8,
};

pub const IdentityTokenPolicy = enum {
    reject,
};

pub const FileReadError = error{
    OutOfMemory,
    FileNotFound,
    AccessDenied,
    InputTooLarge,
    ReadFailed,
};

pub const FileReader = struct {
    context: ?*anyopaque = null,
    read: *const fn (
        context: ?*anyopaque,
        allocator: Allocator,
        io: Io,
        path: []const u8,
        limit: usize,
    ) FileReadError![]u8 = readFileDefault,
};

pub const ProcessResult = struct {
    stdout: []u8,

    pub fn deinit(self: *ProcessResult, allocator: Allocator) void {
        secureFree(allocator, self.stdout);
        self.* = undefined;
    }
};

pub const ProcessError = error{
    OutOfMemory,
    Failed,
    DeadlineExceeded,
    OutputTooLarge,
};

/// Helper execution boundary. The implementation must kill and reap the
/// process before returning `DeadlineExceeded`, bound both stdout and stderr
/// by `max_output`, and never include stderr in its returned error.
pub const ProcessRunner = struct {
    context: ?*anyopaque = null,
    run: *const fn (
        context: ?*anyopaque,
        allocator: Allocator,
        io: Io,
        argv: []const []const u8,
        stdin_data: []const u8,
        max_output: usize,
        timeout_ns: u64,
    ) ProcessError!ProcessResult = runProcessDefault,
};

pub const PathFlavor = enum {
    posix,
    windows,

    pub fn native() PathFlavor {
        return if (native_os == .windows) .windows else .posix;
    }
};

pub const ResolutionContext = struct {
    io: Io,
    environment: ?*const std.process.Environ.Map = null,
    files: FileReader = .{},
    process: ProcessRunner = .{},
    path_flavor: PathFlavor = PathFlavor.native(),
    identity_tokens: IdentityTokenPolicy = .reject,
};

const NormalizedTarget = struct {
    authority: []u8,
    repository: []const u8,

    fn deinit(self: *NormalizedTarget, allocator: Allocator) void {
        allocator.free(self.authority);
        self.* = undefined;
    }
};

/// Applies the mutually exclusive credential policy. `none` and `supplied`
/// return before inspecting environment, files, or process boundaries.
pub fn resolveCredential(
    allocator: Allocator,
    policy: CredentialPolicy,
    target: CredentialTarget,
    context: ResolutionContext,
    limits: Limits,
) Error!?ResolvedCredential {
    try limits.validate();
    switch (policy) {
        .none => return null,
        .supplied => |supplied| return .{
            .source = .supplied,
            .credential = try copySuppliedCredential(allocator, supplied, limits),
        },
        .auth_file => |path| {
            var normalized = try normalizeTarget(allocator, target);
            defer normalized.deinit(allocator);
            const credential = try findCredentialInFile(
                allocator,
                context,
                path,
                normalized,
                limits,
                true,
            ) orelse return error.CredentialNotFound;
            return .{ .source = .explicit_auth_file, .credential = credential };
        },
        .discover => {
            var normalized = try normalizeTarget(allocator, target);
            defer normalized.deinit(allocator);
            return discoverCredential(allocator, context, normalized, limits);
        },
    }
}

fn discoverCredential(
    allocator: Allocator,
    context: ResolutionContext,
    target: NormalizedTarget,
    limits: Limits,
) Error!?ResolvedCredential {
    const environment = context.environment;
    if (environment) |env| {
        if (env.get("REGISTRY_AUTH_FILE")) |path| {
            const credential = try findCredentialInFile(
                allocator,
                context,
                path,
                target,
                limits,
                true,
            ) orelse return error.CredentialNotFound;
            return .{ .source = .registry_auth_file, .credential = credential };
        }
    }

    if (environment) |env| {
        if (env.get("XDG_RUNTIME_DIR")) |runtime_dir| {
            const path = try joinPathAlloc(
                allocator,
                context.path_flavor,
                &.{ runtime_dir, "containers", "auth.json" },
                limits.max_path_bytes,
            );
            defer allocator.free(path);
            if (try findCredentialInFile(allocator, context, path, target, limits, false)) |credential| {
                return .{ .source = .containers_runtime, .credential = credential };
            }
        }
    }

    const home = if (environment) |env|
        env.get("HOME") orelse env.get("USERPROFILE")
    else
        null;

    if (environment) |env| {
        if (env.get("XDG_CONFIG_HOME")) |config_home| {
            const path = try joinPathAlloc(
                allocator,
                context.path_flavor,
                &.{ config_home, "containers", "auth.json" },
                limits.max_path_bytes,
            );
            defer allocator.free(path);
            if (try findCredentialInFile(allocator, context, path, target, limits, false)) |credential| {
                return .{ .source = .containers_config, .credential = credential };
            }
        } else if (home) |home_path| {
            const path = try joinPathAlloc(
                allocator,
                context.path_flavor,
                &.{ home_path, ".config", "containers", "auth.json" },
                limits.max_path_bytes,
            );
            defer allocator.free(path);
            if (try findCredentialInFile(allocator, context, path, target, limits, false)) |credential| {
                return .{ .source = .containers_config, .credential = credential };
            }
        }
    } else if (home) |home_path| {
        const path = try joinPathAlloc(
            allocator,
            context.path_flavor,
            &.{ home_path, ".config", "containers", "auth.json" },
            limits.max_path_bytes,
        );
        defer allocator.free(path);
        if (try findCredentialInFile(allocator, context, path, target, limits, false)) |credential| {
            return .{ .source = .containers_config, .credential = credential };
        }
    }

    if (environment) |env| {
        if (env.get("DOCKER_CONFIG")) |docker_config_dir| {
            const path = try joinPathAlloc(
                allocator,
                context.path_flavor,
                &.{ docker_config_dir, "config.json" },
                limits.max_path_bytes,
            );
            defer allocator.free(path);
            if (try findCredentialInFile(allocator, context, path, target, limits, false)) |credential| {
                return .{ .source = .docker_config, .credential = credential };
            }
        } else if (home) |home_path| {
            const path = try joinPathAlloc(
                allocator,
                context.path_flavor,
                &.{ home_path, ".docker", "config.json" },
                limits.max_path_bytes,
            );
            defer allocator.free(path);
            if (try findCredentialInFile(allocator, context, path, target, limits, false)) |credential| {
                return .{ .source = .docker_config, .credential = credential };
            }
        }
    } else if (home) |home_path| {
        const path = try joinPathAlloc(
            allocator,
            context.path_flavor,
            &.{ home_path, ".docker", "config.json" },
            limits.max_path_bytes,
        );
        defer allocator.free(path);
        if (try findCredentialInFile(allocator, context, path, target, limits, false)) |credential| {
            return .{ .source = .docker_config, .credential = credential };
        }
    }

    if (home) |home_path| {
        const path = try joinPathAlloc(
            allocator,
            context.path_flavor,
            &.{ home_path, ".dockercfg" },
            limits.max_path_bytes,
        );
        defer allocator.free(path);
        if (try findCredentialInFile(allocator, context, path, target, limits, false)) |credential| {
            return .{ .source = .legacy_dockercfg, .credential = credential };
        }
    }
    return null;
}

fn findCredentialInFile(
    allocator: Allocator,
    context: ResolutionContext,
    path: []const u8,
    target: NormalizedTarget,
    limits: Limits,
    required: bool,
) Error!?OwnedCredential {
    if (path.len == 0 or path.len > limits.max_path_bytes or containsUnsafeText(path)) {
        return error.InvalidAuthFile;
    }
    const bytes = context.files.read(
        context.files.context,
        allocator,
        context.io,
        path,
        limits.max_auth_file_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => {
            if (required) return error.AuthFileNotFound;
            return null;
        },
        error.InputTooLarge => return error.AuthFileTooLarge,
        error.AccessDenied, error.ReadFailed => return error.InvalidAuthFile,
    };
    defer secureFree(allocator, bytes);
    if (bytes.len > limits.max_auth_file_bytes) return error.AuthFileTooLarge;
    return parseCredentialFile(allocator, context, bytes, target, limits);
}

fn parseCredentialFile(
    allocator: Allocator,
    context: ResolutionContext,
    bytes: []const u8,
    target: NormalizedTarget,
    limits: Limits,
) Error!?OwnedCredential {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch
        return error.InvalidAuthFile;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidAuthFile,
    };

    if (root.get("credHelpers")) |helpers| {
        const helper_object = switch (helpers) {
            .object => |object| object,
            else => return error.InvalidAuthFile,
        };
        if (try selectMostSpecific(allocator, helper_object, target)) |entry| {
            const helper = switch (entry.value) {
                .string => |value| value,
                else => return error.InvalidAuthFile,
            };
            return try runCredentialHelper(
                allocator,
                context,
                helper,
                entry.key,
                limits,
            );
        }
    }

    if (root.get("credsStore")) |store| {
        const helper = switch (store) {
            .string => |value| value,
            else => return error.InvalidAuthFile,
        };
        if (helper.len != 0) {
            return try runCredentialHelper(
                allocator,
                context,
                helper,
                globalCredentialHelperKey(target.authority),
                limits,
            );
        }
    }

    if (root.get("auths")) |auths| {
        const auth_object = switch (auths) {
            .object => |object| object,
            else => return error.InvalidAuthFile,
        };
        if (try selectMostSpecific(allocator, auth_object, target)) |entry| {
            return @as(?OwnedCredential, try parseInlineCredential(
                allocator,
                entry.value,
                context.identity_tokens,
                limits,
            ));
        }
    } else if (try selectMostSpecific(allocator, root, target)) |entry| {
        return @as(?OwnedCredential, try parseInlineCredential(
            allocator,
            entry.value,
            context.identity_tokens,
            limits,
        ));
    }
    return null;
}

const ObjectEntry = struct {
    key: []const u8,
    value: std.json.Value,
    path_score: usize,
    authority_score: u8,
};

fn selectMostSpecific(
    allocator: Allocator,
    object: std.json.ObjectMap,
    target: NormalizedTarget,
) Error!?ObjectEntry {
    var result: ?ObjectEntry = null;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const candidate = entry.key_ptr.*;
        const match = credentialKeyMatch(allocator, candidate, target) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidAuthority => continue,
            else => return err,
        } orelse continue;
        const proposed: ObjectEntry = .{
            .key = candidate,
            .value = entry.value_ptr.*,
            .path_score = match.path_score,
            .authority_score = match.authority_score,
        };
        if (result == null or entryPreferred(proposed, result.?)) result = proposed;
    }
    return result;
}

fn entryPreferred(candidate: ObjectEntry, existing: ObjectEntry) bool {
    if (candidate.path_score != existing.path_score) {
        return candidate.path_score > existing.path_score;
    }
    if (candidate.authority_score != existing.authority_score) {
        return candidate.authority_score > existing.authority_score;
    }
    return std.mem.order(u8, candidate.key, existing.key) == .lt;
}

const KeyMatch = struct {
    path_score: usize,
    authority_score: u8,
};

fn credentialKeyMatch(
    allocator: Allocator,
    key: []const u8,
    target: NormalizedTarget,
) Error!?KeyMatch {
    var candidate = key;
    if (startsWithIgnoreCase(candidate, "https://")) {
        candidate = candidate["https://".len..];
    } else if (startsWithIgnoreCase(candidate, "http://")) {
        candidate = candidate["http://".len..];
    } else if (std.mem.indexOf(u8, candidate, "://") != null) {
        return error.InvalidAuthority;
    }
    while (candidate.len > 0 and (candidate[candidate.len - 1] == '/' or
        candidate[candidate.len - 1] == '\\'))
    {
        candidate = candidate[0 .. candidate.len - 1];
    }
    if (candidate.len == 0 or containsControl(candidate) or
        std.mem.indexOfScalar(u8, candidate, '?') != null or
        std.mem.indexOfScalar(u8, candidate, '#') != null or
        std.mem.indexOfScalar(u8, candidate, '@') != null)
    {
        return error.InvalidAuthority;
    }

    const slash = std.mem.indexOfAny(u8, candidate, "/\\");
    const candidate_authority = if (slash) |index| candidate[0..index] else candidate;
    var candidate_path = if (slash) |index| candidate[index + 1 ..] else "";
    const normalized_authority = try normalizeAuthorityAlloc(allocator, candidate_authority);
    defer allocator.free(normalized_authority);

    const authority_score: u8 = if (std.mem.eql(u8, normalized_authority, target.authority))
        2
    else if (isDockerHubAlias(normalized_authority) and isDockerHubAlias(target.authority))
        1
    else
        return null;

    if (isDockerHubAlias(normalized_authority) and
        (std.mem.eql(u8, candidate_path, "v1") or
            std.mem.eql(u8, candidate_path, "v2")))
    {
        candidate_path = "";
    }
    if (candidate_path.len != 0 and
        (!std.mem.startsWith(u8, target.repository, candidate_path) or
            (target.repository.len != candidate_path.len and
                target.repository[candidate_path.len] != '/')))
    {
        return null;
    }
    return .{
        .path_score = candidate_path.len,
        .authority_score = authority_score,
    };
}

fn parseInlineCredential(
    allocator: Allocator,
    value: std.json.Value,
    identity_policy: IdentityTokenPolicy,
    limits: Limits,
) Error!OwnedCredential {
    const object = switch (value) {
        .object => |result| result,
        else => return error.UnsupportedCredentialType,
    };

    if (object.get("identitytoken") != null or
        object.get("identityToken") != null or
        object.get("registrytoken") != null or
        object.get("registryToken") != null)
    {
        switch (identity_policy) {
            .reject => return error.UnsupportedCredentialType,
        }
    }

    const auth_value = object.get("auth");
    const username_value = object.get("username");
    const password_value = object.get("password");
    if (auth_value != null and (username_value != null or password_value != null)) {
        return error.InvalidAuthFile;
    }
    if ((username_value == null) != (password_value == null)) {
        return error.UnsupportedCredentialType;
    }

    if (auth_value) |raw_auth| {
        const encoded = switch (raw_auth) {
            .string => |result| result,
            else => return error.InvalidAuthFile,
        };
        return .{ .basic = try decodeInlineBasic(allocator, encoded, limits) };
    }

    if (username_value) |raw_username| {
        const username = switch (raw_username) {
            .string => |result| result,
            else => return error.InvalidAuthFile,
        };
        const password = switch (password_value.?) {
            .string => |result| result,
            else => return error.InvalidAuthFile,
        };
        try validateBasicCredential(.{ .username = username, .secret = password }, limits);
        const owned_username = try allocator.dupe(u8, username);
        errdefer secureFree(allocator, owned_username);
        return .{ .basic = .{
            .username = owned_username,
            .secret = try allocator.dupe(u8, password),
        } };
    }
    return error.UnsupportedCredentialType;
}

fn decodeInlineBasic(
    allocator: Allocator,
    encoded: []const u8,
    limits: Limits,
) Error!OwnedBasicCredential {
    if (encoded.len == 0 or encoded.len > limits.max_auth_file_bytes) {
        return error.InvalidCredential;
    }
    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch
        return error.InvalidCredential;
    if (decoded_size == 0 or decoded_size > limits.max_decoded_credential_bytes) {
        return error.InvalidCredential;
    }
    const decoded = try allocator.alloc(u8, decoded_size);
    defer secureFree(allocator, decoded);
    std.base64.standard.Decoder.decode(decoded, encoded) catch return error.InvalidCredential;

    const canonical_size = std.base64.standard.Encoder.calcSize(decoded.len);
    if (canonical_size != encoded.len) return error.InvalidCredential;
    const canonical = try allocator.alloc(u8, canonical_size);
    defer allocator.free(canonical);
    _ = std.base64.standard.Encoder.encode(canonical, decoded);
    if (!std.mem.eql(u8, canonical, encoded)) return error.InvalidCredential;

    const separator = std.mem.indexOfScalar(u8, decoded, ':') orelse
        return error.InvalidCredential;
    const basic: BasicCredential = .{
        .username = decoded[0..separator],
        .secret = decoded[separator + 1 ..],
    };
    try validateBasicCredential(basic, limits);
    const username = try allocator.dupe(u8, basic.username);
    errdefer secureFree(allocator, username);
    return .{ .username = username, .secret = try allocator.dupe(u8, basic.secret) };
}

fn runCredentialHelper(
    allocator: Allocator,
    context: ResolutionContext,
    helper: []const u8,
    server_key: []const u8,
    limits: Limits,
) Error!OwnedCredential {
    if (!validHelperName(helper, limits.max_helper_name_bytes)) {
        return error.InvalidCredentialHelperName;
    }
    if (server_key.len == 0 or server_key.len > limits.max_helper_input_bytes or
        containsUnsafeText(server_key))
    {
        return error.CredentialHelperInputTooLarge;
    }

    const executable = try std.fmt.allocPrint(allocator, "docker-credential-{s}", .{helper});
    defer allocator.free(executable);
    const argv = [_][]const u8{ executable, "get" };
    const input = try allocator.alloc(u8, server_key.len + 1);
    defer secureFree(allocator, input);
    @memcpy(input[0..server_key.len], server_key);
    input[server_key.len] = '\n';

    var result = context.process.run(
        context.process.context,
        allocator,
        context.io,
        &argv,
        input,
        limits.max_helper_output_bytes,
        limits.helper_timeout_ns,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.OutputTooLarge => return error.CredentialHelperOutputTooLarge,
        error.DeadlineExceeded => return error.CredentialHelperDeadlineExceeded,
        error.Failed => return error.CredentialHelperFailed,
    };
    defer result.deinit(allocator);
    if (result.stdout.len > limits.max_helper_output_bytes) {
        return error.CredentialHelperOutputTooLarge;
    }
    return .{ .basic = try parseHelperOutput(
        allocator,
        result.stdout,
        context.identity_tokens,
        limits,
    ) };
}

fn validHelperName(value: []const u8, limit: usize) bool {
    if (value.len == 0 or value.len > limit or !std.ascii.isAlphanumeric(value[0])) {
        return false;
    }
    for (value[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

fn parseHelperOutput(
    allocator: Allocator,
    bytes: []const u8,
    identity_policy: IdentityTokenPolicy,
    limits: Limits,
) Error!OwnedBasicCredential {
    if (bytes.len == 0 or bytes.len > limits.max_helper_output_bytes) {
        return error.InvalidCredentialHelperOutput;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch
        return error.InvalidCredentialHelperOutput;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidCredentialHelperOutput,
    };
    if (object.get("ServerURL")) |server_url| {
        const value = switch (server_url) {
            .string => |string| string,
            else => return error.InvalidCredentialHelperOutput,
        };
        if (value.len == 0 or containsUnsafeText(value)) {
            return error.InvalidCredentialHelperOutput;
        }
    }
    const username_value = object.get("Username") orelse
        return error.InvalidCredentialHelperOutput;
    const secret_value = object.get("Secret") orelse
        return error.InvalidCredentialHelperOutput;
    const username = switch (username_value) {
        .string => |value| value,
        else => return error.InvalidCredentialHelperOutput,
    };
    const secret = switch (secret_value) {
        .string => |value| value,
        else => return error.InvalidCredentialHelperOutput,
    };
    if (std.mem.eql(u8, username, "<token>")) {
        switch (identity_policy) {
            .reject => return error.UnsupportedCredentialType,
        }
    }
    validateBasicCredential(.{ .username = username, .secret = secret }, limits) catch
        return error.InvalidCredentialHelperOutput;
    const owned_username = try allocator.dupe(u8, username);
    errdefer secureFree(allocator, owned_username);
    return .{
        .username = owned_username,
        .secret = try allocator.dupe(u8, secret),
    };
}

fn globalCredentialHelperKey(authority: []const u8) []const u8 {
    return if (isDockerHubAlias(authority))
        "https://index.docker.io/v1/"
    else
        authority;
}

fn isDockerHubAlias(value: []const u8) bool {
    return std.mem.eql(u8, value, "docker.io") or
        std.mem.eql(u8, value, "index.docker.io") or
        std.mem.eql(u8, value, "registry-1.docker.io");
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn normalizeTarget(allocator: Allocator, target: CredentialTarget) Error!NormalizedTarget {
    if (target.repository.len == 0 or target.repository.len > 1024 or
        target.repository[0] == '/' or
        target.repository[target.repository.len - 1] == '/' or
        containsControl(target.repository) or
        std.mem.indexOf(u8, target.repository, "//") != null)
    {
        return error.InvalidRepository;
    }
    return .{
        .authority = try normalizeAuthorityAlloc(allocator, target.authority),
        .repository = target.repository,
    };
}

pub fn normalizeAuthorityAlloc(
    allocator: Allocator,
    authority: []const u8,
) Error![]u8 {
    if (authority.len == 0 or authority.len > 512 or containsControl(authority) or
        std.mem.indexOf(u8, authority, "://") != null or
        std.mem.indexOfAny(u8, authority, "/\\@?#") != null)
    {
        return error.InvalidAuthority;
    }

    var host: []const u8 = undefined;
    var port: ?u16 = null;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse
            return error.InvalidAuthority;
        if (close == 1) return error.InvalidAuthority;
        _ = std.Io.net.IpAddress.parseIp6(authority[1..close], 0) catch
            return error.InvalidAuthority;
        host = authority[0 .. close + 1];
        if (close + 1 < authority.len) {
            if (authority[close + 1] != ':' or close + 2 >= authority.len) {
                return error.InvalidAuthority;
            }
            port = parsePort(authority[close + 2 ..]) orelse return error.InvalidAuthority;
        }
    } else {
        if (std.mem.indexOfAny(u8, authority, "[]") != null) return error.InvalidAuthority;
        const colon = std.mem.indexOfScalar(u8, authority, ':');
        if (colon) |index| {
            if (std.mem.indexOfScalarPos(u8, authority, index + 1, ':') != null) {
                return error.InvalidAuthority;
            }
            host = authority[0..index];
            port = parsePort(authority[index + 1 ..]) orelse return error.InvalidAuthority;
        } else {
            host = authority;
        }
        if (!validRegistryHost(host)) return error.InvalidAuthority;
    }

    const port_length: usize = if (port) |value| std.fmt.count(":{d}", .{value}) else 0;
    const normalized = try allocator.alloc(u8, host.len + port_length);
    for (host, 0..) |byte, index| normalized[index] = std.ascii.toLower(byte);
    if (port) |value| {
        _ = std.fmt.bufPrint(normalized[host.len..], ":{d}", .{value}) catch unreachable;
    }
    return normalized;
}

fn parsePort(value: []const u8) ?u16 {
    if (value.len == 0 or value.len > 5) return null;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    const port = std.fmt.parseInt(u16, value, 10) catch return null;
    return if (port == 0) null else port;
}

fn validRegistryHost(host: []const u8) bool {
    if (host.len == 0 or host[0] == '.' or host[host.len - 1] == '.') return false;
    for (host) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-') return false;
    }
    return true;
}

fn joinPathAlloc(
    allocator: Allocator,
    flavor: PathFlavor,
    parts: []const []const u8,
    limit: usize,
) Error![]u8 {
    const separator: u8 = if (flavor == .windows) '\\' else '/';
    var total: usize = 0;
    for (parts, 0..) |part, index| {
        if (part.len == 0 or containsUnsafeText(part)) return error.InvalidAuthFile;
        total = std.math.add(usize, total, part.len) catch return error.PathTooLong;
        if (index != 0 and parts[index - 1][parts[index - 1].len - 1] != '/' and
            parts[index - 1][parts[index - 1].len - 1] != '\\')
        {
            total = std.math.add(usize, total, 1) catch return error.PathTooLong;
        }
        if (total > limit) return error.PathTooLong;
    }
    const result = try allocator.alloc(u8, total);
    var offset: usize = 0;
    for (parts, 0..) |part, index| {
        if (index != 0 and offset != 0 and result[offset - 1] != '/' and
            result[offset - 1] != '\\')
        {
            result[offset] = separator;
            offset += 1;
        }
        @memcpy(result[offset..][0..part.len], part);
        offset += part.len;
    }
    return result;
}

fn readFileDefault(
    _: ?*anyopaque,
    allocator: Allocator,
    io: Io,
    path: []const u8,
    limit: usize,
) FileReadError![]u8 {
    var file = if (std.fs.path.isAbsolute(path))
        Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            error.AccessDenied => return error.AccessDenied,
            else => return error.ReadFailed,
        }
    else
        Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            error.AccessDenied => return error.AccessDenied,
            else => return error.ReadFailed,
        };
    defer file.close(io);
    const size = file.length(io) catch return error.ReadFailed;
    if (size > limit or size > std.math.maxInt(usize)) return error.InputTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(bytes);
    const read_count = file.readPositionalAll(io, bytes, 0) catch return error.ReadFailed;
    if (read_count != bytes.len) return error.ReadFailed;
    return bytes;
}

fn runProcessDefault(
    _: ?*anyopaque,
    allocator: Allocator,
    io: Io,
    argv: []const []const u8,
    stdin_data: []const u8,
    max_output: usize,
    timeout_ns: u64,
) ProcessError!ProcessResult {
    const ProcessOutcome = anyerror!ProcessResult;
    const TimerOutcome = Io.Cancelable!void;
    const Selected = union(enum) {
        process: ProcessOutcome,
        timer: TimerOutcome,
    };
    var results: [2]Selected = undefined;
    var select: Io.Select(Selected) = .init(io, &results);

    select.async(.process, runProcessBody, .{
        allocator,
        io,
        argv,
        stdin_data,
        max_output,
    });
    select.async(.timer, helperTimer, .{ io, timeout_ns });

    const first = select.await() catch {
        while (select.cancel()) |remaining| cleanupSelected(allocator, remaining);
        return error.Failed;
    };
    switch (first) {
        .process => |outcome| {
            while (select.cancel()) |remaining| cleanupSelected(allocator, remaining);
            return mapProcessOutcome(outcome);
        },
        .timer => |outcome| {
            _ = outcome catch {};
            while (select.cancel()) |remaining| cleanupSelected(allocator, remaining);
            return error.DeadlineExceeded;
        },
    }
}

fn helperTimer(io: Io, timeout_ns: u64) Io.Cancelable!void {
    return Io.sleep(
        io,
        .fromNanoseconds(@intCast(timeout_ns)),
        .awake,
    );
}

fn cleanupSelected(
    allocator: Allocator,
    selected: anytype,
) void {
    switch (selected) {
        .process => |outcome| {
            if (outcome) |result_value| {
                var result = result_value;
                result.deinit(allocator);
            } else |_| {}
        },
        .timer => |outcome| {
            _ = outcome catch {};
        },
    }
}

fn mapProcessOutcome(outcome: anyerror!ProcessResult) ProcessError!ProcessResult {
    return outcome catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CredentialHelperOutputTooLarge => error.OutputTooLarge,
        else => error.Failed,
    };
}

fn runProcessBody(
    allocator: Allocator,
    io: Io,
    argv: []const []const u8,
    stdin_data: []const u8,
    max_output: usize,
) !ProcessResult {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var stdin = child.stdin.?;
    child.stdin = null;
    try stdin.writeStreamingAll(io, stdin_data);
    stdin.close(io);

    var streams_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var streams: Io.File.MultiReader = undefined;
    streams.init(
        allocator,
        io,
        streams_buffer.toStreams(),
        &.{ child.stdout.?, child.stderr.? },
    );
    const stdout = streams.reader(0);
    const stderr = streams.reader(1);
    defer {
        std.crypto.secureZero(u8, stdout.buffered());
        std.crypto.secureZero(u8, stderr.buffered());
        streams.deinit();
    }

    while (streams.fill(256, .none)) |_| {
        if (stdout.buffered().len > max_output or stderr.buffered().len > max_output) {
            return error.CredentialHelperOutputTooLarge;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try streams.checkAnyError();
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.CredentialHelperFailed,
        else => return error.CredentialHelperFailed,
    }
    const output = try streams.toOwnedSlice(0);
    errdefer secureFree(allocator, output);
    if (output.len > max_output) return error.CredentialHelperOutputTooLarge;
    return .{ .stdout = output };
}

pub const TokenCacheKey = struct {
    context_id: u64,
    registry_origin: []const u8,
    realm: []const u8,
    service: ?[]const u8,
    scopes: []const []const u8,
    credential_generation: u64,
};

pub const TokenCache = struct {
    allocator: Allocator,
    max_entries: usize,
    sequence: u64 = 0,
    entries: std.array_list.Managed(Entry),

    const Entry = struct {
        context_id: u64,
        registry_origin: []u8,
        realm: []u8,
        service: ?[]u8,
        scopes: [][]u8,
        credential_generation: u64,
        token: []u8,
        expires_at: i64,
        sequence: u64,

        fn deinit(self: *Entry, allocator: Allocator) void {
            allocator.free(self.registry_origin);
            allocator.free(self.realm);
            if (self.service) |service| allocator.free(service);
            for (self.scopes) |scope| allocator.free(scope);
            allocator.free(self.scopes);
            secureFree(allocator, self.token);
            self.* = undefined;
        }
    };

    pub fn init(allocator: Allocator, limits: Limits) Error!TokenCache {
        try limits.validate();
        return .{
            .allocator = allocator,
            .max_entries = limits.max_token_cache_entries,
            .entries = std.array_list.Managed(Entry).init(allocator),
        };
    }

    pub fn deinit(self: *TokenCache) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit();
        self.* = undefined;
    }

    pub fn get(
        self: *TokenCache,
        now_seconds: i64,
        key: TokenCacheKey,
    ) ?[]const u8 {
        self.purgeExpired(now_seconds);
        for (self.entries.items) |entry| {
            if (sameTokenKey(entry, key)) return entry.token;
        }
        return null;
    }

    pub fn put(
        self: *TokenCache,
        now_seconds: i64,
        key: TokenCacheKey,
        token: Token,
        limits: Limits,
    ) Error![]const u8 {
        try validateTokenKey(key);
        if (!validBearerToken(token.value, limits.max_token_bytes)) return error.InvalidToken;
        self.purgeExpired(now_seconds);

        const ttl = @min(token.expires_in orelse default_token_ttl_seconds, max_token_ttl_seconds);
        const expires_at = std.math.add(i64, now_seconds, @intCast(ttl)) catch
            std.math.maxInt(i64);
        for (self.entries.items) |*entry| {
            if (!sameTokenKey(entry.*, key)) continue;
            const replacement = try self.allocator.dupe(u8, token.value);
            secureFree(self.allocator, entry.token);
            entry.token = replacement;
            entry.expires_at = expires_at;
            self.sequence +%= 1;
            entry.sequence = self.sequence;
            return entry.token;
        }

        if (self.entries.items.len >= self.max_entries) self.evictOldest();
        var entry = try copyTokenEntry(
            self.allocator,
            key,
            token.value,
            expires_at,
            self.sequence +% 1,
        );
        errdefer entry.deinit(self.allocator);
        self.sequence +%= 1;
        try self.entries.append(entry);
        return self.entries.items[self.entries.items.len - 1].token;
    }

    pub fn invalidate(self: *TokenCache, key: TokenCacheKey) void {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            if (sameTokenKey(self.entries.items[index], key)) {
                var removed = self.entries.orderedRemove(index);
                removed.deinit(self.allocator);
            } else {
                index += 1;
            }
        }
    }

    pub fn clearContext(self: *TokenCache, context_id: u64) void {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            if (self.entries.items[index].context_id == context_id) {
                var removed = self.entries.orderedRemove(index);
                removed.deinit(self.allocator);
            } else {
                index += 1;
            }
        }
    }

    pub fn clear(self: *TokenCache) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.clearRetainingCapacity();
    }

    fn purgeExpired(self: *TokenCache, now_seconds: i64) void {
        const cutoff = std.math.add(i64, now_seconds, token_expiry_skew_seconds) catch
            std.math.maxInt(i64);
        var index: usize = 0;
        while (index < self.entries.items.len) {
            if (self.entries.items[index].expires_at <= cutoff) {
                var removed = self.entries.orderedRemove(index);
                removed.deinit(self.allocator);
            } else {
                index += 1;
            }
        }
    }

    fn evictOldest(self: *TokenCache) void {
        var oldest_index: usize = 0;
        for (self.entries.items[1..], 1..) |entry, index| {
            if (entry.sequence < self.entries.items[oldest_index].sequence) {
                oldest_index = index;
            }
        }
        var removed = self.entries.orderedRemove(oldest_index);
        removed.deinit(self.allocator);
    }
};

fn copyTokenEntry(
    allocator: Allocator,
    key: TokenCacheKey,
    token: []const u8,
    expires_at: i64,
    sequence: u64,
) Error!TokenCache.Entry {
    try validateTokenKey(key);
    const origin = try allocator.dupe(u8, key.registry_origin);
    errdefer allocator.free(origin);
    const realm = try allocator.dupe(u8, key.realm);
    errdefer allocator.free(realm);
    const service = if (key.service) |value| try allocator.dupe(u8, value) else null;
    errdefer if (service) |value| allocator.free(value);
    const scopes = try canonicalScopesAlloc(allocator, key.scopes);
    errdefer {
        for (scopes) |scope| allocator.free(scope);
        allocator.free(scopes);
    }
    const token_copy = try allocator.dupe(u8, token);
    errdefer secureFree(allocator, token_copy);
    return .{
        .context_id = key.context_id,
        .registry_origin = origin,
        .realm = realm,
        .service = service,
        .scopes = scopes,
        .credential_generation = key.credential_generation,
        .token = token_copy,
        .expires_at = expires_at,
        .sequence = sequence,
    };
}

fn validateTokenKey(key: TokenCacheKey) Error!void {
    if (key.registry_origin.len == 0 or key.realm.len == 0 or
        containsControl(key.registry_origin) or containsControl(key.realm))
    {
        return error.InvalidTokenRealm;
    }
    if (key.service) |service| {
        if (containsControl(service)) return error.InvalidTokenRealm;
    }
    for (key.scopes) |scope| {
        if (scope.len == 0 or containsControl(scope)) return error.InvalidTokenRealm;
    }
}

fn canonicalScopesAlloc(
    allocator: Allocator,
    scopes: []const []const u8,
) Allocator.Error![][]u8 {
    var result = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (result.items) |scope| allocator.free(scope);
        result.deinit();
    }
    for (scopes) |scope| {
        var duplicate = false;
        for (result.items) |existing| {
            if (std.mem.eql(u8, existing, scope)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) {
            const copy = try allocator.dupe(u8, scope);
            errdefer allocator.free(copy);
            try result.append(copy);
        }
    }
    std.mem.sort([]u8, result.items, {}, scopeLessThan);
    return result.toOwnedSlice();
}

fn sameTokenKey(entry: TokenCache.Entry, key: TokenCacheKey) bool {
    if (entry.context_id != key.context_id or
        entry.credential_generation != key.credential_generation or
        !std.mem.eql(u8, entry.registry_origin, key.registry_origin) or
        !std.mem.eql(u8, entry.realm, key.realm) or
        ((entry.service == null) != (key.service == null)))
    {
        return false;
    }
    if (entry.service) |service| {
        if (!std.mem.eql(u8, service, key.service.?)) return false;
    }
    return sameCanonicalScopes(entry.scopes, key.scopes);
}

fn sameCanonicalScopes(canonical: [][]u8, supplied: []const []const u8) bool {
    var unique_count: usize = 0;
    for (supplied, 0..) |scope, index| {
        var seen = false;
        for (supplied[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier, scope)) {
                seen = true;
                break;
            }
        }
        if (!seen) unique_count += 1;
    }
    if (unique_count != canonical.len) return false;
    for (canonical) |expected| {
        var found = false;
        for (supplied) |scope| {
            if (std.mem.eql(u8, expected, scope)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

pub const TokenAcquisitionError = error{
    OutOfMemory,
    AuthenticationFailed,
    DeadlineExceeded,
    InvalidResponse,
};

pub const TokenAcquirer = struct {
    context: ?*anyopaque = null,
    acquire: *const fn (
        context: ?*anyopaque,
        allocator: Allocator,
        request: TokenCacheKey,
    ) TokenAcquisitionError!Token,
};

/// Uses a caller-provided clock value and token acquirer. No HTTP or wall
/// clock access is performed by this module.
pub fn cachedOrAcquireToken(
    allocator: Allocator,
    cache: *TokenCache,
    now_seconds: i64,
    key: TokenCacheKey,
    acquirer: TokenAcquirer,
    limits: Limits,
) Error![]const u8 {
    if (cache.get(now_seconds, key)) |token| return token;
    var acquired = acquirer.acquire(acquirer.context, allocator, key) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidResponse => return error.InvalidTokenResponse,
        error.AuthenticationFailed, error.DeadlineExceeded => return error.TokenAcquisitionFailed,
    };
    defer acquired.deinit(allocator);
    return cache.put(now_seconds, key, acquired, limits);
}

test {
    std.testing.refAllDecls(@This());
}

test "WWW-Authenticate parses Basic and Bearer with RFC quoted escaping" {
    var parsed = try parseWwwAuthenticate(std.testing.allocator, &.{
        "bAsIc ReAlM=\"fallback\", BeArEr ReAlM=\"https://token.example/auth?x=1\", SERVICE=\"registry.example\", SCOPE=\"repository:two:pull,push\", scope=\"repository:one:pull\", note=\"a\\\\b\\\"c\"",
    });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.challenges.len);
    try std.testing.expect(parsed.challenges[0].isScheme("BASIC"));
    try std.testing.expectEqualStrings(
        "a\\b\"c",
        parsed.challenges[1].parameter("NOTE").?,
    );

    var selected = (try selectDistributionChallenge(std.testing.allocator, parsed)).?;
    defer selected.deinit();
    switch (selected) {
        .bearer => |bearer| {
            try std.testing.expectEqualStrings("https://token.example/auth?x=1", bearer.realm);
            try std.testing.expectEqualStrings("registry.example", bearer.service.?);
            try std.testing.expectEqual(@as(usize, 2), bearer.scopes.len);
            try std.testing.expectEqualStrings("repository:one:pull", bearer.scopes[0]);
            try std.testing.expectEqualStrings("repository:two:pull,push", bearer.scopes[1]);
        },
        .basic => return error.TestUnexpectedResult,
    }
}

test "challenge parser rejects duplicate singleton malformed and oversized input" {
    try std.testing.expectError(
        error.DuplicateChallengeParameter,
        parseWwwAuthenticate(
            std.testing.allocator,
            &.{"Bearer realm=\"https://one\", REALM=\"https://two\""},
        ),
    );
    try std.testing.expectError(
        error.MalformedChallenge,
        parseWwwAuthenticate(std.testing.allocator, &.{"Bearer realm=\"unterminated"}),
    );
    try std.testing.expectError(
        error.MalformedChallenge,
        parseWwwAuthenticate(
            std.testing.allocator,
            &.{"Bearer realm=\"https://token\"\r\nInjected: x"},
        ),
    );
    try std.testing.expectError(
        error.ChallengeTooLarge,
        parseChallenges(
            std.testing.allocator,
            &.{ "Basic realm=a", "Basic realm=b" },
            .{ .max_challenge_bytes = 20 },
        ),
    );
    try std.testing.expectError(
        error.TooManyChallengeParameters,
        parseChallenges(
            std.testing.allocator,
            &.{"Bearer realm=x,service=y"},
            .{ .max_parameters_per_challenge = 1 },
        ),
    );
    try std.testing.expectError(
        error.TooManyChallenges,
        parseChallenges(
            std.testing.allocator,
            &.{"Basic, Basic"},
            .{ .max_challenges = 1 },
        ),
    );
    try std.testing.expectError(
        error.ChallengeParameterTooLarge,
        parseChallenges(
            std.testing.allocator,
            &.{"Basic realm=\"12345\""},
            .{ .max_parameter_value_bytes = 4 },
        ),
    );
}

test "Bearer semantic errors never downgrade to offered Basic" {
    var missing_realm = try parseWwwAuthenticate(std.testing.allocator, &.{
        "Basic realm=\"fallback\", Bearer service=\"registry.example\"",
    });
    defer missing_realm.deinit();
    try std.testing.expectError(
        error.MissingBearerRealm,
        selectDistributionChallenge(std.testing.allocator, missing_realm),
    );

    var conflicting = try parseWwwAuthenticate(std.testing.allocator, &.{
        "Bearer realm=\"https://one\", Basic realm=\"fallback\"",
        "Bearer realm=\"https://two\"",
    });
    defer conflicting.deinit();
    try std.testing.expectError(
        error.ConflictingBearerChallenges,
        selectDistributionChallenge(std.testing.allocator, conflicting),
    );

    var invalid_realm = try parseWwwAuthenticate(std.testing.allocator, &.{
        "Basic realm=\"fallback\", Bearer realm=\"not-an-absolute-url\"",
    });
    defer invalid_realm.deinit();
    try std.testing.expectError(
        error.InvalidTokenRealm,
        selectDistributionChallenge(std.testing.allocator, invalid_realm),
    );

    var inconsistent_service = try parseWwwAuthenticate(std.testing.allocator, &.{
        "Bearer realm=\"https://token.example\", service=\"registry.example\"",
        "Bearer realm=\"https://token.example\"",
    });
    defer inconsistent_service.deinit();
    try std.testing.expectError(
        error.ConflictingBearerChallenges,
        selectDistributionChallenge(std.testing.allocator, inconsistent_service),
    );
}

test "challenge parser accepts token68 and canonicalizes repeated scopes" {
    var token68 = try parseWwwAuthenticate(std.testing.allocator, &.{"Negotiate YWJjZA=="});
    defer token68.deinit();
    try std.testing.expectEqualStrings("YWJjZA==", token68.challenges[0].token68.?);

    var bearer = try parseWwwAuthenticate(std.testing.allocator, &.{
        "Bearer realm=\"https://token\", scope=\"b\", scope=\"a\", scope=\"b\"",
    });
    defer bearer.deinit();
    var selected = (try selectDistributionChallenge(std.testing.allocator, bearer)).?;
    defer selected.deinit();
    try std.testing.expectEqual(@as(usize, 2), selected.bearer.scopes.len);
    try std.testing.expectEqualStrings("a", selected.bearer.scopes[0]);
    try std.testing.expectEqualStrings("b", selected.bearer.scopes[1]);

    var basic = try parseWwwAuthenticate(std.testing.allocator, &.{
        "Basic realm=\"registry\", charset=\"UTF-8\"",
    });
    defer basic.deinit();
    var basic_selected = (try selectDistributionChallenge(std.testing.allocator, basic)).?;
    defer basic_selected.deinit();
    try std.testing.expectEqualStrings("registry", basic_selected.basic.realm.?);
}

test "token responses URLs and Authorization values are bounded" {
    var token = try parseTokenResponse(
        std.testing.allocator,
        "{\"token\":\"YWJjZA==\",\"access_token\":\"YWJjZA==\",\"expires_in\":3600}",
        .{},
    );
    defer token.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("YWJjZA==", token.value);

    try std.testing.expectError(
        error.InvalidTokenResponse,
        parseTokenResponse(
            std.testing.allocator,
            "{\"token\":\"one\",\"access_token\":\"two\"}",
            .{},
        ),
    );
    try std.testing.expectError(
        error.InvalidTokenResponse,
        parseTokenResponse(std.testing.allocator, "{\"token\":\"bad token\"}", .{}),
    );
    try std.testing.expectError(
        error.TokenResponseTooLarge,
        parseTokenResponse(
            std.testing.allocator,
            "{\"token\":\"x\"}",
            .{ .max_token_response_bytes = 4 },
        ),
    );

    const url = try buildBearerTokenUrlAlloc(
        std.testing.allocator,
        "https://token.example/auth?existing=yes",
        "registry example",
        &.{ "repository:one/image:pull", "repository:two/image:pull,push" },
    );
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://token.example/auth?existing=yes&service=registry%20example&scope=repository%3Aone%2Fimage%3Apull&scope=repository%3Atwo%2Fimage%3Apull%2Cpush",
        url,
    );
    try std.testing.expectError(
        error.InvalidTokenRealm,
        buildBearerTokenUrlAlloc(
            std.testing.allocator,
            "https://user:secret@token.example/auth",
            null,
            &.{},
        ),
    );

    var basic_header = try basicAuthorizationAlloc(
        std.testing.allocator,
        .{ .username = "user", .secret = "secret" },
        .{},
    );
    defer basic_header.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Basic dXNlcjpzZWNyZXQ=", basic_header.bytes);

    var bearer_header = try bearerAuthorizationAlloc(std.testing.allocator, token.value, .{});
    defer bearer_header.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Bearer YWJjZA==", bearer_header.bytes);
}

test "secret-bearing values format only redacted metadata" {
    var owned = OwnedCredential{ .basic = .{
        .username = try std.testing.allocator.dupe(u8, "sensitive-user"),
        .secret = try std.testing.allocator.dupe(u8, "sensitive-secret"),
    } };
    defer owned.deinit(std.testing.allocator);
    var resolved = ResolvedCredential{
        .source = .supplied,
        .credential = .{ .bearer_token = try std.testing.allocator.dupe(
            u8,
            "sensitive-token",
        ) },
    };
    defer resolved.deinit(std.testing.allocator);
    var token = Token{
        .value = try std.testing.allocator.dupe(u8, "another-secret-token"),
        .expires_in = null,
    };
    defer token.deinit(std.testing.allocator);

    var output = Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try output.writer.print("{f} {f} {f}", .{ owned, resolved, token });
    const formatted = output.written();
    try std.testing.expect(std.mem.indexOf(u8, formatted, "sensitive") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "another-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "redacted") != null);
}

test "authority normalization is case-insensitive and preserves port distinctions" {
    const plain = try normalizeAuthorityAlloc(std.testing.allocator, "Registry.Example");
    defer std.testing.allocator.free(plain);
    const port = try normalizeAuthorityAlloc(std.testing.allocator, "Registry.Example:05000");
    defer std.testing.allocator.free(port);
    try std.testing.expectEqualStrings("registry.example", plain);
    try std.testing.expectEqualStrings("registry.example:5000", port);
    try std.testing.expect(!std.mem.eql(u8, plain, port));
    try std.testing.expectError(
        error.InvalidAuthority,
        normalizeAuthorityAlloc(std.testing.allocator, "https://registry.example"),
    );
}

const TestFileRecord = struct {
    path: []const u8,
    contents: []const u8,
};

const TestFiles = struct {
    records: []const TestFileRecord = &.{},
    expected_paths: []const []const u8 = &.{},
    reads: usize = 0,
    valid: bool = true,

    fn boundary(self: *TestFiles) FileReader {
        return .{ .context = self, .read = read };
    }

    fn read(
        raw_context: ?*anyopaque,
        allocator: Allocator,
        _: Io,
        path: []const u8,
        limit: usize,
    ) FileReadError![]u8 {
        const self: *TestFiles = @ptrCast(@alignCast(raw_context.?));
        if (self.reads >= self.expected_paths.len or
            !std.mem.eql(u8, self.expected_paths[self.reads], path))
        {
            self.valid = false;
        }
        self.reads += 1;
        for (self.records) |record| {
            if (!std.mem.eql(u8, record.path, path)) continue;
            if (record.contents.len > limit) return error.InputTooLarge;
            return allocator.dupe(u8, record.contents);
        }
        return error.FileNotFound;
    }
};

const TestProcess = struct {
    const Outcome = enum {
        success,
        failed,
        deadline,
        too_large,
    };

    expected_executable: []const u8 = "",
    expected_input: []const u8 = "",
    expected_timeout_ns: u64 = 15 * std.time.ns_per_s,
    stdout: []const u8 = "",
    outcome: Outcome = .success,
    calls: usize = 0,
    valid: bool = true,

    fn boundary(self: *TestProcess) ProcessRunner {
        return .{ .context = self, .run = run };
    }

    fn run(
        raw_context: ?*anyopaque,
        allocator: Allocator,
        _: Io,
        argv: []const []const u8,
        stdin_data: []const u8,
        _: usize,
        timeout_ns: u64,
    ) ProcessError!ProcessResult {
        const self: *TestProcess = @ptrCast(@alignCast(raw_context.?));
        self.calls += 1;
        if (argv.len != 2 or
            !std.mem.eql(u8, argv[0], self.expected_executable) or
            !std.mem.eql(u8, argv[1], "get") or
            !std.mem.eql(u8, stdin_data, self.expected_input) or
            timeout_ns != self.expected_timeout_ns)
        {
            self.valid = false;
        }
        return switch (self.outcome) {
            .success => .{ .stdout = try allocator.dupe(u8, self.stdout) },
            .failed => error.Failed,
            .deadline => error.DeadlineExceeded,
            .too_large => error.OutputTooLarge,
        };
    }
};

test "none and supplied policies never inspect ambient boundaries" {
    var files = TestFiles{ .expected_paths = &.{} };
    var process = TestProcess{};
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("REGISTRY_AUTH_FILE", "/must/not/read.json");

    const context: ResolutionContext = .{
        .io = std.testing.io,
        .environment = &environment,
        .files = files.boundary(),
        .process = process.boundary(),
    };
    try std.testing.expect((try resolveCredential(
        std.testing.allocator,
        .none,
        .{ .authority = "invalid authority is irrelevant", .repository = "" },
        context,
        .{},
    )) == null);
    var supplied = (try resolveCredential(
        std.testing.allocator,
        .{ .supplied = .{ .basic = .{
            .username = "caller",
            .secret = "caller-secret",
        } } },
        .{ .authority = "also irrelevant", .repository = "" },
        context,
        .{},
    )).?;
    defer supplied.deinit(std.testing.allocator);
    try std.testing.expectEqual(CredentialSource.supplied, supplied.source);
    try std.testing.expectEqualStrings("caller", supplied.credential.basic.username);

    var supplied_token = (try resolveCredential(
        std.testing.allocator,
        .{ .supplied = .{ .bearer_token = "caller-token" } },
        .{ .authority = "also irrelevant", .repository = "" },
        context,
        .{},
    )).?;
    defer supplied_token.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("caller-token", supplied_token.credential.bearer_token);
    try std.testing.expectEqual(@as(usize, 0), files.reads);
    try std.testing.expectEqual(@as(usize, 0), process.calls);
}

test "explicit auth file has no ambient fallback on missing or no match" {
    const explicit = "/explicit/config.json";
    const ambient = "/ambient/config.json";
    var files = TestFiles{
        .records = &.{
            .{ .path = explicit, .contents = "{\"auths\":{\"other.example\":{\"auth\":\"dTpw\"}}}" },
            .{ .path = ambient, .contents = "{\"auths\":{\"registry.example\":{\"auth\":\"YW1iaWVudDpzZWNyZXQ=\"}}}" },
        },
        .expected_paths = &.{explicit},
    };
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("REGISTRY_AUTH_FILE", ambient);
    try std.testing.expectError(
        error.CredentialNotFound,
        resolveCredential(
            std.testing.allocator,
            .{ .auth_file = explicit },
            .{ .authority = "registry.example", .repository = "team/image" },
            .{
                .io = std.testing.io,
                .environment = &environment,
                .files = files.boundary(),
            },
            .{},
        ),
    );
    try std.testing.expect(files.valid);
    try std.testing.expectEqual(@as(usize, 1), files.reads);

    var missing_files = TestFiles{ .expected_paths = &.{"/missing.json"} };
    try std.testing.expectError(
        error.AuthFileNotFound,
        resolveCredential(
            std.testing.allocator,
            .{ .auth_file = "/missing.json" },
            .{ .authority = "registry.example", .repository = "team/image" },
            .{ .io = std.testing.io, .files = missing_files.boundary() },
            .{},
        ),
    );
    try std.testing.expect(missing_files.valid);
}

test "discovery order is deterministic and malformed authoritative files stop" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("XDG_RUNTIME_DIR", "/run/user/1000");
    try environment.put("XDG_CONFIG_HOME", "/config");
    try environment.put("DOCKER_CONFIG", "/docker");
    try environment.put("HOME", "/home/test");

    var files = TestFiles{
        .records = &.{
            .{
                .path = "/run/user/1000/containers/auth.json",
                .contents = "{\"auths\":{\"other.example\":{\"auth\":\"dTpw\"}}}",
            },
            .{
                .path = "/config/containers/auth.json",
                .contents = "{\"auths\":{\"registry.example\":{\"auth\":\"dXNlcjpzZWNyZXQ=\"}}}",
            },
        },
        .expected_paths = &.{
            "/run/user/1000/containers/auth.json",
            "/config/containers/auth.json",
        },
    };
    var resolved = (try resolveCredential(
        std.testing.allocator,
        .discover,
        .{ .authority = "REGISTRY.EXAMPLE", .repository = "team/image" },
        .{
            .io = std.testing.io,
            .environment = &environment,
            .files = files.boundary(),
            .path_flavor = .posix,
        },
        .{},
    )).?;
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqual(CredentialSource.containers_config, resolved.source);
    try std.testing.expectEqualStrings("user", resolved.credential.basic.username);
    try std.testing.expect(files.valid);

    var authoritative_environment = std.process.Environ.Map.init(std.testing.allocator);
    defer authoritative_environment.deinit();
    try authoritative_environment.put("REGISTRY_AUTH_FILE", "/authoritative.json");
    try authoritative_environment.put("HOME", "/home/test");
    var authoritative_files = TestFiles{
        .records = &.{
            .{ .path = "/authoritative.json", .contents = "not-json" },
            .{
                .path = "/home/test/.docker/config.json",
                .contents = "{\"auths\":{\"registry.example\":{\"auth\":\"dXNlcjpzZWNyZXQ=\"}}}",
            },
        },
        .expected_paths = &.{"/authoritative.json"},
    };
    try std.testing.expectError(
        error.InvalidAuthFile,
        resolveCredential(
            std.testing.allocator,
            .discover,
            .{ .authority = "registry.example", .repository = "team/image" },
            .{
                .io = std.testing.io,
                .environment = &authoritative_environment,
                .files = authoritative_files.boundary(),
            },
            .{},
        ),
    );
    try std.testing.expect(authoritative_files.valid);
    try std.testing.expectEqual(@as(usize, 1), authoritative_files.reads);
}

test "discovery path construction is platform-testable without real homes" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("DOCKER_CONFIG", "C:\\Users\\test\\docker");
    var files = TestFiles{
        .records = &.{.{
            .path = "C:\\Users\\test\\docker\\config.json",
            .contents = "{\"auths\":{\"registry.example\":{\"auth\":\"dXNlcjpzZWNyZXQ=\"}}}",
        }},
        .expected_paths = &.{"C:\\Users\\test\\docker\\config.json"},
    };
    var resolved = (try resolveCredential(
        std.testing.allocator,
        .discover,
        .{ .authority = "registry.example", .repository = "team/image" },
        .{
            .io = std.testing.io,
            .environment = &environment,
            .files = files.boundary(),
            .path_flavor = .windows,
        },
        .{},
    )).?;
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqual(CredentialSource.docker_config, resolved.source);
    try std.testing.expect(files.valid);
}

test "auth records use exact normalized authorities and most-specific paths" {
    const path = "/config.json";
    const document =
        \\{"auths":{
        \\"registry.example":{"auth":"cm9vdDpwYXNz"},
        \\"REGISTRY.EXAMPLE/team":{"auth":"dGVhbTpzZWNyZXQ="},
        \\"registry.example:5000/team":{"auth":"cG9ydDpzZWNyZXQ="}
        \\}}
    ;
    var files = TestFiles{
        .records = &.{.{ .path = path, .contents = document }},
        .expected_paths = &.{ path, path },
    };
    const context: ResolutionContext = .{
        .io = std.testing.io,
        .files = files.boundary(),
    };
    var team = (try resolveCredential(
        std.testing.allocator,
        .{ .auth_file = path },
        .{ .authority = "registry.example", .repository = "team/image" },
        context,
        .{},
    )).?;
    defer team.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("team", team.credential.basic.username);

    var port = (try resolveCredential(
        std.testing.allocator,
        .{ .auth_file = path },
        .{ .authority = "registry.example:5000", .repository = "team/image" },
        context,
        .{},
    )).?;
    defer port.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("port", port.credential.basic.username);
    try std.testing.expect(files.valid);
}

test "inline records support strict auth and username password forms" {
    var standalone_files = TestFiles{
        .records = &.{.{
            .path = "/standalone.json",
            .contents = "{\"auths\":{\"registry.example\":{\"username\":\"user\",\"password\":\"secret\"}}}",
        }},
        .expected_paths = &.{"/standalone.json"},
    };
    var standalone = (try resolveCredential(
        std.testing.allocator,
        .{ .auth_file = "/standalone.json" },
        .{ .authority = "registry.example", .repository = "team/image" },
        .{ .io = std.testing.io, .files = standalone_files.boundary() },
        .{},
    )).?;
    defer standalone.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("user", standalone.credential.basic.username);
    try std.testing.expectEqualStrings("secret", standalone.credential.basic.secret);

    inline for (.{
        .{
            .path = "/identity.json",
            .document = "{\"auths\":{\"registry.example\":{\"identitytoken\":\"sensitive-token\"}}}",
            .expected = error.UnsupportedCredentialType,
        },
        .{
            .path = "/empty.json",
            .document = "{\"auths\":{\"registry.example\":{}}}",
            .expected = error.UnsupportedCredentialType,
        },
        .{
            .path = "/bad-base64.json",
            .document = "{\"auths\":{\"registry.example\":{\"auth\":\"dXNlcjpzZWNyZXQ\"}}}",
            .expected = error.InvalidCredential,
        },
    }) |case| {
        var files = TestFiles{
            .records = &.{.{ .path = case.path, .contents = case.document }},
            .expected_paths = &.{case.path},
        };
        try std.testing.expectError(
            case.expected,
            resolveCredential(
                std.testing.allocator,
                .{ .auth_file = case.path },
                .{ .authority = "registry.example", .repository = "team/image" },
                .{ .io = std.testing.io, .files = files.boundary() },
                .{},
            ),
        );
        try std.testing.expect(files.valid);
    }
}

test "auth file and decoded credentials enforce allocation bounds" {
    const oversized = "{" ++ (" " ** 64) ++ "}";
    var files = TestFiles{
        .records = &.{.{ .path = "/large.json", .contents = oversized }},
        .expected_paths = &.{"/large.json"},
    };
    try std.testing.expectError(
        error.AuthFileTooLarge,
        resolveCredential(
            std.testing.allocator,
            .{ .auth_file = "/large.json" },
            .{ .authority = "registry.example", .repository = "team/image" },
            .{ .io = std.testing.io, .files = files.boundary() },
            .{ .max_auth_file_bytes = 32 },
        ),
    );
}

test "matching credential helper wins and receives only bounded stdin" {
    var files = TestFiles{
        .records = &.{.{
            .path = "/helper.json",
            .contents =
            \\{"credHelpers":{"registry.example/team":"safe-helper"},"auths":{"registry.example/team":{"auth":"ZmFsbGJhY2s6c2VjcmV0"}}}
            ,
        }},
        .expected_paths = &.{"/helper.json"},
    };
    var process = TestProcess{
        .expected_executable = "docker-credential-safe-helper",
        .expected_input = "registry.example/team\n",
        .stdout = "{\"ServerURL\":\"registry.example/team\",\"Username\":\"helper-user\",\"Secret\":\"helper-secret\"}",
    };
    var resolved = (try resolveCredential(
        std.testing.allocator,
        .{ .auth_file = "/helper.json" },
        .{ .authority = "registry.example", .repository = "team/image" },
        .{
            .io = std.testing.io,
            .files = files.boundary(),
            .process = process.boundary(),
        },
        .{},
    )).?;
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("helper-user", resolved.credential.basic.username);
    try std.testing.expectEqualStrings("helper-secret", resolved.credential.basic.secret);
    try std.testing.expectEqual(@as(usize, 1), process.calls);
    try std.testing.expect(process.valid);
    try std.testing.expect(files.valid);
}

test "helper failures deadlines and unsafe identifiers never fall back inline" {
    inline for (.{
        .{ .outcome = TestProcess.Outcome.failed, .expected = error.CredentialHelperFailed },
        .{ .outcome = TestProcess.Outcome.deadline, .expected = error.CredentialHelperDeadlineExceeded },
        .{ .outcome = TestProcess.Outcome.too_large, .expected = error.CredentialHelperOutputTooLarge },
    }) |case| {
        var files = TestFiles{
            .records = &.{.{
                .path = "/helper.json",
                .contents =
                \\{"credHelpers":{"registry.example":"test"},"auths":{"registry.example":{"auth":"ZmFsbGJhY2s6c2VjcmV0"}}}
                ,
            }},
            .expected_paths = &.{"/helper.json"},
        };
        var process = TestProcess{
            .expected_executable = "docker-credential-test",
            .expected_input = "registry.example\n",
            .outcome = case.outcome,
        };
        try std.testing.expectError(
            case.expected,
            resolveCredential(
                std.testing.allocator,
                .{ .auth_file = "/helper.json" },
                .{ .authority = "registry.example", .repository = "team/image" },
                .{
                    .io = std.testing.io,
                    .files = files.boundary(),
                    .process = process.boundary(),
                },
                .{},
            ),
        );
        try std.testing.expectEqual(@as(usize, 1), process.calls);
        try std.testing.expect(process.valid);
    }

    var unsafe_files = TestFiles{
        .records = &.{.{
            .path = "/unsafe.json",
            .contents = "{\"credHelpers\":{\"registry.example\":\"../../unsafe\"}}",
        }},
        .expected_paths = &.{"/unsafe.json"},
    };
    var unused_process = TestProcess{};
    try std.testing.expectError(
        error.InvalidCredentialHelperName,
        resolveCredential(
            std.testing.allocator,
            .{ .auth_file = "/unsafe.json" },
            .{ .authority = "registry.example", .repository = "team/image" },
            .{
                .io = std.testing.io,
                .files = unsafe_files.boundary(),
                .process = unused_process.boundary(),
            },
            .{},
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), unused_process.calls);

    var bounded_files = TestFiles{
        .records = &.{.{
            .path = "/bounded.json",
            .contents = "{\"credsStore\":\"test\"}",
        }},
        .expected_paths = &.{"/bounded.json"},
    };
    var bounded_process = TestProcess{};
    try std.testing.expectError(
        error.CredentialHelperInputTooLarge,
        resolveCredential(
            std.testing.allocator,
            .{ .auth_file = "/bounded.json" },
            .{ .authority = "registry.example", .repository = "team/image" },
            .{
                .io = std.testing.io,
                .files = bounded_files.boundary(),
                .process = bounded_process.boundary(),
            },
            .{ .max_helper_input_bytes = 4 },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), bounded_process.calls);
}

test "helper output rejects malformed and identity-token records without diagnostics" {
    inline for (.{
        .{
            .output = "helper-secret is not json",
            .expected = error.InvalidCredentialHelperOutput,
        },
        .{
            .output = "{\"Username\":\"\",\"Secret\":\"helper-secret\"}",
            .expected = error.InvalidCredentialHelperOutput,
        },
        .{
            .output = "{\"Username\":\"<token>\",\"Secret\":\"helper-secret\"}",
            .expected = error.UnsupportedCredentialType,
        },
    }) |case| {
        var files = TestFiles{
            .records = &.{.{
                .path = "/helper.json",
                .contents = "{\"credsStore\":\"test\"}",
            }},
            .expected_paths = &.{"/helper.json"},
        };
        var process = TestProcess{
            .expected_executable = "docker-credential-test",
            .expected_input = "registry.example\n",
            .stdout = case.output,
        };
        const result = resolveCredential(
            std.testing.allocator,
            .{ .auth_file = "/helper.json" },
            .{ .authority = "registry.example", .repository = "team/image" },
            .{
                .io = std.testing.io,
                .files = files.boundary(),
                .process = process.boundary(),
            },
            .{},
        );
        try std.testing.expectError(case.expected, result);
        try std.testing.expect(std.mem.indexOf(u8, @errorName(case.expected), "secret") == null);
        try std.testing.expect(process.valid);
    }
}

test "global Docker Hub helper lookup uses canonical alias" {
    var files = TestFiles{
        .records = &.{.{
            .path = "/docker.json",
            .contents = "{\"credsStore\":\"test\"}",
        }},
        .expected_paths = &.{"/docker.json"},
    };
    var process = TestProcess{
        .expected_executable = "docker-credential-test",
        .expected_input = "https://index.docker.io/v1/\n",
        .stdout = "{\"ServerURL\":\"https://index.docker.io/v1/\",\"Username\":\"docker\",\"Secret\":\"secret\"}",
    };
    var resolved = (try resolveCredential(
        std.testing.allocator,
        .{ .auth_file = "/docker.json" },
        .{ .authority = "registry-1.docker.io", .repository = "library/busybox" },
        .{
            .io = std.testing.io,
            .files = files.boundary(),
            .process = process.boundary(),
        },
        .{},
    )).?;
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("docker", resolved.credential.basic.username);
    try std.testing.expect(process.valid);
}

test "token cache canonicalizes scopes and isolates origins contexts and generations" {
    var cache = try TokenCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var first = try parseTokenResponse(
        std.testing.allocator,
        "{\"token\":\"first-token\",\"expires_in\":3600}",
        .{},
    );
    defer first.deinit(std.testing.allocator);
    const key: TokenCacheKey = .{
        .context_id = 1,
        .registry_origin = "https://registry.example",
        .realm = "https://token.example/auth",
        .service = "registry.example",
        .scopes = &.{ "repository:team/image:pull", "repository:team/image:push" },
        .credential_generation = 7,
    };
    _ = try cache.put(100, key, first, .{});
    try std.testing.expectEqualStrings(
        "first-token",
        cache.get(100, .{
            .context_id = 1,
            .registry_origin = "https://registry.example",
            .realm = "https://token.example/auth",
            .service = "registry.example",
            .scopes = &.{
                "repository:team/image:push",
                "repository:team/image:pull",
                "repository:team/image:pull",
            },
            .credential_generation = 7,
        }).?,
    );
    try std.testing.expect(cache.get(100, .{
        .context_id = 1,
        .registry_origin = "https://other-registry.example",
        .realm = "https://token.example/auth",
        .service = "registry.example",
        .scopes = key.scopes,
        .credential_generation = 7,
    }) == null);
    try std.testing.expect(cache.get(100, .{
        .context_id = 2,
        .registry_origin = key.registry_origin,
        .realm = key.realm,
        .service = key.service,
        .scopes = key.scopes,
        .credential_generation = 7,
    }) == null);
    try std.testing.expect(cache.get(100, .{
        .context_id = 1,
        .registry_origin = key.registry_origin,
        .realm = key.realm,
        .service = key.service,
        .scopes = key.scopes,
        .credential_generation = 8,
    }) == null);
    try std.testing.expect(cache.get(100, .{
        .context_id = 1,
        .registry_origin = key.registry_origin,
        .realm = key.realm,
        .service = key.service,
        .scopes = &.{"repository:team/image:pull"},
        .credential_generation = 7,
    }) == null);
}

test "source destination token scopes and contexts remain isolated" {
    var cache = try TokenCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var pull_token = Token{
        .value = try std.testing.allocator.dupe(u8, "pull-token"),
        .expires_in = 3600,
    };
    defer pull_token.deinit(std.testing.allocator);
    var push_token = Token{
        .value = try std.testing.allocator.dupe(u8, "push-token"),
        .expires_in = 3600,
    };
    defer push_token.deinit(std.testing.allocator);
    const source: TokenCacheKey = .{
        .context_id = 101,
        .registry_origin = "https://source.example",
        .realm = "https://source.example/token",
        .service = "source.example",
        .scopes = &.{"repository:team/image:pull"},
        .credential_generation = 1,
    };
    const destination: TokenCacheKey = .{
        .context_id = 202,
        .registry_origin = "https://destination.example",
        .realm = "https://destination.example/token",
        .service = "destination.example",
        .scopes = &.{"repository:team/image:push"},
        .credential_generation = 1,
    };
    _ = try cache.put(0, source, pull_token, .{});
    _ = try cache.put(0, destination, push_token, .{});
    try std.testing.expectEqualStrings("pull-token", cache.get(0, source).?);
    try std.testing.expectEqualStrings("push-token", cache.get(0, destination).?);
    try std.testing.expect(cache.get(0, .{
        .context_id = source.context_id,
        .registry_origin = source.registry_origin,
        .realm = source.realm,
        .service = source.service,
        .scopes = destination.scopes,
        .credential_generation = source.credential_generation,
    }) == null);
}

test "token cache expiry skew defaults cap and bounded eviction are deterministic" {
    var cache = try TokenCache.init(
        std.testing.allocator,
        .{ .max_token_cache_entries = 2 },
    );
    defer cache.deinit();
    var short = Token{
        .value = try std.testing.allocator.dupe(u8, "short"),
        .expires_in = 11,
    };
    defer short.deinit(std.testing.allocator);
    const key1: TokenCacheKey = .{
        .context_id = 1,
        .registry_origin = "https://one",
        .realm = "https://one/token",
        .service = null,
        .scopes = &.{},
        .credential_generation = 1,
    };
    _ = try cache.put(100, key1, short, .{});
    try std.testing.expectEqualStrings("short", cache.get(100, key1).?);
    try std.testing.expect(cache.get(101, key1) == null);

    var default_ttl = Token{
        .value = try std.testing.allocator.dupe(u8, "default"),
        .expires_in = null,
    };
    defer default_ttl.deinit(std.testing.allocator);
    _ = try cache.put(100, key1, default_ttl, .{});
    try std.testing.expectEqualStrings("default", cache.get(149, key1).?);
    try std.testing.expect(cache.get(150, key1) == null);

    var token2 = Token{
        .value = try std.testing.allocator.dupe(u8, "two"),
        .expires_in = max_token_ttl_seconds + 100,
    };
    defer token2.deinit(std.testing.allocator);
    var token3 = Token{
        .value = try std.testing.allocator.dupe(u8, "three"),
        .expires_in = 3600,
    };
    defer token3.deinit(std.testing.allocator);
    const key2: TokenCacheKey = .{
        .context_id = 1,
        .registry_origin = "https://two",
        .realm = "https://two/token",
        .service = null,
        .scopes = &.{},
        .credential_generation = 1,
    };
    const key3: TokenCacheKey = .{
        .context_id = 1,
        .registry_origin = "https://three",
        .realm = "https://three/token",
        .service = null,
        .scopes = &.{},
        .credential_generation = 1,
    };
    _ = try cache.put(200, key1, default_ttl, .{});
    _ = try cache.put(200, key2, token2, .{});
    _ = try cache.put(200, key3, token3, .{});
    try std.testing.expect(cache.get(200, key1) == null);
    try std.testing.expectEqualStrings("two", cache.get(200, key2).?);
    try std.testing.expect(cache.get(
        200 + @as(i64, @intCast(max_token_ttl_seconds)) - token_expiry_skew_seconds,
        key2,
    ) == null);
}

test "token acquisition and time are caller injected" {
    const Acquisition = struct {
        calls: usize = 0,

        fn acquire(
            raw_context: ?*anyopaque,
            allocator: Allocator,
            request: TokenCacheKey,
        ) TokenAcquisitionError!Token {
            const self: *@This() = @ptrCast(@alignCast(raw_context.?));
            self.calls += 1;
            if (request.context_id != 42 or
                !std.mem.eql(u8, request.registry_origin, "https://registry.example"))
            {
                return error.AuthenticationFailed;
            }
            return .{
                .value = try allocator.dupe(u8, "injected-token"),
                .expires_in = 3600,
            };
        }
    };
    var acquisition = Acquisition{};
    var cache = try TokenCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    const key: TokenCacheKey = .{
        .context_id = 42,
        .registry_origin = "https://registry.example",
        .realm = "https://token.example",
        .service = "registry.example",
        .scopes = &.{"repository:team/image:pull"},
        .credential_generation = 3,
    };
    try std.testing.expectEqualStrings(
        "injected-token",
        try cachedOrAcquireToken(
            std.testing.allocator,
            &cache,
            100,
            key,
            .{ .context = &acquisition, .acquire = Acquisition.acquire },
            .{},
        ),
    );
    try std.testing.expectEqualStrings(
        "injected-token",
        try cachedOrAcquireToken(
            std.testing.allocator,
            &cache,
            101,
            key,
            .{ .context = &acquisition, .acquire = Acquisition.acquire },
            .{},
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), acquisition.calls);
}
