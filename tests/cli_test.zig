const std = @import("std");
const cli = @import("cli");

fn cleanupCliTestArtifacts() void {
    const cwd = std.fs.cwd();

    // Nested Zig cache dirs created by cli.compile_and_run during tests.
    cwd.deleteTree(".zig-cache/fun_cli_global_cache") catch {};
    cwd.deleteTree(".zig-cache/fun_cli_local_cache") catch {};

    // Legacy per-invocation cache dirs from earlier iterations.
    var dir = cwd.openDir(".", .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        switch (entry.kind) {
            .directory => {
                if (std.mem.startsWith(u8, entry.name, ".fun_zig_cache_")) {
                    cwd.deleteTree(entry.name) catch {};
                }
            },
            .file => {
                // Stray temp C files (should normally be cleaned via defers).
                if (std.mem.endsWith(u8, entry.name, ".c") and
                    (std.mem.startsWith(u8, entry.name, "cli_ok_") or
                        std.mem.startsWith(u8, entry.name, "cli_bad_") or
                        std.mem.startsWith(u8, entry.name, "temp_")))
                {
                    cwd.deleteFile(entry.name) catch {};
                }

                // Stray exe/pdbs from interrupted runs.
                if ((std.mem.endsWith(u8, entry.name, ".exe") or std.mem.endsWith(u8, entry.name, ".pdb")) and
                    std.mem.startsWith(u8, entry.name, "cli_compile_and_run_"))
                {
                    cwd.deleteFile(entry.name) catch {};
                }
            },
            else => {},
        }
    }
}

fn writeTempCFile(allocator: std.mem.Allocator, prefix: []const u8, contents: []const u8) ![]const u8 {
    const ts = std.time.nanoTimestamp();
    const name = try std.fmt.allocPrint(allocator, "{s}_{d}.c", .{ prefix, ts });
    errdefer allocator.free(name);

    const f = try std.fs.cwd().createFile(name, .{ .read = true });
    defer f.close();
    try f.writeAll(contents);
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
        std.fs.cwd().deleteFile(c_path) catch {};
        allocator.free(c_path);
    }

    // Should compile and execute without error.
    try cli.compile_and_run(allocator, c_path, true, "cli_compile_and_run_ok.fn", &.{});
}

test "compile_and_run reports compilation failure for invalid C (file)" {
    const allocator = std.testing.allocator;
    defer cleanupCliTestArtifacts();
    const bad_c_src = "int main( { return 0; }\n";

    const c_path = try writeTempCFile(allocator, "cli_bad", bad_c_src);
    defer {
        std.fs.cwd().deleteFile(c_path) catch {};
        allocator.free(c_path);
    }

    try std.testing.expectError(cli.CliError.CompilationFailed, cli.compile_and_run(allocator, c_path, true, "cli_compile_and_run_bad.fn", &.{}));
}
