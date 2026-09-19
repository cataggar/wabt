const std = @import("std");
const content = @import("content.zig");

pub const Operation = enum {
    source,
    destination,
    list_tags,
};

pub const ParseMode = Operation;

pub const Selection = union(enum) {
    tag: []const u8,
    digest: content.Digest,
};

pub const RegistryReference = struct {
    authority: []const u8,
    repository: []const u8,
    selection: ?Selection,
};

pub const LayoutReference = struct {
    path: []const u8,
    selection: ?Selection,
};

pub const Reference = union(enum) {
    registry: RegistryReference,
    layout: LayoutReference,
};

pub const Error = error{
    InvalidReference,
    InvalidAuthority,
    InvalidRepository,
    InvalidTag,
    InvalidLayoutPath,
    InvalidLayoutName,
    MissingSelection,
    UnexpectedSelection,
} || content.Error;

/// Parses exactly one of:
/// - `AUTHORITY/REPOSITORY:TAG`
/// - `AUTHORITY/REPOSITORY@sha256:<hex>`
/// - `oci:PATH`, optionally followed by either selector
///
/// Registry source and destination operations require a selector. List-tags
/// accepts only a selector-less registry repository.
pub fn parse(text: []const u8, operation: Operation) Error!Reference {
    if (text.len == 0) return error.InvalidReference;
    if (std.mem.startsWith(u8, text, "oci:")) {
        if (operation == .list_tags) return error.InvalidReference;
        return .{ .layout = try parseLayout(text["oci:".len..], operation) };
    }
    if (std.mem.indexOf(u8, text, "://") != null) return error.InvalidReference;
    return .{ .registry = try parseRegistry(text, operation) };
}

fn parseRegistry(value: []const u8, operation: Operation) Error!RegistryReference {
    if (hasForbiddenUriSyntax(value)) return error.InvalidReference;

    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return error.InvalidReference;
    const authority = value[0..slash];
    try validateAuthority(authority);

    const repository_and_selection = value[slash + 1 ..];
    const split = try splitRegistrySelection(repository_and_selection);
    try validateRepository(split.base);
    try validateRegistrySelection(split.selection, operation);
    return .{
        .authority = authority,
        .repository = split.base,
        .selection = split.selection,
    };
}

fn parseLayout(value: []const u8, operation: Operation) Error!LayoutReference {
    if (value.len == 0 or hasForbiddenUriSyntax(value) or containsControl(value)) {
        return error.InvalidLayoutPath;
    }
    if (isDriveRelativePath(value)) return error.InvalidLayoutPath;

    const split = try splitLayoutSelection(value);
    try validateLayoutPath(split.base);
    if (split.selection) |selection| switch (selection) {
        .tag => |tag| try validateLayoutName(tag),
        .digest => {},
    };
    try validateLayoutSelection(split.selection, operation);
    return .{ .path = split.base, .selection = split.selection };
}

const Split = struct {
    base: []const u8,
    selection: ?Selection,
};

fn splitRegistrySelection(value: []const u8) Error!Split {
    if (value.len == 0) return error.InvalidRepository;
    if (std.mem.indexOfScalar(u8, value, '@')) |at| {
        if (std.mem.indexOfScalarPos(u8, value, at + 1, '@') != null) {
            return error.InvalidReference;
        }
        return .{
            .base = value[0..at],
            .selection = .{ .digest = try content.Digest.parse(value[at + 1 ..]) },
        };
    }

    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse {
        return .{ .base = value, .selection = null };
    };
    const tag = value[colon + 1 ..];
    try validateTag(tag);
    return .{ .base = value[0..colon], .selection = .{ .tag = tag } };
}

fn splitLayoutSelection(value: []const u8) Error!Split {
    if (std.mem.indexOfScalar(u8, value, '@')) |at| {
        if (std.mem.indexOfScalarPos(u8, value, at + 1, '@') != null) {
            return error.InvalidReference;
        }
        return .{
            .base = value[0..at],
            .selection = .{ .digest = try content.Digest.parse(value[at + 1 ..]) },
        };
    }

    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse {
        return .{ .base = value, .selection = null };
    };
    if (isAbsoluteDriveColon(value, colon)) {
        return .{ .base = value, .selection = null };
    }

    const tag = value[colon + 1 ..];
    try validateLayoutName(tag);
    return .{ .base = value[0..colon], .selection = .{ .tag = tag } };
}

fn validateRegistrySelection(selection: ?Selection, operation: Operation) Error!void {
    switch (operation) {
        .source, .destination => if (selection == null) return error.MissingSelection,
        .list_tags => if (selection != null) return error.UnexpectedSelection,
    }
}

fn validateLayoutSelection(selection: ?Selection, operation: Operation) Error!void {
    switch (operation) {
        .source, .destination => {},
        .list_tags => if (selection != null) return error.UnexpectedSelection,
    }
}

fn validateAuthority(authority: []const u8) Error!void {
    if (authority.len == 0 or authority.len > 255 or
        std.mem.indexOfScalar(u8, authority, '@') != null or
        containsControl(authority)) return error.InvalidAuthority;

    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidAuthority;
        if (close == 1) return error.InvalidAuthority;
        _ = std.Io.net.IpAddress.parseIp6(authority[1..close], 0) catch return error.InvalidAuthority;
        if (close + 1 == authority.len) return;
        if (authority[close + 1] != ':' or close + 2 > authority.len) {
            return error.InvalidAuthority;
        }
        try validatePort(authority[close + 2 ..]);
        return;
    }

    if (std.mem.indexOfScalar(u8, authority, '[') != null or
        std.mem.indexOfScalar(u8, authority, ']') != null) return error.InvalidAuthority;

    const colon = std.mem.indexOfScalar(u8, authority, ':');
    if (colon) |index| {
        if (std.mem.indexOfScalarPos(u8, authority, index + 1, ':') != null) {
            return error.InvalidAuthority;
        }
        try validateHost(authority[0..index]);
        try validatePort(authority[index + 1 ..]);
    } else {
        try validateHost(authority);
    }
}

fn validateHost(host: []const u8) Error!void {
    if (host.len == 0 or host.len > 253) return error.InvalidAuthority;

    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or
            label[0] == '-' or label[label.len - 1] == '-') return error.InvalidAuthority;
        for (label) |byte| {
            if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '-') {
                return error.InvalidAuthority;
            }
        }
    }
}

fn validatePort(port: []const u8) Error!void {
    if (port.len == 0 or port.len > 5) return error.InvalidAuthority;

    var number: u32 = 0;
    for (port) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidAuthority;
        number = number * 10 + (byte - '0');
    }
    if (number == 0 or number > 65535) return error.InvalidAuthority;
}

fn validateRepository(repository: []const u8) Error!void {
    if (repository.len == 0 or repository.len > 255 or
        repository[0] == '/' or repository[repository.len - 1] == '/')
    {
        return error.InvalidRepository;
    }

    var segments = std.mem.splitScalar(u8, repository, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or
            (!std.ascii.isLower(segment[0]) and !std.ascii.isDigit(segment[0])) or
            (!std.ascii.isLower(segment[segment.len - 1]) and
                !std.ascii.isDigit(segment[segment.len - 1])))
        {
            return error.InvalidRepository;
        }

        var index: usize = 0;
        while (index < segment.len) {
            while (index < segment.len and
                (std.ascii.isLower(segment[index]) or std.ascii.isDigit(segment[index])))
            {
                index += 1;
            }
            if (index == segment.len) break;

            switch (segment[index]) {
                '.' => index += 1,
                '_' => {
                    index += 1;
                    if (index < segment.len and segment[index] == '_') index += 1;
                },
                '-' => while (index < segment.len and segment[index] == '-') : (index += 1) {},
                else => return error.InvalidRepository,
            }
            if (index == segment.len or
                (!std.ascii.isLower(segment[index]) and !std.ascii.isDigit(segment[index])))
            {
                return error.InvalidRepository;
            }
        }
    }
}

fn validateTag(tag: []const u8) Error!void {
    if (tag.len == 0 or tag.len > 128 or
        (!std.ascii.isAlphanumeric(tag[0]) and tag[0] != '_')) return error.InvalidTag;
    for (tag) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '.' and byte != '-') {
            return error.InvalidTag;
        }
    }
}

fn validateLayoutName(name: []const u8) Error!void {
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\:@") != null) {
        return error.InvalidLayoutName;
    }
    validateTag(name) catch return error.InvalidLayoutName;
}

fn validateLayoutPath(path: []const u8) Error!void {
    if (path.len == 0 or containsControl(path) or isDriveRelativePath(path)) {
        return error.InvalidLayoutPath;
    }
    var colon_index = std.mem.indexOfScalar(u8, path, ':');
    while (colon_index) |index| {
        if (!isAbsoluteDriveColon(path, index)) return error.InvalidLayoutPath;
        colon_index = std.mem.indexOfScalarPos(u8, path, index + 1, ':');
    }
}

fn hasForbiddenUriSyntax(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, "?#") != null;
}

fn containsControl(value: []const u8) bool {
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) return true;
    }
    return false;
}

fn isDriveRelativePath(value: []const u8) bool {
    return value.len >= 2 and std.ascii.isAlphabetic(value[0]) and value[1] == ':' and
        (value.len == 2 or (value[2] != '\\' and value[2] != '/'));
}

fn isAbsoluteDriveColon(value: []const u8, colon: usize) bool {
    return colon == 1 and value.len >= 3 and std.ascii.isAlphabetic(value[0]) and
        (value[2] == '\\' or value[2] == '/');
}

const test_digest = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

test "accepted references cover registry layout and operation modes" {
    const cases = [_]struct {
        text: []const u8,
        operation: Operation,
        kind: std.meta.Tag(Reference),
    }{
        .{ .text = "registry.example/team/image:stable", .operation = .source, .kind = .registry },
        .{ .text = "localhost:5000/repo:Tag_1.2", .operation = .destination, .kind = .registry },
        .{ .text = "[2001:db8::1]:5000/team/image@" ++ test_digest, .operation = .source, .kind = .registry },
        .{ .text = "registry.example/team/image", .operation = .list_tags, .kind = .registry },
        .{ .text = "oci:/var/lib/layout", .operation = .source, .kind = .layout },
        .{ .text = "oci:relative/layout:stable", .operation = .destination, .kind = .layout },
        .{ .text = "oci:C:\\images\\layout:stable", .operation = .source, .kind = .layout },
        .{ .text = "oci:C:/images/layout@" ++ test_digest, .operation = .source, .kind = .layout },
        .{ .text = "oci:\\\\server\\share\\layout:stable", .operation = .source, .kind = .layout },
        .{ .text = "oci://server/share/layout", .operation = .destination, .kind = .layout },
    };

    for (cases) |case| {
        const reference = try parse(case.text, case.operation);
        try std.testing.expectEqual(case.kind, std.meta.activeTag(reference));
    }
}

test "parsed registry and Windows layout fields are unambiguous" {
    const registry = (try parse(
        "[2001:db8::1]:5000/team/image@" ++ test_digest,
        .source,
    )).registry;
    try std.testing.expectEqualStrings("[2001:db8::1]:5000", registry.authority);
    try std.testing.expectEqualStrings("team/image", registry.repository);
    try std.testing.expect(registry.selection.? == .digest);

    const windows = (try parse("oci:C:\\images\\layout:stable", .source)).layout;
    try std.testing.expectEqualStrings("C:\\images\\layout", windows.path);
    try std.testing.expectEqualStrings("stable", windows.selection.?.tag);

    const unc = (try parse("oci:\\\\server\\share\\layout:root", .source)).layout;
    try std.testing.expectEqualStrings("\\\\server\\share\\layout", unc.path);
    try std.testing.expectEqualStrings("root", unc.selection.?.tag);
}

test "rejected references cover unsafe ambiguous and mode-invalid forms" {
    const cases = [_]struct {
        text: []const u8,
        operation: Operation,
        expected: anyerror,
    }{
        .{ .text = "docker://registry.example/team/image:tag", .operation = .source, .expected = error.InvalidReference },
        .{ .text = "registry.example/team/image", .operation = .source, .expected = error.MissingSelection },
        .{ .text = "registry.example/team/image:tag", .operation = .list_tags, .expected = error.UnexpectedSelection },
        .{ .text = "oci:/layout", .operation = .list_tags, .expected = error.InvalidReference },
        .{ .text = "user@registry.example/team/image:tag", .operation = .source, .expected = error.InvalidAuthority },
        .{ .text = "registry.example:0/team/image:tag", .operation = .source, .expected = error.InvalidAuthority },
        .{ .text = "registry.example:65536/team/image:tag", .operation = .source, .expected = error.InvalidAuthority },
        .{ .text = "[2001:db8:::1]/team/image:tag", .operation = .source, .expected = error.InvalidAuthority },
        .{ .text = "2001:db8::1/team/image:tag", .operation = .source, .expected = error.InvalidAuthority },
        .{ .text = "Registry.example/team/image:tag", .operation = .source, .expected = error.InvalidAuthority },
        .{ .text = "registry.example/Team/image:tag", .operation = .source, .expected = error.InvalidRepository },
        .{ .text = "registry.example/team//image:tag", .operation = .source, .expected = error.InvalidRepository },
        .{ .text = "registry.example/team/foo..bar:tag", .operation = .source, .expected = error.InvalidRepository },
        .{ .text = "registry.example/team/image:bad!", .operation = .source, .expected = error.InvalidTag },
        .{ .text = "registry.example/team/image:tag?query", .operation = .source, .expected = error.InvalidReference },
        .{ .text = "registry.example/team/image:tag#fragment", .operation = .source, .expected = error.InvalidReference },
        .{ .text = "registry.example/team/image@" ++ test_digest ++ "@again", .operation = .source, .expected = error.InvalidReference },
        .{ .text = "registry.example/team/image@sha256:ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789", .operation = .source, .expected = error.InvalidDigest },
        .{ .text = "registry.example/team/image@sha512:00", .operation = .source, .expected = error.UnsupportedDigestAlgorithm },
        .{ .text = "oci:", .operation = .source, .expected = error.InvalidLayoutPath },
        .{ .text = "oci:C:layout", .operation = .source, .expected = error.InvalidLayoutPath },
        .{ .text = "oci:C:layout:tag", .operation = .source, .expected = error.InvalidLayoutPath },
        .{ .text = "oci:/layout:bad:tag", .operation = .source, .expected = error.InvalidLayoutPath },
        .{ .text = "oci:C:\\layout:bad:tag", .operation = .source, .expected = error.InvalidLayoutPath },
        .{ .text = "oci:/layout:bad/name", .operation = .source, .expected = error.InvalidLayoutName },
        .{ .text = "oci:/layout:bad\\name", .operation = .source, .expected = error.InvalidLayoutName },
        .{ .text = "oci:/layout:tag?query", .operation = .source, .expected = error.InvalidLayoutPath },
        .{ .text = "oci:/layout@" ++ test_digest ++ "@again", .operation = .source, .expected = error.InvalidReference },
    };

    for (cases) |case| {
        try std.testing.expectError(case.expected, parse(case.text, case.operation));
    }
}
