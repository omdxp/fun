const std = @import("std");
const cli = @import("cli");
const manifest = cli.manifest;

test "manifest: parses package + single exe target" {
    const allocator = std.testing.allocator;
    const text =
        "[package]\n" ++
        "name = \"myproject\"\n" ++
        "version = \"0.1.0\"\n" ++
        "\n" ++
        "[[exe]]\n" ++
        "name = \"myapp\"\n" ++
        "path = \"src/main.fn\"\n";

    var m = try manifest.parse(allocator, text);
    defer m.deinit();

    try std.testing.expectEqualStrings("myproject", m.package_name);
    try std.testing.expectEqualStrings("0.1.0", m.version);
    try std.testing.expectEqual(@as(usize, 1), m.bins.len);
    try std.testing.expectEqualStrings("myapp", m.bins[0].name);
    try std.testing.expectEqualStrings("src/main.fn", m.bins[0].path);
}

test "manifest: multiple exe targets, comments, and default version" {
    const allocator = std.testing.allocator;
    const text =
        "# a project manifest\n" ++
        "[package]\n" ++
        "name = \"toolchain\"\n" ++
        "\n" ++
        "[[exe]]\n" ++
        "name = \"fun\"\n" ++
        "path = \"cmd/fun/main.fn\"\n" ++
        "\n" ++
        "[[exe]]\n" ++
        "name = \"fls\"\n" ++
        "path = \"cmd/fls/main.fn\"\n";

    var m = try manifest.parse(allocator, text);
    defer m.deinit();

    try std.testing.expectEqualStrings("toolchain", m.package_name);
    try std.testing.expectEqualStrings("0.0.0", m.version);
    try std.testing.expectEqual(@as(usize, 2), m.bins.len);
    try std.testing.expectEqualStrings("fun", m.bins[0].name);
    try std.testing.expectEqualStrings("cmd/fun/main.fn", m.bins[0].path);
    try std.testing.expectEqualStrings("fls", m.bins[1].name);
    try std.testing.expectEqualStrings("cmd/fls/main.fn", m.bins[1].path);
}

test "manifest: missing package section is an error" {
    const allocator = std.testing.allocator;
    const text = "[[exe]]\nname = \"a\"\npath = \"a.fn\"\n";
    try std.testing.expectError(manifest.ManifestError.MissingPackageName, manifest.parse(allocator, text));
}

test "manifest: exe missing a path is an error" {
    const allocator = std.testing.allocator;
    const text = "[package]\nname = \"p\"\n\n[[exe]]\nname = \"a\"\n";
    try std.testing.expectError(manifest.ManifestError.MissingBinPath, manifest.parse(allocator, text));
}

test "manifest: the old [[bin]] spelling is no longer accepted" {
    const allocator = std.testing.allocator;
    const text = "[package]\nname = \"p\"\n\n[[bin]]\nname = \"a\"\npath = \"a.fn\"\n";
    try std.testing.expectError(manifest.ManifestError.InvalidManifest, manifest.parse(allocator, text));
}

test "manifest: unknown section is an error" {
    const allocator = std.testing.allocator;
    const text = "[nope]\nname = \"a\"\n";
    try std.testing.expectError(manifest.ManifestError.InvalidManifest, manifest.parse(allocator, text));
}
