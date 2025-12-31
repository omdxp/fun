const std = @import("std");
const cli = @import("cli");

fn writeTempFnFile(allocator: std.mem.Allocator, prefix: []const u8, contents: []const u8) ![]const u8 {
    const ts = std.time.nanoTimestamp();
    const name = try std.fmt.allocPrint(allocator, "{s}_{d}.fn", .{ prefix, ts });
    errdefer allocator.free(name);

    const f = try std.fs.cwd().createFile(name, .{ .read = true });
    defer f.close();
    try f.writeAll(contents);
    return name;
}

fn makeTempDir(allocator: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    const ts = std.time.nanoTimestamp();
    const name = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ prefix, ts });
    errdefer allocator.free(name);
    try std.fs.cwd().makePath(name);
    return name;
}

fn writeFileInDir(allocator: std.mem.Allocator, dir: []const u8, rel: []const u8, contents: []const u8) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ dir, rel });
    errdefer allocator.free(path);

    if (std.fs.path.dirname(path)) |pdir| {
        try std.fs.cwd().makePath(pdir);
    }

    const f = try std.fs.cwd().createFile(path, .{ .read = true });
    defer f.close();
    try f.writeAll(contents);
    return path;
}

fn deleteTreeIfExists(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
}

test "-fmt formats file in-place" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun  add(num a,num b) num{ret a+b;}\n" ++
        "//comment\n" ++
        "if true{ret 1;}else{ret 2;}\n";

    const path = try writeTempFnFile(allocator, "fmt", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    const expected =
        "fun add(num a, num b) num {\n" ++
        "    ret a + b;\n" ++
        "}\n" ++
        "//comment\n" ++
        "if true {\n" ++
        "    ret 1;\n" ++
        "} else {\n" ++
        "    ret 2;\n" ++
        "}\n";

    try std.testing.expectEqualStrings(expected, got);
}

test "-fmt keeps a blank line between functions" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun a() num{ret 1;}fun b() num{ret 2;}\n";

    const path = try writeTempFnFile(allocator, "fmt_two", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    const expected =
        "fun a() num {\n" ++
        "    ret 1;\n" ++
        "}\n" ++
        "\n" ++
        "fun b() num {\n" ++
        "    ret 2;\n" ++
        "}\n";

    try std.testing.expectEqualStrings(expected, got);
}

test "-fmt groups imports and globals at top" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun main() num{ret 0;}\n" ++
        "imp std.io;\n" ++
        "num x=1;\n" ++
        "imp foo.bar;\n" ++
        "num y=2;\n";

    const path = try writeTempFnFile(allocator, "fmt_groups", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    const expected =
        "imp std.io;\n" ++
        "imp foo.bar;\n" ++
        "\n" ++
        "num x = 1;\n" ++
        "num y = 2;\n" ++
        "\n" ++
        "fun main() num {\n" ++
        "    ret 0;\n" ++
        "}\n";

    try std.testing.expectEqualStrings(expected, got);
}

test "-fmt-all formats local imports recursively (skips std.*)" {
    const allocator = std.testing.allocator;

    const dir = try makeTempDir(allocator, "fmt_all");
    defer {
        deleteTreeIfExists(dir);
        allocator.free(dir);
    }

    // main.fn imports a local module and std.io (std import should be skipped).
    const main_path = try writeFileInDir(
        allocator,
        dir,
        "main.fn",
        "imp foo.bar; imp std.io; fun  main() num{ret 0;}\n",
    );
    defer allocator.free(main_path);

    const imported_path = try writeFileInDir(
        allocator,
        dir,
        "foo/bar.fn",
        "fun  add(num a,num b) num{ret a+b;}\n",
    );
    defer allocator.free(imported_path);

    try cli.format_file_and_imports_in_place(allocator, main_path);

    const got_main = try std.fs.cwd().readFileAlloc(allocator, main_path, 1024 * 1024);
    defer allocator.free(got_main);
    try std.testing.expect(std.mem.indexOf(u8, got_main, "imp foo.bar;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got_main, "imp std.io;\n") != null);

    const got_import = try std.fs.cwd().readFileAlloc(allocator, imported_path, 1024 * 1024);
    defer allocator.free(got_import);
    const expected_imported =
        "fun add(num a, num b) num {\n" ++
        "    ret a + b;\n" ++
        "}\n";
    try std.testing.expectEqualStrings(expected_imported, got_import);
}

test "-fmt-all has cycle protection" {
    const allocator = std.testing.allocator;

    const dir = try makeTempDir(allocator, "fmt_cycle");
    defer {
        deleteTreeIfExists(dir);
        allocator.free(dir);
    }

    const a_path = try writeFileInDir(
        allocator,
        dir,
        "a.fn",
        "imp b; fun a() num{ret 1;}\n",
    );
    defer allocator.free(a_path);

    const b_path = try writeFileInDir(
        allocator,
        dir,
        "b.fn",
        "imp a; fun b() num{ret 2;}\n",
    );
    defer allocator.free(b_path);

    try cli.format_file_and_imports_in_place(allocator, a_path);

    const got_a = try std.fs.cwd().readFileAlloc(allocator, a_path, 1024 * 1024);
    defer allocator.free(got_a);
    try std.testing.expect(std.mem.indexOf(u8, got_a, "fun a() num") != null);

    const got_b = try std.fs.cwd().readFileAlloc(allocator, b_path, 1024 * 1024);
    defer allocator.free(got_b);
    try std.testing.expect(std.mem.indexOf(u8, got_b, "fun b() num") != null);
}
