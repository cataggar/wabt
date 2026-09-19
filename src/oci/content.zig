const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const algorithm = "sha256";
pub const digest_size = Sha256.digest_length;
pub const encoded_size = digest_size * 2;
pub const digest_text_size = algorithm.len + 1 + encoded_size;
pub const blob_path_prefix = "blobs/sha256/";
pub const blob_path_size = blob_path_prefix.len + encoded_size;

pub const Error = error{
    InvalidDigest,
    UnsupportedDigestAlgorithm,
    SizeMismatch,
    DigestMismatch,
    SizeOverflow,
    VerifierFinished,
};

/// A parsed canonical SHA-256 OCI content digest.
pub const Digest = struct {
    bytes: [digest_size]u8,

    pub fn parse(text: []const u8) Error!Digest {
        const separator = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidDigest;
        const name = text[0..separator];
        if (!std.mem.eql(u8, name, algorithm)) {
            if (isCanonicalAlgorithmName(name)) return error.UnsupportedDigestAlgorithm;
            return error.InvalidDigest;
        }
        if (separator != algorithm.len or text.len != digest_text_size) return error.InvalidDigest;

        const encoded = text[separator + 1 ..];
        for (encoded) |byte| {
            if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) {
                return error.InvalidDigest;
            }
        }

        var bytes: [digest_size]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, encoded) catch return error.InvalidDigest;
        return .{ .bytes = bytes };
    }

    pub fn format(self: Digest) [digest_text_size]u8 {
        var text: [digest_text_size]u8 = undefined;
        @memcpy(text[0..algorithm.len], algorithm);
        text[algorithm.len] = ':';
        const encoded = self.blobPathComponent();
        @memcpy(text[algorithm.len + 1 ..], &encoded);
        return text;
    }

    /// Returns the digest-derived filename component, never unparsed input.
    pub fn blobPathComponent(self: Digest) [encoded_size]u8 {
        return std.fmt.bytesToHex(self.bytes, .lower);
    }

    /// Returns the canonical relative path used by an OCI image layout.
    pub fn blobPath(self: Digest) [blob_path_size]u8 {
        var path: [blob_path_size]u8 = undefined;
        @memcpy(path[0..blob_path_prefix.len], blob_path_prefix);
        const component = self.blobPathComponent();
        @memcpy(path[blob_path_prefix.len..], &component);
        return path;
    }

    pub fn eql(a: Digest, b: Digest) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

fn isCanonicalAlgorithmName(name: []const u8) bool {
    if (name.len == 0 or
        (!std.ascii.isLower(name[0]) and !std.ascii.isDigit(name[0]))) return false;

    var previous_separator = false;
    for (name[1..]) |byte| {
        const separator = byte == '+' or byte == '.' or byte == '_' or byte == '-';
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and !separator) return false;
        if (separator and previous_separator) return false;
        previous_separator = separator;
    }
    return !previous_separator;
}

pub fn checkedSize(size: usize) Error!u64 {
    return std.math.cast(u64, size) orelse error.SizeOverflow;
}

pub fn checkedAddSize(current: u64, amount: u64) Error!u64 {
    return std.math.add(u64, current, amount) catch error.SizeOverflow;
}

pub const Verifier = struct {
    expected: Digest,
    expected_size: u64,
    size: u64 = 0,
    hash: Sha256 = Sha256.init(.{}),
    finished: bool = false,

    pub fn init(expected: Digest, expected_size: u64) Verifier {
        return .{ .expected = expected, .expected_size = expected_size };
    }

    pub fn update(self: *Verifier, bytes: []const u8) Error!void {
        if (self.finished) return error.VerifierFinished;
        const byte_count = try checkedSize(bytes.len);
        const new_size = try checkedAddSize(self.size, byte_count);
        if (new_size > self.expected_size) return error.SizeMismatch;
        self.hash.update(bytes);
        self.size = new_size;
    }

    /// Finishing is terminal, including size or digest mismatch results.
    pub fn finish(self: *Verifier) Error!void {
        if (self.finished) return error.VerifierFinished;
        self.finished = true;
        if (self.size != self.expected_size) return error.SizeMismatch;

        var actual: [digest_size]u8 = undefined;
        self.hash.final(&actual);
        if (!std.mem.eql(u8, &actual, &self.expected.bytes)) return error.DigestMismatch;
    }
};

pub fn verifyBytes(expected: Digest, expected_size: u64, bytes: []const u8) Error!void {
    var verifier = Verifier.init(expected, expected_size);
    try verifier.update(bytes);
    try verifier.finish();
}

pub fn digestBytes(bytes: []const u8) Digest {
    var digest: [digest_size]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return .{ .bytes = digest };
}

pub const Description = struct {
    digest: Digest,
    size: u64,
};

pub fn describeBytes(bytes: []const u8) Error!Description {
    return .{
        .digest = digestBytes(bytes),
        .size = try checkedSize(bytes.len),
    };
}

test "digest parse format and blob paths round trip canonically" {
    const text = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const digest = try Digest.parse(text);
    const formatted = digest.format();
    const component = digest.blobPathComponent();
    const path = digest.blobPath();

    try std.testing.expectEqualStrings(text, &formatted);
    try std.testing.expectEqualStrings(text["sha256:".len..], &component);
    try std.testing.expectEqualStrings(
        "blobs/sha256/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        &path,
    );
    try std.testing.expect(digest.eql(try Digest.parse(&formatted)));
}

test "digest parser distinguishes noncanonical syntax and unsupported algorithms" {
    const cases = [_][]const u8{
        "sha256:ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
        "SHA256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "sha256:0123",
        "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef00",
        "sha256-:0123",
        "sha256::0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        ":0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    };
    for (cases) |text| {
        try std.testing.expectError(error.InvalidDigest, Digest.parse(text));
    }

    try std.testing.expectError(
        error.UnsupportedDigestAlgorithm,
        Digest.parse("sha512:0123456789abcdef"),
    );
    try std.testing.expectError(
        error.UnsupportedDigestAlgorithm,
        Digest.parse("blake3:xyz"),
    );
}

test "verifier accepts arbitrary chunking" {
    const bytes = "streamed content across chunks";
    const description = try describeBytes(bytes);
    var verifier = Verifier.init(description.digest, description.size);
    try verifier.update(bytes[0..1]);
    try verifier.update(bytes[1..10]);
    try verifier.update(bytes[10..10]);
    try verifier.update(bytes[10..]);
    try verifier.finish();
}

test "verifier distinguishes early and late size mismatches" {
    const digest = digestBytes("abc");

    var early = Verifier.init(digest, 2);
    try std.testing.expectError(error.SizeMismatch, early.update("abc"));

    var late = Verifier.init(digest, 4);
    try late.update("abc");
    try std.testing.expectError(error.SizeMismatch, late.finish());
}

test "verifier distinguishes digest mismatch" {
    const digest = digestBytes("abc");
    try std.testing.expectError(error.DigestMismatch, verifyBytes(digest, 3, "abd"));
}

test "verifier finish is terminal on success and failure" {
    const digest = digestBytes("abc");

    var complete = Verifier.init(digest, 3);
    try complete.update("abc");
    try complete.finish();
    try std.testing.expectError(error.VerifierFinished, complete.update(""));
    try std.testing.expectError(error.VerifierFinished, complete.finish());

    var incomplete = Verifier.init(digest, 3);
    try incomplete.update("ab");
    try std.testing.expectError(error.SizeMismatch, incomplete.finish());
    try std.testing.expectError(error.VerifierFinished, incomplete.update("c"));
    try std.testing.expectError(error.VerifierFinished, incomplete.finish());

    var mismatched = Verifier.init(digest, 3);
    try mismatched.update("abd");
    try std.testing.expectError(error.DigestMismatch, mismatched.finish());
    try std.testing.expectError(error.VerifierFinished, mismatched.update(""));
    try std.testing.expectError(error.VerifierFinished, mismatched.finish());
}

test "size accounting is checked" {
    try std.testing.expectError(error.SizeOverflow, checkedAddSize(std.math.maxInt(u64), 1));

    var verifier = Verifier.init(digestBytes(""), std.math.maxInt(u64));
    verifier.size = std.math.maxInt(u64);
    try std.testing.expectError(error.SizeOverflow, verifier.update("x"));
}
