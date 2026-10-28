//! Static contract tests for the OCI qualification workflow, fixture manifest,
//! documentation, provenance, and release packaging.

const std = @import("std");

fn readRepoFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(16 * 1024 * 1024),
    );
}

fn normalizeWhitespaceLower(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    var iter = std.mem.tokenizeAny(u8, input, " \t\r\n");
    var first = true;
    while (iter.next()) |token| {
        if (!first) {
            try out.append(allocator, ' ');
        }
        first = false;
        for (token) |c| {
            try out.append(allocator, std.ascii.toLower(c));
        }
    }
    return out.toOwnedSlice(allocator);
}

fn requireText(
    allocator: std.mem.Allocator,
    path: []const u8,
    needles: []const []const u8,
) !void {
    const text = try readRepoFile(allocator, path);
    defer allocator.free(text);
    for (needles) |needle| {
        if (std.mem.indexOf(u8, text, needle) == null) {
            std.debug.print("{s}: missing {s}\n", .{ path, needle });
            return error.MissingRequiredText;
        }
    }
}

fn requireNormalizedText(
    allocator: std.mem.Allocator,
    path: []const u8,
    needles: []const []const u8,
) !void {
    const raw = try readRepoFile(allocator, path);
    defer allocator.free(raw);
    const normalized_text = try normalizeWhitespaceLower(allocator, raw);
    defer allocator.free(normalized_text);

    for (needles) |needle| {
        const normalized_needle = try normalizeWhitespaceLower(allocator, needle);
        defer allocator.free(normalized_needle);
        if (std.mem.indexOf(u8, normalized_text, normalized_needle) == null) {
            std.debug.print("{s}: missing {s}\n", .{ path, needle });
            return error.MissingRequiredNormalizedText;
        }
    }
}

fn is40LowerHex(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    }
    return true;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "OCI qualification workflow, manifest, documentation, and package contracts" {
    const allocator = std.testing.allocator;
    const workflow_path = ".github/workflows/oci-interop.yml";
    const workflow = try readRepoFile(allocator, workflow_path);
    defer allocator.free(workflow);

    const generator = try readRepoFile(allocator, "scripts/oci/generate_interop_fixtures.sh");
    defer allocator.free(generator);

    const manifest_bytes = try readRepoFile(allocator, "src/fixtures/oci/manifest.json");
    defer allocator.free(manifest_bytes);

    var parsed_manifest = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        manifest_bytes,
        .{},
    );
    defer parsed_manifest.deinit();
    const manifest = parsed_manifest.value.object;
    const producers = manifest.get("producers").?.object;

    // 1. Check .github/workflows/oci-interop.yml action pins and forbidden/required strings.
    var action_count: usize = 0;
    var lines = std.mem.splitScalar(u8, workflow, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        const uses_rest = if (std.mem.startsWith(u8, line, "uses:"))
            line["uses:".len..]
        else if (std.mem.startsWith(u8, line, "- uses:"))
            line["- uses:".len..]
        else
            continue;

        const spec = std.mem.trimStart(u8, uses_rest, " \t");
        const at_idx = std.mem.indexOfScalar(u8, spec, '@') orelse return error.InvalidActionUses;
        if (at_idx == 0) return error.InvalidActionUses;
        const after_at = spec[at_idx + 1 ..];
        const end_idx = std.mem.indexOfAny(u8, after_at, " \t#") orelse after_at.len;
        const action_ref = after_at[0..end_idx];
        action_count += 1;
        if (!is40LowerHex(action_ref)) {
            std.debug.print(
                "{s}: action is not pinned by a full commit SHA: {s}\n",
                .{ workflow_path, action_ref },
            );
            return error.UnpinnedActionRef;
        }
    }
    try std.testing.expect(action_count > 0);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "secrets.") == null);
    try std.testing.expect(!containsIgnoreCase(workflow, "azure"));
    try std.testing.expect(!containsIgnoreCase(workflow, "acr"));
    try std.testing.expect(std.mem.indexOf(u8, workflow, "docker ") == null);

    try requireText(allocator, workflow_path, &.{
        "runs-on: ubuntu-22.04-arm",
        "persist-credentials: false",
        "WABT_OCI_INTEROP_MODE: qualify",
        "WABT_OCI_INTEROP_STATE_DIR=$RUNNER_TEMP/wabt-oci-interoperability",
        "${{ runner.temp }}/wabt-oci-interoperability/tools/downloads",
        "for pass in one two",
        "scripts/oci/generate_interop_fixtures.sh",
        "scripts/oci/verify_interop_fixtures.sh",
        "git diff --exit-code -- src/fixtures/oci",
        "if: failure()",
        "summary.txt",
        "retention-days: 3",
    });

    // 2. Check manifest.json schema, layouts, matrix, and producer pins.
    try std.testing.expectEqualStrings(
        "wabt.oci.interop-fixtures",
        manifest.get("schema").?.string,
    );
    try std.testing.expectEqual(@as(i64, 1), manifest.get("schemaVersion").?.integer);
    try std.testing.expectEqualStrings(
        "linux/arm64",
        manifest.get("executionPlatform").?.string,
    );

    const expected_layouts = [_][]const u8{
        "copy-roundtrip",
        "index",
        "oras-oci-v1.0",
        "oras-oci-v1.1",
        "wabt-oci-v1.1",
        "wabt-wasm-v0",
        "wkg-wasm-v0",
    };
    const layouts = manifest.get("layouts").?.object;
    try std.testing.expectEqual(expected_layouts.len, layouts.count());
    for (expected_layouts) |layout_name| {
        try std.testing.expect(layouts.contains(layout_name));
    }

    const matrix_items = manifest.get("matrix").?.array.items;
    const required_cases = [_][]const u8{
        "wkg-to-wabt",
        "wabt-wasm-v0-to-wkg",
        "oras-oci-1.0-to-wabt",
        "oras-oci-1.1-to-wabt",
        "wabt-generic-to-oras",
        "wabt-generic-to-wkg",
        "digest-preserving-copies",
        "index-preservation-and-extraction-rejection",
    };
    for (required_cases) |case_id| {
        var found = false;
        for (matrix_items) |item| {
            const obj = item.object;
            if (std.mem.eql(u8, obj.get("id").?.string, case_id)) {
                found = true;
                if (std.mem.eql(u8, case_id, "wabt-generic-to-wkg")) {
                    try std.testing.expectEqualStrings(
                        "pass-expected-rejection",
                        obj.get("result").?.string,
                    );
                }
                break;
            }
        }
        try std.testing.expect(found);
    }

    const oras = producers.get("oras").?.object;
    const wkg = producers.get("wkg").?.object;
    const oci_wasm = producers.get("oci-wasm").?.object;
    const registry = producers.get("registry").?.object;
    const rustup = producers.get("rustup").?.object;
    const wkg_build = wkg.get("build").?.object;
    const compiler_ver_line = wkg_build.get("compiler").?.object
        .get("versionOutput").?.array.items[0].string;
    var ver_tok = std.mem.tokenizeAny(u8, compiler_ver_line, " \t");
    _ = ver_tok.next();
    const rust_ver = ver_tok.next() orelse return error.MissingCompilerVersion;

    const pinned_values = [_][]const u8{
        oras.get("version").?.string,
        oras.get("commit").?.string,
        oras.get("checksumList").?.object.get("sha256").?.string,
        oras.get("archive").?.object.get("sha256").?.string,
        wkg.get("version").?.string,
        wkg.get("sourceRevision").?.string,
        wkg.get("sourceTree").?.string,
        wkg.get("cargoLockSha256").?.string,
        oci_wasm.get("version").?.string,
        oci_wasm.get("crateChecksumSha256").?.string,
        oci_wasm.get("tagCommit").?.string,
        registry.get("version").?.string,
        registry.get("archive").?.object.get("sha256").?.string,
        rustup.get("version").?.string,
        rustup.get("archive").?.object.get("sha256").?.string,
        rust_ver,
    };
    for (pinned_values) |pin| {
        if (std.mem.indexOf(u8, generator, pin) == null) {
            std.debug.print("generator missing manifest pin {s}\n", .{pin});
            return error.MissingManifestPin;
        }
    }

    try requireText(allocator, "scripts/oci/generate_interop_fixtures.sh", &.{
        "WABT_OCI_INTEROP_MODE",
        "WABT_OCI_INTEROP_STATE_DIR",
        "RUNNER_TEMP",
        "registry\" serve",
        "oci_fixture_manifest.zig\" -- qualify",
        "oci_fixture_manifest.zig\" -- verify",
        "MAX_STATE_KIB",
    });

    // 3. Check retired Python scripts do not exist.
    for ([_][]const u8{
        "scripts/oci_interop.py",
        "scripts/check_oci_qualification.py",
        "scripts/oci/fixture_manifest.py",
    }) |retired_path| {
        try std.testing.expectError(
            error.FileNotFound,
            std.Io.Dir.cwd().statFile(std.testing.io, retired_path, .{}),
        );
    }

    // 4. Check documentation, CLI, packaging, provenance, notices, and CI workflow contracts.
    try requireNormalizedText(allocator, "docs/oci.md", &.{
        "wabt oci push",
        "wabt oci pull",
        "wabt oci copy",
        "wabt oci inspect",
        "wabt oci resolve",
        "wabt oci list-tags",
        "wabt.oci.push",
        "wabt.oci.pull",
        "wabt.oci.copy",
        "wabt.oci.inspect",
        "wabt.oci.resolve",
        "wabt.oci.list-tags",
        "operator-run azure container registry walkthrough",
        "00000000-0000-0000-0000-000000000000",
        "az acr login --name \"$acr_name\" --expose-token",
        "transport evidence is not runtime qualification",
        "not automatically wkg-compatible",
        "does not execute",
        "signing or signature verification",
        "production-readiness",
        "wamr and wasmtime execution is outside transport qualification",
    });

    try requireNormalizedText(allocator, "README.md", &.{
        "## OCI artifacts",
        "[OCI user guide](docs/oci.md)",
        "does not execute",
    });

    try requireText(allocator, "src/tools/oci.zig", &.{
        "https://github.com/cataggar/wabt/blob/main/docs/oci.md",
        "never execute downloaded WebAssembly",
    });

    try requireText(allocator, "build.zig.zon", &.{
        "\"docs\"",
        "\"SOURCE_PROVENANCE.md\"",
        "\"THIRD_PARTY_NOTICES.md\"",
    });

    try requireText(allocator, ".github/workflows/release.yml", &.{
        "cp -R docs \"$PKGNAME/\"",
        "\"$PKGNAME/docs/oci.md\"",
        "\"$PKGNAME/docs/oci-authentication.md\"",
        "## Highlights",
        "## Full changelog",
        "## Install",
    });

    try requireText(allocator, "scripts/build_wheels.py", &.{
        "(\"docs/oci.md\", \"docs/oci.md\")",
        "(\"docs/oci-authentication.md\", \"docs/oci-authentication.md\")",
    });

    try requireText(allocator, "src/fixtures/oci/README.md", &.{
        "scripts/oci/verify_interop_fixtures.sh",
        "scripts/oci/generate_interop_fixtures.sh",
        "2026-09-19T00:00:00Z",
    });

    const provenance = try readRepoFile(allocator, "SOURCE_PROVENANCE.md");
    defer allocator.free(provenance);
    const provenance_values = [_][]const u8{
        oras.get("archive").?.object.get("sha256").?.string,
        oras.get("binary").?.object.get("sha256").?.string,
        wkg.get("binary").?.object.get("sha256").?.string,
        registry.get("archive").?.object.get("sha256").?.string,
        registry.get("binary").?.object.get("sha256").?.string,
        wkg_build.get("compiler").?.object.get("sha256").?.string,
        wkg_build.get("cargo").?.object.get("sha256").?.string,
        wkg_build.get("zigLinker").?.object.get("sha256").?.string,
    };
    for (provenance_values) |val| {
        if (std.mem.indexOf(u8, provenance, val) == null) {
            std.debug.print("SOURCE_PROVENANCE.md missing {s}\n", .{val});
            return error.MissingProvenanceHash;
        }
    }
    try requireNormalizedText(allocator, "SOURCE_PROVENANCE.md", &.{
        "oras cli 1.3.4",
        "wkg 0.16.1",
        "oci-wasm 0.6.0",
        "distribution registry 3.1.1",
        "transport interoperability does not claim signature verification",
    });

    try requireNormalizedText(allocator, "THIRD_PARTY_NOTICES.md", &.{
        "oci fixture and qualification producers",
        "not runtime dependencies",
    });

    const ci = try readRepoFile(allocator, ".github/workflows/ci.yml");
    defer allocator.free(ci);
    try std.testing.expect(std.mem.indexOf(u8, ci, "oci-interop") == null);
    try std.testing.expect(
        std.mem.indexOf(u8, ci, "os: [ubuntu-22.04, macos-latest, windows-latest]") != null and
            std.mem.indexOf(u8, ci, "optimize: [debug, safe]") != null,
    );
}
