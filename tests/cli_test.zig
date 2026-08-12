const std = @import("std");
const cli = @import("cli");

/// A directory of this test's own, named after `prefix`, for a build that would
/// otherwise write into the repository the tests run in.
fn makeCliTempDir(allocator: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    const ts = std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds;
    const name = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ prefix, ts });
    errdefer allocator.free(name);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, name);
    return name;
}

fn cleanupCliTestArtifacts() void {
    const cwd = std.Io.Dir.cwd();

    // Nested Zig cache dirs created by cli.compile_and_run during tests.
    std.Io.Dir.cwd().deleteTree(std.testing.io, ".zig-cache/fun_cli_global_cache") catch {};
    std.Io.Dir.cwd().deleteTree(std.testing.io, ".zig-cache/fun_cli_local_cache") catch {};

    // Legacy per-invocation cache dirs from earlier iterations.
    var dir = cwd.openDir(std.testing.io, ".", .{ .iterate = true }) catch return;
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    while (it.next(std.testing.io) catch null) |entry| {
        switch (entry.kind) {
            .directory => {
                if (std.mem.startsWith(u8, entry.name, ".fun_zig_cache_")) {
                    std.Io.Dir.cwd().deleteTree(std.testing.io, entry.name) catch {};
                }
            },
            .file => {
                // Stray temp C files (should normally be cleaned via defers).
                if (std.mem.endsWith(u8, entry.name, ".c") and
                    (std.mem.startsWith(u8, entry.name, "cli_ok_") or
                        std.mem.startsWith(u8, entry.name, "cli_bad_") or
                        std.mem.startsWith(u8, entry.name, "temp_")))
                {
                    cwd.deleteFile(std.testing.io, entry.name) catch {};
                }

                // Stray exe/pdbs from interrupted runs.
                if ((std.mem.endsWith(u8, entry.name, ".exe") or std.mem.endsWith(u8, entry.name, ".pdb")) and
                    std.mem.startsWith(u8, entry.name, "cli_compile_and_run_"))
                {
                    cwd.deleteFile(std.testing.io, entry.name) catch {};
                }
            },
            else => {},
        }
    }
}

fn writeTempCFile(allocator: std.mem.Allocator, prefix: []const u8, contents: []const u8) ![]const u8 {
    const ts = std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds;
    const name = try std.fmt.allocPrint(allocator, "{s}_{d}.c", .{ prefix, ts });
    errdefer allocator.free(name);

    const f = try std.Io.Dir.cwd().createFile(std.testing.io, name, .{ .read = true });
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, contents);
    return name;
}

test "compile_and_run succeeds with valid C (file)" {
    const allocator = std.testing.allocator;
    defer cleanupCliTestArtifacts();
    const c_src =
        "#include <stdio.h>\n" ++
        "int main(void) {\n" ++
        "  puts(\"ok\");\n" ++
        "  return 0;\n" ++
        "}\n";

    const c_path = try writeTempCFile(allocator, "cli_ok", c_src);
    defer {
        std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
        allocator.free(c_path);
    }

    // Should compile and execute without error.
    try cli.compile_and_run(allocator, std.testing.io, c_path, true, "cli_compile_and_run_ok.fn", &.{}, false, false);
}

test "compile_and_run reports compilation failure for invalid C (file)" {
    const allocator = std.testing.allocator;
    defer cleanupCliTestArtifacts();
    const bad_c_src = "int main( { return 0; }\n";

    const c_path = try writeTempCFile(allocator, "cli_bad", bad_c_src);
    defer {
        std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
        allocator.free(c_path);
    }

    try std.testing.expectError(cli.CliError.CompilationFailed, cli.compile_and_run(allocator, std.testing.io, c_path, true, "cli_compile_and_run_bad.fn", &.{}, false, false));
}

test "parse_args supports -fmt-check-all without -in" {
    const allocator = std.testing.allocator;
    const options = try cli.parse_args(allocator, std.testing.io, &.{"-fmt-check-all"});
    defer cli.free_options(allocator, options);

    try std.testing.expect(options.fmt_check_all);
    try std.testing.expectEqualStrings(".", options.input_file);
}

test "parse_args keeps directory input for -fmt-check-all" {
    const allocator = std.testing.allocator;
    const options = try cli.parse_args(allocator, std.testing.io, &.{ "-fmt-check-all", "-in", "examples" });
    defer cli.free_options(allocator, options);

    try std.testing.expect(options.fmt_check_all);
    try std.testing.expectEqualStrings("examples", options.input_file);
}

test "run_build: compiles a fun.toml manifest's bin target and it runs correctly" {
    const allocator = std.testing.allocator;

    // The build runs in a directory of its own. Writing the manifest into the
    // working directory would overwrite the repository's own `fun.toml`, and
    // deleting it afterwards would take that file with it.
    const root = try makeCliTempDir(allocator, "cli_run_build");
    defer allocator.free(root);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    const manifest_path = try std.fs.path.join(allocator, &.{ root, "fun.toml" });
    defer allocator.free(manifest_path);
    const fn_path = try std.fs.path.join(allocator, &.{ root, "cli_run_build_hello.fn" });
    defer allocator.free(fn_path);
    const exe_leaf = if (@import("builtin").target.os.tag == .windows)
        "cli_run_build_hello.exe"
    else
        "cli_run_build_hello";
    const exe_path = try std.fs.path.join(allocator, &.{ root, "fun-out", "bin", exe_leaf });
    defer allocator.free(exe_path);

    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, manifest_path, .{ .truncate = true });
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "[package]\n" ++
            "name = \"cli-run-build-test\"\n" ++
            "\n" ++
            "[[bin]]\n" ++
            "name = \"cli_run_build_hello\"\n" ++
            "path = \"cli_run_build_hello.fn\"\n");
    }
    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, fn_path, .{ .truncate = true });
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "imp std.c.io;\n" ++
            "fun main() num {\n" ++
            "  printf(\"built by fun build\\n\");\n" ++
            "  ret 0;\n" ++
            "}\n");
    }

    try cli.run_build_in(allocator, std.testing.io, root, false);

    const exe_abs = blk: {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try std.Io.Dir.cwd().realPathFile(std.testing.io, exe_path, &buf);
        break :blk try allocator.dupe(u8, buf[0..n]);
    };
    defer allocator.free(exe_abs);
    const result = try std.process.run(allocator, std.testing.io, .{ .argv = &.{exe_abs} });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| try std.testing.expect(code == 0),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("built by fun build\n", result.stdout);
}

test "run_build: missing fun.toml reports ManifestNotFound" {
    const allocator = std.testing.allocator;

    // An empty directory of its own, so the result does not depend on whether
    // the repository the tests run in happens to carry a manifest.
    const root = try makeCliTempDir(allocator, "cli_run_build_missing");
    defer allocator.free(root);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};

    try std.testing.expectError(cli.CliError.ManifestNotFound, cli.run_build_in(allocator, std.testing.io, root, false));
}
