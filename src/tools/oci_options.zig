const std = @import("std");
const wabt = @import("wabt");

pub const max_deadline_ns: u64 = 24 * std.time.ns_per_hour;

pub const endpoint_help =
    \\  --username USER                  Username paired with --password-stdin
    \\  --password-stdin                 Read one password line from caller/stdin
    \\  --token-stdin                    Read one bearer token line from caller/stdin
    \\  --auth-file FILE                 Use only this registry authentication file
    \\  --ca-file FILE                   Add certificates from FILE to system trust
    \\  --deadline DURATION              One operation budget: 1ms..24h (ms, s, m, h)
    \\  --plain-http                     Allow HTTP only for a loopback registry
    \\  --no-credential-discovery        Disable ambient files and credential helpers
;

pub const copy_endpoint_help =
    \\  --source-username USER / --destination-username USER
    \\  --source-password-stdin / --destination-password-stdin
    \\  --source-token-stdin / --destination-token-stdin
    \\  --source-auth-file FILE / --destination-auth-file FILE
    \\  --source-ca-file FILE / --destination-ca-file FILE
    \\  --source-deadline DURATION / --destination-deadline DURATION
    \\  --source-plain-http / --destination-plain-http
    \\  --source-no-credential-discovery / --destination-no-credential-discovery
    \\                       Registry-side options are independent and invalid
    \\                       on an oci: layout side. If both sides request a
    \\                       stdin secret, source is read before destination.
;

pub const Error = error{
    DuplicateOption,
    MissingOptionValue,
    InvalidOptionValue,
    UnknownOption,
    PlaintextSecretOption,
    ConflictingCredentialOptions,
    UsernameRequiresPasswordStdin,
    PasswordStdinRequiresUsername,
    RegistryOptionForLayout,
    InsecurePlainHttp,
    InvalidDuration,
    DeadlineOverflow,
    InvalidFile,
    InvalidOutputFile,
    InvalidTimestamp,
};

pub const SecretInput = union(enum) {
    stdin,
    caller: []const u8,

    pub fn format(_: SecretInput, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("<secret-input:redacted>");
    }
};

pub const BasicInput = struct {
    username: []const u8,
    secret: SecretInput,

    pub fn format(_: BasicInput, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("<basic-input:redacted>");
    }
};

pub const CredentialInput = union(enum) {
    discover,
    none,
    auth_file: []const u8,
    basic: BasicInput,
    bearer: SecretInput,

    pub fn format(_: CredentialInput, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("<credential-input:redacted>");
    }
};

/// CLI parsing produces a relative deadline. Embedders may construct an
/// absolute value directly; runtime wiring must resolve a relative value once.
pub const DeadlineInput = union(enum) {
    relative_ns: u64,
    absolute_ns: i128,

    pub fn absoluteNs(self: DeadlineInput, now_ns: i128) Error!i128 {
        return switch (self) {
            .absolute_ns => |value| value,
            .relative_ns => |value| std.math.add(
                i128,
                now_ns,
                @as(i128, @intCast(value)),
            ) catch return error.DeadlineOverflow,
        };
    }
};

pub const EndpointOptions = struct {
    credentials: CredentialInput = .discover,
    additional_ca_file: ?[]const u8 = null,
    deadline: ?DeadlineInput = null,
    plain_http: bool = false,

    pub fn format(_: EndpointOptions, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("<oci-endpoint-options:redacted>");
    }
};

pub const Scope = enum {
    single,
    source,
    destination,
};

const OptionNames = struct {
    username: []const u8,
    password_stdin: []const u8,
    token_stdin: []const u8,
    auth_file: []const u8,
    ca_file: []const u8,
    deadline: []const u8,
    plain_http: []const u8,
    no_discovery: []const u8,
    password_plain: []const u8,
    token_plain: []const u8,
};

fn optionNames(scope: Scope) OptionNames {
    return switch (scope) {
        .single => .{
            .username = "--username",
            .password_stdin = "--password-stdin",
            .token_stdin = "--token-stdin",
            .auth_file = "--auth-file",
            .ca_file = "--ca-file",
            .deadline = "--deadline",
            .plain_http = "--plain-http",
            .no_discovery = "--no-credential-discovery",
            .password_plain = "--password",
            .token_plain = "--token",
        },
        .source => .{
            .username = "--source-username",
            .password_stdin = "--source-password-stdin",
            .token_stdin = "--source-token-stdin",
            .auth_file = "--source-auth-file",
            .ca_file = "--source-ca-file",
            .deadline = "--source-deadline",
            .plain_http = "--source-plain-http",
            .no_discovery = "--source-no-credential-discovery",
            .password_plain = "--source-password",
            .token_plain = "--source-token",
        },
        .destination => .{
            .username = "--destination-username",
            .password_stdin = "--destination-password-stdin",
            .token_stdin = "--destination-token-stdin",
            .auth_file = "--destination-auth-file",
            .ca_file = "--destination-ca-file",
            .deadline = "--destination-deadline",
            .plain_http = "--destination-plain-http",
            .no_discovery = "--destination-no-credential-discovery",
            .password_plain = "--destination-password",
            .token_plain = "--destination-token",
        },
    };
}

pub const EndpointBuilder = struct {
    username: ?[]const u8 = null,
    auth_file: ?[]const u8 = null,
    ca_file: ?[]const u8 = null,
    deadline: ?DeadlineInput = null,
    password_stdin: bool = false,
    token_stdin: bool = false,
    plain_http: bool = false,
    no_discovery: bool = false,
    username_seen: bool = false,
    auth_file_seen: bool = false,
    ca_file_seen: bool = false,
    deadline_seen: bool = false,
    password_stdin_seen: bool = false,
    token_stdin_seen: bool = false,
    plain_http_seen: bool = false,
    no_discovery_seen: bool = false,
    used: bool = false,

    pub fn consume(
        self: *EndpointBuilder,
        args: []const []const u8,
        index: *usize,
        scope: Scope,
    ) Error!bool {
        const arg = args[index.*];
        const names = optionNames(scope);

        if (std.mem.eql(u8, arg, names.username)) {
            try markOnce(&self.username_seen);
            self.username = try takeValue(args, index);
            if (!validUsername(self.username.?)) return error.InvalidOptionValue;
        } else if (std.mem.eql(u8, arg, names.password_stdin)) {
            try markOnce(&self.password_stdin_seen);
            self.password_stdin = true;
        } else if (std.mem.eql(u8, arg, names.token_stdin)) {
            try markOnce(&self.token_stdin_seen);
            self.token_stdin = true;
        } else if (std.mem.eql(u8, arg, names.auth_file)) {
            try markOnce(&self.auth_file_seen);
            self.auth_file = try takeValue(args, index);
            if (!validPathOption(self.auth_file.?)) return error.InvalidOptionValue;
        } else if (std.mem.eql(u8, arg, names.ca_file)) {
            try markOnce(&self.ca_file_seen);
            self.ca_file = try takeValue(args, index);
            if (!validPathOption(self.ca_file.?)) return error.InvalidOptionValue;
        } else if (std.mem.eql(u8, arg, names.deadline)) {
            try markOnce(&self.deadline_seen);
            self.deadline = try parseDuration(try takeValue(args, index));
        } else if (std.mem.eql(u8, arg, names.plain_http)) {
            try markOnce(&self.plain_http_seen);
            self.plain_http = true;
        } else if (std.mem.eql(u8, arg, names.no_discovery)) {
            try markOnce(&self.no_discovery_seen);
            self.no_discovery = true;
        } else if (isPlaintextSecretOption(arg)) {
            return error.PlaintextSecretOption;
        } else {
            return false;
        }

        self.used = true;
        return true;
    }

    pub fn finish(
        self: EndpointBuilder,
        reference: wabt.oci.Reference,
    ) Error!?EndpointOptions {
        const registry = switch (reference) {
            .layout => {
                if (self.used) return error.RegistryOptionForLayout;
                return null;
            },
            .registry => |value| value,
        };

        if (self.username != null and !self.password_stdin) {
            return error.UsernameRequiresPasswordStdin;
        }
        if (self.password_stdin and self.username == null) {
            return error.PasswordStdinRequiresUsername;
        }

        const basic = self.username != null;
        const source_count =
            @as(u8, @intFromBool(basic)) +
            @as(u8, @intFromBool(self.token_stdin)) +
            @as(u8, @intFromBool(self.auth_file != null));
        if (source_count > 1) return error.ConflictingCredentialOptions;

        const credentials: CredentialInput = if (basic)
            .{ .basic = .{
                .username = self.username.?,
                .secret = .stdin,
            } }
        else if (self.token_stdin)
            .{ .bearer = .stdin }
        else if (self.auth_file) |path|
            .{ .auth_file = path }
        else if (self.no_discovery)
            .none
        else
            .discover;

        if (self.plain_http and !isLoopbackAuthority(registry.authority)) {
            return error.InsecurePlainHttp;
        }

        return .{
            .credentials = credentials,
            .additional_ca_file = self.ca_file,
            .deadline = self.deadline,
            .plain_http = self.plain_http,
        };
    }
};

pub const EndpointRole = enum {
    source,
    destination,
};

pub const SecretKind = enum {
    password,
    token,
};

pub const SecretRequest = struct {
    role: EndpointRole,
    kind: SecretKind,
};

pub fn appendStdinRequests(
    endpoint: ?EndpointOptions,
    role: EndpointRole,
    requests: *[2]SecretRequest,
    count: *usize,
) void {
    const options = endpoint orelse return;
    const kind: ?SecretKind = switch (options.credentials) {
        .basic => |basic| switch (basic.secret) {
            .stdin => .password,
            .caller => null,
        },
        .bearer => |secret| switch (secret) {
            .stdin => .token,
            .caller => null,
        },
        .discover, .none, .auth_file => null,
    };
    if (kind) |value| {
        requests[count.*] = .{ .role = role, .kind = value };
        count.* += 1;
    }
}

pub fn parseDuration(text: []const u8) Error!DeadlineInput {
    const suffix_len: usize, const factor: u64 = if (std.mem.endsWith(u8, text, "ms"))
        .{ 2, std.time.ns_per_ms }
    else if (std.mem.endsWith(u8, text, "s"))
        .{ 1, std.time.ns_per_s }
    else if (std.mem.endsWith(u8, text, "m"))
        .{ 1, std.time.ns_per_min }
    else if (std.mem.endsWith(u8, text, "h"))
        .{ 1, std.time.ns_per_hour }
    else
        return error.InvalidDuration;

    const digits = text[0 .. text.len - suffix_len];
    if (digits.len == 0) return error.InvalidDuration;
    for (digits) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidDuration;
    }
    const amount = std.fmt.parseInt(u64, digits, 10) catch return error.InvalidDuration;
    const duration = std.math.mul(u64, amount, factor) catch return error.InvalidDuration;
    if (duration == 0 or duration > max_deadline_ns) return error.InvalidDuration;
    return .{ .relative_ns = duration };
}

pub fn validateOutputFile(path: []const u8) Error!void {
    validateFile(path) catch return error.InvalidOutputFile;
    const separator = std.mem.lastIndexOfAny(u8, path, "/\\");
    const base = if (separator) |at| path[at + 1 ..] else path;
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) {
        return error.InvalidOutputFile;
    }
}

pub fn validateFile(path: []const u8) Error!void {
    if (!validPathOption(path) or path[path.len - 1] == '/' or path[path.len - 1] == '\\') {
        return error.InvalidFile;
    }
}

pub fn validateRfc3339(text: []const u8) Error!void {
    if (text.len < 20 or
        text[4] != '-' or text[7] != '-' or
        (text[10] != 'T' and text[10] != 't') or
        text[13] != ':' or text[16] != ':')
    {
        return error.InvalidTimestamp;
    }

    const year = try decimal(text[0..4]);
    const month = try decimal(text[5..7]);
    const day = try decimal(text[8..10]);
    const hour = try decimal(text[11..13]);
    const minute = try decimal(text[14..16]);
    const second = try decimal(text[17..19]);
    if (month < 1 or month > 12 or day < 1 or
        day > daysInMonth(year, month) or hour > 23 or minute > 59 or second > 60)
    {
        return error.InvalidTimestamp;
    }

    var index: usize = 19;
    if (index < text.len and text[index] == '.') {
        index += 1;
        const start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
        if (index == start) return error.InvalidTimestamp;
    }
    if (index == text.len) return error.InvalidTimestamp;
    if ((text[index] == 'Z' or text[index] == 'z') and index + 1 == text.len) return;
    if ((text[index] != '+' and text[index] != '-') or index + 6 != text.len or
        text[index + 3] != ':')
    {
        return error.InvalidTimestamp;
    }
    const offset_hour = try decimal(text[index + 1 .. index + 3]);
    const offset_minute = try decimal(text[index + 4 .. index + 6]);
    if (offset_hour > 23 or offset_minute > 59) return error.InvalidTimestamp;
}

pub fn isPlaintextSecretOption(arg: []const u8) bool {
    const names = [_][]const u8{
        "--password",
        "--token",
        "--source-password",
        "--source-token",
        "--destination-password",
        "--destination-token",
    };
    for (names) |name| {
        if (std.mem.eql(u8, arg, name) or
            (std.mem.startsWith(u8, arg, name) and
                arg.len > name.len and arg[name.len] == '='))
        {
            return true;
        }
    }
    return false;
}

pub fn takeValue(args: []const []const u8, index: *usize) Error![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.MissingOptionValue;
    const value = args[index.*];
    if (value.len == 0 or containsControl(value)) return error.InvalidOptionValue;
    return value;
}

pub fn markOnce(seen: *bool) Error!void {
    if (seen.*) return error.DuplicateOption;
    seen.* = true;
}

fn validUsername(value: []const u8) bool {
    return value.len != 0 and value.len <= 64 * 1024 and
        std.mem.indexOfScalar(u8, value, ':') == null and !containsControl(value);
}

fn validPathOption(value: []const u8) bool {
    return value.len != 0 and value.len <= 32 * 1024 and !containsControl(value);
}

fn containsControl(value: []const u8) bool {
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) return true;
    }
    return false;
}

fn decimal(text: []const u8) Error!u16 {
    if (text.len == 0) return error.InvalidTimestamp;
    var value: u16 = 0;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidTimestamp;
        value = value * 10 + (byte - '0');
    }
    return value;
}

fn daysInMonth(year: u16, month: u16) u16 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) 29 else 28,
        else => 0,
    };
}

fn isLoopbackAuthority(authority: []const u8) bool {
    const host = if (authority[0] == '[') blk: {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return false;
        break :blk authority[1..close];
    } else blk: {
        const colon = std.mem.indexOfScalar(u8, authority, ':');
        break :blk if (colon) |at| authority[0..at] else authority;
    };

    if (std.mem.eql(u8, host, "localhost")) return true;
    if (host.len >= 4 and std.mem.startsWith(u8, host, "127.")) {
        var parts = std.mem.splitScalar(u8, host, '.');
        var count: usize = 0;
        while (parts.next()) |part| : (count += 1) {
            if (part.len == 0 or part.len > 3) return false;
            const value = std.fmt.parseInt(u8, part, 10) catch return false;
            if (count == 0 and value != 127) return false;
        }
        return count == 4;
    }
    return isIpv6Loopback(host);
}

fn isIpv6Loopback(host: []const u8) bool {
    if (std.mem.eql(u8, host, "::1")) return true;
    var groups = std.mem.splitScalar(u8, host, ':');
    var count: usize = 0;
    var last: ?u16 = null;
    var saw_empty = false;
    while (groups.next()) |group| {
        if (group.len == 0) {
            saw_empty = true;
            continue;
        }
        if (group.len > 4) return false;
        if (last) |value| {
            if (value != 0) return false;
        }
        last = std.fmt.parseInt(u16, group, 16) catch return false;
        count += 1;
    }
    return last == 1 and ((saw_empty and count < 8) or (!saw_empty and count == 8));
}

const digest =
    "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

test "duration input is bounded and resolves once" {
    const cases = [_]struct {
        text: []const u8,
        expected: u64,
    }{
        .{ .text = "1ms", .expected = std.time.ns_per_ms },
        .{ .text = "9s", .expected = 9 * std.time.ns_per_s },
        .{ .text = "12m", .expected = 12 * std.time.ns_per_min },
        .{ .text = "24h", .expected = max_deadline_ns },
    };
    for (cases) |case| {
        const parsed = try parseDuration(case.text);
        try std.testing.expectEqual(case.expected, parsed.relative_ns);
        try std.testing.expectEqual(@as(i128, 7 + case.expected), try parsed.absoluteNs(7));
    }
    try std.testing.expectEqual(@as(i128, 42), try (DeadlineInput{ .absolute_ns = 42 }).absoluteNs(7));

    for ([_][]const u8{ "", "0s", "1", "-1s", "1.5s", "25h", "18446744073709551615h" }) |text| {
        try std.testing.expectError(error.InvalidDuration, parseDuration(text));
    }
}

test "endpoint credential policies are explicit and conflicting inputs fail" {
    const reference = try wabt.oci.parseReference("localhost:5000/team/app:tag", .source);

    var basic: EndpointBuilder = .{};
    var basic_args = [_][]const u8{ "--username", "alice", "--password-stdin" };
    var index: usize = 0;
    while (index < basic_args.len) : (index += 1) {
        try std.testing.expect(try basic.consume(&basic_args, &index, .single));
    }
    const basic_options = (try basic.finish(reference)).?;
    try std.testing.expect(basic_options.credentials == .basic);
    try std.testing.expectEqualStrings("alice", basic_options.credentials.basic.username);
    try std.testing.expect(basic_options.credentials.basic.secret == .stdin);

    var token: EndpointBuilder = .{};
    var token_args = [_][]const u8{ "--token-stdin", "--no-credential-discovery" };
    index = 0;
    while (index < token_args.len) : (index += 1) {
        try std.testing.expect(try token.consume(&token_args, &index, .single));
    }
    try std.testing.expect((try token.finish(reference)).?.credentials == .bearer);

    var auth_file: EndpointBuilder = .{};
    var auth_args = [_][]const u8{ "--auth-file", "auth.json", "--no-credential-discovery" };
    index = 0;
    while (index < auth_args.len) : (index += 1) {
        try std.testing.expect(try auth_file.consume(&auth_args, &index, .single));
    }
    try std.testing.expect((try auth_file.finish(reference)).?.credentials == .auth_file);

    var conflict: EndpointBuilder = .{};
    var conflict_args = [_][]const u8{ "--username", "alice", "--password-stdin", "--token-stdin" };
    index = 0;
    while (index < conflict_args.len) : (index += 1) {
        try std.testing.expect(try conflict.consume(&conflict_args, &index, .single));
    }
    try std.testing.expectError(error.ConflictingCredentialOptions, conflict.finish(reference));

    var username_only: EndpointBuilder = .{};
    var username_args = [_][]const u8{ "--username", "alice" };
    index = 0;
    try std.testing.expect(try username_only.consume(&username_args, &index, .single));
    try std.testing.expectError(
        error.UsernameRequiresPasswordStdin,
        username_only.finish(reference),
    );

    var password_only: EndpointBuilder = .{};
    var password_args = [_][]const u8{"--password-stdin"};
    index = 0;
    try std.testing.expect(try password_only.consume(&password_args, &index, .single));
    try std.testing.expectError(
        error.PasswordStdinRequiresUsername,
        password_only.finish(reference),
    );

    var duplicate: EndpointBuilder = .{};
    var duplicate_args = [_][]const u8{ "--ca-file", "one.pem", "--ca-file", "two.pem" };
    index = 0;
    try std.testing.expect(try duplicate.consume(&duplicate_args, &index, .single));
    index += 1;
    try std.testing.expectError(
        error.DuplicateOption,
        duplicate.consume(&duplicate_args, &index, .single),
    );

    var missing: EndpointBuilder = .{};
    var missing_args = [_][]const u8{"--deadline"};
    index = 0;
    try std.testing.expectError(
        error.MissingOptionValue,
        missing.consume(&missing_args, &index, .single),
    );
}

test "layout rejects registry options and plain HTTP is loopback only" {
    const layout = try wabt.oci.parseReference("oci:layout:root", .source);
    try std.testing.expect((try (EndpointBuilder{}).finish(layout)) == null);

    var layout_options: EndpointBuilder = .{};
    var layout_args = [_][]const u8{"--source-no-credential-discovery"};
    var index: usize = 0;
    try std.testing.expect(try layout_options.consume(&layout_args, &index, .source));
    try std.testing.expectError(error.RegistryOptionForLayout, layout_options.finish(layout));

    var insecure: EndpointBuilder = .{};
    var http_args = [_][]const u8{"--plain-http"};
    index = 0;
    try std.testing.expect(try insecure.consume(&http_args, &index, .single));
    const remote = try wabt.oci.parseReference("registry.example/team/app@" ++ digest, .source);
    try std.testing.expectError(error.InsecurePlainHttp, insecure.finish(remote));

    const loopbacks = [_][]const u8{
        "localhost:5000/team/app:tag",
        "127.0.0.2/team/app:tag",
        "[::1]:5000/team/app:tag",
        "[0:0:0:0:0:0:0:1]/team/app:tag",
    };
    for (loopbacks) |text| {
        try std.testing.expect((try insecure.finish(
            try wabt.oci.parseReference(text, .source),
        )).?.plain_http);
    }
}

test "stdin request order is source then destination" {
    const source = EndpointOptions{
        .credentials = .{ .basic = .{
            .username = "source-user",
            .secret = .stdin,
        } },
    };
    const destination = EndpointOptions{
        .credentials = .{ .bearer = .stdin },
    };
    var requests: [2]SecretRequest = undefined;
    var count: usize = 0;
    appendStdinRequests(source, .source, &requests, &count);
    appendStdinRequests(destination, .destination, &requests, &count);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(EndpointRole.source, requests[0].role);
    try std.testing.expectEqual(SecretKind.password, requests[0].kind);
    try std.testing.expectEqual(EndpointRole.destination, requests[1].role);
    try std.testing.expectEqual(SecretKind.token, requests[1].kind);
}

test "plaintext secret flags and unsafe values are rejected" {
    for ([_][]const u8{
        "--password",
        "--password=secret",
        "--token",
        "--source-password=secret",
        "--destination-token=value",
    }) |arg| {
        try std.testing.expect(isPlaintextSecretOption(arg));
    }

    var builder: EndpointBuilder = .{};
    var args = [_][]const u8{"--password=do-not-print"};
    var index: usize = 0;
    try std.testing.expectError(
        error.PlaintextSecretOption,
        builder.consume(&args, &index, .single),
    );
}

test "output filename and RFC3339 validation are syntactic only" {
    try validateOutputFile("out/module.wasm");
    try validateOutputFile("C:\\out\\module.wasm");
    for ([_][]const u8{ "", ".", "..", "out/", "C:\\out\\" }) |path| {
        try std.testing.expectError(error.InvalidOutputFile, validateOutputFile(path));
    }

    try validateRfc3339("2026-09-19T12:16:26Z");
    try validateRfc3339("2024-02-29T23:59:60.123+02:30");
    for ([_][]const u8{
        "2026-09-19",
        "2023-02-29T00:00:00Z",
        "2026-09-19T24:00:00Z",
        "2026-09-19T12:16:26",
    }) |timestamp| {
        try std.testing.expectError(error.InvalidTimestamp, validateRfc3339(timestamp));
    }
}
