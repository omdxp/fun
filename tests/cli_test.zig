const std = @import("std");
const cli = @import("cli");

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
    try cli.compile_and_run(allocator, std.testing.io, c_path, true, "cli_compile_and_run_ok.fn", &.{}, false);
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

    try std.testing.expectError(cli.CliError.CompilationFailed, cli.compile_and_run(allocator, std.testing.io, c_path, true, "cli_compile_and_run_bad.fn", &.{}, false));
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
