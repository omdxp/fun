const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const lexer = @import("lexer");
const ParseProcess = @import("parser").ParseProcess;
const codegen = @import("codegen");
const cli = @import("cli");

/// Compatibility shim: ArrayList with embedded allocator (old-style managed API).
fn ArrayList(comptime T: type) type {
    return std.array_list.Managed(T);
}

const EnvOverride = struct {
    key: []const u8,
    value: []const u8,
};

fn runTranspile(allocator: std.mem.Allocator, input_path: []const u8, input: []const u8) ![]const u8 {
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, input_path, .{ .read = true, .truncate = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, input);
    }

    const out_path = try std.fmt.allocPrint(allocator, "{s}.out.c", .{input_path});
    defer allocator.free(out_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, out_path) catch {};

    var transpile_proc = try codegen.TranspileProcess.init(allocator, input_path, out_path, .{
        .outf = false,
        .preload_imports = false,
        .preload_std_imports = false,
        .emit_stderr = false,
    });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);

    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
    }

    try lex_proc.lex();
    try parse_proc.parse();
    try transpile_proc.transpile();

    const out = transpile_proc.get_output() orelse return error.NoOutput;
    // Copy it so it remains valid after deinit.
    return allocator.dupe(u8, out);
}

fn runTranspileExpectFailure(allocator: std.mem.Allocator, input_path: []const u8, input: []const u8) !void {
    const out_owned = runTranspile(allocator, input_path, input) catch {
        std.Io.Dir.cwd().deleteFile(std.testing.io, input_path) catch {};
        return;
    };
    defer allocator.free(out_owned);
    std.Io.Dir.cwd().deleteFile(std.testing.io, input_path) catch {};
    return error.ExpectedFailure;
}

fn compileWithZigCc(allocator: std.mem.Allocator, c_path: []const u8, exe_path: []const u8) !void {
    var argv = ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    try argv.append("zig");
    try argv.append("cc");
    try argv.append(c_path);
    try argv.append("-o");
    try argv.append(exe_path);
    if (builtin.os.tag == .windows) {
        // `std.c.net` uses winsock symbols on Windows.
        try argv.append("-lws2_32");
    } else {
        try argv.append("-lm");
    }

    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = argv.items,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                if (result.stderr.len != 0) {
                    std.debug.print("{s}\n", .{result.stderr});
                }
                return error.CompilationFailed;
            }
        },
        else => return error.CompilationFailed,
    }
}

fn normalizeCrLfOwned(allocator: std.mem.Allocator, owned: []u8) ![]u8 {
    var crlf_count: usize = 0;
    var i: usize = 0;
    while (i + 1 < owned.len) : (i += 1) {
        if (owned[i] == '\r' and owned[i + 1] == '\n') {
            crlf_count += 1;
        }
    }

    if (crlf_count == 0) {
        return owned;
    }

    const out_len = owned.len - crlf_count;
    var out = allocator.alloc(u8, out_len) catch |err| {
        allocator.free(owned);
        return err;
    };

    var read_i: usize = 0;
    var write_i: usize = 0;
    while (read_i < owned.len) : (read_i += 1) {
        if (read_i + 1 < owned.len and owned[read_i] == '\r' and owned[read_i + 1] == '\n') {
            continue;
        }
        out[write_i] = owned[read_i];
        write_i += 1;
    }

    std.debug.assert(write_i == out_len);
    allocator.free(owned);
    return out;
}

fn runExeWithEnv(allocator: std.mem.Allocator, exe_path: []const u8, overrides: []const EnvOverride) ![]const u8 {
    const exe_abs = blk: {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try std.Io.Dir.cwd().realPathFile(std.testing.io, exe_path, &buf);
        break :blk try allocator.dupe(u8, buf[0..n]);
    };
    defer allocator.free(exe_abs);

    var env_map = try std.testing.environ.createMap(allocator);
    defer env_map.deinit();

    for (overrides) |ov| {
        try env_map.put(ov.key, ov.value);
    }

    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{exe_abs},
        .environ_map = &env_map,
        .stdout_limit = .limited(10 * 1024 * 1024),
        .stderr_limit = .limited(10 * 1024 * 1024),
    });
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                allocator.free(result.stdout);
                return error.ExecutionFailed;
            }
        },
        else => {
            allocator.free(result.stdout);
            return error.ExecutionFailed;
        },
    }

    return normalizeCrLfOwned(allocator, result.stdout);
}

fn runExeWithEnvTimeout(
    allocator: std.mem.Allocator,
    exe_path: []const u8,
    overrides: []const EnvOverride,
    timeout_ms: u32,
) ![]const u8 {
    const exe_abs = blk: {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try std.Io.Dir.cwd().realPathFile(std.testing.io, exe_path, &buf);
        break :blk try allocator.dupe(u8, buf[0..n]);
    };
    defer allocator.free(exe_abs);

    var env_map = try std.testing.environ.createMap(allocator);
    defer env_map.deinit();

    for (overrides) |ov| {
        try env_map.put(ov.key, ov.value);
    }

    const result = std.process.run(allocator, std.testing.io, .{
        .argv = &.{exe_abs},
        .environ_map = &env_map,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(@intCast(timeout_ms)), .clock = .real } },
    }) catch |err| switch (err) {
        error.Timeout => return error.ExecutionTimedOut,
        else => return err,
    };
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                if (result.stderr.len != 0) {
                    std.debug.print("{s}\n", .{result.stderr});
                }
                allocator.free(result.stdout);
                return error.ExecutionFailed;
            }
        },
        else => {
            allocator.free(result.stdout);
            return error.ExecutionFailed;
        },
    }

    return normalizeCrLfOwned(allocator, result.stdout);
}

fn parseMetricValue(stdout: []const u8, key: []const u8) ![]const u8 {
    var lines = std.mem.tokenizeScalar(u8, stdout, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len <= key.len) continue;
        if (line[key.len] != '=') continue;
        if (std.mem.eql(u8, line[0..key.len], key)) {
            return line[key.len + 1 ..];
        }
    }

    return error.MetricNotFound;
}

fn parseMetricInt(stdout: []const u8, key: []const u8) !i64 {
    const value = try parseMetricValue(stdout, key);
    return std.fmt.parseInt(i64, value, 10);
}

test "if/elif/else transpiles" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_if_elif_else.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  num x = 1;\n" ++
        "  if x == 1 { printf(\"a\\n\"); }\n" ++
        "  elif x == 2 { printf(\"b\\n\"); }\n" ++
        "  else { printf(\"c\\n\"); }\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "if (") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "if (x == 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "else if (x == 2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "else {") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "defer inside false if branch does not run" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_defer_if_branch.fn";
    const c_path = "codegen_defer_if_branch.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_defer_if_branch.exe" else "codegen_defer_if_branch";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "fun logLine(str msg) { printf(\"%s\\n\", msg); }\n" ++
        "fun main() num {\n" ++
        "  num x = 43;\n" ++
        "  if x == 42 {\n" ++
        "    defer logLine(\"defer inside if\");\n" ++
        "  }\n" ++
        "  defer logLine(\"always\");\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);

    try std.testing.expectEqualStrings("always\n", stdout);
}

test "defer inside fit branch runs only for matched branch" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_defer_fit_branch.fn";
    const c_path = "codegen_defer_fit_branch.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_defer_fit_branch.exe" else "codegen_defer_fit_branch";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "fun logLine(str msg) { printf(\"%s\\n\", msg); }\n" ++
        "fun runCase(num x) {\n" ++
        "  printf(\"case=%lld\\n\", x);\n" ++
        "  defer logLine(\"defer always\");\n" ++
        "  fit x {\n" ++
        "    1 -> {\n" ++
        "      logLine(\"body1\");\n" ++
        "      defer logLine(\"defer branch1\");\n" ++
        "    },\n" ++
        "    2 -> {\n" ++
        "      logLine(\"body2\");\n" ++
        "    },\n" ++
        "    _ -> {\n" ++
        "      logLine(\"body_\");\n" ++
        "      defer logLine(\"defer branch_\");\n" ++
        "    }\n" ++
        "  }\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  runCase(1);\n" ++
        "  runCase(2);\n" ++
        "  runCase(3);\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);

    const expected =
        "case=1\n" ++
        "body1\n" ++
        "defer branch1\n" ++
        "defer always\n" ++
        "case=2\n" ++
        "body2\n" ++
        "defer always\n" ++
        "case=3\n" ++
        "body_\n" ++
        "defer branch_\n" ++
        "defer always\n";
    try std.testing.expectEqualStrings(expected, stdout);
}

test "defer in range loop runs at each iteration end" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_defer_range_loop.fn";
    const c_path = "codegen_defer_range_loop.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_defer_range_loop.exe" else "codegen_defer_range_loop";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "fun logLine(str msg) { printf(\"%s\\n\", msg); }\n" ++
        "fun main() num {\n" ++
        "  for i : 0..3 {\n" ++
        "    printf(\"body=%lld\\n\", i);\n" ++
        "    defer logLine(\"defer iter\");\n" ++
        "  }\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);

    const expected =
        "body=0\n" ++
        "defer iter\n" ++
        "body=1\n" ++
        "defer iter\n" ++
        "body=2\n" ++
        "defer iter\n";
    try std.testing.expectEqualStrings(expected, stdout);
}

test "defer in loop runs on continue and break" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_defer_loop_continue_break.fn";
    const c_path = "codegen_defer_loop_continue_break.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_defer_loop_continue_break.exe" else "codegen_defer_loop_continue_break";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "fun logLine(str msg) { printf(\"%s\\n\", msg); }\n" ++
        "fun main() num {\n" ++
        "  num i = 0;\n" ++
        "  for i < 4 {\n" ++
        "    defer logLine(\"defer iter\");\n" ++
        "    i = i + 1;\n" ++
        "    if i == 2 {\n" ++
        "      logLine(\"continue\");\n" ++
        "      continue;\n" ++
        "    }\n" ++
        "    if i == 3 {\n" ++
        "      logLine(\"break\");\n" ++
        "      break;\n" ++
        "    }\n" ++
        "    logLine(\"tail\");\n" ++
        "  }\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);

    const expected =
        "tail\n" ++
        "defer iter\n" ++
        "continue\n" ++
        "defer iter\n" ++
        "break\n" ++
        "defer iter\n";
    try std.testing.expectEqualStrings(expected, stdout);
}

test "array indexing expression transpiles" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_index.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  num[] arr = [1, 2, 3];\n" ++
        "  num x = arr[1];\n" ++
        "  printf(\"%d\\n\", x);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t arr[] = {1, 2, 3};") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "arr[1]") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "compound assignment transpiles" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_compound_assign.fn";

    const input =
        "fun main() {\n" ++
        "  num x = 1;\n" ++
        "  x += 2;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "x += 2") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "raw pointer maps to void*" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_raw_ptr.fn";

    const input =
        "fun id(raw* p) raw* { ret p; }\n" ++
        "fun main() { raw* x = id(0); }\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "void* id(void* p)") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "async and await surface transpiles and runs" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_async_await_surface.fn";
    const c_path = "codegen_async_await_surface.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_async_await_surface.exe" else "codegen_async_await_surface";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "async fun inc(num x) num { ret x + 1; }\n" ++
        "async fun main() {\n" ++
        "  num out = await inc(41);\n" ++
        "  printf(\"%lld\", out);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t inc(int64_t x)") != null);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42", stdout);
}

test "async and await let surface transpiles and runs" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_async_await_let_surface.fn";
    const c_path = "codegen_async_await_let_surface.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_async_await_let_surface.exe" else "codegen_async_await_let_surface";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "async fun inc(num x) num { ret x + 1; }\n" ++
        "async fun main() {\n" ++
        "  let out = await inc(41);\n" ++
        "  printf(\"%lld\", out);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "__fun_async_call_inc") != null);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42", stdout);
}

test "async await statement form transpiles and runs" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_async_await_statement_surface.fn";
    const c_path = "codegen_async_await_statement_surface.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_async_await_statement_surface.exe" else "codegen_async_await_statement_surface";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "async fun inc(num x) num { ret x + 1; }\n" ++
        "async fun main() {\n" ++
        "  await inc(40);\n" ++
        "  num out = await inc(41);\n" ++
        "  printf(\"%lld\", out);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "__fun_async_call_inc(40);") != null);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42", stdout);
}

test "let await requires async context during transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_let_await_requires_async_context.fn";
    const input =
        "async fun inc(num x) num { ret x + 1; }\n" ++
        "fun main() {\n" ++
        "  let out = await inc(1);\n" ++
        "  _ = out;\n" ++
        "}\n";

    try runTranspileExpectFailure(allocator, ifilepath, input);
}

test "let async call requires await during transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_let_async_call_requires_await.fn";
    const input =
        "async fun inc(num x) num { ret x + 1; }\n" ++
        "async fun main() {\n" ++
        "  let out = inc(1);\n" ++
        "  _ = out;\n" ++
        "}\n";

    try runTranspileExpectFailure(allocator, ifilepath, input);
}

test "async impl method await transpiles and runs" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_async_impl_method_await.fn";
    const c_path = "codegen_async_impl_method_await.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_async_impl_method_await.exe" else "codegen_async_impl_method_await";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "impl Counter {\n" ++
        "  async add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Counter c;\n" ++
        "  c.base = 41;\n" ++
        "  num out = await c.add(1);\n" ++
        "  printf(\"%lld\", out);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "__fun_async_call_Counter__add(") != null);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42", stdout);
}

test "async field method await transpiles and runs" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_async_field_method_await.fn";
    const c_path = "codegen_async_field_method_await.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_async_field_method_await.exe" else "codegen_async_field_method_await";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "compound Holder {\n" ++
        "  Counter counter;\n" ++
        "}\n" ++
        "impl Counter {\n" ++
        "  async add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Holder h;\n" ++
        "  h.counter.base = 41;\n" ++
        "  num out = await h.counter.add(1);\n" ++
        "  printf(\"%lld\", out);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "__fun_async_call_Counter__add(") != null);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42", stdout);
}

test "async generic function await transpiles and runs" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_async_generic_fn_await.fn";
    const c_path = "codegen_async_generic_fn_await.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_async_generic_fn_await.exe" else "codegen_async_generic_fn_await";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "async fun id<T>(T x) T { ret x; }\n" ++
        "async fun main() {\n" ++
        "  num out = await id(42);\n" ++
        "  printf(\"%lld\", out);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "__fun_async_call_id__num(") != null);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42", stdout);
}

test "async generic impl method await transpiles and runs" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_async_generic_method_await.fn";
    const c_path = "codegen_async_generic_method_await.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_async_generic_method_await.exe" else "codegen_async_generic_method_await";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "compound Box<T> {\n" ++
        "  num pad;\n" ++
        "}\n" ++
        "impl Box<T> {\n" ++
        "  async forty_two() num { ret 42; }\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Box<num> b;\n" ++
        "  num out = await b.forty_two();\n" ++
        "  printf(\"%lld\", out);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "__fun_async_call_Box__num__forty_two(") != null);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42", stdout);
}

test "async quirk dispatch await transpiles and runs" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_async_quirk_dispatch_await.fn";
    const c_path = "codegen_async_quirk_dispatch_await.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_async_quirk_dispatch_await.exe" else "codegen_async_quirk_dispatch_await";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "quirk AsyncCounter {\n" ++
        "  async add(num x) num;\n" ++
        "}\n" ++
        "impl Counter as AsyncCounter {\n" ++
        "  async add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Counter c;\n" ++
        "  c.base = 41;\n" ++
        "  AsyncCounter q = &c;\n" ++
        "  num out = await q.add(1);\n" ++
        "  printf(\"%lld\", out);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, ".vtable->add(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "__fun_async_call_Counter__AsyncCounter__add") != null);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42", stdout);
}

test "async quirk field dispatch await transpiles and runs" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_async_quirk_field_dispatch_await.fn";
    const c_path = "codegen_async_quirk_field_dispatch_await.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_async_quirk_field_dispatch_await.exe" else "codegen_async_quirk_field_dispatch_await";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "quirk AsyncCounter {\n" ++
        "  async add(num x) num;\n" ++
        "}\n" ++
        "compound Holder {\n" ++
        "  AsyncCounter q;\n" ++
        "}\n" ++
        "impl Counter as AsyncCounter {\n" ++
        "  async add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Counter c;\n" ++
        "  c.base = 41;\n" ++
        "  Holder h = Holder{ q = &c };\n" ++
        "  num out = await h.q.add(1);\n" ++
        "  printf(\"%lld\", out);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, ".vtable->add(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "h.q") != null);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42", stdout);
}

test "async quirk function-returned receiver await transpiles and runs" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_async_quirk_function_receiver_await.fn";
    const c_path = "codegen_async_quirk_function_receiver_await.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_async_quirk_function_receiver_await.exe" else "codegen_async_quirk_function_receiver_await";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "quirk AsyncCounter {\n" ++
        "  async add(num x) num;\n" ++
        "}\n" ++
        "impl Counter as AsyncCounter {\n" ++
        "  async add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "fun passthrough(AsyncCounter q) AsyncCounter {\n" ++
        "  ret q;\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Counter c;\n" ++
        "  c.base = 41;\n" ++
        "  AsyncCounter q = &c;\n" ++
        "  num out = await passthrough(q).add(1);\n" ++
        "  printf(\"%lld\", out);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, ".vtable->add(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "passthrough") != null);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42", stdout);
}

test "async quirk nested composite receiver await transpiles and runs" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_async_quirk_nested_receiver_await.fn";
    const c_path = "codegen_async_quirk_nested_receiver_await.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_async_quirk_nested_receiver_await.exe" else "codegen_async_quirk_nested_receiver_await";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "quirk AsyncCounter {\n" ++
        "  async add(num x) num;\n" ++
        "}\n" ++
        "compound Holder {\n" ++
        "  AsyncCounter q;\n" ++
        "}\n" ++
        "compound Wrap {\n" ++
        "  Holder h;\n" ++
        "}\n" ++
        "impl Counter as AsyncCounter {\n" ++
        "  async add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "fun wrap(AsyncCounter q) Wrap {\n" ++
        "  ret Wrap{ h = Holder{ q = q } };\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Counter c;\n" ++
        "  c.base = 41;\n" ++
        "  AsyncCounter q = &c;\n" ++
        "  num out = await wrap(q).h.q.add(1);\n" ++
        "  printf(\"%lld\", out);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, ".vtable->add(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "wrap") != null);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42", stdout);
}

test "async quirk generic wrapper receiver await transpiles and runs" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_async_quirk_generic_wrapper_receiver_await.fn";
    const c_path = "codegen_async_quirk_generic_wrapper_receiver_await.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_async_quirk_generic_wrapper_receiver_await.exe" else "codegen_async_quirk_generic_wrapper_receiver_await";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "quirk AsyncCounter {\n" ++
        "  async add(num x) num;\n" ++
        "}\n" ++
        "compound Box<T> {\n" ++
        "  T v;\n" ++
        "}\n" ++
        "impl Counter as AsyncCounter {\n" ++
        "  async add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "fun pack(AsyncCounter q) Box<AsyncCounter> {\n" ++
        "  ret Box<AsyncCounter>{ v = q };\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Counter c;\n" ++
        "  c.base = 41;\n" ++
        "  AsyncCounter q = &c;\n" ++
        "  num out = await pack(q).v.add(1);\n" ++
        "  printf(\"%lld\", out);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, ".vtable->add(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Box") != null);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42", stdout);
}

test "async quirk parenthesized generic receiver await transpiles and runs" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_async_quirk_paren_generic_receiver_await.fn";
    const c_path = "codegen_async_quirk_paren_generic_receiver_await.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_async_quirk_paren_generic_receiver_await.exe" else "codegen_async_quirk_paren_generic_receiver_await";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "quirk AsyncCounter {\n" ++
        "  async add(num x) num;\n" ++
        "}\n" ++
        "compound Box<T> {\n" ++
        "  T v;\n" ++
        "}\n" ++
        "impl Counter as AsyncCounter {\n" ++
        "  async add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "fun pack(AsyncCounter q) Box<AsyncCounter> {\n" ++
        "  ret Box<AsyncCounter>{ v = q };\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Counter c;\n" ++
        "  c.base = 41;\n" ++
        "  AsyncCounter q = &c;\n" ++
        "  num out = await (pack(q).v).add(1);\n" ++
        "  printf(\"%lld\", out);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, ".vtable->add(") != null);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42", stdout);
}

test "async quirk pointer generic receiver await transpiles and runs" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_async_quirk_ptr_generic_receiver_await.fn";
    const c_path = "codegen_async_quirk_ptr_generic_receiver_await.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_async_quirk_ptr_generic_receiver_await.exe" else "codegen_async_quirk_ptr_generic_receiver_await";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "quirk AsyncCounter {\n" ++
        "  async add(num x) num;\n" ++
        "}\n" ++
        "compound Box<T> {\n" ++
        "  T v;\n" ++
        "}\n" ++
        "impl Counter as AsyncCounter {\n" ++
        "  async add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "fun ptr(Box<AsyncCounter>* b) Box<AsyncCounter>* {\n" ++
        "  ret b;\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Counter c;\n" ++
        "  c.base = 41;\n" ++
        "  AsyncCounter q = &c;\n" ++
        "  Box<AsyncCounter> b = Box<AsyncCounter>{ v = q };\n" ++
        "  num out = await (*ptr(&b)).v.add(1);\n" ++
        "  printf(\"%lld\", out);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, ".vtable->add(") != null);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42", stdout);
}

test "async quirk helper pointer generic receiver await transpiles and runs" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_async_quirk_helper_ptr_generic_receiver_await.fn";
    const c_path = "codegen_async_quirk_helper_ptr_generic_receiver_await.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_async_quirk_helper_ptr_generic_receiver_await.exe" else "codegen_async_quirk_helper_ptr_generic_receiver_await";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "quirk AsyncCounter {\n" ++
        "  async add(num x) num;\n" ++
        "}\n" ++
        "compound Box<T> {\n" ++
        "  T v;\n" ++
        "}\n" ++
        "impl Counter as AsyncCounter {\n" ++
        "  async add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "fun ptr(Box<AsyncCounter>* b) Box<AsyncCounter>* {\n" ++
        "  ret b;\n" ++
        "}\n" ++
        "fun box(Box<AsyncCounter>* b) Box<AsyncCounter> {\n" ++
        "  ret *b;\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Counter c;\n" ++
        "  c.base = 41;\n" ++
        "  AsyncCounter q = &c;\n" ++
        "  Box<AsyncCounter> b = Box<AsyncCounter>{ v = q };\n" ++
        "  num out = await (box(ptr(&b)).v).add(1);\n" ++
        "  printf(\"%lld\", out);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, ".vtable->add(") != null);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42", stdout);
}

test "async quirk indexed generic receiver await transpiles and runs" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_async_quirk_indexed_generic_receiver_await.fn";
    const c_path = "codegen_async_quirk_indexed_generic_receiver_await.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_async_quirk_indexed_generic_receiver_await.exe" else "codegen_async_quirk_indexed_generic_receiver_await";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "quirk AsyncCounter {\n" ++
        "  async add(num x) num;\n" ++
        "}\n" ++
        "impl Counter as AsyncCounter {\n" ++
        "  async add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "Counter[] counters = [Counter{ base = 40 }, Counter{ base = 41 }];\n" ++
        "async fun main() {\n" ++
        "  Counter picked = counters[1];\n" ++
        "  num out = await picked.add(1);\n" ++
        "  printf(\"%lld\", out);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Counter__AsyncCounter__add") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "[1]") != null);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42", stdout);
}

test "aliased module async quirk generic receiver await transpiles and runs" {
    const allocator = std.testing.allocator;
    const mod_path = "codegen_alias_async_quirk_mod.fn";
    const main_path = "codegen_alias_async_quirk_main.fn";
    const c_path = "codegen_alias_async_quirk_main.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_alias_async_quirk_main.exe" else "codegen_alias_async_quirk_main";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, mod_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, main_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    {
        const mod_file = try std.Io.Dir.cwd().createFile(std.testing.io, mod_path, .{ .read = true });
        defer mod_file.close(std.testing.io);
        try mod_file.writeStreamingAll(
            std.testing.io,
            "pub compound Counter {\n" ++
                "  num base;\n" ++
                "}\n" ++
                "pub quirk AsyncCounter {\n" ++
                "  async add(num x) num;\n" ++
                "}\n" ++
                "impl Counter as AsyncCounter {\n" ++
                "  async add(num x) num { ret self.base + x; }\n" ++
                "}\n" ++
                "pub fun to_async(Counter* c) AsyncCounter {\n" ++
                "  ret c;\n" ++
                "}\n",
        );
    }

    const input =
        "imp std.c.io;\n" ++
        "imp codegen_alias_async_quirk_mod as m;\n" ++
        "async fun main() {\n" ++
        "  m.Counter c;\n" ++
        "  c.base = 41;\n" ++
        "  num out = await (m.to_async(&c)).add(1);\n" ++
        "  printf(\"%lld\", out);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, main_path, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, ".vtable->add(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "m__to_async") != null);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42", stdout);
}

test "function definitions can be out of order (prototypes emitted)" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_fn_prototype_order.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  foo();\n" ++
        "}\n" ++
        "fun foo() {\n" ++
        "  printf(\"ok\\n\");\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    const proto_idx = std.mem.indexOf(u8, out_owned, "void foo();") orelse return error.TestExpectedPrototype;
    const main_idx = std.mem.indexOf(u8, out_owned, "int main") orelse return error.TestExpectedMain;
    try std.testing.expect(proto_idx < main_idx);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "declaration-only function emits semicolon prototype" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_decl_only_fn.fn";

    const input =
        "fun someCFunc() str;\n" ++
        "fun main() {\n" ++
        "  someCFunc();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "char* someCFunc();") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "char* someCFunc() ;") == null);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "aliased import calls transpile to qualified symbols" {
    const allocator = std.testing.allocator;
    const ifilepath = "examples/imports/alias_collision/main_codegen_alias.fn";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};

    const input =
        "imp mod1 as one;\n" ++
        "imp mod2 as two;\n" ++
        "fun main() {\n" ++
        "  num a = one.pick();\n" ++
        "  num b = two.pick();\n" ++
        "  _ = a + b;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "one__pick(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "two__pick(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t one__pick()") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t two__pick()") != null);
}

test "aliased import supports public type and value access" {
    const allocator = std.testing.allocator;
    const mod_path = "codegen_alias_exports_mod.fn";
    const main_path = "codegen_alias_exports_main.fn";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, mod_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, main_path) catch {};

    {
        const mod_file = try std.Io.Dir.cwd().createFile(std.testing.io, mod_path, .{ .read = true });
        defer mod_file.close(std.testing.io);
        try mod_file.writeStreamingAll(
            std.testing.io,
            "pub compound User {\n" ++
                "  num id;\n" ++
                "}\n" ++
                "pub num answer = 7;\n" ++
                "pub fun get_answer() num { ret answer; }\n",
        );
    }

    const input =
        "imp codegen_alias_exports_mod as m;\n" ++
        "fun main() {\n" ++
        "  m.User u;\n" ++
        "  u.id = m.answer;\n" ++
        "  num a = m.get_answer();\n" ++
        "  _ = u.id + a;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, main_path, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "User u") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "m__answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "m__get_answer(") != null);
}

test "aliased compound method calls use canonical impl" {
    const allocator = std.testing.allocator;
    const mod_path = "codegen_alias_compound_mod.fn";
    const main_path = "codegen_alias_compound_main.fn";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, mod_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, main_path) catch {};

    {
        const mod_file = try std.Io.Dir.cwd().createFile(std.testing.io, mod_path, .{ .read = true });
        defer mod_file.close(std.testing.io);
        try mod_file.writeStreamingAll(
            std.testing.io,
            "pub compound Vec2 {\n" ++
                "  dec x;\n" ++
                "  dec y;\n" ++
                "}\n" ++
                "impl Vec2 {\n" ++
                "  pub len() dec { ret self.x + self.y; }\n" ++
                "}\n",
        );
    }

    const input =
        "imp codegen_alias_compound_mod as g;\n" ++
        "fun main() {\n" ++
        "  g.Vec2 v;\n" ++
        "  v.x = 1.0;\n" ++
        "  v.y = 2.0;\n" ++
        "  dec s = v.len();\n" ++
        "  _ = s;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, main_path, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "typedef struct Vec2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Vec2__len(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "g__Vec2__len(") == null);
}

test "aliased io.format with bare placeholder renders values" {
    const allocator = std.testing.allocator;
    const input_path = "codegen_alias_io_format_main.fn";
    const c_path = "codegen_alias_io_format_main.c";
    const out_path = "codegen_alias_io_format_out.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, input_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, out_path) catch {};

    const input =
        "imp std.io as io;\n" ++
        "fun main() {\n" ++
        "  str msg = io.format(\"Hello, {}!\", \"Alice\");\n" ++
        "  _ = io.write_all(\"codegen_alias_io_format_out.txt\", msg);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, input_path, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try cli.compile_and_run(allocator, std.testing.io, c_path, true, input_path, &.{}, false);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, out_path, allocator, .limited(1024 * 1024));
    defer allocator.free(got);
    try std.testing.expectEqualStrings("Hello, Alice!", got);
}

test "aliased math rand option program compiles and runs" {
    const allocator = std.testing.allocator;
    const input_path = "codegen_alias_math_rand_option_main.fn";
    const c_path = "codegen_alias_math_rand_option_main.c";
    const out_path = "codegen_alias_math_rand_option_out.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, input_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, out_path) catch {};

    const input =
        "imp std.io as io;\n" ++
        "imp std.math as m;\n" ++
        "imp std.rand as r;\n" ++
        "imp std.option;\n\n" ++
        "compound Person<T> {\n" ++
        "  T name;\n" ++
        "  num age;\n" ++
        "  Option<str> nickname;\n" ++
        "}\n\n" ++
        "impl Person<T> {\n" ++
        "  new(T name, num age) Person<T> {\n" ++
        "    ret Person{name = name, age = age, nickname = some(\"none\")};\n" ++
        "  }\n" ++
        "}\n\n" ++
        "fun main() {\n" ++
        "  let root = m.sqrt_dec(4);\n" ++
        "  r.Rand rand = r.rand_init(42);\n" ++
        "  let flip = rand.chance(0.5);\n" ++
        "\n" ++
        "  Person<str> p;\n" ++
        "  p = p.new(\"Alice\", 30);\n" ++
        "  p.nickname = some(\"Ally\");\n" ++
        "  let nick = p.nickname.unwrap_or(\"none\");\n" ++
        "\n" ++
        "  _ = root;\n" ++
        "  _ = flip;\n" ++
        "  str msg = io.format(\"{str}\", nick);\n" ++
        "  _ = io.write_all(\"codegen_alias_math_rand_option_out.txt\", msg);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, input_path, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try cli.compile_and_run(allocator, std.testing.io, c_path, true, input_path, &.{}, false);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, out_path, allocator, .limited(1024 * 1024));
    defer allocator.free(got);
    try std.testing.expectEqualStrings("Ally", got);
}

test "aliased sys try_env and log program compiles and runs" {
    const allocator = std.testing.allocator;
    const input_path = "codegen_sys_log_alias_main.fn";
    const c_path = "codegen_sys_log_alias_main.c";
    const out_path = "codegen_sys_log_alias_out.txt";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, input_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, out_path) catch {};

    const input =
        "imp std.io as io;\n" ++
        "imp std.log as l;\n" ++
        "imp std.result;\n" ++
        "imp std.sys as sys;\n\n" ++
        "fun main() {\n" ++
        "  let env = sys.try_env(\"PATH\");\n" ++
        "  Result<str> copy = env;\n" ++
        "  str status = \"err\";\n" ++
        "  if copy.is_ok() {\n" ++
        "    status = \"ok\";\n" ++
        "  }\n" ++
        "  l.log(l.LogLevel.Info, \"env check\");\n" ++
        "  l.Logger logger = l.logger_init(l.LogLevel.Debug);\n" ++
        "  logger.warn(\"warn\");\n" ++
        "  _ = io.write_all(\"codegen_sys_log_alias_out.txt\", status);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, input_path, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try cli.compile_and_run(allocator, std.testing.io, c_path, true, input_path, &.{}, false);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, out_path, allocator, .limited(1024 * 1024));
    defer allocator.free(got);
    try std.testing.expectEqualStrings("ok", got);
}

test "defer emits in LIFO order before return" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_defer_lifo.fn";

    const input =
        "fun a() { ret; }\n" ++
        "fun b() { ret; }\n" ++
        "fun foo() num {\n" ++
        "  defer a();\n" ++
        "  defer b();\n" ++
        "  ret 1;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    // The return value is snapshotted into a temp BEFORE the defers run (so a defer
    // mutating a returned variable can't corrupt the value), then the defers emit in
    // LIFO order (b before a), then the function returns the temp. So the ordering is:
    //   __fun_ret_N = 1;  b();  a();  return __fun_ret_N;
    const ret_assign_opt = std.mem.indexOf(u8, out_owned, "__fun_ret");
    const b_pos_opt = std.mem.lastIndexOf(u8, out_owned, "b();");
    const a_pos_opt = std.mem.lastIndexOf(u8, out_owned, "a();");
    const ret_pos_opt = std.mem.lastIndexOf(u8, out_owned, "return __fun_ret");
    try std.testing.expect(ret_assign_opt != null);
    try std.testing.expect(b_pos_opt != null);
    try std.testing.expect(a_pos_opt != null);
    try std.testing.expect(ret_pos_opt != null);
    const ret_assign = ret_assign_opt.?;
    const b_pos = b_pos_opt.?;
    const a_pos = a_pos_opt.?;
    const ret_pos = ret_pos_opt.?;
    try std.testing.expect(ret_assign < b_pos); // value computed before defers
    try std.testing.expect(b_pos < a_pos); // LIFO: b (last deferred) runs first
    try std.testing.expect(a_pos < ret_pos); // defers before the actual return

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "defer block emits before function end" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_defer_block.fn";

    const input =
        "fun a() { ret; }\n" ++
        "fun b() { ret; }\n" ++
        "fun foo() {\n" ++
        "  defer {\n" ++
        "    a();\n" ++
        "    b();\n" ++
        "  }\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "a();") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "b();") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "enum types can be referenced before declaration" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_enum_after_main.fn";

    const input =
        "imp std.c.io;\n" ++
        "\n" ++
        "fun takesColor(Color c) num {\n" ++
        "  if c == .Blue { ret 1; }\n" ++
        "  ret 0;\n" ++
        "}\n" ++
        "\n" ++
        "fun main() {\n" ++
        "  num v = takesColor(.Blue);\n" ++
        "  printf(\"%d\\n\", v);\n" ++
        "}\n" ++
        "\n" ++
        "enum Color {\n" ++
        "  Red,\n" ++
        "  Blue,\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    // Ensure the enum variant constant made it through lowering/codegen.
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Color_Blue") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.time import adds time.h include" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_time.fn";

    const input =
        "imp std.c.time;\n" ++
        "fun main() { ret; }\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <time.h>") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.c.thread import emits portable thread include layer" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_thread_c.fn";

    const input =
        "imp std.c.thread;\n" ++
        "fun main() { ret; }\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#if defined(_WIN32)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <pthread.h>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "long long pthread_create(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.c.thread symbols are callable after import" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_thread_symbols.fn";

    const input =
        "imp std.c.thread;\n" ++
        "fun main() {\n" ++
        "  pthread_self();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "pthread_self()") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.c.thread_windows import emits portable thread include layer" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_thread_windows_c.fn";

    const input =
        "imp std.c.thread_windows;\n" ++
        "fun main() { ret; }\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#if defined(_WIN32)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <pthread.h>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "long long pthread_cond_timedwait(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.c.thread_windows symbols are callable after import" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_thread_windows_symbols.fn";

    const input =
        "imp std.c.thread_windows;\n" ++
        "fun main() {\n" ++
        "  pthread_self();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "pthread_self()") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "transitive std.thread import emits pthread headers" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_transitive_std_thread.fn";

    const input =
        "imp std.thread;\n" ++
        "fun main() { ret; }\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <pthread.h>") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.thread helper lifecycle APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_thread_helpers.fn";

    const input =
        "imp std.thread;\n" ++
        "fun main() {\n" ++
        "  Thread t = thread_new();\n" ++
        "  _ = thread_start(&t, NULL, NULL);\n" ++
        "  _ = thread_join(&t, NULL);\n" ++
        "  _ = thread_detach(&t);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_start(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_join(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_detach(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.thread accepts named function callbacks" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_thread_callback_symbol.fn";

    const input =
        "imp std.thread;\n" ++
        "fun worker(raw* arg) raw* {\n" ++
        "  ret arg;\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  Thread t = thread_new();\n" ++
        "  _ = thread_start(&t, worker, NULL);\n" ++
        "  _ = thread_join(&t, NULL);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_start(&t, worker, NULL)") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.sync helper lifecycle APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_sync_helpers.fn";

    const input =
        "imp std.sync;\n" ++
        "fun main() {\n" ++
        "  Mutex m = mutex_new();\n" ++
        "  CondVar c = condvar_new();\n" ++
        "  _ = mutex_init(&m);\n" ++
        "  _ = mutex_lock(&m);\n" ++
        "  _ = mutex_try_lock(&m);\n" ++
        "  _ = mutex_unlock(&m);\n" ++
        "  _ = condvar_init(&c);\n" ++
        "  _ = condvar_wait(&c, &m);\n" ++
        "  _ = condvar_timed_wait(&c, &m, NULL);\n" ++
        "  _ = condvar_signal(&c);\n" ++
        "  _ = condvar_broadcast(&c);\n" ++
        "  _ = condvar_destroy(&c);\n" ++
        "  _ = mutex_destroy(&m);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "mutex_init(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "mutex_lock(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "mutex_try_lock(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "mutex_unlock(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "mutex_destroy(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "condvar_init(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "condvar_wait(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "condvar_timed_wait(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "condvar_signal(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "condvar_broadcast(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "condvar_destroy(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "transitive std.sync_runtime import emits pthread headers" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_transitive_std_sync_runtime.fn";

    const input =
        "imp std.sync_runtime;\n" ++
        "fun main() { ret; }\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <pthread.h>") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.sync_runtime lifecycle APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_sync_runtime_helpers.fn";

    const input =
        "imp std.sync_runtime;\n" ++
        "fun main() {\n" ++
        "  Mutex m = runtime_mutex_new();\n" ++
        "  CondVar c = runtime_condvar_new();\n" ++
        "  _ = runtime_mutex_init(&m);\n" ++
        "  _ = runtime_mutex_lock(&m);\n" ++
        "  _ = runtime_mutex_try_lock(&m);\n" ++
        "  _ = runtime_mutex_unlock(&m);\n" ++
        "  _ = runtime_condvar_init(&c);\n" ++
        "  _ = runtime_condvar_wait(&c, &m);\n" ++
        "  _ = runtime_condvar_timed_wait(&c, &m, NULL);\n" ++
        "  _ = runtime_condvar_signal(&c);\n" ++
        "  _ = runtime_condvar_broadcast(&c);\n" ++
        "  _ = runtime_condvar_destroy(&c);\n" ++
        "  _ = runtime_mutex_destroy(&m);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_mutex_new(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_condvar_new(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_mutex_init(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_mutex_lock(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_mutex_try_lock(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_mutex_unlock(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_mutex_destroy(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_condvar_init(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_condvar_wait(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_condvar_timed_wait(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_condvar_signal(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_condvar_broadcast(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_condvar_destroy(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.sync_runtime backend selector APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_sync_runtime_backend.fn";

    const input =
        "imp std.sync_runtime;\n" ++
        "fun main() {\n" ++
        "  num id = sync_runtime_backend_id();\n" ++
        "  str name = sync_runtime_backend_name();\n" ++
        "  bin p = sync_runtime_backend_is_posix();\n" ++
        "  bin w = sync_runtime_backend_is_windows();\n" ++
        "  _ = id;\n" ++
        "  _ = name;\n" ++
        "  _ = p;\n" ++
        "  _ = w;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_runtime_backend_id(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_runtime_backend_name(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_runtime_backend_is_posix(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_runtime_backend_is_windows(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.runtime_backend selector APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_runtime_backend.fn";

    const input =
        "imp std.runtime_backend;\n" ++
        "fun main() {\n" ++
        "  num id = runtime_backend_id();\n" ++
        "  str name = runtime_backend_name();\n" ++
        "  bin p = runtime_backend_is_posix();\n" ++
        "  bin w = runtime_backend_is_windows();\n" ++
        "  _ = runtime_backend_posix_id();\n" ++
        "  _ = runtime_backend_windows_id();\n" ++
        "  _ = id;\n" ++
        "  _ = name;\n" ++
        "  _ = p;\n" ++
        "  _ = w;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_backend_id(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_backend_name(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_backend_is_posix(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_backend_is_windows(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_backend_posix_id(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_backend_windows_id(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.sync_backend_windows native APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_sync_backend_windows.fn";

    const input =
        "imp std.sync_backend_windows;\n" ++
        "fun main() {\n" ++
        "  Mutex m = sync_backend_windows_mutex_new();\n" ++
        "  CondVar c = sync_backend_windows_condvar_new();\n" ++
        "  _ = sync_backend_windows_unavailable();\n" ++
        "  _ = sync_backend_windows_mutex_init(&m);\n" ++
        "  _ = sync_backend_windows_mutex_lock(&m);\n" ++
        "  _ = sync_backend_windows_mutex_try_lock(&m);\n" ++
        "  _ = sync_backend_windows_mutex_unlock(&m);\n" ++
        "  _ = sync_backend_windows_condvar_init(&c);\n" ++
        "  _ = sync_backend_windows_condvar_wait(&c, &m);\n" ++
        "  _ = sync_backend_windows_condvar_timed_wait(&c, &m, NULL);\n" ++
        "  _ = sync_backend_windows_condvar_signal(&c);\n" ++
        "  _ = sync_backend_windows_condvar_broadcast(&c);\n" ++
        "  _ = sync_backend_windows_condvar_destroy(&c);\n" ++
        "  _ = sync_backend_windows_mutex_destroy(&m);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_windows_unavailable(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_windows_mutex_new(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_windows_condvar_new(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_windows_mutex_init(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_windows_mutex_lock(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_windows_mutex_try_lock(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_windows_mutex_unlock(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_windows_mutex_destroy(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_windows_condvar_init(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_windows_condvar_wait(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_windows_condvar_timed_wait(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_windows_condvar_signal(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_windows_condvar_broadcast(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_windows_condvar_destroy(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "pthread_mutex_init(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_posix_mutex_init(") == null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.sync_backend_posix lifecycle APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_sync_backend_posix.fn";

    const input =
        "imp std.sync_backend_posix;\n" ++
        "fun main() {\n" ++
        "  Mutex m = sync_backend_posix_mutex_new();\n" ++
        "  CondVar c = sync_backend_posix_condvar_new();\n" ++
        "  _ = sync_backend_posix_mutex_init(&m);\n" ++
        "  _ = sync_backend_posix_mutex_lock(&m);\n" ++
        "  _ = sync_backend_posix_mutex_try_lock(&m);\n" ++
        "  _ = sync_backend_posix_mutex_unlock(&m);\n" ++
        "  _ = sync_backend_posix_condvar_init(&c);\n" ++
        "  _ = sync_backend_posix_condvar_wait(&c, &m);\n" ++
        "  _ = sync_backend_posix_condvar_timed_wait(&c, &m, NULL);\n" ++
        "  _ = sync_backend_posix_condvar_signal(&c);\n" ++
        "  _ = sync_backend_posix_condvar_broadcast(&c);\n" ++
        "  _ = sync_backend_posix_condvar_destroy(&c);\n" ++
        "  _ = sync_backend_posix_mutex_destroy(&m);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_posix_mutex_new(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_posix_condvar_new(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_posix_mutex_init(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_posix_mutex_lock(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_posix_mutex_try_lock(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_posix_mutex_unlock(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_posix_mutex_destroy(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_posix_condvar_init(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_posix_condvar_wait(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_posix_condvar_timed_wait(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_posix_condvar_signal(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_posix_condvar_broadcast(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_backend_posix_condvar_destroy(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.thread_backend_windows native APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_thread_backend_windows.fn";

    const input =
        "imp std.thread_backend_windows;\n" ++
        "fun main() {\n" ++
        "  Thread t = thread_backend_windows_new();\n" ++
        "  _ = thread_backend_windows_unavailable();\n" ++
        "  _ = thread_backend_windows_start(&t, NULL, NULL);\n" ++
        "  _ = thread_backend_windows_join(&t, NULL);\n" ++
        "  _ = thread_backend_windows_detach(&t);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_backend_windows_new(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_backend_windows_unavailable(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_backend_windows_start(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_backend_windows_join(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_backend_windows_detach(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "pthread_create(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_backend_posix_start(") == null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.thread_backend_posix lifecycle APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_thread_backend_posix.fn";

    const input =
        "imp std.thread_backend_posix;\n" ++
        "fun main() {\n" ++
        "  Thread t = thread_backend_posix_new();\n" ++
        "  _ = thread_backend_posix_start(&t, NULL, NULL);\n" ++
        "  _ = thread_backend_posix_join(&t, NULL);\n" ++
        "  _ = thread_backend_posix_detach(&t);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_backend_posix_new(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_backend_posix_start(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_backend_posix_join(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_backend_posix_detach(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "runtime backend honors FUN_RUNTIME_BACKEND override" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_runtime_backend_override_windows.fn";
    const cpath = "codegen_runtime_backend_override_windows.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_runtime_backend_override_windows.exe"
    else
        "codegen_runtime_backend_override_windows";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.runtime_backend;\n" ++
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  printf(\"%s\", runtime_backend_name());\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, cpath, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, cpath, exe_path);

    const stdout = try runExeWithEnv(allocator, exe_path, &.{
        .{ .key = "FUN_RUNTIME_BACKEND", .value = "windows" },
        .{ .key = "FUN_RUNTIME_OS", .value = "posix" },
    });
    defer allocator.free(stdout);

    try std.testing.expectEqualStrings("windows", stdout);
}

test "runtime backend FUN_RUNTIME_BACKEND wins over FUN_RUNTIME_OS" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_runtime_backend_precedence.fn";
    const cpath = "codegen_runtime_backend_precedence.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_runtime_backend_precedence.exe"
    else
        "codegen_runtime_backend_precedence";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.runtime_backend;\n" ++
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  printf(\"%s\", runtime_backend_name());\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, cpath, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, cpath, exe_path);

    const stdout = try runExeWithEnv(allocator, exe_path, &.{
        .{ .key = "FUN_RUNTIME_BACKEND", .value = "posix" },
        .{ .key = "FUN_RUNTIME_OS", .value = "windows" },
        .{ .key = "OS", .value = "Windows_NT" },
    });
    defer allocator.free(stdout);

    try std.testing.expectEqualStrings("posix", stdout);
}

test "runtime backend uses FUN_RUNTIME_OS when backend override is unknown" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_runtime_backend_os_override.fn";
    const cpath = "codegen_runtime_backend_os_override.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_runtime_backend_os_override.exe"
    else
        "codegen_runtime_backend_os_override";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.runtime_backend;\n" ++
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  printf(\"%s\", runtime_backend_name());\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, cpath, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, cpath, exe_path);

    const stdout = try runExeWithEnv(allocator, exe_path, &.{
        .{ .key = "FUN_RUNTIME_BACKEND", .value = "unknown" },
        .{ .key = "FUN_RUNTIME_OS", .value = "windows" },
    });
    defer allocator.free(stdout);

    try std.testing.expectEqualStrings("windows", stdout);
}

test "thread and sync runtime selectors align with runtime backend" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_runtime_backend_alignment.fn";
    const cpath = "codegen_runtime_backend_alignment.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_runtime_backend_alignment.exe"
    else
        "codegen_runtime_backend_alignment";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.runtime_backend;\n" ++
        "imp std.thread_runtime;\n" ++
        "imp std.sync_runtime;\n" ++
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  printf(\"%s|%s|%s\", runtime_backend_name(), thread_runtime_backend_name(), sync_runtime_backend_name());\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, cpath, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, cpath, exe_path);

    const stdout = try runExeWithEnv(allocator, exe_path, &.{
        .{ .key = "FUN_RUNTIME_BACKEND", .value = "windows" },
    });
    defer allocator.free(stdout);

    try std.testing.expectEqualStrings("windows|windows|windows", stdout);
}

test "windows-selected sync runtime lifecycle operations execute" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_runtime_windows_sync_ops.fn";
    const cpath = "codegen_runtime_windows_sync_ops.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_runtime_windows_sync_ops.exe"
    else
        "codegen_runtime_windows_sync_ops";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.sync_runtime;\n" ++
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  Mutex m = runtime_mutex_new();\n" ++
        "  CondVar c = runtime_condvar_new();\n" ++
        "  num sum = 0;\n" ++
        "  sum += runtime_mutex_init(&m);\n" ++
        "  sum += runtime_condvar_init(&c);\n" ++
        "  sum += runtime_mutex_lock(&m);\n" ++
        "  sum += runtime_mutex_unlock(&m);\n" ++
        "  sum += runtime_condvar_signal(&c);\n" ++
        "  sum += runtime_condvar_broadcast(&c);\n" ++
        "  sum += runtime_condvar_destroy(&c);\n" ++
        "  sum += runtime_mutex_destroy(&m);\n" ++
        "  printf(\"%d\", sum);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, cpath, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, cpath, exe_path);

    const stdout = try runExeWithEnv(allocator, exe_path, &.{
        .{ .key = "FUN_RUNTIME_BACKEND", .value = "windows" },
    });
    defer allocator.free(stdout);

    try std.testing.expectEqualStrings("0", stdout);
}

test "windows-selected thread runtime null-pointer behavior is non-stub" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_runtime_windows_thread_null_ops.fn";
    const cpath = "codegen_runtime_windows_thread_null_ops.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_runtime_windows_thread_null_ops.exe"
    else
        "codegen_runtime_windows_thread_null_ops";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.thread_runtime;\n" ++
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  num s = runtime_thread_start(NULL, NULL, NULL);\n" ++
        "  num j = runtime_thread_join(NULL, NULL);\n" ++
        "  num d = runtime_thread_detach(NULL);\n" ++
        "  printf(\"%d|%d|%d\", s, j, d);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, cpath, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, cpath, exe_path);

    const stdout = try runExeWithEnv(allocator, exe_path, &.{
        .{ .key = "FUN_RUNTIME_BACKEND", .value = "windows" },
    });
    defer allocator.free(stdout);

    try std.testing.expectEqualStrings("-1|-1|-1", stdout);
}

test "transitive std.thread_runtime import emits pthread headers" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_transitive_std_thread_runtime.fn";

    const input =
        "imp std.thread_runtime;\n" ++
        "fun main() { ret; }\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <pthread.h>") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.thread_runtime lifecycle APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_thread_runtime_helpers.fn";

    const input =
        "imp std.thread_runtime;\n" ++
        "fun main() {\n" ++
        "  Thread t = runtime_thread_new();\n" ++
        "  _ = runtime_thread_start(&t, NULL, NULL);\n" ++
        "  _ = runtime_thread_join(&t, NULL);\n" ++
        "  _ = runtime_thread_detach(&t);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_thread_new(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_thread_start(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_thread_join(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_thread_detach(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.thread_runtime async task handle APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_thread_runtime_async_task.fn";

    const input =
        "imp std.thread_runtime;\n" ++
        "fun worker(raw* arg) raw* {\n" ++
        "  ret arg;\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  RuntimeAsyncTask task = runtime_async_spawn(worker, NULL);\n" ++
        "  _ = task.is_active();\n" ++
        "  _ = task.last_start_rc();\n" ++
        "  _ = task.join(NULL);\n" ++
        "  _ = task.detach();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_async_spawn(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "RuntimeAsyncTask__join(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "RuntimeAsyncTask__detach(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.thread_runtime async task handle behavior is stable across backend selectors" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_thread_runtime_async_task_behavior.fn";
    const cpath = "codegen_std_thread_runtime_async_task_behavior.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_std_thread_runtime_async_task_behavior.exe"
    else
        "codegen_std_thread_runtime_async_task_behavior";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.thread_runtime;\n" ++
        "imp std.runtime_backend;\n" ++
        "imp std.c.io;\n" ++
        "fun worker(raw* arg) raw* {\n" ++
        "  ret arg;\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  RuntimeAsyncTask joined = runtime_async_spawn(worker, NULL);\n" ++
        "  num joined_start = joined.last_start_rc();\n" ++
        "  bin joined_active_before = joined.is_active();\n" ++
        "  num joined_join_rc = await joined.join_async(NULL);\n" ++
        "  bin joined_active_after = joined.is_active();\n" ++
        "\n" ++
        "  RuntimeAsyncTask detached = runtime_async_spawn(worker, NULL);\n" ++
        "  num detached_start = detached.last_start_rc();\n" ++
        "  bin detached_active_before = detached.is_active();\n" ++
        "  num detached_detach_rc = await detached.detach_async();\n" ++
        "  bin detached_active_after = detached.is_active();\n" ++
        "\n" ++
        "  RuntimeAsyncTask bad = runtime_async_task_new();\n" ++
        "  bad.start_rc = -7;\n" ++
        "  bad.active = false;\n" ++
        "  num bad_start = bad.last_start_rc();\n" ++
        "  num bad_join_rc = await bad.join_async(NULL);\n" ++
        "  num bad_detach_rc = await bad.detach_async();\n" ++
        "  bin bad_active = bad.is_active();\n" ++
        "\n" ++
        "  printf(\"backend=%s\\n\", runtime_backend_name());\n" ++
        "  printf(\"joined_start=%lld\\n\", joined_start);\n" ++
        "  printf(\"joined_active_before=%lld\\n\", joined_active_before);\n" ++
        "  printf(\"joined_join_rc=%lld\\n\", joined_join_rc);\n" ++
        "  printf(\"joined_active_after=%lld\\n\", joined_active_after);\n" ++
        "  printf(\"detached_start=%lld\\n\", detached_start);\n" ++
        "  printf(\"detached_active_before=%lld\\n\", detached_active_before);\n" ++
        "  printf(\"detached_detach_rc=%lld\\n\", detached_detach_rc);\n" ++
        "  printf(\"detached_active_after=%lld\\n\", detached_active_after);\n" ++
        "  printf(\"bad_start=%lld\\n\", bad_start);\n" ++
        "  printf(\"bad_join_rc=%lld\\n\", bad_join_rc);\n" ++
        "  printf(\"bad_detach_rc=%lld\\n\", bad_detach_rc);\n" ++
        "  printf(\"bad_active=%lld\\n\", bad_active);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, cpath, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, cpath, exe_path);

    for ([_][]const u8{ "posix", "windows" }) |backend_name| {
        const overrides = [_]EnvOverride{
            .{ .key = "FUN_RUNTIME_BACKEND", .value = backend_name },
        };

        const stdout = try runExeWithEnvTimeout(allocator, exe_path, &overrides, 12_000);
        defer allocator.free(stdout);

        try std.testing.expectEqualStrings(backend_name, try parseMetricValue(stdout, "backend"));

        try std.testing.expectEqual(@as(i64, 0), try parseMetricInt(stdout, "joined_start"));
        try std.testing.expectEqual(@as(i64, 1), try parseMetricInt(stdout, "joined_active_before"));
        try std.testing.expectEqual(@as(i64, 0), try parseMetricInt(stdout, "joined_join_rc"));
        try std.testing.expectEqual(@as(i64, 0), try parseMetricInt(stdout, "joined_active_after"));

        try std.testing.expectEqual(@as(i64, 0), try parseMetricInt(stdout, "detached_start"));
        try std.testing.expectEqual(@as(i64, 1), try parseMetricInt(stdout, "detached_active_before"));
        try std.testing.expectEqual(@as(i64, 0), try parseMetricInt(stdout, "detached_detach_rc"));
        try std.testing.expectEqual(@as(i64, 0), try parseMetricInt(stdout, "detached_active_after"));

        const bad_start = try parseMetricInt(stdout, "bad_start");
        const bad_join_rc = try parseMetricInt(stdout, "bad_join_rc");
        const bad_detach_rc = try parseMetricInt(stdout, "bad_detach_rc");
        try std.testing.expectEqual(@as(i64, -7), bad_start);
        try std.testing.expectEqual(@as(i64, -7), bad_join_rc);
        try std.testing.expectEqual(@as(i64, -7), bad_detach_rc);
        try std.testing.expectEqual(@as(i64, 0), try parseMetricInt(stdout, "bad_active"));
    }
}

test "std.thread_runtime backend selector APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_thread_runtime_backend.fn";

    const input =
        "imp std.thread_runtime;\n" ++
        "fun main() {\n" ++
        "  num id = thread_runtime_backend_id();\n" ++
        "  str name = thread_runtime_backend_name();\n" ++
        "  bin p = thread_runtime_backend_is_posix();\n" ++
        "  bin w = thread_runtime_backend_is_windows();\n" ++
        "  _ = id;\n" ++
        "  _ = name;\n" ++
        "  _ = p;\n" ++
        "  _ = w;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_runtime_backend_id(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_runtime_backend_name(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_runtime_backend_is_posix(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_runtime_backend_is_windows(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.channel runtime conformance matrix is stable across backend selectors" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_channel_runtime_conformance.fn";
    const cpath = "codegen_channel_runtime_conformance.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_channel_runtime_conformance.exe"
    else
        "codegen_channel_runtime_conformance";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.channel;\n" ++
        "imp std.runtime_backend;\n" ++
        "imp std.sync_runtime;\n" ++
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  Channel<num> ch = channel_new_cap(0, 1);\n" ++
        "  num out = -1;\n" ++
        "  num rc_try_recv_empty = ch.try_recv(&out);\n" ++
        "  num rc_send_ok = ch.send_timeout(11, 0);\n" ++
        "  num rc_try_send_full = ch.try_send(22);\n" ++
        "  num rc_recv_ok = ch.recv_timeout_into(&out, 0);\n" ++
        "  num recv_value = out;\n" ++
        "  num rc_recv_timeout = ch.recv_timeout_into(&out, 0);\n" ++
        "  _ = ch.send_timeout(33, 0);\n" ++
        "  num cancel = 1;\n" ++
        "  num rc_send_cancelled = ch.send_timeout_with_cancel(44, 50, &cancel);\n" ++
        "  _ = ch.close();\n" ++
        "  num rc_send_closed = ch.send_timeout(55, 0);\n" ++
        "  num rc_recv_after_close_drain = ch.recv_timeout_into(&out, 0);\n" ++
        "  num recv_after_close_value = out;\n" ++
        "  num rc_recv_closed = ch.recv_timeout_into(&out, 0);\n" ++
        "\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  num idx = 99;\n" ++
        "  num out_sel = 0;\n" ++
        "  num rc_default = a.select_recv_default_with(&b, &out_sel, &idx);\n" ++
        "  num idx_default = idx;\n" ++
        "  num rc_select_timeout = a.select_recv_timeout_with_tuning_cancel(&b, &out_sel, &idx, 20);\n" ++
        "  num cancel_select = 1;\n" ++
        "  num rc_select_cancelled = a.select_recv_timeout_with_tuning_cancel(&b, &out_sel, &idx, 20, -1, -1, &cancel_select);\n" ++
        "\n" ++
        "  printf(\"backend=%s\\n\", runtime_backend_name());\n" ++
        "  printf(\"sync_backend=%s\\n\", sync_runtime_backend_name());\n" ++
        "  printf(\"const_rc_ok=%lld\\n\", channel_rc_ok());\n" ++
        "  printf(\"const_rc_timeout=%lld\\n\", channel_rc_timeout());\n" ++
        "  printf(\"const_rc_full=%lld\\n\", channel_rc_full());\n" ++
        "  printf(\"const_rc_empty=%lld\\n\", channel_rc_empty());\n" ++
        "  printf(\"const_rc_default=%lld\\n\", channel_rc_default());\n" ++
        "  printf(\"const_rc_cancelled=%lld\\n\", channel_rc_cancelled());\n" ++
        "  printf(\"const_select_default=%lld\\n\", channel_select_index_default());\n" ++
        "  printf(\"rc_try_recv_empty=%lld\\n\", rc_try_recv_empty);\n" ++
        "  printf(\"rc_send_ok=%lld\\n\", rc_send_ok);\n" ++
        "  printf(\"rc_try_send_full=%lld\\n\", rc_try_send_full);\n" ++
        "  printf(\"rc_recv_ok=%lld\\n\", rc_recv_ok);\n" ++
        "  printf(\"recv_value=%lld\\n\", recv_value);\n" ++
        "  printf(\"rc_recv_timeout=%lld\\n\", rc_recv_timeout);\n" ++
        "  printf(\"rc_send_cancelled=%lld\\n\", rc_send_cancelled);\n" ++
        "  printf(\"rc_send_closed=%lld\\n\", rc_send_closed);\n" ++
        "  printf(\"rc_recv_after_close_drain=%lld\\n\", rc_recv_after_close_drain);\n" ++
        "  printf(\"recv_after_close_value=%lld\\n\", recv_after_close_value);\n" ++
        "  printf(\"rc_recv_closed=%lld\\n\", rc_recv_closed);\n" ++
        "  printf(\"rc_default=%lld\\n\", rc_default);\n" ++
        "  printf(\"idx_default=%lld\\n\", idx_default);\n" ++
        "  printf(\"rc_select_timeout=%lld\\n\", rc_select_timeout);\n" ++
        "  printf(\"rc_select_cancelled=%lld\\n\", rc_select_cancelled);\n" ++
        "\n" ++
        "  _ = ch.destroy();\n" ++
        "  _ = a.destroy();\n" ++
        "  _ = b.destroy();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, cpath, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, cpath, exe_path);

    for ([_][]const u8{ "posix", "windows" }) |backend_name| {
        const overrides = [_]EnvOverride{
            .{ .key = "FUN_RUNTIME_BACKEND", .value = backend_name },
        };

        const stdout = try runExeWithEnvTimeout(allocator, exe_path, &overrides, 12_000);
        defer allocator.free(stdout);

        try std.testing.expectEqualStrings(backend_name, try parseMetricValue(stdout, "backend"));
        try std.testing.expectEqualStrings(backend_name, try parseMetricValue(stdout, "sync_backend"));

        try std.testing.expectEqual(@as(i64, 0), try parseMetricInt(stdout, "const_rc_ok"));
        try std.testing.expectEqual(@as(i64, 2), try parseMetricInt(stdout, "const_rc_timeout"));
        try std.testing.expectEqual(@as(i64, 2), try parseMetricInt(stdout, "const_rc_full"));
        try std.testing.expectEqual(@as(i64, 2), try parseMetricInt(stdout, "const_rc_empty"));
        try std.testing.expectEqual(@as(i64, 3), try parseMetricInt(stdout, "const_rc_default"));
        try std.testing.expectEqual(@as(i64, 3), try parseMetricInt(stdout, "const_rc_cancelled"));
        try std.testing.expectEqual(@as(i64, -1), try parseMetricInt(stdout, "const_select_default"));

        try std.testing.expectEqual(@as(i64, 2), try parseMetricInt(stdout, "rc_try_recv_empty"));
        try std.testing.expectEqual(@as(i64, 0), try parseMetricInt(stdout, "rc_send_ok"));
        try std.testing.expectEqual(@as(i64, 2), try parseMetricInt(stdout, "rc_try_send_full"));
        try std.testing.expectEqual(@as(i64, 0), try parseMetricInt(stdout, "rc_recv_ok"));
        try std.testing.expectEqual(@as(i64, 11), try parseMetricInt(stdout, "recv_value"));
        try std.testing.expectEqual(@as(i64, 2), try parseMetricInt(stdout, "rc_recv_timeout"));
        try std.testing.expectEqual(@as(i64, 3), try parseMetricInt(stdout, "rc_send_cancelled"));
        try std.testing.expectEqual(@as(i64, 1), try parseMetricInt(stdout, "rc_send_closed"));
        try std.testing.expectEqual(@as(i64, 0), try parseMetricInt(stdout, "rc_recv_after_close_drain"));
        try std.testing.expectEqual(@as(i64, 33), try parseMetricInt(stdout, "recv_after_close_value"));
        try std.testing.expectEqual(@as(i64, 1), try parseMetricInt(stdout, "rc_recv_closed"));
        try std.testing.expectEqual(@as(i64, 3), try parseMetricInt(stdout, "rc_default"));
        try std.testing.expectEqual(@as(i64, -1), try parseMetricInt(stdout, "idx_default"));
        try std.testing.expectEqual(@as(i64, 2), try parseMetricInt(stdout, "rc_select_timeout"));
        try std.testing.expectEqual(@as(i64, 3), try parseMetricInt(stdout, "rc_select_cancelled"));
    }
}

test "std.channel fairness and timeout benchmark stays within backend thresholds" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_channel_runtime_benchmark.fn";
    const cpath = "codegen_channel_runtime_benchmark.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_channel_runtime_benchmark.exe"
    else
        "codegen_channel_runtime_benchmark";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.channel;\n" ++
        "imp std.runtime_backend;\n" ++
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  num rounds = 120;\n" ++
        "  num total_rounds = rounds * 3;\n" ++
        "  num timeout_rounds = 20;\n" ++
        "\n" ++
        "  Channel<num> a = channel_new_cap(0, rounds);\n" ++
        "  Channel<num> b = channel_new_cap(0, rounds);\n" ++
        "  Channel<num> c = channel_new_cap(0, rounds);\n" ++
        "\n" ++
        "  num i = 0;\n" ++
        "  for i < rounds {\n" ++
        "    _ = a.send(i);\n" ++
        "    _ = b.send(i + 1000);\n" ++
        "    _ = c.send(i + 2000);\n" ++
        "    i = i + 1;\n" ++
        "  }\n" ++
        "\n" ++
        "  num next = 0;\n" ++
        "  num count_a = 0;\n" ++
        "  num count_b = 0;\n" ++
        "  num count_c = 0;\n" ++
        "  num fairness_rc = channel_rc_ok();\n" ++
        "\n" ++
        "  i = 0;\n" ++
        "  for i < total_rounds {\n" ++
        "    num out = 0;\n" ++
        "    num which = -1;\n" ++
        "    num rc = a.select_recv_timeout3_rr_with_tuning_cancel(&b, &c, &next, &out, &which, 50, 5, 0);\n" ++
        "    if rc != channel_rc_ok() {\n" ++
        "      fairness_rc = rc;\n" ++
        "      i = total_rounds;\n" ++
        "    } else {\n" ++
        "      if which == channel_select_index_self() {\n" ++
        "        count_a = count_a + 1;\n" ++
        "      } elif which == channel_select_index_other() {\n" ++
        "        count_b = count_b + 1;\n" ++
        "      } elif which == channel_select_index_other_b() {\n" ++
        "        count_c = count_c + 1;\n" ++
        "      }\n" ++
        "      i = i + 1;\n" ++
        "    }\n" ++
        "  }\n" ++
        "\n" ++
        "  num max_count = count_a;\n" ++
        "  if count_b > max_count {\n" ++
        "    max_count = count_b;\n" ++
        "  }\n" ++
        "  if count_c > max_count {\n" ++
        "    max_count = count_c;\n" ++
        "  }\n" ++
        "\n" ++
        "  num min_count = count_a;\n" ++
        "  if count_b < min_count {\n" ++
        "    min_count = count_b;\n" ++
        "  }\n" ++
        "  if count_c < min_count {\n" ++
        "    min_count = count_c;\n" ++
        "  }\n" ++
        "\n" ++
        "  Channel<num> x = channel_new(0);\n" ++
        "  Channel<num> y = channel_new(0);\n" ++
        "  Channel<num> z = channel_new(0);\n" ++
        "\n" ++
        "  num out_timeout = 0;\n" ++
        "  num idx_timeout = -1;\n" ++
        "  num next_timeout = 0;\n" ++
        "  num timeout_failures = 0;\n" ++
        "  i = 0;\n" ++
        "  for i < timeout_rounds {\n" ++
        "    num timeout_rc = x.select_recv_timeout3_rr_with_tuning_cancel(&y, &z, &next_timeout, &out_timeout, &idx_timeout, 15, 5, 0);\n" ++
        "    if timeout_rc != channel_rc_timeout() {\n" ++
        "      timeout_failures = timeout_failures + 1;\n" ++
        "    }\n" ++
        "    i = i + 1;\n" ++
        "  }\n" ++
        "\n" ++
        "  printf(\"backend=%s\\n\", runtime_backend_name());\n" ++
        "  printf(\"fairness_rc=%lld\\n\", fairness_rc);\n" ++
        "  printf(\"fairness_skew=%lld\\n\", max_count - min_count);\n" ++
        "  printf(\"count_a=%lld\\n\", count_a);\n" ++
        "  printf(\"count_b=%lld\\n\", count_b);\n" ++
        "  printf(\"count_c=%lld\\n\", count_c);\n" ++
        "  printf(\"count_total=%lld\\n\", count_a + count_b + count_c);\n" ++
        "  printf(\"timeout_rounds=%lld\\n\", timeout_rounds);\n" ++
        "  printf(\"timeout_failures=%lld\\n\", timeout_failures);\n" ++
        "\n" ++
        "  _ = a.destroy();\n" ++
        "  _ = b.destroy();\n" ++
        "  _ = c.destroy();\n" ++
        "  _ = x.destroy();\n" ++
        "  _ = y.destroy();\n" ++
        "  _ = z.destroy();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, cpath, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, cpath, exe_path);

    var posix_elapsed: i64 = -1;
    var windows_elapsed: i64 = -1;

    for ([_][]const u8{ "posix", "windows" }) |backend_name| {
        const overrides = [_]EnvOverride{
            .{ .key = "FUN_RUNTIME_BACKEND", .value = backend_name },
        };

        const started_ms: i64 = @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms));
        const stdout = try runExeWithEnvTimeout(allocator, exe_path, &overrides, 12_000);
        const finished_ms: i64 = @intCast(@divFloor(std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds, std.time.ns_per_ms));
        defer allocator.free(stdout);

        try std.testing.expectEqualStrings(backend_name, try parseMetricValue(stdout, "backend"));
        try std.testing.expectEqual(@as(i64, 0), try parseMetricInt(stdout, "fairness_rc"));
        try std.testing.expect((try parseMetricInt(stdout, "fairness_skew")) <= 1);
        try std.testing.expectEqual(@as(i64, 360), try parseMetricInt(stdout, "count_total"));
        try std.testing.expectEqual(@as(i64, 20), try parseMetricInt(stdout, "timeout_rounds"));
        try std.testing.expectEqual(@as(i64, 0), try parseMetricInt(stdout, "timeout_failures"));

        const elapsed = finished_ms - started_ms;
        try std.testing.expect(elapsed >= 150);
        try std.testing.expect(elapsed <= 5000);

        if (std.mem.eql(u8, backend_name, "posix")) {
            posix_elapsed = elapsed;
        } else {
            windows_elapsed = elapsed;
        }
    }

    try std.testing.expect(posix_elapsed >= 0);
    try std.testing.expect(windows_elapsed >= 0);

    const drift = if (posix_elapsed > windows_elapsed)
        posix_elapsed - windows_elapsed
    else
        windows_elapsed - posix_elapsed;
    try std.testing.expect(drift <= 800);
}

test "transitive std.channel import emits pthread headers" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_transitive_std_channel.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() { ret; }\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <pthread.h>") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "transitive std.thread_pool import emits pthread headers" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_transitive_std_thread_pool.fn";

    const input =
        "imp std.thread_pool;\n" ++
        "fun main() { ret; }\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <pthread.h>") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.thread_pool lifecycle APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_thread_pool_lifecycle.fn";

    const input =
        "imp std.thread_pool;\n" ++
        "fun main() {\n" ++
        "  ThreadPool p = thread_pool_new(0);\n" ++
        "  _ = p.start_all(NULL, NULL);\n" ++
        "  _ = p.join_all(NULL);\n" ++
        "  _ = p.detach_all();\n" ++
        "  _ = p.count();\n" ++
        "  _ = p.is_ready();\n" ++
        "  _ = p.destroy();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_pool_new(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "ThreadPool__start_all(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "ThreadPool__join_all(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "ThreadPool__detach_all(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "ThreadPool__count(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "ThreadPool__is_ready(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "ThreadPool__destroy(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.channel send and recv transpile for num" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_send_recv.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> ch = channel_new(0);\n" ++
        "  _ = ch.send(7);\n" ++
        "  num out = ch.recv();\n" ++
        "  _ = out;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__send(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__recv(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.channel buffered constructor and try_send transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_buffered.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> ch = channel_new_cap(0, 4);\n" ++
        "  _ = ch.try_send(1);\n" ++
        "  _ = ch.try_send(2);\n" ++
        "  num a = ch.recv();\n" ++
        "  num b = ch.recv();\n" ++
        "  _ = a + b;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "channel_new_cap__num") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__try_send(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.channel timeout send and recv transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_timeout.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> ch = channel_new_cap(0, 1);\n" ++
        "  _ = ch.send_timeout(1, 0);\n" ++
        "  num out = 0;\n" ++
        "  _ = ch.recv_timeout_into(&out, 0);\n" ++
        "  num v = ch.recv_timeout(0);\n" ++
        "  _ = out + v;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <time.h>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__send_timeout(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__recv_timeout_into(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__recv_timeout(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.channel async wrapper APIs await and run" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_async_wrappers.fn";
    const cpath = "codegen_std_channel_async_wrappers.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_std_channel_async_wrappers.exe"
    else
        "codegen_std_channel_async_wrappers";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.channel;\n" ++
        "imp std.c.io;\n" ++
        "async fun main() {\n" ++
        "  Channel<num> ch = channel_new_cap(0, 1);\n" ++
        "  num rc_send = await ch.send_async(41);\n" ++
        "  num first = await ch.recv_async();\n" ++
        "\n" ++
        "  ChannelCancelToken token = channel_cancel_token_new();\n" ++
        "  _ = channel_cancel_token_reset(&token);\n" ++
        "  num rc_send_timed = await ch.send_timeout_with_token_async(42, 0, &token);\n" ++
        "  num out = 0;\n" ++
        "  num rc_recv_into = await ch.recv_timeout_into_async(&out, 0);\n" ++
        "\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  _ = await b.send_async(99);\n" ++
        "  num idx = -1;\n" ++
        "  num sel = 0;\n" ++
        "  num rc_sel = await a.select_recv_timeout_with_tuning_cancel_async(&b, &sel, &idx);\n" ++
        "\n" ++
        "  Channel<num> x = channel_new(0);\n" ++
        "  Channel<num> y = channel_new(0);\n" ++
        "  Channel<num> z = channel_new(0);\n" ++
        "  _ = await y.send_async(7);\n" ++
        "  num next = 0;\n" ++
        "  num out3 = 0;\n" ++
        "  num idx3 = -1;\n" ++
        "  num rc_sel3 = await x.select_recv_timeout3_rr_with_tuning_cancel_async(&y, &z, &next, &out3, &idx3);\n" ++
        "\n" ++
        "  printf(\"%lld|%lld|%lld|%lld|%lld|%lld|%lld|%lld|%lld|%lld|%lld\", rc_send, first, rc_send_timed, rc_recv_into, out, rc_sel, idx, sel, rc_sel3, idx3, out3);\n" ++
        "\n" ++
        "  _ = ch.destroy();\n" ++
        "  _ = a.destroy();\n" ++
        "  _ = b.destroy();\n" ++
        "  _ = x.destroy();\n" ++
        "  _ = y.destroy();\n" ++
        "  _ = z.destroy();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, cpath, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, cpath, exe_path);

    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);

    try std.testing.expectEqualStrings("0|41|0|0|42|0|1|99|0|1|7", stdout);
}

test "std.channel async forwarding APIs await and run" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_async_forwarding.fn";
    const cpath = "codegen_std_channel_async_forwarding.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_std_channel_async_forwarding.exe"
    else
        "codegen_std_channel_async_forwarding";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.channel;\n" ++
        "imp std.c.io;\n" ++
        "async fun main() {\n" ++
        "  Channel<num> src = channel_new_cap(0, 1);\n" ++
        "  Channel<num> dst = channel_new_cap(0, 1);\n" ++
        "  _ = await src.send_async(55);\n" ++
        "  num rc_fwd = await src.forward_one_to_async(&dst, 20);\n" ++
        "  num moved = await dst.recv_async();\n" ++
        "\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  Channel<num> out = channel_new(0);\n" ++
        "  _ = await b.send_async(77);\n" ++
        "  num idx = -1;\n" ++
        "  num rc_sel_fwd = await a.select_forward_one_to_async(&b, &out, 20, &idx);\n" ++
        "  num moved_sel = await out.recv_async();\n" ++
        "\n" ++
        "  ChannelCancelToken token = channel_cancel_token_new();\n" ++
        "  _ = channel_cancel_token_cancel(&token);\n" ++
        "  num rc_cancel = await a.forward_one_to_with_token_async(&out, 20, &token);\n" ++
        "\n" ++
        "  printf(\"%lld|%lld|%lld|%lld|%lld|%lld\", rc_fwd, moved, rc_sel_fwd, idx, moved_sel, rc_cancel);\n" ++
        "\n" ++
        "  _ = src.destroy();\n" ++
        "  _ = dst.destroy();\n" ++
        "  _ = a.destroy();\n" ++
        "  _ = b.destroy();\n" ++
        "  _ = out.destroy();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, cpath, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, cpath, exe_path);

    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);

    try std.testing.expectEqualStrings("0|55|0|1|77|3", stdout);
}

test "std.io APIs usable in async function transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_io_async_context.fn";

    const input =
        "imp std.io;\n" ++
        "async fun main() {\n" ++
        "  str path = \"codegen_std_io_async_context_tmp.txt\";\n" ++
        "  _ = write_all(path, \"xyz\");\n" ++
        "  File f = open_read(path);\n" ++
        "  _ = f.read_bytes(3);\n" ++
        "  f.close();\n" ++
        "  _ = read_all(path);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "write_all(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "open_read(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "read_bytes(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "read_all(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.net async APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_net_async_apis.fn";

    const input =
        "imp std.net;\n" ++
        "imp std.channel;\n" ++
        "async fun main() {\n" ++
        "  Channel<str> reqs = channel_new_cap(\"\", 1);\n" ++
        "  ChannelCancelToken token = channel_cancel_token_new();\n" ++
        "  _ = await build_http_get_to_channel_async(\"http://example.com/\", &reqs, &token);\n" ++
        "  _ = await tcp_roundtrip_async(-1, \"ping\", \"\", 1, &token);\n" ++
        "  _ = await tcp_roundtrip_offload_async(-1, \"ping\", \"\", 1, &token);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "build_http_get_to_channel_async") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "tcp_roundtrip_async") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "tcp_roundtrip_offload_async") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.net offload async edge return codes are stable across backend selectors" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_net_offload_edge_codes.fn";
    const cpath = "codegen_std_net_offload_edge_codes.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_std_net_offload_edge_codes.exe"
    else
        "codegen_std_net_offload_edge_codes";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.net;\n" ++
        "imp std.channel;\n" ++
        "imp std.runtime_backend;\n" ++
        "imp std.c.io;\n" ++
        "async fun main() {\n" ++
        "  ChannelCancelToken token = channel_cancel_token_new();\n" ++
        "  ChannelCancelToken cancelled = channel_cancel_token_new();\n" ++
        "  _ = channel_cancel_token_cancel(&cancelled);\n" ++
        "\n" ++
        "  str recv_buf = malloc(8);\n" ++
        "  str recv_buf2 = malloc(8);\n" ++
        "\n" ++
        "  num rc_cancelled = -99;\n" ++
        "  if recv_buf != NULL {\n" ++
        "    rc_cancelled = await tcp_roundtrip_offload_async(-1, \"PING\", recv_buf, 7, &cancelled);\n" ++
        "    free(recv_buf);\n" ++
        "  }\n" ++
        "\n" ++
        "  num rc_invalid_buf = await tcp_roundtrip_offload_async(-1, \"PING\", NULL, 7, &token);\n" ++
        "  num rc_invalid_len = -99;\n" ++
        "  if recv_buf2 != NULL {\n" ++
        "    rc_invalid_len = await tcp_roundtrip_offload_async(-1, \"PING\", recv_buf2, 0, &token);\n" ++
        "    free(recv_buf2);\n" ++
        "  }\n" ++
        "\n" ++
        "  str recv_buf3 = malloc(8);\n" ++
        "  num rc_invalid_fd = -99;\n" ++
        "  if recv_buf3 != NULL {\n" ++
        "    rc_invalid_fd = await tcp_roundtrip_offload_async(-1, \"PING\", recv_buf3, 7, &token);\n" ++
        "    free(recv_buf3);\n" ++
        "  }\n" ++
        "\n" ++
        "  printf(\"backend=%s\\n\", runtime_backend_name());\n" ++
        "  printf(\"rc_cancelled=%lld\\n\", rc_cancelled);\n" ++
        "  printf(\"rc_invalid_buf=%lld\\n\", rc_invalid_buf);\n" ++
        "  printf(\"rc_invalid_len=%lld\\n\", rc_invalid_len);\n" ++
        "  printf(\"rc_invalid_fd=%lld\\n\", rc_invalid_fd);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, cpath, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, cpath, exe_path);

    for ([_][]const u8{ "posix", "windows" }) |backend_name| {
        const overrides = [_]EnvOverride{
            .{ .key = "FUN_RUNTIME_BACKEND", .value = backend_name },
        };

        const stdout = try runExeWithEnv(allocator, exe_path, &overrides);
        defer allocator.free(stdout);

        try std.testing.expectEqualStrings(backend_name, try parseMetricValue(stdout, "backend"));
        try std.testing.expectEqual(@as(i64, -3), try parseMetricInt(stdout, "rc_cancelled"));
        try std.testing.expectEqual(@as(i64, -1), try parseMetricInt(stdout, "rc_invalid_buf"));
        try std.testing.expectEqual(@as(i64, -1), try parseMetricInt(stdout, "rc_invalid_len"));
        try std.testing.expectEqual(@as(i64, -1), try parseMetricInt(stdout, "rc_invalid_fd"));
    }
}

test "std.channel cancel-aware send and recv APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_cancel_send_recv.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> ch = channel_new_cap(0, 1);\n" ++
        "  num out = 0;\n" ++
        "  num cancel = 1;\n" ++
        "  _ = ch.send_timeout_with_cancel(1, 10, &cancel);\n" ++
        "  _ = ch.send_with_cancel(1, &cancel);\n" ++
        "  _ = ch.recv_timeout_into_with_cancel(&out, 10, &cancel);\n" ++
        "  _ = ch.recv_into_with_cancel(&out, &cancel);\n" ++
        "  num a = ch.recv_timeout_with_cancel(10, &cancel);\n" ++
        "  num b = ch.recv_with_cancel(&cancel);\n" ++
        "  _ = out + a + b;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__send_timeout_with_cancel(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__send_with_cancel(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__recv_timeout_into_with_cancel(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__recv_into_with_cancel(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__recv_timeout_with_cancel(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__recv_with_cancel(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.channel cancel token APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_cancel_token.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> ch = channel_new_cap(0, 1);\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  Channel<num> c = channel_new(0);\n" ++
        "  num out = 0;\n" ++
        "  num idx = -1;\n" ++
        "  num next = 0;\n" ++
        "  ChannelCancelToken token = channel_cancel_token_new();\n" ++
        "  _ = channel_cancel_token_cancel(&token);\n" ++
        "  _ = channel_cancel_token_reset(&token);\n" ++
        "  bin cancelled = channel_cancel_token_is_cancelled(&token);\n" ++
        "  _ = cancelled;\n" ++
        "  _ = ch.send_timeout_with_token(1, 10, &token);\n" ++
        "  _ = ch.send_with_token(1, &token);\n" ++
        "  _ = ch.recv_timeout_into_with_token(&out, 10, &token);\n" ++
        "  _ = ch.recv_into_with_token(&out, &token);\n" ++
        "  num v1 = ch.recv_timeout_with_token(10, &token);\n" ++
        "  num v2 = ch.recv_with_token(&token);\n" ++
        "  _ = a.select_recv_timeout_with_tuning_token(&b, &out, &idx, 10, 2, 1, &token);\n" ++
        "  _ = a.select_recv_timeout3_rr_with_tuning_token(&b, &c, &next, &out, &idx, 10, 2, 1, &token);\n" ++
        "  _ = out + idx + next + v1 + v2;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "channel_cancel_token_new(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "channel_cancel_token_cancel(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "channel_cancel_token_reset(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "channel_cancel_token_is_cancelled(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__send_timeout_with_token(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__send_with_token(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__recv_timeout_into_with_token(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__recv_into_with_token(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__recv_timeout_with_token(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__recv_with_token(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_timeout_with_tuning_token(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_timeout3_rr_with_tuning_token(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.channel select recv2 timeout transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_select2.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  _ = b.send(42);\n" ++
        "  num out = 0;\n" ++
        "  num idx = -1;\n" ++
        "  _ = a.select_recv_timeout_with_tuning_cancel(&b, &out, &idx, 10);\n" ++
        "  _ = out + idx;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_timeout_with_tuning_cancel(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_try_recv_with(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.channel select recv3 fair timeout transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_select3_rr.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  Channel<num> c = channel_new(0);\n" ++
        "  _ = c.send(7);\n" ++
        "  num out = 0;\n" ++
        "  num idx = -1;\n" ++
        "  num next = 0;\n" ++
        "  _ = a.select_recv_timeout3_rr_with_tuning_cancel(&b, &c, &next, &out, &idx, 10);\n" ++
        "  _ = out + idx + next;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_timeout3_rr_with_tuning_cancel(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_try_recv3_rr_with(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.channel select default branch APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_select_default.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  Channel<num> c = channel_new(0);\n" ++
        "  num out = 0;\n" ++
        "  num idx = -1;\n" ++
        "  num next = 0;\n" ++
        "  _ = a.select_recv_default_with(&b, &out, &idx);\n" ++
        "  _ = a.select_recv3_rr_default_with(&b, &c, &next, &out, &idx);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_default_with(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv3_rr_default_with(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.channel select cancel-aware APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_select_cancel.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  Channel<num> c = channel_new(0);\n" ++
        "  num out = 0;\n" ++
        "  num idx = -1;\n" ++
        "  num next = 0;\n" ++
        "  num cancel = 1;\n" ++
        "  _ = a.select_recv_timeout_with_tuning_cancel(&b, &out, &idx, 10, -1, -1, &cancel);\n" ++
        "  _ = a.select_recv_timeout_with_tuning_cancel(&b, &out, &idx, -1, -1, -1, &cancel);\n" ++
        "  _ = a.select_recv_timeout3_rr_with_tuning_cancel(&b, &c, &next, &out, &idx, 10, -1, -1, &cancel);\n" ++
        "  _ = a.select_recv_timeout3_rr_with_tuning_cancel(&b, &c, &next, &out, &idx, -1, -1, -1, &cancel);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_timeout_with_tuning_cancel(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_timeout_with_tuning_cancel(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_timeout3_rr_with_tuning_cancel(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_timeout3_rr_with_tuning_cancel(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.channel select wait-slice tuning transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_select_wait_slice.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> ch = channel_new(0);\n" ++
        "  ch.set_select_wait_slice_ms(3);\n" ++
        "  num slice = ch.get_select_wait_slice_ms();\n" ++
        "  _ = slice;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__set_select_wait_slice_ms(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__get_select_wait_slice_ms(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.channel select explicit wait-slice override transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_select_wait_slice_override.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  Channel<num> c = channel_new(0);\n" ++
        "  num out = 0;\n" ++
        "  num idx = -1;\n" ++
        "  num next = 0;\n" ++
        "  _ = a.select_recv_timeout_with_tuning_cancel(&b, &out, &idx, 10, 2);\n" ++
        "  _ = a.select_recv_timeout3_rr_with_tuning_cancel(&b, &c, &next, &out, &idx, 10, 2);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_timeout_with_tuning_cancel(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_timeout3_rr_with_tuning_cancel(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.channel select explicit wait-slice and backoff override transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_select_tuning_override.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  Channel<num> c = channel_new(0);\n" ++
        "  num out = 0;\n" ++
        "  num idx = -1;\n" ++
        "  num next = 0;\n" ++
        "  _ = a.select_recv_timeout_with_tuning_cancel(&b, &out, &idx, 10, 2, 1);\n" ++
        "  _ = a.select_recv_timeout3_rr_with_tuning_cancel(&b, &c, &next, &out, &idx, 10, 2, 1);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_timeout_with_tuning_cancel(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_timeout3_rr_with_tuning_cancel(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.channel select blocking tuning overrides transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_select_blocking_tuning_override.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  Channel<num> c = channel_new(0);\n" ++
        "  num out = 0;\n" ++
        "  num idx = -1;\n" ++
        "  num next = 0;\n" ++
        "  _ = a.select_recv_timeout_with_tuning_cancel(&b, &out, &idx, -1, 2, 1);\n" ++
        "  _ = a.select_recv_timeout3_rr_with_tuning_cancel(&b, &c, &next, &out, &idx, -1, 2, 1);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_timeout_with_tuning_cancel(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_timeout3_rr_with_tuning_cancel(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.channel select adaptive wait backoff transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_select_adaptive_wait.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  num out = 0;\n" ++
        "  num idx = -1;\n" ++
        "  _ = a.select_recv_timeout_with_tuning_cancel(&b, &out, &idx, 10);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "channel_compute_wait_slice_ms(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "std.channel select backoff-step tuning transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_select_backoff_steps.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> ch = channel_new(0);\n" ++
        "  ch.set_select_wait_backoff_steps(4);\n" ++
        "  num steps = ch.get_select_wait_backoff_steps();\n" ++
        "  _ = steps;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__set_select_wait_backoff_steps(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__get_select_wait_backoff_steps(") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "channel select default returns default branch when empty" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_channel_select_default_runtime.fn";
    const cpath = "codegen_channel_select_default_runtime.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_channel_select_default_runtime.exe"
    else
        "codegen_channel_select_default_runtime";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.channel;\n" ++
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  Channel<num> c = channel_new(0);\n" ++
        "  num out = 0;\n" ++
        "  num idx = -1;\n" ++
        "  num next = 0;\n" ++
        "  num rc2 = a.select_recv_default_with(&b, &out, &idx);\n" ++
        "  num idx2 = idx;\n" ++
        "  num rc3 = a.select_recv3_rr_default_with(&b, &c, &next, &out, &idx);\n" ++
        "  num idx3 = idx;\n" ++
        "  num ok_rc2 = 0;\n" ++
        "  if rc2 == channel_rc_default() { ok_rc2 = 1; }\n" ++
        "  num ok_idx2 = 0;\n" ++
        "  if idx2 == channel_select_index_default() { ok_idx2 = 1; }\n" ++
        "  num ok_rc3 = 0;\n" ++
        "  if rc3 == channel_rc_default() { ok_rc3 = 1; }\n" ++
        "  num ok_idx3 = 0;\n" ++
        "  if idx3 == channel_select_index_default() { ok_idx3 = 1; }\n" ++
        "  printf(\"%lld|%lld|%lld|%lld\", ok_rc2, ok_idx2, ok_rc3, ok_idx3);\n" ++
        "  _ = a.destroy();\n" ++
        "  _ = b.destroy();\n" ++
        "  _ = c.destroy();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, cpath, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, cpath, exe_path);

    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);

    try std.testing.expectEqualStrings("1|1|1|1", stdout);
}

test "channel select cancel returns cancelled status" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_channel_select_cancel_runtime.fn";
    const cpath = "codegen_channel_select_cancel_runtime.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_channel_select_cancel_runtime.exe"
    else
        "codegen_channel_select_cancel_runtime";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.channel;\n" ++
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  Channel<num> c = channel_new(0);\n" ++
        "  num out = 0;\n" ++
        "  num idx = -1;\n" ++
        "  num next = 0;\n" ++
        "  num cancel = 1;\n" ++
        "  num rc2 = a.select_recv_timeout_with_tuning_cancel(&b, &out, &idx, 10, -1, -1, &cancel);\n" ++
        "  num idx2 = idx;\n" ++
        "  num rc3 = a.select_recv_timeout3_rr_with_tuning_cancel(&b, &c, &next, &out, &idx, 10, -1, -1, &cancel);\n" ++
        "  num idx3 = idx;\n" ++
        "  num ok_rc2 = 0;\n" ++
        "  if rc2 == channel_rc_cancelled() { ok_rc2 = 1; }\n" ++
        "  num ok_idx2 = 0;\n" ++
        "  if idx2 == channel_select_index_default() { ok_idx2 = 1; }\n" ++
        "  num ok_rc3 = 0;\n" ++
        "  if rc3 == channel_rc_cancelled() { ok_rc3 = 1; }\n" ++
        "  num ok_idx3 = 0;\n" ++
        "  if idx3 == channel_select_index_default() { ok_idx3 = 1; }\n" ++
        "  printf(\"%lld|%lld|%lld|%lld\", ok_rc2, ok_idx2, ok_rc3, ok_idx3);\n" ++
        "  _ = a.destroy();\n" ++
        "  _ = b.destroy();\n" ++
        "  _ = c.destroy();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, cpath, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, cpath, exe_path);

    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);

    try std.testing.expectEqualStrings("1|1|1|1", stdout);
}

test "channel cancel-aware send and recv return cancelled status" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_channel_cancel_send_recv_runtime.fn";
    const cpath = "codegen_channel_cancel_send_recv_runtime.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_channel_cancel_send_recv_runtime.exe"
    else
        "codegen_channel_cancel_send_recv_runtime";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.channel;\n" ++
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  Channel<num> ch = channel_new_cap(0, 1);\n" ++
        "  _ = ch.send(1);\n" ++
        "  num cancel = 1;\n" ++
        "  num out = 0;\n" ++
        "  num rc_send = ch.send_timeout_with_cancel(2, 10, &cancel);\n" ++
        "  _ = ch.recv_into(&out);\n" ++
        "  num rc_recv = ch.recv_timeout_into_with_cancel(&out, 10, &cancel);\n" ++
        "  num ok_send = 0;\n" ++
        "  if rc_send == channel_rc_cancelled() { ok_send = 1; }\n" ++
        "  num ok_recv = 0;\n" ++
        "  if rc_recv == channel_rc_cancelled() { ok_recv = 1; }\n" ++
        "  printf(\"%lld|%lld\", ok_send, ok_recv);\n" ++
        "  _ = ch.destroy();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, cpath, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, cpath, exe_path);

    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);

    try std.testing.expectEqualStrings("1|1", stdout);
}

test "channel cancel-aware send and recv succeed when not cancelled" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_channel_cancel_send_recv_success_runtime.fn";
    const cpath = "codegen_channel_cancel_send_recv_success_runtime.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_channel_cancel_send_recv_success_runtime.exe"
    else
        "codegen_channel_cancel_send_recv_success_runtime";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.channel;\n" ++
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  Channel<num> ch = channel_new_cap(0, 1);\n" ++
        "  num cancel = 0;\n" ++
        "  num out = 0;\n" ++
        "  num rc1 = ch.send_with_cancel(5, &cancel);\n" ++
        "  num rc2 = ch.recv_into_with_cancel(&out, &cancel);\n" ++
        "  num rc3 = ch.send_timeout_with_cancel(6, 10, &cancel);\n" ++
        "  num rc4 = ch.recv_timeout_into_with_cancel(&out, 10, &cancel);\n" ++
        "  num ok1 = 0;\n" ++
        "  if rc1 == channel_rc_ok() { ok1 = 1; }\n" ++
        "  num ok2 = 0;\n" ++
        "  if rc2 == channel_rc_ok() { ok2 = 1; }\n" ++
        "  num ok3 = 0;\n" ++
        "  if rc3 == channel_rc_ok() { ok3 = 1; }\n" ++
        "  num ok4 = 0;\n" ++
        "  if rc4 == channel_rc_ok() { ok4 = 1; }\n" ++
        "  num ok_out = 0;\n" ++
        "  if out == 6 { ok_out = 1; }\n" ++
        "  printf(\"%lld|%lld|%lld|%lld|%lld\", ok1, ok2, ok3, ok4, ok_out);\n" ++
        "  _ = ch.destroy();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, cpath, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, cpath, exe_path);

    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);

    try std.testing.expectEqualStrings("1|1|1|1|1", stdout);
}

test "channel cancel token controls cancel and reset behavior" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_channel_cancel_token_runtime.fn";
    const cpath = "codegen_channel_cancel_token_runtime.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_channel_cancel_token_runtime.exe"
    else
        "codegen_channel_cancel_token_runtime";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.channel;\n" ++
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  Channel<num> ch = channel_new_cap(0, 1);\n" ++
        "  ChannelCancelToken token = channel_cancel_token_new();\n" ++
        "  num out = 0;\n" ++
        "  _ = ch.send(1);\n" ++
        "  _ = channel_cancel_token_cancel(&token);\n" ++
        "  num rc_cancel = ch.send_timeout_with_token(2, 10, &token);\n" ++
        "  _ = ch.recv_into(&out);\n" ++
        "  _ = channel_cancel_token_reset(&token);\n" ++
        "  num rc_send = ch.send_with_token(3, &token);\n" ++
        "  num rc_recv = ch.recv_into_with_token(&out, &token);\n" ++
        "  num ok_cancel = 0;\n" ++
        "  if rc_cancel == channel_rc_cancelled() { ok_cancel = 1; }\n" ++
        "  num ok_send = 0;\n" ++
        "  if rc_send == channel_rc_ok() { ok_send = 1; }\n" ++
        "  num ok_recv = 0;\n" ++
        "  if rc_recv == channel_rc_ok() { ok_recv = 1; }\n" ++
        "  num ok_out = 0;\n" ++
        "  if out == 3 { ok_out = 1; }\n" ++
        "  num ok_state = 0;\n" ++
        "  if channel_cancel_token_is_cancelled(&token) == false { ok_state = 1; }\n" ++
        "  printf(\"%lld|%lld|%lld|%lld|%lld\", ok_cancel, ok_send, ok_recv, ok_out, ok_state);\n" ++
        "  _ = ch.destroy();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, cpath, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, cpath, exe_path);

    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);

    try std.testing.expectEqualStrings("1|1|1|1|1", stdout);
}

test "channel select3 rr stress drains all values with expected statuses" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_channel_select_rr_stress_runtime.fn";
    const cpath = "codegen_channel_select_rr_stress_runtime.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_channel_select_rr_stress_runtime.exe"
    else
        "codegen_channel_select_rr_stress_runtime";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.channel;\n" ++
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  Channel<num> a = channel_new_cap(0, 256);\n" ++
        "  Channel<num> b = channel_new_cap(0, 256);\n" ++
        "  Channel<num> c = channel_new_cap(0, 256);\n" ++
        "  num i = 0;\n" ++
        "  for i < 200 {\n" ++
        "    _ = a.send(i);\n" ++
        "    _ = b.send(i + 1000);\n" ++
        "    _ = c.send(i + 2000);\n" ++
        "    i = i + 1;\n" ++
        "  }\n" ++
        "  num next = 0;\n" ++
        "  num out = 0;\n" ++
        "  num idx = channel_select_index_default();\n" ++
        "  num got_a = 0;\n" ++
        "  num got_b = 0;\n" ++
        "  num got_c = 0;\n" ++
        "  num sum = 0;\n" ++
        "  i = 0;\n" ++
        "  for i < 600 {\n" ++
        "    num rc = a.select_recv_timeout3_rr_with_tuning_cancel(&b, &c, &next, &out, &idx, -1);\n" ++
        "    if rc != channel_rc_ok() {\n" ++
        "      printf(\"0|0|0|0|0\");\n" ++
        "      _ = a.destroy();\n" ++
        "      _ = b.destroy();\n" ++
        "      _ = c.destroy();\n" ++
        "      ret;\n" ++
        "    }\n" ++
        "    if idx == channel_select_index_self() {\n" ++
        "      got_a = got_a + 1;\n" ++
        "    } elif idx == channel_select_index_other() {\n" ++
        "      got_b = got_b + 1;\n" ++
        "    } else {\n" ++
        "      got_c = got_c + 1;\n" ++
        "    }\n" ++
        "    sum = sum + out;\n" ++
        "    i = i + 1;\n" ++
        "  }\n" ++
        "  _ = a.close();\n" ++
        "  _ = b.close();\n" ++
        "  _ = c.close();\n" ++
        "  num tail = 0;\n" ++
        "  num rc_done = a.select_try_recv3_rr_with(&b, &c, &next, &tail, &idx);\n" ++
        "  num ok_a = 0;\n" ++
        "  if got_a == 200 { ok_a = 1; }\n" ++
        "  num ok_b = 0;\n" ++
        "  if got_b == 200 { ok_b = 1; }\n" ++
        "  num ok_c = 0;\n" ++
        "  if got_c == 200 { ok_c = 1; }\n" ++
        "  num ok_sum = 0;\n" ++
        "  if sum == 659700 { ok_sum = 1; }\n" ++
        "  num ok_done = 0;\n" ++
        "  if rc_done == channel_rc_closed() { ok_done = 1; }\n" ++
        "  printf(\"%lld|%lld|%lld|%lld|%lld\", ok_a, ok_b, ok_c, ok_sum, ok_done);\n" ++
        "  _ = a.destroy();\n" ++
        "  _ = b.destroy();\n" ++
        "  _ = c.destroy();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, cpath, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, cpath, exe_path);

    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);

    try std.testing.expectEqualStrings("1|1|1|1|1", stdout);
}

test "channel default and cancel select stress stays stable" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_channel_select_default_cancel_stress_runtime.fn";
    const cpath = "codegen_channel_select_default_cancel_stress_runtime.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_channel_select_default_cancel_stress_runtime.exe"
    else
        "codegen_channel_select_default_cancel_stress_runtime";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.channel;\n" ++
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  num out = 0;\n" ++
        "  num idx = channel_select_index_default();\n" ++
        "  num i = 0;\n" ++
        "  num ok_default = 1;\n" ++
        "  for i < 300 {\n" ++
        "    num rc = a.select_recv_default_with(&b, &out, &idx);\n" ++
        "    if rc != channel_rc_default() {\n" ++
        "      ok_default = 0;\n" ++
        "    } elif idx != channel_select_index_default() {\n" ++
        "      ok_default = 0;\n" ++
        "    }\n" ++
        "    i = i + 1;\n" ++
        "  }\n" ++
        "  num cancel = 1;\n" ++
        "  i = 0;\n" ++
        "  num ok_cancel = 1;\n" ++
        "  for i < 300 {\n" ++
        "    num rc = a.select_recv_timeout_with_tuning_cancel(&b, &out, &idx, 5, -1, -1, &cancel);\n" ++
        "    if rc != channel_rc_cancelled() {\n" ++
        "      ok_cancel = 0;\n" ++
        "    } elif idx != channel_select_index_default() {\n" ++
        "      ok_cancel = 0;\n" ++
        "    }\n" ++
        "    i = i + 1;\n" ++
        "  }\n" ++
        "  printf(\"%lld|%lld\", ok_default, ok_cancel);\n" ++
        "  _ = a.destroy();\n" ++
        "  _ = b.destroy();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, cpath, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, cpath, exe_path);

    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);

    try std.testing.expectEqualStrings("1|1", stdout);
}

test "channel pthread close race under contention" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_channel_thread_close_race.fn";
    const cpath = "codegen_channel_thread_close_race.c";
    const hpath = "codegen_channel_thread_close_race_harness.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_channel_thread_close_race.exe"
    else
        "codegen_channel_thread_close_race";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, hpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.channel;\n" ++
        "fun touch() {\n" ++
        "  Channel<num> ch = channel_new_cap(0, 64);\n" ++
        "  num out = 0;\n" ++
        "  _ = ch.try_send(1);\n" ++
        "  _ = ch.try_recv(&out);\n" ++
        "  _ = ch.len();\n" ++
        "  _ = ch.close();\n" ++
        "  _ = ch.destroy();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, cpath, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    const harness =
        "#include \"codegen_channel_thread_close_race.c\"\n" ++
        "#include <stdatomic.h>\n" ++
        "#if defined(_WIN32)\n" ++
        "#include <windows.h>\n" ++
        "static void spin_pause(void) { Sleep(0); }\n" ++
        "#else\n" ++
        "#include <sched.h>\n" ++
        "static void spin_pause(void) { sched_yield(); }\n" ++
        "#endif\n" ++
        "\n" ++
        "typedef struct {\n" ++
        "  Channel__num* ch;\n" ++
        "  _Atomic long long* sends_ok;\n" ++
        "  _Atomic long long* bad_rc;\n" ++
        "} SenderCtx;\n" ++
        "\n" ++
        "typedef struct {\n" ++
        "  Channel__num* ch;\n" ++
        "  _Atomic long long* recvs_ok;\n" ++
        "  _Atomic long long* bad_rc;\n" ++
        "} ReceiverCtx;\n" ++
        "\n" ++
        "static void* sender_main(void* arg) {\n" ++
        "  SenderCtx* ctx = (SenderCtx*)arg;\n" ++
        "  for (long long i = 0; i < 10000; ++i) {\n" ++
        "    long long rc = Channel__num__try_send(ctx->ch, i);\n" ++
        "    if (rc == channel_rc_ok()) {\n" ++
        "      atomic_fetch_add(ctx->sends_ok, 1);\n" ++
        "      continue;\n" ++
        "    }\n" ++
        "    if (rc == channel_rc_full()) {\n" ++
        "      spin_pause();\n" ++
        "      continue;\n" ++
        "    }\n" ++
        "    if (rc == channel_rc_closed()) {\n" ++
        "      break;\n" ++
        "    }\n" ++
        "    atomic_fetch_add(ctx->bad_rc, 1);\n" ++
        "    break;\n" ++
        "  }\n" ++
        "  return NULL;\n" ++
        "}\n" ++
        "\n" ++
        "static void* receiver_main(void* arg) {\n" ++
        "  ReceiverCtx* ctx = (ReceiverCtx*)arg;\n" ++
        "  for (long long i = 0; i < 10000; ++i) {\n" ++
        "    long long out = 0;\n" ++
        "    long long rc = Channel__num__try_recv(ctx->ch, &out);\n" ++
        "    if (rc == channel_rc_ok()) {\n" ++
        "      atomic_fetch_add(ctx->recvs_ok, 1);\n" ++
        "      continue;\n" ++
        "    }\n" ++
        "    if (rc == channel_rc_empty()) {\n" ++
        "      spin_pause();\n" ++
        "      continue;\n" ++
        "    }\n" ++
        "    if (rc == channel_rc_closed()) {\n" ++
        "      break;\n" ++
        "    }\n" ++
        "    atomic_fetch_add(ctx->bad_rc, 1);\n" ++
        "    break;\n" ++
        "  }\n" ++
        "  return NULL;\n" ++
        "}\n" ++
        "\n" ++
        "int main(void) {\n" ++
        "  Channel__num ch = channel_new_cap__num(0, 64);\n" ++
        "\n" ++
        "  _Atomic long long sends_ok = 0;\n" ++
        "  _Atomic long long recvs_ok = 0;\n" ++
        "  _Atomic long long bad_rc = 0;\n" ++
        "  _Atomic long long start_err = 0;\n" ++
        "\n" ++
        "  enum { N = 1 };\n" ++
        "  pthread_t senders[N];\n" ++
        "  pthread_t receivers[N];\n" ++
        "  int sender_started[N];\n" ++
        "  int receiver_started[N];\n" ++
        "  SenderCtx sender_ctx[N];\n" ++
        "  ReceiverCtx receiver_ctx[N];\n" ++
        "\n" ++
        "  for (int i = 0; i < N; ++i) {\n" ++
        "    sender_started[i] = 0;\n" ++
        "    receiver_started[i] = 0;\n" ++
        "\n" ++
        "    sender_ctx[i].ch = &ch;\n" ++
        "    sender_ctx[i].sends_ok = &sends_ok;\n" ++
        "    sender_ctx[i].bad_rc = &bad_rc;\n" ++
        "\n" ++
        "    receiver_ctx[i].ch = &ch;\n" ++
        "    receiver_ctx[i].recvs_ok = &recvs_ok;\n" ++
        "    receiver_ctx[i].bad_rc = &bad_rc;\n" ++
        "\n" ++
        "    long long src = pthread_create(&senders[i], NULL, sender_main, &sender_ctx[i]);\n" ++
        "    if (src == 0) {\n" ++
        "      sender_started[i] = 1;\n" ++
        "    } else {\n" ++
        "      atomic_fetch_add(&start_err, 1);\n" ++
        "    }\n" ++
        "\n" ++
        "    long long rrc = pthread_create(&receivers[i], NULL, receiver_main, &receiver_ctx[i]);\n" ++
        "    if (rrc == 0) {\n" ++
        "      receiver_started[i] = 1;\n" ++
        "    } else {\n" ++
        "      atomic_fetch_add(&start_err, 1);\n" ++
        "    }\n" ++
        "  }\n" ++
        "\n" ++
        "  for (int i = 0; i < N; ++i) {\n" ++
        "    if (sender_started[i] == 1) {\n" ++
        "      long long jrc = pthread_join(senders[i], NULL);\n" ++
        "      if (jrc != 0) {\n" ++
        "        atomic_fetch_add(&start_err, 1);\n" ++
        "      }\n" ++
        "    }\n" ++
        "  }\n" ++
        "\n" ++
        "  for (int i = 0; i < N; ++i) {\n" ++
        "    if (receiver_started[i] == 1) {\n" ++
        "      long long jrc = pthread_join(receivers[i], NULL);\n" ++
        "      if (jrc != 0) {\n" ++
        "        atomic_fetch_add(&start_err, 1);\n" ++
        "      }\n" ++
        "    }\n" ++
        "  }\n" ++
        "\n" ++
        "  long long close_code = Channel__num__close(&ch);\n" ++
        "\n" ++
        "  long long sends = atomic_load(&sends_ok);\n" ++
        "  long long recvs = atomic_load(&recvs_ok);\n" ++
        "  long long bad = atomic_load(&bad_rc);\n" ++
        "  long long serr = atomic_load(&start_err);\n" ++
        "  long long len = Channel__num__len(&ch);\n" ++
        "\n" ++
        "  long long ok_close = 0;\n" ++
        "  if (close_code == channel_rc_ok()) {\n" ++
        "    ok_close = 1;\n" ++
        "  }\n" ++
        "\n" ++
        "  long long ok_counts = 0;\n" ++
        "  if (sends >= recvs && (sends - recvs) <= 64) {\n" ++
        "    ok_counts = 1;\n" ++
        "  }\n" ++
        "\n" ++
        "  long long ok_len = 0;\n" ++
        "  if (len == (sends - recvs)) {\n" ++
        "    ok_len = 1;\n" ++
        "  }\n" ++
        "\n" ++
        "  long long ok_bad = 0;\n" ++
        "  if (bad == 0 && serr == 0) {\n" ++
        "    ok_bad = 1;\n" ++
        "  }\n" ++
        "\n" ++
        "  printf(\"%lld|%lld|%lld|%lld\", ok_close, ok_counts, ok_len, ok_bad);\n" ++
        "  (void)Channel__num__destroy(&ch);\n" ++
        "  return 0;\n" ++
        "}\n";

    {
        const h_file = try std.Io.Dir.cwd().createFile(std.testing.io, hpath, .{});
        defer h_file.close(std.testing.io);
        try h_file.writeStreamingAll(std.testing.io, harness);
    }

    try compileWithZigCc(allocator, hpath, exe_path);

    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);

    try std.testing.expectEqualStrings("1|1|1|1", stdout);
}

test "channel pthread cancelled-token contention is stable" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_channel_thread_cancel_token_contention.fn";
    const cpath = "codegen_channel_thread_cancel_token_contention.c";
    const hpath = "codegen_channel_thread_cancel_token_contention_harness.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_channel_thread_cancel_token_contention.exe"
    else
        "codegen_channel_thread_cancel_token_contention";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, hpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.channel;\n" ++
        "fun touch() {\n" ++
        "  Channel<num> ch = channel_new_cap(0, 8);\n" ++
        "  ChannelCancelToken tok = channel_cancel_token_cancelled();\n" ++
        "  num out = 0;\n" ++
        "  _ = ch.send_timeout_with_token(1, 0, &tok);\n" ++
        "  _ = ch.recv_timeout_into_with_token(&out, 0, &tok);\n" ++
        "  _ = ch.close();\n" ++
        "  _ = ch.destroy();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, cpath, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    const harness =
        "#include \"codegen_channel_thread_cancel_token_contention.c\"\n" ++
        "#include <stdatomic.h>\n" ++
        "\n" ++
        "typedef struct {\n" ++
        "  Channel__num ch;\n" ++
        "  ChannelCancelToken token;\n" ++
        "  _Atomic long long* cancelled;\n" ++
        "  _Atomic long long* bad_rc;\n" ++
        "} TokenSenderCtx;\n" ++
        "\n" ++
        "typedef struct {\n" ++
        "  Channel__num ch;\n" ++
        "  ChannelCancelToken token;\n" ++
        "  _Atomic long long* cancelled;\n" ++
        "  _Atomic long long* bad_rc;\n" ++
        "} TokenReceiverCtx;\n" ++
        "\n" ++
        "static void* token_sender_main(void* arg) {\n" ++
        "  TokenSenderCtx* ctx = (TokenSenderCtx*)arg;\n" ++
        "  for (long long i = 0; i < 1000; ++i) {\n" ++
        "    long long rc = Channel__num__send_timeout_with_token(&ctx->ch, i, 0, &ctx->token);\n" ++
        "    if (rc == channel_rc_cancelled()) {\n" ++
        "      atomic_fetch_add(ctx->cancelled, 1);\n" ++
        "      continue;\n" ++
        "    }\n" ++
        "    atomic_fetch_add(ctx->bad_rc, 1);\n" ++
        "    break;\n" ++
        "  }\n" ++
        "  return NULL;\n" ++
        "}\n" ++
        "\n" ++
        "static void* token_receiver_main(void* arg) {\n" ++
        "  TokenReceiverCtx* ctx = (TokenReceiverCtx*)arg;\n" ++
        "  for (long long i = 0; i < 1000; ++i) {\n" ++
        "    long long out = 0;\n" ++
        "    long long rc = Channel__num__recv_timeout_into_with_token(&ctx->ch, &out, 0, &ctx->token);\n" ++
        "    if (rc == channel_rc_cancelled()) {\n" ++
        "      atomic_fetch_add(ctx->cancelled, 1);\n" ++
        "      continue;\n" ++
        "    }\n" ++
        "    atomic_fetch_add(ctx->bad_rc, 1);\n" ++
        "    break;\n" ++
        "  }\n" ++
        "  return NULL;\n" ++
        "}\n" ++
        "\n" ++
        "int main(void) {\n" ++
        "  _Atomic long long send_cancelled = 0;\n" ++
        "  _Atomic long long recv_cancelled = 0;\n" ++
        "  _Atomic long long bad_rc = 0;\n" ++
        "  _Atomic long long start_err = 0;\n" ++
        "\n" ++
        "  enum { N = 6 };\n" ++
        "  enum { ITERS = 1000 };\n" ++
        "\n" ++
        "  pthread_t senders[N];\n" ++
        "  pthread_t receivers[N];\n" ++
        "  int sender_started[N];\n" ++
        "  int receiver_started[N];\n" ++
        "  TokenSenderCtx sender_ctx[N];\n" ++
        "  TokenReceiverCtx receiver_ctx[N];\n" ++
        "\n" ++
        "  for (int i = 0; i < N; ++i) {\n" ++
        "    sender_started[i] = 0;\n" ++
        "    receiver_started[i] = 0;\n" ++
        "\n" ++
        "    sender_ctx[i].ch = channel_new_cap__num(0, 8);\n" ++
        "    sender_ctx[i].token = channel_cancel_token_cancelled();\n" ++
        "    sender_ctx[i].cancelled = &send_cancelled;\n" ++
        "    sender_ctx[i].bad_rc = &bad_rc;\n" ++
        "\n" ++
        "    receiver_ctx[i].ch = channel_new_cap__num(0, 8);\n" ++
        "    receiver_ctx[i].token = channel_cancel_token_cancelled();\n" ++
        "    receiver_ctx[i].cancelled = &recv_cancelled;\n" ++
        "    receiver_ctx[i].bad_rc = &bad_rc;\n" ++
        "\n" ++
        "    long long src = pthread_create(&senders[i], NULL, token_sender_main, &sender_ctx[i]);\n" ++
        "    if (src == 0) {\n" ++
        "      sender_started[i] = 1;\n" ++
        "    } else {\n" ++
        "      atomic_fetch_add(&start_err, 1);\n" ++
        "    }\n" ++
        "\n" ++
        "    long long rrc = pthread_create(&receivers[i], NULL, token_receiver_main, &receiver_ctx[i]);\n" ++
        "    if (rrc == 0) {\n" ++
        "      receiver_started[i] = 1;\n" ++
        "    } else {\n" ++
        "      atomic_fetch_add(&start_err, 1);\n" ++
        "    }\n" ++
        "  }\n" ++
        "\n" ++
        "  for (int i = 0; i < N; ++i) {\n" ++
        "    if (sender_started[i] == 1) {\n" ++
        "      long long jrc = pthread_join(senders[i], NULL);\n" ++
        "      if (jrc != 0) {\n" ++
        "        atomic_fetch_add(&start_err, 1);\n" ++
        "      }\n" ++
        "    }\n" ++
        "  }\n" ++
        "\n" ++
        "  for (int i = 0; i < N; ++i) {\n" ++
        "    if (receiver_started[i] == 1) {\n" ++
        "      long long jrc = pthread_join(receivers[i], NULL);\n" ++
        "      if (jrc != 0) {\n" ++
        "        atomic_fetch_add(&start_err, 1);\n" ++
        "      }\n" ++
        "    }\n" ++
        "  }\n" ++
        "\n" ++
        "  for (int i = 0; i < N; ++i) {\n" ++
        "    (void)Channel__num__close(&sender_ctx[i].ch);\n" ++
        "    (void)Channel__num__destroy(&sender_ctx[i].ch);\n" ++
        "    (void)Channel__num__close(&receiver_ctx[i].ch);\n" ++
        "    (void)Channel__num__destroy(&receiver_ctx[i].ch);\n" ++
        "  }\n" ++
        "\n" ++
        "  long long sc = atomic_load(&send_cancelled);\n" ++
        "  long long rc = atomic_load(&recv_cancelled);\n" ++
        "  long long bad = atomic_load(&bad_rc);\n" ++
        "  long long serr = atomic_load(&start_err);\n" ++
        "\n" ++
        "  long long expected = (long long)N * (long long)ITERS;\n" ++
        "\n" ++
        "  long long ok_send = 0;\n" ++
        "  if (sc == expected) {\n" ++
        "    ok_send = 1;\n" ++
        "  }\n" ++
        "\n" ++
        "  long long ok_recv = 0;\n" ++
        "  if (rc == expected) {\n" ++
        "    ok_recv = 1;\n" ++
        "  }\n" ++
        "\n" ++
        "  long long ok_bad = 0;\n" ++
        "  if (bad == 0 && serr == 0) {\n" ++
        "    ok_bad = 1;\n" ++
        "  }\n" ++
        "\n" ++
        "  printf(\"%lld|%lld|%lld\", ok_send, ok_recv, ok_bad);\n" ++
        "  return 0;\n" ++
        "}\n";

    {
        const h_file = try std.Io.Dir.cwd().createFile(std.testing.io, hpath, .{});
        defer h_file.close(std.testing.io);
        try h_file.writeStreamingAll(std.testing.io, harness);
    }

    try compileWithZigCc(allocator, hpath, exe_path);

    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);

    try std.testing.expectEqualStrings("1|1|1", stdout);
}

test "generic function specialization emits concrete names" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_generic_fn.fn";

    const input =
        "fun id<T>(T x) T { ret x; }\n" ++
        "fun main() {\n" ++
        "  num a = id(1);\n" ++
        "  str b = id(\"hi\");\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "id__num") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "id__str") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "id__T") == null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "generic inference after init transpiles with concrete specializations and runs" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_generic_inference_after_init_regression.fn";
    const c_path = "codegen_generic_inference_after_init_regression.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_generic_inference_after_init_regression.exe"
    else
        "codegen_generic_inference_after_init_regression";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "\n" ++
        "compound Box<T> {\n" ++
        "  T value;\n" ++
        "}\n" ++
        "\n" ++
        "compound Pair<L, R> {\n" ++
        "  L left;\n" ++
        "  R right;\n" ++
        "}\n" ++
        "\n" ++
        "fun make_box<T>(T x) Box<T> {\n" ++
        "  ret Box<T>{value = x};\n" ++
        "}\n" ++
        "\n" ++
        "fun make_pair<L, R>(L left, R right) Pair<L, R> {\n" ++
        "  ret Pair<L, R>{left = left, right = right};\n" ++
        "}\n" ++
        "\n" ++
        "fun pick_left<L, R>(Pair<L, R> p) L {\n" ++
        "  ret p.left;\n" ++
        "}\n" ++
        "\n" ++
        "fun swap_pair<L, R>(Pair<L, R> p) Pair<R, L> {\n" ++
        "  ret Pair<R, L>{left = p.right, right = p.left};\n" ++
        "}\n" ++
        "\n" ++
        "fun main() {\n" ++
        "  let nbox = Box{value = 7};\n" ++
        "  nbox.value += 1;\n" ++
        "  let sbox = make_box(\"hi\");\n" ++
        "  let pair = make_pair(nbox.value, sbox.value);\n" ++
        "  let swapped = swap_pair(pair);\n" ++
        "  let left_num = pick_left(pair);\n" ++
        "  let left_str = pick_left(swapped);\n" ++
        "  printf(\"nbox=%lld sbox=%s\\n\", nbox.value, sbox.value);\n" ++
        "  printf(\"pair=(%lld,%s) swapped=(%s,%lld)\\n\", pair.left, pair.right, swapped.left, swapped.right);\n" ++
        "  printf(\"picks=(%lld,%s)\\n\", left_num, left_str);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "make_pair__num__str") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "swap_pair__num__str") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Pair__num__str") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Pair__str__num") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "make_pair__L__R") == null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Pair__L__R") == null);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings(
        "nbox=8 sbox=hi\n" ++
            "pair=(8,hi) swapped=(hi,8)\n" ++
            "picks=(8,hi)\n",
        stdout,
    );
}

test "assert emits abort and message" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_assert.fn";

    const input =
        "fun main() {\n" ++
        "  assert true, \"ok\";\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "fprintf(stderr, \"Assertion failed at ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "abort()") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "compounds + quirks + impl vtables transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_quirk_vtable.fn";

    const input =
        "compound Point { num x; num y; }\n" ++
        "quirk HasX { getX() num; }\n" ++
        "impl Point as HasX {\n" ++
        "  getX() num { ret self.x; }\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  Point p;\n" ++
        "  p.x = 1;\n" ++
        "  HasX h = &p;\n" ++
        "  h = &p;\n" ++
        "  num v = h.getX();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "typedef struct Point") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t x;") != null);

    // Canonical quirk types and impl helpers use hashed names.
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "__fun_quirk_") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "_vtable") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "__fun_coerce_Point_") != null);

    // Coercion and dispatch.
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "HasX h = __fun_coerce_Point_") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "h = __fun_coerce_Point_") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "h.vtable->getX") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "h.self") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "pointer field access uses arrow" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_compound_ptr_field.fn";

    const input =
        "compound Point { num x; }\n" ++
        "fun main() {\n" ++
        "  Point p;\n" ++
        "  Point* pp = &p;\n" ++
        "  pp.x = 1;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "pp->x") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

fn extractFirstQuirkBaseName(out: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, out, "typedef struct __fun_quirk_") orelse return null;
    const sub = out[start..];
    const base_start = std.mem.indexOf(u8, sub, "__fun_quirk_") orelse return null;
    const after_prefix = sub[base_start..];
    const vtable_idx = std.mem.indexOf(u8, after_prefix, "_vtable") orelse return null;
    return after_prefix[0..vtable_idx];
}

test "structural quirks share canonical C type" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_quirk_structural_equiv.fn";

    const input =
        "compound Point { num x; }\n" ++
        "quirk Q1 { getX() num; }\n" ++
        "quirk Q2 { getX() num; }\n" ++
        "impl Point as Q1 { getX() num { ret self.x; } }\n" ++
        "fun main() {\n" ++
        "  Point p;\n" ++
        "  Q1 a = &p;\n" ++
        "  Q2 b = &p;\n" ++
        "  num x = a.getX();\n" ++
        "  num y = b.getX();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    const base = extractFirstQuirkBaseName(out_owned) orelse return error.TestExpectedQuirkType;

    const q1_typedef = try std.fmt.allocPrint(allocator, "typedef {s} Q1;", .{base});
    defer allocator.free(q1_typedef);
    const q2_typedef = try std.fmt.allocPrint(allocator, "typedef {s} Q2;", .{base});
    defer allocator.free(q2_typedef);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, q1_typedef) != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, q2_typedef) != null);

    // Both should coerce via the same impl key (signature-canonicalized).
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "__fun_coerce_Point_") != null);

    // Both should dispatch through the same canonical vtable/object shape.
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "a.vtable->getX") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "b.vtable->getX") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "asm statement transpiles" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_asm.fn";

    const input =
        "fun main() {\n" ++
        "  num x = 1;\n" ++
        "  num y = 0;\n" ++
        "  asm volatile (out y: \"=r\" = y; in x: \"r\" = x; clobber \"memory\") \"mov %[x], %[y]\";\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "__asm__ __volatile__") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "\"=r\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "\"memory\"") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "asm block preserves newlines" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_asm_block.fn";

    const input =
        "fun main() {\n" ++
        "  asm volatile {\n" ++
        "    mov x0, 0\n" ++
        "    mov x8, 93\n" ++
        "    svc 0\n" ++
        "  };\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "mov x0, 0\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "mov x8, 93\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "svc 0\\n") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "transitive std.net import emits socket headers" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_transitive_std_net.fn";

    const input =
        "imp std.net;\n" ++
        "fun main() {\n" ++
        "  ret;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#if defined(_WIN32)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <winsock2.h>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <ws2tcpip.h>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <sys/socket.h>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <netinet/in.h>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <arpa/inet.h>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <unistd.h>") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "main num return emits exit status" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_main_num_return.fn";

    const input =
        "fun main() num {\n" ++
        "  ret 7;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int main") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "return (int)(7);") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "map compound key specialization symbols emit" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_map_compound_key.fn";

    const input =
        "imp stdlib.std.map;\n" ++
        "compound UserKey { num id; num region; }\n" ++
        "fun main() {\n" ++
        "  Map<UserKey, str> by_user;\n" ++
        "  by_user.init(8);\n" ++
        "  UserKey a = UserKey{id = 7, region = 1};\n" ++
        "  UserKey b = UserKey{id = 9, region = 2};\n" ++
        "  by_user.put(a, \"alice\");\n" ++
        "  by_user.put(b, \"bob\");\n" ++
        "  str out = by_user.get(a);\n" ++
        "  bin present = by_user.has(a);\n" ++
        "  by_user.remove(b);\n" ++
        "  if present == false { ret; }\n" ++
        "  if out == \"alice\" { ret; }\n" ++
        "  by_user.free();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Map__UserKey__str") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Map__UserKey__str__init") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Map__UserKey__str__put") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Map__UserKey__str__get") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Map__UserKey__str__has") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Map__UserKey__str__remove") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "stdlib hot path stress transpiles" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_stdlib_hot_stress.fn";

    const input =
        "imp stdlib.std.map;\n" ++
        "fun main() {\n" ++
        "  Map<num, str> m;\n" ++
        "  m.init(256);\n" ++
        "  num i = 0;\n" ++
        "  for i < 2000 {\n" ++
        "    m.put(i, \"v\");\n" ++
        "    i = i + 1;\n" ++
        "  }\n" ++
        "  i = 0;\n" ++
        "  for i < 1000 {\n" ++
        "    if m.has(i) == false {\n" ++
        "      ret;\n" ++
        "    }\n" ++
        "    i = i + 1;\n" ++
        "  }\n" ++
        "  m.remove(42);\n" ++
        "  str out = m.get(7);\n" ++
        "  if m.has(7) == true {\n" ++
        "    if out == \"v\" { ret; }\n" ++
        "  }\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Map__num__str__put") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Map__num__str__has") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Map__num__str__remove") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "generic specialization plus net offload async regression stays stable" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_generic_net_regression.fn";

    const input =
        "imp stdlib.std.map;\n" ++
        "imp std.net;\n" ++
        "imp std.channel;\n" ++
        "imp std.c.mem;\n" ++
        "compound UserKey { num id; num region; }\n" ++
        "async fun main() {\n" ++
        "  Map<UserKey, str> by_user;\n" ++
        "  by_user.init(8);\n" ++
        "  UserKey a = UserKey{id = 7, region = 1};\n" ++
        "  by_user.put(a, \"alice\");\n" ++
        "  str out = by_user.get(a);\n" ++
        "  bin present = by_user.has(a);\n" ++
        "\n" ++
        "  ChannelCancelToken token = channel_cancel_token_new();\n" ++
        "  str recv_buf = malloc(8);\n" ++
        "  num rc = -2;\n" ++
        "  if recv_buf != NULL {\n" ++
        "    rc = await tcp_roundtrip_offload_async(-1, \"PING\", recv_buf, 7, &token);\n" ++
        "    free(recv_buf);\n" ++
        "  }\n" ++
        "\n" ++
        "  if present == true {\n" ++
        "    _ = out;\n" ++
        "  }\n" ++
        "  _ = rc;\n" ++
        "  by_user.free();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Map__UserKey__str__init") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Map__UserKey__str__put") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Map__UserKey__str__get") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "tcp_roundtrip_offload_async") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "nested import generic impl specialization prototypes emit and run" {
    const allocator = std.testing.allocator;
    const leaf_path = "codegen_nested_generic_leaf.fn";
    const mid_path = "codegen_nested_generic_mid.fn";
    const main_path = "codegen_nested_generic_main.fn";
    const cpath = "codegen_nested_generic_main.c";
    const exe_path = if (builtin.os.tag == .windows)
        "codegen_nested_generic_main.exe"
    else
        "codegen_nested_generic_main";

    defer std.Io.Dir.cwd().deleteFile(std.testing.io, leaf_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, mid_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, main_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cpath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    {
        const leaf_file = try std.Io.Dir.cwd().createFile(std.testing.io, leaf_path, .{ .read = true, .truncate = true });
        defer leaf_file.close(std.testing.io);
        try leaf_file.writeStreamingAll(
            std.testing.io,
            "pub compound Box<T> {\n" ++
                "  T value;\n" ++
                "}\n" ++
                "impl Box<T> {\n" ++
                "  pub id() T { ret self.value; }\n" ++
                "}\n",
        );
    }

    {
        const mid_file = try std.Io.Dir.cwd().createFile(std.testing.io, mid_path, .{ .read = true, .truncate = true });
        defer mid_file.close(std.testing.io);
        try mid_file.writeStreamingAll(
            std.testing.io,
            "imp codegen_nested_generic_leaf;\n" ++
                "pub fun calc_num() num {\n" ++
                "  Box<num> b = Box<num>{value = 42};\n" ++
                "  ret b.id();\n" ++
                "}\n" ++
                "pub fun calc_str() str {\n" ++
                "  Box<str> b = Box<str>{value = \"ok\"};\n" ++
                "  ret b.id();\n" ++
                "}\n",
        );
    }

    const input =
        "imp codegen_nested_generic_mid;\n" ++
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  num a = calc_num();\n" ++
        "  str b = calc_str();\n" ++
        "  printf(\"%lld|%s\", a, b);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, main_path, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Box__num__id") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Box__str__id") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Box__T__id") == null);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, cpath, .{});
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, cpath, exe_path);

    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42|ok", stdout);
}

test "hexadecimal literals with a-f and A-F digits compile and run" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_hex_literals.fn";
    const c_path = "codegen_hex_literals.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_hex_literals.exe" else "codegen_hex_literals";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: is_hex_number previously only accepted 'a'..'b', so any literal
    // containing c-f or uppercase A-F failed to lex ("failed to parse number ''").
    const input =
        "imp std.c.io;\n" ++
        "fun main() num {\n" ++
        "  num a = 0xdead;\n" ++
        "  num b = 0xBEEF;\n" ++
        "  num c = 0xFF;\n" ++
        "  num d = 0x1f;\n" ++
        "  printf(\"%lld %lld %lld %lld\\n\", a, b, c, d);\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);

    try std.testing.expectEqualStrings("57005 48879 255 31\n", stdout);
}

test "long type name with quirk impl does not overflow mangled C identifier buffers" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_long_type_name.fn";
    const c_path = "codegen_long_type_name.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_long_type_name.exe" else "codegen_long_type_name";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: quirk-impl C-identifier mangling used fixed [96]/[128]u8 stack
    // buffers with `bufPrint(...) catch unreachable`. A type name longer than the
    // buffer's free space panicked the compiler ("NoSpaceLeft") on valid input.
    const long_name = "A" ** 90;
    const input =
        "imp std.c.io;\n" ++
        "quirk Greeter {\n" ++
        "  greet() str;\n" ++
        "}\n" ++
        "compound " ++ long_name ++ " {\n" ++
        "  num x;\n" ++
        "}\n" ++
        "impl " ++ long_name ++ " as Greeter {\n" ++
        "  greet() str { ret \"hi\"; }\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  " ++ long_name ++ " g;\n" ++
        "  g.x = 1;\n" ++
        "  printf(\"%s\\n\", g.greet());\n" ++
        "  ret 0;\n" ++
        "}\n";

    // The key assertion is that transpilation completes without a panic.
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }

    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);

    try std.testing.expectEqualStrings("hi\n", stdout);
}

test "forward-referenced compound struct-initializer expression compiles and runs" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_fwd_struct_init.fn";
    const c_path = "codegen_fwd_struct_init.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_fwd_struct_init.exe" else "codegen_fwd_struct_init";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: a `Name{...}` initializer EXPRESSION used before `Name` is
    // declared (forward reference) was rejected with "unknown identifier",
    // because the single-pass parser only recognized compound-init for types
    // already in the symbol table. A token pre-scan now records forward type
    // names. Covers both a plain compound and a generic one.
    const input =
        "imp std.c.io;\n" ++
        "fun main() num {\n" ++
        "  Point p = Point{x = 3, y = 4};\n" ++
        "  let b = Box<num>{value = 7};\n" ++
        "  printf(\"%lld %lld %lld\\n\", p.x, p.y, b.value);\n" ++
        "  ret 0;\n" ++
        "}\n" ++
        "compound Point { num x; num y; }\n" ++
        "compound Box<T> { T value; }\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("3 4 7\n", stdout);
}

test "compound-initializer with a genuinely unknown type is still rejected" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_unknown_struct_init.fn";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};

    // False-negative guard: the forward pre-scan must NOT accept a type that is
    // never declared anywhere — this must still be an error.
    const input =
        "imp std.c.io;\n" ++
        "fun main() num {\n" ++
        "  let z = Nonexistent{q = 1};\n" ++
        "  ret 0;\n" ++
        "}\n";

    try runTranspileExpectFailure(allocator, ifilepath, input);
}

test "compound-assignment operators %= &= |= ^= compute correctly" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_compound_assign_ops.fn";
    const c_path = "codegen_compound_assign_ops.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_compound_assign_ops.exe" else "codegen_compound_assign_ops";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: utils.op_valid() omitted %= &= |= ^=, so the lexer flushed them
    // back to a bare %/&/|/^ and the parser saw a binary op with no RHS.
    const input =
        "imp std.c.io;\n" ++
        "fun main() num {\n" ++
        "  num a = 100; a %= 7;\n" ++
        "  num b = 100; b &= 7;\n" ++
        "  num c = 100; c |= 7;\n" ++
        "  num d = 100; d ^= 7;\n" ++
        "  printf(\"%lld %lld %lld %lld\\n\", a, b, c, d);\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("2 4 103 99\n", stdout);
}

test "escaped double-quote inside a string literal compiles and prints" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_escaped_quote.fn";
    const c_path = "codegen_escaped_quote.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_escaped_quote.exe" else "codegen_escaped_quote";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: the lexer's string escape handling was commented out, so an
    // escaped quote \" prematurely terminated the Fun string literal.
    const input =
        "imp std.c.io;\n" ++
        "fun main() num {\n" ++
        "  str s = \"she said \\\"hi\\\" ok\";\n" ++
        "  printf(\"%s\\n\", s);\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("she said \"hi\" ok\n", stdout);
}

test "single-letter quirk name emits impl method bodies (links)" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_single_letter_quirk.fn";
    const c_path = "codegen_single_letter_quirk.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_single_letter_quirk.exe" else "codegen_single_letter_quirk";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: a single-uppercase-letter quirk name (Q) was misread as an
    // unresolved generic placeholder, so the impl method body was never emitted
    // (link error). Also covers a single-letter generic compound (G<T>).
    const input =
        "imp std.c.io;\n" ++
        "quirk Q { getX() num; }\n" ++
        "compound Foo { num x; }\n" ++
        "impl Foo as Q { getX() num { ret self.x; } }\n" ++
        "compound G<T> { T x; }\n" ++
        "fun main() num {\n" ++
        "  Foo f = Foo{x = 5};\n" ++
        "  Q q = &f;\n" ++
        "  G<num> g; g.x = 9;\n" ++
        "  printf(\"%lld %lld\\n\", q.getX(), g.x);\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("5 9\n", stdout);
}

test "stacked unary operator does not crash the parser" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_stacked_unary.fn";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};

    // Regression: two `~~a` statements panicked the parser (null unwrap in
    // parse_for_normal_unary). The compiler must never panic — at worst a clean
    // diagnostic. We accept either success or a Fun-level error, but NOT a crash.
    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  num a = 5;\n" ++
        "  num b = ~~a;\n" ++
        "  num c = ~~a;\n" ++
        "  printf(\"%d %d\\n\", b, c);\n" ++
        "}\n";

    // runTranspile either returns output or a Fun error; the key property is that
    // it returns (does not panic/abort the test process).
    if (runTranspile(allocator, ifilepath, input)) |out| {
        allocator.free(out);
    } else |_| {
        // A clean parse error is acceptable.
    }
}

test "member-access multiplied by an identifier parses as multiplication" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_member_mul.fn";
    const c_path = "codegen_member_mul.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_member_mul.exe" else "codegen_member_mul";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: `s.id * x` (field access times a bare identifier) was misparsed
    // as a pointer declaration `id* x;` because, while parsing the `.`-RHS field
    // `id`, the decl lookahead matched the trailing `* x ;`. Covers plain, self,
    // and nested member access.
    const input =
        "imp std.c.io;\n" ++
        "compound O { num v; }\n" ++
        "compound W { O inner; }\n" ++
        "compound S { num id; }\n" ++
        "impl S { pub m(num x) num { ret self.id * x; } }\n" ++
        "fun nested(W o, num x) num { ret o.inner.v * x; }\n" ++
        "fun main() num {\n" ++
        "  S s; s.id = 3;\n" ++
        "  W w; w.inner.v = 5;\n" ++
        "  printf(\"%lld %lld\\n\", s.m(4), nested(w, 6));\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("12 30\n", stdout);
}

test "double pointer dereference emits two stars" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_double_deref.fn";
    const c_path = "codegen_double_deref.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_double_deref.exe" else "codegen_double_deref";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: `**pp` emitted a single `*pp` (the codegen wrote the unary op
    // once, ignoring indirection.depth). Covers write and read sides.
    const input =
        "imp std.c.io;\n" ++
        "fun set_via(num** pp, num val) { **pp = val; }\n" ++
        "fun main() num {\n" ++
        "  num x = 5;\n" ++
        "  num* p = &x;\n" ++
        "  num** pp = &p;\n" ++
        "  set_via(pp, 42);\n" ++
        "  num v = **pp;\n" ++
        "  printf(\"%lld %lld\\n\", x, v);\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42 42\n", stdout);
}

test "field access on element of array-of-pointers emits arrow" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_arr_ptr_arrow.fn";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};

    // Regression: `arr[0].id` where `arr: Item*[]` emitted C `.` instead of `->`.
    // The generated C must use `arr[0]->id`. (We only need the field-access
    // codegen here, so assert on the emitted C — the array-literal call path has
    // a separate, unrelated limitation.)
    const input =
        "imp std.c.io;\n" ++
        "compound Item { num id; }\n" ++
        "fun first_id(Item*[] arr) num { ret arr[0].id; }\n" ++
        "fun main() { _ = first_id; printf(\"ok\\n\"); }\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "arr[0]->id") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "arr[0].id") == null);
}

test "fit on a string value lowers to strcmp chain and dispatches correctly" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_fit_str.fn";
    const c_path = "codegen_fit_str.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_fit_str.exe" else "codegen_fit_str";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: `fit` on a str condition emitted invalid C `switch(char*)`.
    // It now lowers to an if/else-if strcmp chain.
    const input =
        "imp std.c.io;\n" ++
        "fun classify(str s) {\n" ++
        "  fit s {\n" ++
        "    \"go\" -> { printf(\"going\\n\"); },\n" ++
        "    \"stop\" -> { printf(\"stopped\\n\"); },\n" ++
        "    _ -> { printf(\"idle\\n\"); }\n" ++
        "  }\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  classify(\"go\");\n" ++
        "  classify(\"stop\");\n" ++
        "  classify(\"wait\");\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    // Must NOT emit a switch on the string condition.
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "strcmp") != null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("going\nstopped\nidle\n", stdout);
}

test "local array of compound stays in function body (not hoisted to file scope)" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_local_compound_array.fn";
    const c_path = "codegen_local_compound_array.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_local_compound_array.exe" else "codegen_local_compound_array";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: a local `P[]` declaration (user-defined element type) was not
    // recognized by the statement-level decl detector (it only skipped `*`, not
    // `[]`), so it fell to the expression path and was emitted at file scope —
    // dragging the following statements out of the function and breaking codegen.
    const input =
        "imp std.c.io;\n" ++
        "compound P { num x; }\n" ++
        "fun main() num {\n" ++
        "  P[] pts = [P{x = 1}, P{x = 2}, P{x = 3}];\n" ++
        "  num sum = 0;\n" ++
        "  for p : pts { sum = sum + p.x; }\n" ++
        "  printf(\"sum=%lld\\n\", sum);\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("sum=6\n", stdout);
}

test "local T[] initialized from a pointer emits a C pointer, not an array" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_array_from_ptr.fn";
    const c_path = "codegen_array_from_ptr.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_array_from_ptr.exe" else "codegen_array_from_ptr";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: `num[] a = <pointer>` emitted `int64_t a[] = ptr;` (illegal C).
    // It must emit `int64_t* a = ptr;`. This is the heap-as-array idiom (Vec/Array).
    const input =
        "imp std.c.io;\n" ++
        "imp std.c.mem;\n" ++
        "fun main() num {\n" ++
        "  raw* mem = malloc(24);\n" ++
        "  num[] a = mem;\n" ++
        "  a[0] = 42;\n" ++
        "  a[1] = 7;\n" ++
        "  printf(\"%lld\\n\", a[0] + a[1]);\n" ++
        "  free(mem);\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t* a = ") != null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("49\n", stdout);
}

test "compound initializer field after an address-of-valued field parses correctly" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_initfield_after_addr.fn";
    const c_path = "codegen_initfield_after_addr.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_initfield_after_addr.exe" else "codegen_initfield_after_addr";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: in `Car{motor = &e, wheels = 4}` the `&e` value parse ignored
    // the enclosing `stop_at_comma`, consuming `, wheels` and rejecting `wheels`
    // as an unknown identifier. The unary operand + trailing-expression parse now
    // honor stop_at_comma.
    const input =
        "imp std.c.io;\n" ++
        "compound Engine { num power; }\n" ++
        "compound Car { Engine* motor; num wheels; }\n" ++
        "fun main() num {\n" ++
        "  Engine e; e.power = 50;\n" ++
        "  Car c = Car{motor = &e, wheels = 4};\n" ++
        "  printf(\"%lld %lld\\n\", c.motor.power, c.wheels);\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("50 4\n", stdout);
}

test "generic compound coerces to a quirk (mangled coercion helper name)" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_generic_quirk_coerce.fn";
    const c_path = "codegen_generic_quirk_coerce.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_generic_quirk_coerce.exe" else "codegen_generic_quirk_coerce";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: coercing a generic compound instance to a quirk emitted a call
    // to `__fun_coerce_Box_<hash>` (base name) while the helper was DEFINED as
    // `__fun_coerce_Box__num_<hash>` (mangled). Covers var-init, assignment, and
    // compound-field positions.
    const input =
        "imp std.c.io;\n" ++
        "quirk Lenable { size() num; }\n" ++
        "compound Box<T> { T v; num count; }\n" ++
        "impl Box<T> as Lenable { size() num { ret self.count; } }\n" ++
        "compound Holder { Lenable item; }\n" ++
        "fun main() num {\n" ++
        "  Box<num> bn = Box<num>{v = 9, count = 3};\n" ++
        "  Lenable la = &bn;\n" ++
        "  Lenable lb;\n" ++
        "  lb = &bn;\n" ++
        "  Holder h = Holder{item = &bn};\n" ++
        "  printf(\"%lld %lld %lld\\n\", la.size(), lb.size(), h.item.size());\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("3 3 3\n", stdout);
}

test "sizeof works with generic types, generic instances, and locals" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_sizeof_generics.fn";
    const c_path = "codegen_sizeof_generics.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_sizeof_generics.exe" else "codegen_sizeof_generics";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: `sizeof(Box<num>)` failed to parse (the `<` was read as a
    // comparison), and `sizeof(localVar)` reported "sizeof unknown type". Now
    // sizeof accepts a generic type operand and a value operand (mangling generic
    // instances to their concrete C struct, e.g. Box__num).
    const input =
        "imp std.c.io;\n" ++
        "compound Box<T> { T v; }\n" ++ // 8 bytes for num
        "compound Pair<A, B> { A a; B b; }\n" ++ // 16 bytes for <num,num>
        "fun main() num {\n" ++
        "  Box<num> b;\n" ++
        "  num a = sizeof(Box<num>);\n" ++ // 8
        "  num c = sizeof(b);\n" ++ // 8 (local generic instance)
        "  num d = sizeof(Pair<num, num>);\n" ++ // 16
        "  num e = sizeof(Box<Box<num>>);\n" ++ // 8 (nested)
        "  printf(\"%lld %lld %lld %lld\\n\", a, c, d, e);\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("8 8 16 8\n", stdout);
}

test "sizeof on an undeclared type is still rejected" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_sizeof_unknown.fn";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    const input =
        "imp std.c.io;\n" ++
        "fun main() num { num x = sizeof(Nope); ret 0; }\n";
    try runTranspileExpectFailure(allocator, ifilepath, input);
}

test "P5: constant division by zero is rejected at compile time" {
    const allocator = std.testing.allocator;
    // A literal `/ 0` divisor previously passed straight through to C, where it
    // is undefined behavior (garbage / SIGFPE at runtime). It must now be a clean
    // compile error.
    {
        const ifilepath = "codegen_div_zero_lit.fn";
        defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
        try runTranspileExpectFailure(allocator, ifilepath, "imp std.c.io;\nfun main() num { num c = 10 / 0; ret 0; }\n");
    }
    // The same for the modulo operator (`% 0`).
    {
        const ifilepath = "codegen_mod_zero_lit.fn";
        defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
        try runTranspileExpectFailure(allocator, ifilepath, "imp std.c.io;\nfun main() num { num c = 7 % 0; ret 0; }\n");
    }
    // A divisor that constant-folds to zero (`(2 - 2)`) is rejected too.
    {
        const ifilepath = "codegen_div_zero_folded.fn";
        defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
        try runTranspileExpectFailure(allocator, ifilepath, "imp std.c.io;\nfun main() num { num c = 8 / (2 - 2); ret 0; }\n");
    }
}

test "P5: non-zero and runtime divisors still compile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_div_ok.fn";
    const c_path = "codegen_div_ok.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_div_ok.exe" else "codegen_div_ok";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // A non-zero constant divisor and a runtime (variable) divisor must both
    // still compile and run — only a *constant-zero* divisor is rejected.
    const input =
        "imp std.c.io;\n" ++
        "fun main() num {\n" ++
        "  num x = 2;\n" ++
        "  num a = 10 / 2;\n" ++
        "  num b = 9 % x;\n" ++
        "  printf(\"%lld %lld\\n\", a, b);\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("5 1\n", stdout);
}

test "P4: multi-dimensional array indexing (2D/3D) type-checks and runs" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_multidim_index.fn";
    const c_path = "codegen_multidim_index.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_multidim_index.exe" else "codegen_multidim_index";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: a 2D/3D array could be *declared* (`int64_t m[2][3]`), but the
    // index typecheck dropped the array depth after one `[]`, so `m[i][j]` was
    // wrongly rejected with "indexing requires an array". The result of indexing
    // an N-deep array is now an (N-1)-deep array, so chained subscripts work and a
    // 2D fixed-size initializer (`[[..],[..]]`) round-trips.
    const input =
        "imp std.c.io;\n" ++
        "fun main() num {\n" ++
        "  num[2][3] m;\n" ++
        "  m[0][0] = 5;\n" ++
        "  m[1][2] = 9;\n" ++
        "  num[2][2] init = [[1, 2], [3, 4]];\n" ++
        "  num[2][2][2] t;\n" ++
        "  t[1][1][1] = 7;\n" ++
        "  printf(\"%lld %lld %lld %lld %lld\\n\", m[0][0], m[1][2], init[0][1], init[1][0], t[1][1][1]);\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    // The declaration must be a real C 2D array, not a flattened pointer.
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "m[2][3]") != null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("5 9 2 3 7\n", stdout);
}

test "P4: partial index of a 2D array yields an array, not a num" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_multidim_partial.fn";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    // Soundness guard for the multi-dim fix: a single index of `num[2][3]` is a
    // `num[3]` (an array), so assigning it to a `num` must still be rejected.
    try runTranspileExpectFailure(
        allocator,
        ifilepath,
        "imp std.c.io;\nfun main() num { num[2][3] m; num x = m[0]; ret 0; }\n",
    );
}

test "P3: float literals (scientific, leading-dot, trailing-dot) and the range operator coexist" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_float_literals.fn";
    const c_path = "codegen_float_literals.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_float_literals.exe" else "codegen_float_literals";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Scientific notation (1e1, 1.5e-1, 2E+1), leading-dot (.5) and trailing-dot
    // (3.) decimal literals all lex as f64. CRITICAL regression guard: the
    // trailing-dot path must NOT swallow the first '.' of the range operator
    // `0..3` (it once turned `0.` into `0.0`, breaking every literal `for i:0..N`).
    const input =
        "imp std.c.io;\n" ++
        "fun main() num {\n" ++
        "  dec a = 1e1;\n" ++
        "  dec b = 1.5e-1;\n" ++
        "  dec c = 2E+1;\n" ++
        "  dec d = .5;\n" ++
        "  dec e = 3.;\n" ++
        "  num sum = 0;\n" ++
        "  for i : 0..3 { sum = sum + i; }\n" ++
        "  printf(\"%.1f %.2f %.1f %.1f %.1f %lld\\n\", a, b, c, d, e, sum);\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    // 0..3 sums 0+1+2 = 3 (proving the range operator survived the float lexer).
    try std.testing.expectEqualStrings("10.0 0.15 20.0 0.5 3.0 3\n", stdout);
}

test "P3: comparison operators do not maximal-munch a following minus" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_munch.fn";
    const c_path = "codegen_munch.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_munch.exe" else "codegen_munch";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // `a >=-1` once lexed `>=-` as one (invalid) operator and kept only `>`, losing
    // the negative RHS. The lexer now keeps the longest VALID operator prefix, so
    // `>=` / `<=` / `==` / `!=` never absorb a trailing `-`. The compound-assign
    // ops (`>>=`, `<<=`, `+=`) must remain intact (regression guards).
    const input =
        "imp std.c.io;\n" ++
        "fun main() num {\n" ++
        "  num a = 5;\n" ++
        "  bin ge = a >=-1;\n" ++ // 5 >= -1 -> true
        "  bin le = a <=-1;\n" ++ // 5 <= -1 -> false
        "  bin eq = a ==-5;\n" ++ // 5 == -5 -> false
        "  bin ne = a !=-5;\n" ++ // 5 != -5 -> true
        "  num sh = 4; sh >>= 1;\n" ++ // 2
        "  printf(\"%d %d %d %d %lld\\n\", ge, le, eq, ne, sh);\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("1 0 0 1 2\n", stdout);
}

test "P3: enum variants accept explicit negative values" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_neg_enum.fn";
    const c_path = "codegen_neg_enum.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_neg_enum.exe" else "codegen_neg_enum";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // `enum E { A = -1 }` once failed to parse (the lexer munched `=-`). It now
    // parses and emits valid C (`E_A = -1`). We read the value through a `num`
    // binding (the sound idiom: enums are int-width in C, so passing one straight
    // to a `%lld` vararg would mis-read its width — assigning to num sign-extends).
    const input =
        "imp std.c.io;\n" ++
        "enum E { A = -1, B = 0, C = 5 }\n" ++
        "fun main() num {\n" ++
        "  E a = E.A;\n" ++
        "  E c = E.C;\n" ++
        "  num na = a;\n" ++
        "  num nc = c;\n" ++
        "  printf(\"%lld %lld %lld\\n\", na, nc, na + 10);\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "E_A = -1") != null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("-1 5 9\n", stdout);
}

test "P3: uninstantiated generic compound does not trip false cyclic-dependency" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_uninst_generic.fn";
    const c_path = "codegen_uninst_generic.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_uninst_generic.exe" else "codegen_uninst_generic";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // A generic compound that is DECLARED but never instantiated used to drain to
    // an empty work-list yet still trip the `!progress` guard -> false "cyclic
    // by-value compound dependency". Removing a generic template now counts as
    // progress. Here `Box<T>` and the self-referential-via-pointer `Node<T>` are
    // both unused; only `Node<num>` is instantiated.
    const input =
        "imp std.c.io;\n" ++
        "pub compound Box<T> { T v; }\n" ++
        "pub compound Node<T> { T val; Node<T>* next; }\n" ++
        "fun main() num {\n" ++
        "  Node<num> a = Node<num>{val = 7, next = NULL};\n" ++
        "  printf(\"%lld\\n\", a.val);\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("7\n", stdout);
}

test "P3: a genuine by-value compound cycle is still rejected" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_real_cycle.fn";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    // Soundness guard for the false-cyclic fix: a real non-generic by-value cycle
    // (A holds B by value, B holds A by value) must STILL be a clean error.
    try runTranspileExpectFailure(
        allocator,
        ifilepath,
        "imp std.c.io;\ncompound A { B b; }\ncompound B { A a; }\nfun main() num { ret 0; }\n",
    );
}

test "private field (leading underscore): same-module read/write/self access works" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_priv_field.fn";
    const c_path = "codegen_priv_field.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_priv_field.exe" else "codegen_priv_field";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // A field named with a leading `_` is module-private. Within the SAME module
    // (this file), it is freely readable/writable and reachable via `self._x` in a
    // method body. The name emits verbatim into the C struct (`_password`).
    const input =
        "imp std.c.io;\n" ++
        "compound User { num id; num _password; }\n" ++
        "impl User {\n" ++
        "  pub set_pw(num p) { self._password = p; }\n" ++
        "  pub check(num p) bin { ret self._password == p; }\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  User u = User{id = 1, _password = 42};\n" ++
        "  num a = u._password;\n" ++
        "  u._password = 99;\n" ++
        "  u.set_pw(7);\n" ++
        "  printf(\"%lld %lld %d\\n\", a, u._password, u.check(7));\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "_password") != null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42 7 1\n", stdout);
}

test "data-carrying enum: construct + pattern-match with payload bindings" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_data_enum.fn";
    const c_path = "codegen_data_enum.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_data_enum.exe" else "codegen_data_enum";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // A variant with a payload makes the enum a tagged union, emitted as
    // `struct { Enum_tag tag; union { ... } payload; }`. Construction is a compound
    // literal; `fit` switches on `.tag` and binds the matched payload into locals.
    // A payload-free variant in a tagged union still constructs the struct.
    const input =
        "imp std.c.io;\n" ++
        "enum Val { I(num), Pair(num, num), Nil }\n" ++
        "fun sum(Val v) num {\n" ++
        "  fit v {\n" ++
        "    Val.I(x) -> { ret x; }\n" ++
        "    Val.Pair(a, b) -> { ret a + b; }\n" ++
        "    Val.Nil -> { ret 0; }\n" ++
        "  }\n" ++
        "  ret -1;\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  Val a = Val.I(7);\n" ++
        "  Val b = Val.Pair(3, 4);\n" ++
        "  Val c = Val.Nil;\n" ++
        "  printf(\"%lld %lld %lld\\n\", sum(a), sum(b), sum(c));\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    // Tagged-union shape: discriminant enum + payload union.
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Val_tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, ".payload.") != null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("7 7 0\n", stdout);
}

test "data-carrying enum: shorthand .Variant(x) and _ catch-all" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_data_enum_short.fn";
    const c_path = "codegen_data_enum_short.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_data_enum_short.exe" else "codegen_data_enum_short";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "enum Opt { Some(num), None }\n" ++
        "fun get(Opt o) num {\n" ++
        "  fit o {\n" ++
        "    Opt.Some(v) -> { ret v; }\n" ++
        "    _ -> { ret -9; }\n" ++
        "  }\n" ++
        "  ret 0;\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  printf(\"%lld %lld\\n\", get(Opt.Some(5)), get(Opt.None));\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("5 -9\n", stdout);
}

test "data-carrying enum: shorthand construction in typed var-init and return" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_data_enum_shorthand.fn";
    const c_path = "codegen_data_enum_shorthand.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_data_enum_shorthand.exe" else "codegen_data_enum_shorthand";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // `.Variant(args)` shorthand construction resolves the enum from the expected
    // type: a typed var-init's declared type, and a function's return type.
    const input =
        "imp std.c.io;\n" ++
        "enum Opt { Some(num), None }\n" ++
        "fun mk(num x) Opt { ret .Some(x); }\n" ++ // shorthand in return position
        "fun get(Opt o) num {\n" ++
        "  fit o {\n" ++
        "    Opt.Some(v) -> { ret v; }\n" ++
        "    Opt.None -> { ret -1; }\n" ++
        "  }\n" ++
        "  ret 0;\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  Opt a = .Some(9);\n" ++ // shorthand in typed var-init
        "  Opt b = .None;\n" ++ // payload-free shorthand still works
        "  printf(\"%lld %lld %lld\\n\", get(a), get(b), get(mk(42)));\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("9 -1 42\n", stdout);
}

test "plain (payload-free) enum still lowers to a C enum, unaffected by tagged unions" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_plain_enum_still.fn";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    const input =
        "imp std.c.io;\n" ++
        "enum Color { Red, Green, Blue }\n" ++
        "fun main() num { Color c = Color.Green; ret 0; }\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    // No payload anywhere -> classic C enum, NOT a tagged union (no _tag struct).
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "typedef enum Color {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Color_tag") == null);
}

test "direct call-site quirk coercion: callee(&concrete) wraps in __fun_coerce" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_callsite_quirk_coerce.fn";
    const c_path = "codegen_callsite_quirk_coerce.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_callsite_quirk_coerce.exe" else "codegen_callsite_quirk_coerce";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: passing a concrete pointer directly to a quirk-typed parameter
    // (`describe(7, &d, "hi")`) emitted a raw `Dog*` where a `Speaker` fat-pointer
    // was expected (a C type error). Now the concrete-pointer arg is wrapped in the
    // `__fun_coerce_<Type>_<hash>` helper, while sibling non-quirk args (`num`,
    // `str`) and an entirely non-quirk call (`plain`) pass through untouched.
    const input =
        "imp std.c.io;\n" ++
        "quirk Speaker { speak() str; }\n" ++
        "compound Dog { num age; }\n" ++
        "impl Dog as Speaker { speak() str { ret \"woof\"; } }\n" ++
        "fun describe(num n, Speaker s, str tag) {\n" ++
        "  printf(\"%lld %s %s\\n\", n, s.speak(), tag);\n" ++
        "}\n" ++
        "fun plain(num a, num b) num { ret a + b; }\n" ++
        "fun main() num {\n" ++
        "  Dog d = Dog{age = 3};\n" ++
        "  describe(7, &d, \"hi\");\n" ++
        "  printf(\"%lld\\n\", plain(2, 3));\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    // The quirk arg is wrapped; the non-quirk call is left as a bare call.
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "__fun_coerce_Dog_") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "plain(2, 3)") != null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("7 woof hi\n5\n", stdout);
}

test "generic compound coerces to a quirk at a call site and via var-init" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_generic_callsite_quirk.fn";
    const c_path = "codegen_generic_callsite_quirk.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_generic_callsite_quirk.exe" else "codegen_generic_callsite_quirk";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: a generic-compound instance (`Box<num>`) coerced to a quirk both
    // through a direct call argument (`report(&b)`) and a var-init (`Sized sz=&b`)
    // failed type-checking ("type mismatch"), and even when forced, codegen emitted
    // the base-name helper `__fun_coerce_Box_...` instead of the mangled
    // `__fun_coerce_Box__num_...` that is actually DEFINED. Now both compile and run.
    const input =
        "imp std.c.io;\n" ++
        "quirk Sized { size() num; }\n" ++
        "compound Box<T> { T v; }\n" ++
        "impl Box<num> as Sized { size() num { ret 8; } }\n" ++
        "fun report(Sized s) num { ret s.size(); }\n" ++
        "fun main() num {\n" ++
        "  Box<num> b = Box<num>{v = 42};\n" ++
        "  num viaCall = report(&b);\n" ++
        "  Sized sz = &b;\n" ++
        "  num viaVar = sz.size();\n" ++
        "  printf(\"%lld %lld\\n\", viaCall, viaVar);\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    // Both coercions must use the MANGLED helper name (Box__num), matching the def.
    // (If the base-name `__fun_coerce_Box_<hash>` were emitted instead, the call
    // would reference an undeclared function and the C below would fail to compile.)
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "__fun_coerce_Box__num_") != null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("8 8\n", stdout);
}

test "quirk method dispatched on a call result materializes the receiver once" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_quirk_on_call_result.fn";
    const c_path = "codegen_quirk_on_call_result.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_quirk_on_call_result.exe" else "codegen_quirk_on_call_result";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: calling a quirk method directly on a function-call result
    // (`make(&st).weight()`) emitted a raw C `.member` access on the quirk
    // fat-pointer (no `weight` member -> C error), instead of vtable dispatch.
    // The receiver is an rvalue, so it must be materialized into a temp exactly
    // once (emitting it twice would call `make` twice). Lowers to a statement
    // expression `({ Q __t = make(&st); __t.vtable->weight(__t.self); })`.
    const input =
        "imp std.c.io;\n" ++
        "quirk Weighable { weight() num; }\n" ++
        "compound Stone { num kg; }\n" ++
        "impl Stone as Weighable { weight() num { ret self.kg; } }\n" ++
        "fun make(Stone* s) Weighable { ret s; }\n" ++
        "fun main() num {\n" ++
        "  Stone st = Stone{kg = 5};\n" ++
        "  Weighable d = make(&st);\n" ++
        "  printf(\"%lld\\n\", d.weight());\n" ++ // var-form (vtable dispatch)
        "  printf(\"%lld\\n\", make(&st).weight());\n" ++ // call-result (materialized)
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    // The call-result form must dispatch through the vtable (statement-expr temp),
    // never a bare `.weight()` member access on the quirk struct.
    try std.testing.expect(std.mem.indexOf(u8, out_owned, ".vtable->weight(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "make((&st)).weight()") == null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("5\n5\n", stdout);
}

// ===== P0 hardening regression tests (from the production-readiness audit) =====

test "P0: fixed-size array compound field is inline, not a pointer" {
    const allocator = std.testing.allocator;
    const ifilepath = "p0_fixed_array_field.fn";
    const c_path = "p0_fixed_array_field.c";
    const exe_path = if (builtin.os.tag == .windows) "p0_fixed_array_field.exe" else "p0_fixed_array_field";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: `num[3] data;` as a compound field was emitted as a bare pointer
    // (`int64_t* data;`), giving the wrong layout (sizeof 8 not 24) and leaving the
    // field uninitialized/dangling. It must be an inline C array `int64_t data[3];`.
    const input =
        "imp std.c.io;\n" ++
        "compound Buf { num[3] data; num tag; }\n" ++
        "fun main() num {\n" ++
        "  Buf b;\n" ++
        "  b.data[0] = 10; b.data[1] = 20; b.data[2] = 30; b.tag = 99;\n" ++
        "  printf(\"%lld %lld %lld %lld %lld\\n\", b.data[0], b.data[1], b.data[2], b.tag, sizeof(Buf));\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t data[3]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t* data") == null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("10 20 30 99 32\n", stdout);
}

test "P0: unsized array compound field stays a pointer" {
    const allocator = std.testing.allocator;
    const ifilepath = "p0_unsized_array_field.fn";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    // The fixed-array fix must NOT change unsized `num[] data;` fields, which have
    // no concrete extent and remain pointers.
    const input =
        "compound Dyn { num[] data; num n; }\n" ++
        "fun main() num { ret 0; }\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t* data") != null);
}

test "P0: cross-enum equality is rejected, same-enum and enum-vs-num still allowed" {
    const allocator = std.testing.allocator;
    // Distinct enums must NOT be comparable by ordinal.
    try runTranspileExpectFailure(allocator, "p0_cross_enum_eq.fn", "enum A { X }\nenum B { P }\nfun main() { A a = .X; B b = .P; if a == b {} }\n");
    // Same enum compares fine.
    {
        const ok = try runTranspile(allocator, "p0_same_enum_eq.fn", "enum A { X, Y }\nfun main() { A a = .X; A a2 = .Y; if a == a2 {} }\n");
        allocator.free(ok);
        std.Io.Dir.cwd().deleteFile(std.testing.io, "p0_same_enum_eq.fn") catch {};
    }
    // Enum vs numeric literal still compares fine.
    {
        const ok = try runTranspile(allocator, "p0_enum_num_eq.fn", "enum A { X, Y }\nfun main() { A a = .Y; if a == 1 {} }\n");
        allocator.free(ok);
        std.Io.Dir.cwd().deleteFile(std.testing.io, "p0_enum_num_eq.fn") catch {};
    }
}

test "P0: fit with a different enum's variant as a branch is rejected" {
    const allocator = std.testing.allocator;
    try runTranspileExpectFailure(allocator, "p0_cross_enum_fit.fn", "enum A { X, Y }\nenum B { P, Q }\n" ++
        "fun main() { A a = .X; fit a { B.P -> {}, _ -> {} } }\n");
}

test "P0: char escape \\r decodes to 13, unknown escape is rejected" {
    const allocator = std.testing.allocator;
    const ifilepath = "p0_char_escape.fn";
    const c_path = "p0_char_escape.c";
    const exe_path = if (builtin.os.tag == .windows) "p0_char_escape.exe" else "p0_char_escape";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    // '\r' was silently decoded to NUL; it must be 13. Also '\t'=9, '\0'=0.
    const input =
        "imp std.c.io;\n" ++
        "fun main() num { printf(\"%d %d %d\\n\", '\\r', '\\t', '\\0'); ret 0; }\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("13 9 0\n", stdout);

    // An unrecognized escape in a char literal is a clean error, not silent NUL.
    try runTranspileExpectFailure(allocator, "p0_bad_escape.fn", "fun main() { chr q = '\\q'; }\n");
}

test "P0: block comment is lexed; unterminated /* and stray top-level token error cleanly" {
    const allocator = std.testing.allocator;
    const ifilepath = "p0_block_comment.fn";
    const c_path = "p0_block_comment.c";
    const exe_path = if (builtin.os.tag == .windows) "p0_block_comment.exe" else "p0_block_comment";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    // A `/* ... */` block comment (top-level and multi-line) is now supported and
    // skipped, where it previously triggered a compiler panic.
    const input =
        "/* a top-level block comment */\n" ++
        "imp std.c.io;\n" ++
        "fun main() num {\n" ++
        "  /* multi\n     line */\n" ++
        "  printf(\"ok\\n\");\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("ok\n", stdout);

    // Unterminated block comment -> clean error (no panic).
    try runTranspileExpectFailure(allocator, "p0_unterminated_bc.fn", "/* never closed\n");
    // Stray top-level operator -> clean error (was `else => unreachable` panic).
    try runTranspileExpectFailure(allocator, "p0_stray_op.fn", "* 5\nfun main() {}\n");
}

/// Payload + entry point for running the deep-expression transpile on a
/// dedicated large-stack thread, mirroring how the real CLI runs the compile
/// pipeline (cmd/fun/main.zig spawns it with `pipeline_stack_size`). The
/// recursive-descent parser/typechecker needs the big stack to reach its
/// depth guard and report ExpressionTooDeep instead of overflowing the test
/// runner's small default thread stack.
const DeepExprCtx = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    result: anyerror!void = {},
};

fn runDeepExprOnThread(ctx: *DeepExprCtx) void {
    ctx.result = runTranspileExpectFailure(ctx.allocator, "p0_deep_expr.fn", ctx.input);
}

test "P0: pathologically deep expression errors cleanly instead of crashing" {
    const allocator = std.testing.allocator;
    // A nesting depth past the parser guard must yield ExpressionTooDeep, not a
    // stack-overflow segfault. 1200 > the 600 guard limit.
    const depth: usize = 1200;
    var src = ArrayList(u8).init(allocator);
    defer src.deinit();
    try src.appendSlice("fun main() num { num x = ");
    var i: usize = 0;
    while (i < depth) : (i += 1) try src.append('(');
    try src.append('1');
    i = 0;
    while (i < depth) : (i += 1) try src.append(')');
    try src.appendSlice("; ret x; }\n");

    // Run on a large dedicated stack, exactly as the CLI does — the test runner's
    // default thread stack is too small to hold the guard-depth recursion.
    var ctx = DeepExprCtx{ .allocator = allocator, .input = src.items };
    const thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 * 1024 }, runDeepExprOnThread, .{&ctx});
    thread.join();
    try ctx.result;
}

test "P0: typed format decodes escapes and treats unknown {foo} as literal" {
    const allocator = std.testing.allocator;
    const ifilepath = "p0_format_escapes.fn";
    const c_path = "p0_format_escapes.c";
    const exe_path = if (builtin.os.tag == .windows) "p0_format_escapes.exe" else "p0_format_escapes";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Two miscompiles: (1) typed println_fmt rendered escape sequences literally
    // (`\t` stayed backslash+t); (2) `{foo}` (not a type-name placeholder) was
    // eaten by the runtime format path but kept by the compile-time path. After
    // the fix `\t` is a real TAB and `{foo}` is literal text in both paths.
    const input =
        "imp std.io;\n" ++
        "fun main() {\n" ++
        "  println_fmt(\"a\\tb={num}\", 1);\n" ++
        "  println_fmt(\"lit {foo} end {num}\", 2);\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    // Line 1: 'a' + real TAB + "b=1". Line 2: "lit {foo} end 2".
    try std.testing.expectEqualStrings("a\tb=1\nlit {foo} end 2\n", stdout);
}

// ===== P1 invalid-c / soundness regression tests (production-readiness audit) =====

test "P1: plain-impl method chaining on call results materializes once" {
    const allocator = std.testing.allocator;
    const ifilepath = "p1_method_chain.fn";
    const c_path = "p1_method_chain.c";
    const exe_path = if (builtin.os.tag == .windows) "p1_method_chain.exe" else "p1_method_chain";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    // Regression: `b.add(2).get()` / `a.add(5).add(10)` emitted raw C member access
    // on a call result. Now the rvalue receiver is materialized into a temp.
    const input =
        "imp std.c.io;\n" ++
        "compound C { num v; }\n" ++
        "impl C { add(num n) C { C r; r.v = self.v + n; ret r; } get() num { ret self.v; } }\n" ++
        "fun mk(num n) C { C c; c.v = n; ret c; }\n" ++
        "fun main() num {\n" ++
        "  C c; c.v = 1;\n" ++
        "  printf(\"%lld %lld\\n\", c.add(2).add(3).get(), mk(7).get());\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("6 7\n", stdout);
}

test "P1: quirk coercion from &arr[i] and &struct.field, plus quirk array element dispatch" {
    const allocator = std.testing.allocator;
    const ifilepath = "p1_quirk_coerce.fn";
    const c_path = "p1_quirk_coerce.c";
    const exe_path = if (builtin.os.tag == .windows) "p1_quirk_coerce.exe" else "p1_quirk_coerce";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    const input =
        "imp std.c.io;\n" ++
        "compound Item { num v; }\n" ++
        "compound Outer { Item it; }\n" ++
        "quirk Valued { value() num; }\n" ++
        "impl Item as Valued { value() num { ret self.v; } }\n" ++
        "fun main() num {\n" ++
        "  Item a; a.v = 10;\n" ++
        "  Item[] items = [a];\n" ++
        "  Valued q = &items[0];\n" ++ // &arr[i]
        "  Outer o; o.it.v = 20;\n" ++
        "  Valued g = &o.it;\n" ++ // &struct.field
        "  Valued[1] arr; arr[0] = &a;\n" ++ // quirk array elem assign
        "  printf(\"%lld %lld %lld\\n\", q.value(), g.value(), arr[0].value());\n" ++ // indexed dispatch
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("10 20 10\n", stdout);
}

test "P1: fit on dec, fit on str variable, comma multi-label, duplicate enum case" {
    const allocator = std.testing.allocator;
    const ifilepath = "p1_fit.fn";
    const c_path = "p1_fit.c";
    const exe_path = if (builtin.os.tag == .windows) "p1_fit.exe" else "p1_fit";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    const input =
        "imp std.c.io;\n" ++
        "enum Color { Red, Green, Blue }\n" ++
        "fun main() num {\n" ++
        "  dec d = 1.0;\n" ++
        "  fit d { 1.0 -> { printf(\"d1\\n\"); }, _ -> { printf(\"d?\\n\"); } }\n" ++ // fit on dec
        "  str s = \"b\"; str target = \"b\";\n" ++
        "  fit s { target -> { printf(\"smatch\\n\"); }, _ -> { printf(\"sno\\n\"); } }\n" ++ // fit on str var
        "  num x = 2;\n" ++
        "  fit x { 1, 2 -> { printf(\"lo\\n\"); }, _ -> { printf(\"hi\\n\"); } }\n" ++ // comma multi-label
        "  Color c = Color.Green;\n" ++
        "  fit c { Color.Green -> { printf(\"g1\\n\"); }, Color.Green -> { printf(\"g2\\n\"); }, _ -> {} }\n" ++ // duplicate case
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("d1\nsmatch\nlo\ng1\n", stdout);
}

test "P1: sizeof of primitive/pointer/compound/generic variables" {
    const allocator = std.testing.allocator;
    const ifilepath = "p1_sizeof_var.fn";
    const c_path = "p1_sizeof_var.c";
    const exe_path = if (builtin.os.tag == .windows) "p1_sizeof_var.exe" else "p1_sizeof_var";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    // Regression: sizeof(num) on a primitive variable emitted the raw Fun keyword.
    const input =
        "imp std.c.io;\n" ++
        "compound P { num x; num y; }\n" ++
        "fun main() num {\n" ++
        "  num n = 0; str s = \"\"; dec d = 0.0; bin b = true; num* p = &n; P pt;\n" ++
        "  printf(\"%lld %lld %lld %lld %lld %lld\\n\", sizeof(n), sizeof(s), sizeof(d), sizeof(b), sizeof(p), sizeof(pt));\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("8 8 8 1 8 16\n", stdout);
}

test "P1: pointer-as-array element field access uses dot, array-literal call arg, array fixes" {
    const allocator = std.testing.allocator;
    const ifilepath = "p1_ptr_array.fn";
    const c_path = "p1_ptr_array.c";
    const exe_path = if (builtin.os.tag == .windows) "p1_ptr_array.exe" else "p1_ptr_array";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    const input =
        "imp std.c.io;\n" ++
        "imp std.c.mem;\n" ++
        "compound Point { num x; num y; }\n" ++
        "fun sum2(num[] a) num { ret a[0] + a[1]; }\n" ++
        "fun main() num {\n" ++
        "  Point* pts = malloc(2 * sizeof(Point));\n" ++
        "  pts[0].x = 5; pts[1].x = 9;\n" ++ // pointer-as-array element field: must use .
        "  num s = sum2([10, 20]);\n" ++ // array literal as call arg: compound literal
        "  printf(\"%lld %lld %lld\\n\", pts[0].x, pts[1].x, s);\n" ++
        "  free(pts);\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "pts[0].x") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "(int64_t[]){10, 20}") != null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("5 9 30\n", stdout);
}

test "P1: let inference from dereferenced generic pointer yields the value type" {
    const allocator = std.testing.allocator;
    const ifilepath = "p1_deref_let.fn";
    const c_path = "p1_deref_let.c";
    const exe_path = if (builtin.os.tag == .windows) "p1_deref_let.exe" else "p1_deref_let";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    const input =
        "imp std.c.io;\n" ++
        "compound Box<T> { T v; }\n" ++
        "fun main() num {\n" ++
        "  Box<num> b; b.v = 7;\n" ++
        "  Box<num>* pb = &b;\n" ++
        "  let boxed = *pb;\n" ++
        "  printf(\"%lld\\n\", boxed.v);\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Box__num boxed") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Box__num* boxed") == null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("7\n", stdout);
}

test "P1: hex string escape is bounded to two digits" {
    const allocator = std.testing.allocator;
    const ifilepath = "p1_hex_escape.fn";
    const c_path = "p1_hex_escape.c";
    const exe_path = if (builtin.os.tag == .windows) "p1_hex_escape.exe" else "p1_hex_escape";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    // `"\x42C"` must be byte 0x42 ('B') then 'C', not one out-of-range escape.
    const input =
        "imp std.c.io;\n" ++
        "fun main() num { printf(\"%s\\n\", \"\\x42C\"); ret 0; }\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "\"\\x42\" \"C\"") != null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("BC\n", stdout);
}

test "P1: empty enum, let-from-void, and format arg-mismatch are rejected" {
    const allocator = std.testing.allocator;
    try runTranspileExpectFailure(allocator, "p1_empty_enum.fn", "enum Void {}\nfun main() {}\n");
    try runTranspileExpectFailure(allocator, "p1_let_void.fn", "fun doit() { ret; }\nfun main() { let x = doit(); }\n");
    try runTranspileExpectFailure(allocator, "p1_fmt_mismatch.fn", "imp std.io;\nfun main() { str r = format(\"{num} {num}\", 1); }\n");
}

// ===== Re-audit fixes (R1 + P1/P2/P3 after the post-fix re-audit) =====

test "reaudit R1: generic compound fixed-size array field is inline" {
    const allocator = std.testing.allocator;
    const ifilepath = "ra_r1_generic_array.fn";
    const c_path = "ra_r1_generic_array.c";
    const exe_path = if (builtin.os.tag == .windows) "ra_r1_generic_array.exe" else "ra_r1_generic_array";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    // Regression: a fixed-size array field in a GENERIC compound was demoted to a
    // pointer (the non-generic fix wasn't mirrored into the specialization path),
    // crashing at runtime with sizeof 8 instead of 32.
    const input =
        "imp std.c.io;\n" ++
        "compound Buf<T> { T[3] items; num n; }\n" ++
        "fun main() num {\n" ++
        "  Buf<num> b;\n" ++
        "  b.items[0] = 10; b.items[1] = 20; b.items[2] = 30; b.n = 3;\n" ++
        "  printf(\"%lld %llu\\n\", b.items[0] + b.items[1] + b.items[2], sizeof(Buf<num>));\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t items[3]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t* items") == null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("60 32\n", stdout);
}

test "reaudit: distinct generic instantiations are not interchangeable types" {
    const allocator = std.testing.allocator;
    // Box<num> must NOT be accepted where Box<str> is expected.
    try runTranspileExpectFailure(allocator, "ra_generic_typearg.fn", "compound Box<T> { T v; }\n" ++
        "fun take(Box<str> b) {}\n" ++
        "fun main() { Box<num> bn; take(bn); }\n");
}

test "reaudit: array-literal struct field init (single + multi element)" {
    const allocator = std.testing.allocator;
    const ifilepath = "ra_arr_field.fn";
    const c_path = "ra_arr_field.c";
    const exe_path = if (builtin.os.tag == .windows) "ra_arr_field.exe" else "ra_arr_field";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    // Single-element emitted invalid `(int64_t[]){7}`; multi-element failed to parse
    // (stop_at_comma leaked into the bracket). Both must be bare brace-lists now.
    const input =
        "imp std.c.io;\n" ++
        "compound Row { num[3] cols; }\n" ++
        "fun main() num {\n" ++
        "  Row a = Row{cols = [7]};\n" ++
        "  Row b = Row{cols = [1, 2, 3]};\n" ++
        "  printf(\"%lld %lld %lld %lld\\n\", a.cols[0], b.cols[0], b.cols[1], b.cols[2]);\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "(int64_t[]){") == null); // not a compound literal
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("7 1 2 3\n", stdout);
}

test "reaudit: sizeof accepts pointer types" {
    const allocator = std.testing.allocator;
    const ifilepath = "ra_sizeof_ptr.fn";
    const c_path = "ra_sizeof_ptr.c";
    const exe_path = if (builtin.os.tag == .windows) "ra_sizeof_ptr.exe" else "ra_sizeof_ptr";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    const input =
        "imp std.c.io;\n" ++
        "fun main() num { printf(\"%lld %lld %lld\\n\", sizeof(num*), sizeof(raw*), sizeof(num)); ret 0; }\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sizeof(int64_t*)") != null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("8 8 8\n", stdout);
}

test "reaudit: await binds tighter than a following binary operator" {
    const allocator = std.testing.allocator;
    const ifilepath = "ra_await_prec.fn";
    const c_path = "ra_await_prec.c";
    const exe_path = if (builtin.os.tag == .windows) "ra_await_prec.exe" else "ra_await_prec";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    // `await inc(5) + 1` must be `(await inc(5)) + 1` = 7, not `await (inc(5)+1)`.
    const input =
        "imp std.c.io;\n" ++
        "async fun inc(num x) num { ret x + 1; }\n" ++
        "async fun main() {\n" ++
        "  num r = await inc(5) + 1;\n" ++
        "  printf(\"%lld\\n\", r);\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("7\n", stdout);
}

test "reaudit R2: Map and Set compare string keys by value, num keys by bytes" {
    const allocator = std.testing.allocator;
    const ifilepath = "ra_r2_map_str.fn";
    const c_path = "ra_r2_map_str.c";
    const exe_path = if (builtin.os.tag == .windows) "ra_r2_map_str.exe" else "ra_r2_map_str";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    // Regression: Map<str>/Set<str> compared keys by POINTER (memcmp(&a,&b,sizeof)),
    // so a value-equal string at a different address was never found. The
    // __fun_key_eq/__fun_key_hash intrinsics now use strcmp/string-hash for str
    // keys and byte semantics for value keys.
    const input =
        "imp std.c.io;\n" ++
        "imp std.map;\n" ++
        "imp std.string;\n" ++
        "fun main() num {\n" ++
        "  Map<str, num> m;\n" ++
        "  m.init(16);\n" ++
        "  m.put(\"hello\", 1);\n" ++
        "  str other = substr(\"xhellox\", 1, 5);\n" ++ // value-equal "hello", different address
        "  Map<num, num> mn;\n" ++
        "  mn.init(16);\n" ++
        "  mn.put(42, 9); mn.put(42, 9);\n" ++ // num keys: same value -> one entry
        "  printf(\"%lld %lld %lld\\n\", m.get(other), mn.get(42), mn.len);\n" ++
        "  m.free();\n" ++
        "  mn.free();\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    // str key found by value (1), num key found (9), num map has a single entry (1).
    try std.testing.expectEqualStrings("1 9 1\n", stdout);
}

// ===== Re-audit round-2 fixes: quirk cluster + defer-ret + generic chaining =====

test "reaudit Q: ptr->quirk coercion on field assign and array-literal elements" {
    const allocator = std.testing.allocator;
    const ifilepath = "ra_q_coerce.fn";
    const c_path = "ra_q_coerce.c";
    const exe_path = if (builtin.os.tag == .windows) "ra_q_coerce.exe" else "ra_q_coerce";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    const input =
        "imp std.c.io;\n" ++
        "compound Engine { num hp; }\n" ++
        "quirk Powered { power() num; }\n" ++
        "impl Engine as Powered { power() num { ret self.hp; } }\n" ++
        "compound Car { Powered engine; }\n" ++
        "fun main() num {\n" ++
        "  Engine e; e.hp = 300;\n" ++
        "  Car car; car.engine = &e;\n" ++ // ptr->quirk struct-field assign
        "  Engine a; a.hp = 5;\n" ++
        "  Engine b; b.hp = 7;\n" ++
        "  Powered[] arr = [&a, &b];\n" ++ // ptr->quirk array-literal elements
        "  printf(\"%lld %lld\\n\", car.engine.power(), arr[0].power() + arr[1].power());\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("300 12\n", stdout);
}

test "reaudit Q: return coerced self + chaining on a quirk-returning quirk method" {
    const allocator = std.testing.allocator;
    const ifilepath = "ra_q_chain.fn";
    const c_path = "ra_q_chain.c";
    const exe_path = if (builtin.os.tag == .windows) "ra_q_chain.exe" else "ra_q_chain";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    // `to_b()` returns a quirk over A's OWN embedded B (`&self.b`), which stays
    // alive through `qa`'s self pointer — so the chained `.gv()` reads valid memory
    // (avoids the dangling-stack-pointer UB of returning `&local`). This exercises:
    // (1) returning coerced self (`self_q`), and (2) chaining a method on a
    // quirk-returning quirk method result (`qa.to_b().gv()`).
    const input =
        "imp std.c.io;\n" ++
        "compound B { num y; }\n" ++
        "compound A { num x; B b; }\n" ++
        "quirk QB { gv() num; }\n" ++
        "quirk QA { to_b() QB; self_q() QA; }\n" ++
        "impl B as QB { gv() num { ret self.y; } }\n" ++
        "impl A as QA {\n" ++
        "  to_b() QB { self.b.y = self.x + 1; ret &self.b; }\n" ++
        "  self_q() QA { ret self; }\n" ++ // returning coerced self
        "}\n" ++
        "fun main() num {\n" ++
        "  A a; a.x = 7;\n" ++
        "  QA qa = &a;\n" ++
        "  printf(\"%lld\\n\", qa.to_b().gv());\n" ++ // chain on quirk-method result
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("8\n", stdout);
}

test "reaudit: defer that mutates a returned variable does not corrupt the value" {
    const allocator = std.testing.allocator;
    const ifilepath = "ra_defer_ret.fn";
    const c_path = "ra_defer_ret.c";
    const exe_path = if (builtin.os.tag == .windows) "ra_defer_ret.exe" else "ra_defer_ret";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    // `defer x = 999; ret x + 1` must return 6 — the return value is snapshotted
    // before the defer runs.
    const input =
        "imp std.c.io;\n" ++
        "fun expr_ret() num {\n" ++
        "  num x = 5;\n" ++
        "  defer x = 999;\n" ++
        "  ret x + 1;\n" ++
        "}\n" ++
        "fun main() num { printf(\"%lld\\n\", expr_ret()); ret 0; }\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("6\n", stdout);
}

test "reaudit: method chaining on a generic function return is monomorphized" {
    const allocator = std.testing.allocator;
    const ifilepath = "ra_generic_chain.fn";
    const c_path = "ra_generic_chain.c";
    const exe_path = if (builtin.os.tag == .windows) "ra_generic_chain.exe" else "ra_generic_chain";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    // `some(7).unwrap_or(0)` must use the monomorphized `Option__num` type/method,
    // not the un-monomorphized base `Option`.
    const input =
        "imp std.c.io;\n" ++
        "imp std.option;\n" ++
        "fun main() num { printf(\"%lld\\n\", some(7).unwrap_or(0)); ret 0; }\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Option__num __fun_mrecv") != null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("7\n", stdout);
}

// ===== Round-3 re-audit fixes: crash, deep chains, coercion shapes, resolver gaps =====

test "ra3: no crash on field access of a generic-impl method returning a compound" {
    const allocator = std.testing.allocator;
    const ifilepath = "ra3_crash.fn";
    const c_path = "ra3_crash.c";
    const exe_path = if (builtin.os.tag == .windows) "ra3_crash.exe" else "ra3_crash";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    // Was a use-after-free segfault (stack-local return dtype). `b.get_inner().code`.
    const input =
        "imp std.c.io;\n" ++
        "compound Inner { num code; }\n" ++
        "compound Box<T> { T v; }\n" ++
        "impl Box<T> { get_inner() Inner { Inner i; i.code = 42; ret i; } }\n" ++
        "fun main() num { Box<num> b; printf(\"%lld\\n\", b.get_inner().code); ret 0; }\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42\n", stdout);
}

test "ra3: deep method chains (3-level quirk, fn-returns-generic, generic-method chain)" {
    const allocator = std.testing.allocator;
    const ifilepath = "ra3_chains.fn";
    const c_path = "ra3_chains.c";
    const exe_path = if (builtin.os.tag == .windows) "ra3_chains.exe" else "ra3_chains";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    const input =
        "imp std.c.io;\n" ++
        "imp std.option;\n" ++
        "compound C { num val; }\n" ++
        "quirk QC { gv() num; }\n" ++
        "impl C as QC { gv() num { ret self.val; } }\n" ++
        "compound B { C c; }\n" ++
        "quirk QB { to_c() QC; }\n" ++
        "impl B as QB { to_c() QC { ret &self.c; } }\n" ++
        "compound A { B b; }\n" ++
        "quirk QA { to_b() QB; }\n" ++
        "impl A as QA { to_b() QB { ret &self.b; } }\n" ++
        "compound Box<T> { T value; }\n" ++
        "impl Box<T> { pub get() T { ret self.value; } pub with(T x) Box<T> { ret Box<T>{value = x}; } }\n" ++
        "fun mk(num n) Option<num> { ret some(n); }\n" ++
        "fun main() num {\n" ++
        "  A a; a.b.c.val = 123; QA qa = &a;\n" ++
        "  let bx = Box<num>{value = 10};\n" ++
        "  printf(\"%lld %lld %lld\\n\", qa.to_b().to_c().gv(), mk(55).unwrap_or(0), bx.with(99).get());\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("123 55 99\n", stdout);
}

test "ra3: quirk coercion of deref, parenthesized address-of, and pointer-field" {
    const allocator = std.testing.allocator;
    const ifilepath = "ra3_coerce.fn";
    const c_path = "ra3_coerce.c";
    const exe_path = if (builtin.os.tag == .windows) "ra3_coerce.exe" else "ra3_coerce";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    const input =
        "imp std.c.io;\n" ++
        "compound Inner { num v; }\n" ++
        "compound Outer { Inner* inner; }\n" ++
        "quirk HasV { getV() num; }\n" ++
        "impl Inner as HasV { getV() num { ret self.v; } }\n" ++
        "fun extract(Outer* o) HasV { ret o.inner; }\n" ++ // pointer-field coerced
        "fun main() num {\n" ++
        "  Inner p = Inner{v = 55};\n" ++
        "  Inner* pp = &p; Inner** ppp = &pp;\n" ++
        "  HasV a = *ppp;\n" ++ // deref coerced
        "  HasV b = (&p);\n" ++ // parenthesized address-of coerced
        "  Inner i = Inner{v = 99};\n" ++
        "  Outer o = Outer{inner = &i};\n" ++
        "  printf(\"%lld %lld %lld\\n\", a.getV(), b.getV(), extract(&o).getV());\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    // a = *ppp and b = (&p) both reference p (v=55); extract(&o) references i (v=99).
    try std.testing.expectEqualStrings("55 55 99\n", stdout);
}

test "ra3: generic T[] param accepts a concrete array arg; extra pub method in as-Quirk impl callable" {
    const allocator = std.testing.allocator;
    const ifilepath = "ra3_resolver.fn";
    const c_path = "ra3_resolver.c";
    const exe_path = if (builtin.os.tag == .windows) "ra3_resolver.exe" else "ra3_resolver";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    const input =
        "imp std.c.io;\n" ++
        "quirk Named { name() str; }\n" ++
        "compound Box<T> { T[] data; num n; }\n" ++
        "impl Box<T> { pub fill(T[] src, num c) { self.data = src; self.n = c; } pub at(num i) T { ret self.data[i]; } }\n" ++
        "compound Dog { num age; }\n" ++
        "impl Dog as Named { pub name() str { ret \"rex\"; } pub age_years() num { ret self.age; } }\n" ++
        "fun main() num {\n" ++
        "  Box<num> b;\n" ++
        "  num[] arr = [10, 20, 30];\n" ++
        "  b.fill(arr, 3);\n" ++ // num[] arg to generic T[] param
        "  Dog d; d.age = 5;\n" ++
        "  printf(\"%lld %lld\\n\", b.at(1), d.age_years());\n" ++ // extra pub method in as-Quirk impl
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("20 5\n", stdout);
}

test "P3: nil literal lowers to NULL and coerces to pointer/str" {
    const allocator = std.testing.allocator;
    const ifilepath = "p3_nil.fn";
    const c_path = "p3_nil.c";
    const exe_path = if (builtin.os.tag == .windows) "p3_nil.exe" else "p3_nil";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "compound Node { num val; Node* next; }\n" ++
        "fun main() num {\n" ++
        "  num* p = nil;\n" ++
        "  Node tail = Node{val = 2, next = nil};\n" ++
        "  Node head = Node{val = 1, next = &tail};\n" ++
        "  num isnil = 0; if p == nil { isnil = 1; }\n" ++
        "  num sum = 0; Node* cur = &head;\n" ++
        "  for cur != nil { sum = sum + cur.val; cur = cur.next; }\n" ++
        "  printf(\"%lld %lld\\n\", isnil, sum);\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    // `nil` must emit the C null-pointer constant `NULL`.
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "NULL") != null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("1 3\n", stdout);
}

test "P3: fork spawns virtual threads onto the M:N scheduler" {
    const allocator = std.testing.allocator;
    const ifilepath = "p3_fork.fn";
    const c_path = "p3_fork.c";
    const exe_path = if (builtin.os.tag == .windows) "p3_fork.exe" else "p3_fork";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "imp std.channel;\n" ++
        "async fun worker(Channel<num>* ch, num v) { ch.send(v * 10); }\n" ++
        "fun main() num {\n" ++
        "  Channel<num> ch = channel_new_cap(0, 8);\n" ++
        "  fork worker(&ch, 1);\n" ++
        "  fork worker(&ch, 2);\n" ++
        "  fork worker(&ch, 3);\n" ++
        "  num sum = 0; num i = 0;\n" ++
        "  for i < 3 { sum = sum + ch.recv(); i = i + 1; }\n" ++
        "  printf(\"sum=%lld\\n\", sum);\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    // The scheduler runtime + per-callee fork helper + main drain must be emitted.
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "__fun_go(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "__fun_fork_call_worker") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "__fun_sched_wait_idle();") != null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("sum=60\n", stdout);
}

test "P3: channel operators ch <- v and <-ch desugar to send/recv" {
    const allocator = std.testing.allocator;
    const ifilepath = "p3_chan_ops.fn";
    const c_path = "p3_chan_ops.c";
    const exe_path = if (builtin.os.tag == .windows) "p3_chan_ops.exe" else "p3_chan_ops";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "imp std.channel;\n" ++
        "fun main() num {\n" ++
        "  Channel<num> ch = channel_new_cap(0, 4);\n" ++
        "  ch <- 7;\n" ++ // statement send
        "  ch <- 3 + 4;\n" ++ // expression send -> send(3 + 4)
        "  let a = <-ch;\n" ++ // let-recv
        "  num b = <-ch;\n" ++ // typed-recv
        "  printf(\"%lld %lld\\n\", a, b);\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    // Desugared to the existing send/recv method calls (no new codegen path).
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "send") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "recv") != null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("7 7\n", stdout);
}

test "P3: a <- b is a channel send, but x < -y stays a comparison (munch)" {
    const allocator = std.testing.allocator;
    const ifilepath = "p3_munch.fn";
    const c_path = "p3_munch.c";
    const exe_path = if (builtin.os.tag == .windows) "p3_munch.exe" else "p3_munch";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // `a < -y` (with a space) must lex as `<` then `-y`, NOT as the `<-` channel op.
    const input =
        "imp std.c.io;\n" ++
        "fun main() num {\n" ++
        "  num a = 5; num y = 3;\n" ++
        "  bin lt = a < -y;\n" ++ // 5 < -3 -> false
        "  bin gt = a > -y;\n" ++ // 5 > -3 -> true
        "  printf(\"%d %d\\n\", lt, gt);\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("0 1\n", stdout);
}

test "fork target async fn is not flagged unused" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_fork_unused.fn";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};

    // An `async fun` used ONLY as a `fork` target must NOT trigger the
    // unused_function warning, and must type-check without the "async call must
    // be awaited" error (fork invokes it fire-and-forget).
    const input =
        "imp std.c.io;\n" ++
        "imp std.channel;\n" ++
        "async fun worker(Channel<num>* out, num v) {\n" ++
        "  out <- v * v;\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  Channel<num> ch = channel_new_cap(0, 4);\n" ++
        "  fork worker(&ch, 5);\n" ++
        "  num r = <- ch;\n" ++
        "  printf(\"%lld\\n\", r);\n" ++
        "  ret 0;\n" ++
        "}\n";

    // It must transpile cleanly (no TypeMismatch from the must-await rule). The
    // emitted C references the worker function, so it is genuinely used.
    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "worker") != null);
}

test "channel of a data-carrying enum, received and matched with fit" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_channel_enum_fit.fn";
    const c_path = "codegen_channel_enum_fit.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_channel_enum_fit.exe" else "codegen_channel_enum_fit";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: (1) a `Channel<Msg>` where Msg is a tagged-union enum must
    // emit the enum's forward declaration before the channel specialization (a
    // `Msg* data` field once referenced an undeclared `Msg`); (2) `fit <- ch`
    // over a data-enum recv expression must switch on the variant `.tag`, not on
    // the whole struct.
    const input =
        "imp std.c.io;\n" ++
        "imp std.channel;\n" ++
        "enum Msg { Compute(num), Result(num), Stop }\n" ++
        "async fun worker(Channel<Msg>* inbox, Channel<Msg>* outbox) {\n" ++
        "  fit <- inbox {\n" ++
        "    Msg.Compute(v) -> { outbox <- Msg.Result(v * v); }\n" ++
        "    Msg.Stop -> { outbox <- Msg.Stop; }\n" ++
        "    _ -> {}\n" ++
        "  }\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  Channel<Msg> inbox = channel_new_cap(Msg.Stop, 4);\n" ++
        "  Channel<Msg> outbox = channel_new_cap(Msg.Stop, 4);\n" ++
        "  fork worker(&inbox, &outbox);\n" ++
        "  inbox <- Msg.Compute(6);\n" ++
        "  fit <- outbox {\n" ++
        "    Msg.Result(r) -> { printf(\"result=%lld\\n\", r); }\n" ++
        "    _ -> { printf(\"other\\n\"); }\n" ++
        "  }\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnvTimeout(allocator, exe_path, &.{}, 15_000);
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("result=36\n", stdout);
}

test "generic data enum: Option<num> construct, pass, fit, payload binding" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_generic_enum_option.fn";
    const c_path = "codegen_generic_enum_option.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_generic_enum_option.exe" else "codegen_generic_enum_option";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // A GENERIC data enum monomorphizes per instantiation (Option<num> -> Option__num),
    // constructs both a payload variant (Some) and a payload-free variant (None),
    // passes as a parameter, and matches with `fit` binding the payload (typed `num`,
    // not the bare `T`). Both `Enum.Variant` and shorthand `.Variant` forms.
    const input =
        "imp std.c.io;\n" ++
        "enum Option<T> { Some(T), None }\n" ++
        "fun describe(Option<num> o) num {\n" ++
        "  fit o {\n" ++
        "    Option.Some(v) -> { ret v; }\n" ++
        "    Option.None -> { ret -1; }\n" ++
        "  }\n" ++
        "  ret -2;\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  Option<num> a = Option.Some(42);\n" ++
        "  Option<num> b = .None;\n" ++
        "  printf(\"%lld %lld\\n\", describe(a), describe(b));\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    // The monomorphized type and tag must be mangled, never the bare template.
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Option__num") != null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42 -1\n", stdout);
}

test "generic data enum: Result<T, E> with two type params and mixed payloads" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_generic_enum_result.fn";
    const c_path = "codegen_generic_enum_result.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_generic_enum_result.exe" else "codegen_generic_enum_result";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Two type parameters with distinct payload types (Ok carries num, Err carries
    // str). Each arm binds its payload at the substituted concrete type.
    const input =
        "imp std.c.io;\n" ++
        "enum Result<T, E> { Ok(T), Err(E) }\n" ++
        "fun main() num {\n" ++
        "  Result<num, str> a = Result.Ok(7);\n" ++
        "  Result<num, str> b = Result.Err(\"boom\");\n" ++
        "  fit a {\n" ++
        "    Result.Ok(v) -> { printf(\"ok %lld\\n\", v); }\n" ++
        "    Result.Err(e) -> { printf(\"err %s\\n\", e); }\n" ++
        "  }\n" ++
        "  fit b {\n" ++
        "    Result.Ok(v) -> { printf(\"ok %lld\\n\", v); }\n" ++
        "    Result.Err(e) -> { printf(\"err %s\\n\", e); }\n" ++
        "  }\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("ok 7\nerr boom\n", stdout);
}

test "generic fn returning a generic enum monomorphizes the enum type (regression)" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_generic_fn_returns_enum.fn";
    const c_path = "codegen_generic_fn_returns_enum.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_generic_fn_returns_enum.exe" else "codegen_generic_fn_returns_enum";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: a GENERIC FREE FUNCTION whose body constructs the enum via BOTH a
    // `T`-payload variant (Ok) and a different concrete-payload variant (Error(num)),
    // returning `RR<T>`. Instantiated at T=num, the monomorphized `RR__num` type
    // appears only through the generic fn's return type — the template node still says
    // `RR<T>`. Previously the `RR__num` typedef was never emitted (used-but-undefined).
    const input =
        "imp std.c.io;\n" ++
        "enum RR<T> { Ok(T), Closed, Error(num) }\n" ++
        "fun wrap<T>(num rc, T value) RR<T> {\n" ++
        "  if rc == 0 { ret RR.Ok(value); }\n" ++
        "  ret RR.Error(rc);\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  fit wrap(0, 42) {\n" ++
        "    RR.Ok(v) -> { printf(\"ok %lld\\n\", v); }\n" ++
        "    RR.Closed -> { printf(\"closed\\n\"); }\n" ++
        "    RR.Error(e) -> { printf(\"err %lld\\n\", e); }\n" ++
        "  }\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    // The monomorphized enum typedef MUST be present (not used-but-undefined).
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "RR__num") != null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("ok 42\n", stdout);
}

test "default parameter values: free fn, method, multi-default, explicit override" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_default_params.fn";
    const c_path = "codegen_default_params.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_default_params.exe" else "codegen_default_params";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // A call omitting trailing args fills them from the callee's defaults — for a free
    // function (multiple defaults), and for a method (the implicit `self` is unaffected).
    const input =
        "imp std.c.io;\n" ++
        "fun three(num a, num b = 2, num c = 3) num { ret a * 100 + b * 10 + c; }\n" ++
        "compound Box { num v; }\n" ++
        "impl Box {\n" ++
        "  pub add(num x, num y = 100) num { ret self.v + x + y; }\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  printf(\"%lld %lld %lld\\n\", three(1), three(1, 5), three(1, 5, 9));\n" ++
        "  Box b; b.v = 1000;\n" ++
        "  printf(\"%lld %lld\\n\", b.add(1), b.add(1, 1));\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    // The C function signature must NOT carry the default (`= 2`) — C has no default args.
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "= 2)") == null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("123 153 159\n1101 1002\n", stdout);
}

test "default parameter rejected: required param after a defaulted one" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_default_params_bad_order.fn";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    const input =
        "fun f(num x = 1, num y) num { ret x + y; }\n" ++
        "fun main() num { ret f(1, 2); }\n";
    const res = runTranspile(allocator, ifilepath, input);
    if (res) |out| {
        allocator.free(out);
        return error.TestExpectedError; // should have failed
    } else |_| {}
}

test "default parameter rejected: default references self" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_default_params_self_ref.fn";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    const input =
        "compound C { num cfg; }\n" ++
        "impl C { pub poll(num slice = self.cfg) num { ret slice; } }\n" ++
        "fun main() num { C c; c.cfg = 1; ret c.poll(); }\n";
    const res = runTranspile(allocator, ifilepath, input);
    if (res) |out| {
        allocator.free(out);
        return error.TestExpectedError;
    } else |_| {}
}

test "default parameter longhand enum values work for generic enums" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_default_params_longhand_enum.fn";
    const c_path = "codegen_default_params_longhand_enum.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_default_params_longhand_enum.exe" else "codegen_default_params_longhand_enum";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    const input =
        "imp std.c.io;\n" ++
        "enum Option<T> { Some(T), None }\n" ++
        "fun pick(Option<num> v = Option.None) num {\n" ++
        "  fit v {\n" ++
        "    Option.Some(n) -> { ret n; }\n" ++
        "    Option.None -> { ret 7; }\n" ++
        "  }\n" ++
        "  ret -1;\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  printf(\"%lld %lld\\n\", pick(), pick(Option.Some(9)));\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Option__num_None") != null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("7 9\n", stdout);
}

test "default parameter after a generic-typed param: omitting the trailing default still typechecks" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_default_after_generic_param.fn";
    const c_path = "codegen_default_after_generic_param.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_default_after_generic_param.exe" else "codegen_default_after_generic_param";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // A generic free function whose FIRST param's type mentions the function's own
    // type param (`Node<T>*`) previously made the arg-count check for a defaulted
    // TRAILING param (`with_addr = false`) require an exact match against every
    // declared param instead of just the leading required ones — so omitting the
    // default incorrectly errored "expects 2 args, got 1". The equivalent
    // non-generic signature (a concrete `Node<num>*`) never hit this, since it
    // goes through a different (already-correct) call-arg-count check.
    const input =
        "imp std.c.io;\n" ++
        "compound Node<T> { T value; Node<T>* next; }\n" ++
        "fun show<T>(Node<T>* head, bin with_addr = false) T {\n" ++
        "  if with_addr { printf(\"with_addr=true\\n\"); } else { printf(\"with_addr=false\\n\"); }\n" ++
        "  ret head.value;\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  Node<num> n;\n" ++
        "  n.value = 5;\n" ++
        "  n.next = nil;\n" ++
        "  let a = show(&n);\n" ++
        "  let b = show(&n, true);\n" ++
        "  printf(\"%lld %lld\\n\", a, b);\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("with_addr=false\nwith_addr=true\n5 5\n", stdout);
}

test "quirk-impl method call chains onto a call-expression receiver" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_chained_quirk_method_call.fn";
    const c_path = "codegen_chained_quirk_method_call.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_chained_quirk_method_call.exe" else "codegen_chained_quirk_method_call";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // `len()`/`is_empty()` come from `impl Vec<T> as Sized`, not a plain `impl
    // Vec<T>` block. Chaining `.len()` onto a CALL-expression receiver (no
    // named variable to take the address of) used to fall through to plain
    // field access — `Vec` also has a `len` FIELD of the same name — emitting
    // invalid C that tried to call an int64_t. Regresses that codegen path.
    const input =
        "imp std.c.io;\n" ++
        "imp std.vec;\n" ++
        "fun make_vec() Vec<num> {\n" ++
        "  Vec<num> v;\n" ++
        "  v.init(4);\n" ++
        "  v.push(1);\n" ++
        "  v.push(2);\n" ++
        "  ret v;\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  printf(\"%lld %d\\n\", make_vec().len(), make_vec().is_empty());\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("2 0\n", stdout);
}

test "std.log supports rotating sink destinations" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_log_rotating_sink.fn";
    const c_path = "codegen_log_rotating_sink.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_log_rotating_sink.exe" else "codegen_log_rotating_sink";
    const out_path = "codegen_log_rotating_sink.out";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, out_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, "codegen_log_rotating_sink.out.1") catch {};

    const input =
        "imp std.log;\n" ++
        "imp std.io;\n" ++
        "fun main() num {\n" ++
        "  RotatingSink rot = rotating_sink_new(\"codegen_log_rotating_sink.out\", 1024, 2);\n" ++
        "  Sink s = Sink.Rotating(&rot);\n" ++
        "  Logger l = logger_init(.Info).with_timestamps(false).to_sink(s);\n" ++
        "  l.info(\"hello rotating sink\");\n" ++
        "  _ = s.flush();\n" ++
        "  rot.close();\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Sink_Rotating") != null);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    _ = try runExeWithEnv(allocator, exe_path, &.{});
    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, out_path, allocator, .limited(1024 * 1024));
    defer allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "hello rotating sink") != null);
}

test "for item : iterable drives a user Iterator via next()/Option; break exits the loop" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_for_iter_quirk.fn";
    const c_path = "codegen_for_iter_quirk.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_for_iter_quirk.exe" else "codegen_for_iter_quirk";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // A self-contained Iterator: `Counter` yields 0,1,2,... up to `limit`. `for x : c`
    // must desugar to the next()/Option loop, and a `break` inside the body must exit
    // the generated loop (not just a fit/switch). No stdlib collections involved.
    const input =
        "imp std.c.io;\n" ++
        "enum Option<T> { Some(T), None }\n" ++
        "quirk Iterator<T> { next() Option<T>; }\n" ++
        "compound Counter { num cur; num limit; }\n" ++
        "impl Counter as Iterator<num> {\n" ++
        "  pub next() Option<num> {\n" ++
        "    if self.cur >= self.limit { ret Option.None; }\n" ++
        "    num v = self.cur;\n" ++
        "    self.cur = self.cur + 1;\n" ++
        "    ret Option.Some(v);\n" ++
        "  }\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  Counter c = Counter{cur = 0, limit = 5};\n" ++
        "  num sum = 0;\n" ++
        "  for x : c {\n" ++
        "    if x == 3 { break; }\n" ++ // break must exit the for-iter loop
        "    sum = sum + x;\n" ++
        "  }\n" ++
        "  printf(\"%lld\\n\", sum);\n" ++ // 0+1+2 = 3
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("3\n", stdout);
}

test "for k, v :: map iterates key/value pairs" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_for_map_kv.fn";
    const c_path = "codegen_for_map_kv.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_for_map_kv.exe" else "codegen_for_map_kv";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // `for k, v :: map` binds each key to k and its value to v. Order is hash-defined,
    // so the program reduces to an order-independent total to keep the assertion stable.
    const input =
        "imp std.c.io;\n" ++
        "imp std.map;\n" ++
        "imp std.option;\n" ++
        "imp std.quirks;\n" ++
        "fun main() num {\n" ++
        "  Map<str, num> m;\n" ++
        "  m.init(8);\n" ++
        "  m.put(\"a\", 10);\n" ++
        "  m.put(\"b\", 20);\n" ++
        "  m.put(\"c\", 30);\n" ++
        "  num klen = 0;\n" ++
        "  num vsum = 0;\n" ++
        "  for k, v :: m {\n" ++
        "    klen = klen + _slen(k);\n" ++ // sum of key lengths (each key is 1 char => 3)
        "    vsum = vsum + v;\n" ++ // 10+20+30 = 60
        "  }\n" ++
        "  printf(\"%lld %lld\\n\", klen, vsum);\n" ++
        "  ret 0;\n" ++
        "}\n" ++
        "fun _slen(str s) num { num i = 0; for s[i] != 0 { i = i + 1; } ret i; }\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("3 60\n", stdout);
}

test "default parameter values: free fn + method, omitting trailing args fills defaults" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_default_params.fn";
    const c_path = "codegen_default_params.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_default_params.exe" else "codegen_default_params";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // A trailing default param may be omitted at the call site; the callee's default
    // expression is materialized there. Covers: free fn with two defaults (omit 2 / omit
    // 1 / pass all), and a method default. A default may call a global fn (`base()`).
    const input =
        "imp std.c.io;\n" ++
        "fun base() num { ret 100; }\n" ++
        "fun three(num a, num b = 2, num c = base()) num { ret a * 1000 + b * 10 + c; }\n" ++
        "compound Box { num v; }\n" ++
        "impl Box {\n" ++
        "  pub add(num x, num y = 50) num { ret self.v + x + y; }\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  printf(\"%lld %lld %lld\\n\", three(1), three(1, 5), three(1, 5, 9));\n" ++
        "  Box b;\n" ++
        "  b.v = 1000;\n" ++
        "  printf(\"%lld %lld\\n\", b.add(1), b.add(1, 1));\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    // three(1)=1000+20+100=1120; three(1,5)=1000+50+100=1150; three(1,5,9)=1000+50+9=1059
    // b.add(1)=1000+1+50=1051; b.add(1,1)=1000+1+1=1002
    try std.testing.expectEqualStrings("1120 1150 1059\n1051 1002\n", stdout);
}

test "deadlock watchdog fires on a plain (non-fork) blocking channel wait" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_sync_runtime_backend.fn";
    const c_path = "codegen_wd_nofork.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_wd_nofork.exe" else "codegen_wd_nofork";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // No `fork` anywhere: the M:N scheduler (and its watchdog) never gets emitted,
    // so this program must get the standalone non-fork watchdog runtime instead.
    // `ch.recv()` blocks forever (nothing ever sends), which FUN_DEADLOCK_WATCHDOG_MS
    // + FUN_DEADLOCK_ABORT should catch and abort on.
    const input =
        "imp std.c.io;\n" ++
        "imp std.channel;\n" ++
        "fun main() num {\n" ++
        "  Channel<num> ch = channel_new(0);\n" ++
        "  num v = ch.recv();\n" ++
        "  printf(\"%lld\\n\", v);\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);

    const exe_abs = blk: {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try std.Io.Dir.cwd().realPathFile(std.testing.io, exe_path, &buf);
        break :blk try allocator.dupe(u8, buf[0..n]);
    };
    defer allocator.free(exe_abs);

    var env_map = try std.testing.environ.createMap(allocator);
    defer env_map.deinit();
    try env_map.put("FUN_DEADLOCK_WATCHDOG_MS", "200");
    try env_map.put("FUN_DEADLOCK_ABORT", "1");

    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{exe_abs},
        .environ_map = &env_map,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(10_000), .clock = .real } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Aborted (not a plain hang the timeout above had to kill, and not a clean exit).
    switch (result.term) {
        .signal => {},
        .exited => |code| try std.testing.expect(code != 0),
        else => return error.UnexpectedTermination,
    }
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "possible deadlock") != null);
}

test "format()/println_fmt's {} auto-dispatches to Display through a pointer dereference" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_display_via_deref.fn";
    const c_path = "codegen_display_via_deref.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_display_via_deref.exe" else "codegen_display_via_deref";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: `resolve_display_call_for_expr` only recognized a bare
    // identifier (`{}`, val) or `&identifier` as a Display-dispatchable
    // vararg — a dereference (`*ptr`) fell through to `return null` and
    // format()/println_fmt printed the raw pointee bytes instead of calling
    // Display's to_string(). This is exactly the shape a recursive,
    // pointer-linked structure's own Display impl needs for its `next`
    // field, so found via a compiler-shaped torture test (a toy AST
    // interpreter with a Node<T>-style generic linked structure).
    const input =
        "imp std.c.io;\n" ++
        "imp std.c.mem;\n" ++
        "imp std.io;\n" ++
        "imp std.quirks;\n" ++
        "compound Point { num x; num y; }\n" ++
        "impl Point as Display {\n" ++
        "  pub to_string() str {\n" ++
        "    ret format(\"({}, {})\", self.x, self.y);\n" ++
        "  }\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  Point p = Point{x = 1, y = 2};\n" ++
        "  println_fmt(\"direct = {}\", p);\n" ++
        "  Point* pp = &p;\n" ++
        "  println_fmt(\"deref  = {}\", *pp);\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("direct = (1, 2)\nderef  = (1, 2)\n", stdout);
}

test "exhaustive fit over every enum variant (no catch-all) counts as always-returning" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_exhaustive_fit_no_catchall.fn";
    const c_path = "codegen_exhaustive_fit_no_catchall.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_exhaustive_fit_no_catchall.exe" else "codegen_exhaustive_fit_no_catchall";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: `stmts_always_return`'s `.StatementFit` case only counted
    // a fit as guaranteed-returning when it had an explicit `_` catch-all
    // branch (`has_default_branch`), even when every arm named a distinct
    // enum variant and the match was already provably exhaustive (no
    // fit_non_exhaustive diagnostic). A method whose whole body was one
    // such fit, with every arm returning, spuriously got the
    // "may reach the end of its body without returning a value" warning.
    // Found via the same torture test (an AST enum's recursive Display
    // impl, matched exhaustively by naming all five variants).
    const input =
        "imp std.c.io;\n" ++
        "imp std.io;\n" ++
        "imp std.quirks;\n" ++
        "enum Shape { Circle(num), Rect(num, num), Empty }\n" ++
        "impl Shape as Display {\n" ++
        "  pub to_string() str {\n" ++
        "    fit *self {\n" ++
        "      Shape.Circle(r) -> { ret format(\"circle {}\", r); }\n" ++
        "      Shape.Rect(w, h) -> { ret format(\"rect {} {}\", w, h); }\n" ++
        "      Shape.Empty -> { ret \"empty\"; }\n" ++
        "    }\n" ++
        "  }\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  Shape s = Shape.Rect(3, 4);\n" ++
        "  println_fmt(\"{}\", s);\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("rect 3 4\n", stdout);
}

test "a locally-declared enum is not shadowed by an unrelated workspace file's same-named type" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_enum_not_workspace_shadowed.fn";
    const unrelated_path = "codegen_enum_not_workspace_shadowed_UNRELATED.fn";
    const c_path = "codegen_enum_not_workspace_shadowed.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_enum_not_workspace_shadowed.exe" else "codegen_enum_not_workspace_shadowed";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, unrelated_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: `auto_import_missing_user_types` best-effort-scans every
    // `.fn` file reachable from cwd for a `compound Name`/`quirk Name` this
    // file references but never declares, so scripts can skip explicit
    // imports. Its "already declared locally, nothing to do" guard checked
    // ONLY compound/quirk (`has_compound_named`/`has_quirk_named`), never
    // enum — so a file declaring `enum Wxqzy123` still got the scan run for
    // "Wxqzy123", found this UNRELATED sibling file's `quirk Wxqzy123`
    // (never imported, contents otherwise irrelevant to this program), and
    // auto-imported it, colliding with the local enum and misattributing
    // the resulting "type is private"/duplicate-symbol error to the
    // unrelated file. Found via a compiler-shaped torture test run from
    // this repo's root, where `examples/advanced/quirks.fn`'s `quirk Shape`
    // collided with a torture-test program's own unrelated `enum Shape`.
    {
        const unrelated_file = try std.Io.Dir.cwd().createFile(std.testing.io, unrelated_path, .{ .truncate = true });
        defer unrelated_file.close(std.testing.io);
        try unrelated_file.writeStreamingAll(std.testing.io,
            \\quirk Wxqzy123 {
            \\  area() num;
            \\}
            \\
        );
    }

    const input =
        "imp std.c.io;\n" ++
        "enum Wxqzy123 { A, B }\n" ++
        "fun main() num {\n" ++
        "  Wxqzy123 v = Wxqzy123.B;\n" ++
        "  fit v {\n" ++
        "    Wxqzy123.A -> { printf(\"a\\n\"); }\n" ++
        "    Wxqzy123.B -> { printf(\"b\\n\"); }\n" ++
        "  }\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("b\n", stdout);
}

test "two unrelated files each declaring a private function of the same name is rejected clearly" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_private_fn_collision_main.fn";
    const unrelated_path = "codegen_private_fn_collision_UNRELATED.fn";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, unrelated_path) catch {};

    // Regression: two DIFFERENT files each declaring their own private
    // (non-`pub`) top-level function under the same bare name both emitted
    // a plain, unmangled C function with that name -- neither Fun's own
    // visibility rules nor the C backend caught the collision until `cc`
    // failed on a confusing "redefinition of 'helper'" error far removed
    // from the actual cause. Worse, resolving a module's OWN call to its
    // own private helper searched from the whole-program ROOT first, so it
    // could find (and wrongly reject as "private") an unrelated file's
    // same-named private helper instead of the caller's own. Found via a
    // multi-file compiler-shaped torture test (a lexer/parser/ast/eval
    // module split, each with private helpers like `mk_bin`/`peek`). Now
    // caught with a clear Fun-level diagnostic before C emission.
    // The unrelated module has its own PRIVATE `helper` (the colliding
    // name) plus a `pub` function the main file genuinely needs -- so the
    // two files are legitimately part of the SAME program (main imports
    // the module for `other_thing`), exactly like `parser.fn` importing
    // `token.fn`/`ast.fn` while both `parser.fn` and `main.fn` separately
    // declared their own private `mk_bin` in the original torture test.
    {
        const unrelated_file = try std.Io.Dir.cwd().createFile(std.testing.io, unrelated_path, .{ .truncate = true });
        defer unrelated_file.close(std.testing.io);
        try unrelated_file.writeStreamingAll(std.testing.io,
            \\fun helper(num x) num {
            \\  ret x * 2;
            \\}
            \\pub fun other_thing() num {
            \\  ret helper(10);
            \\}
            \\
        );
    }

    const input =
        "imp std.c.io;\n" ++
        "imp codegen_private_fn_collision_UNRELATED;\n" ++
        "fun helper(num x) num {\n" ++
        "  ret x + 1;\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  printf(\"%lld %lld\\n\", helper(5), other_thing());\n" ++
        "  ret 0;\n" ++
        "}\n";

    const result = runTranspile(allocator, ifilepath, input);
    try std.testing.expectError(error.DuplicateSymbol, result);
}

test "fit statement with an explicit catch-all branch compiles and evaluates correctly" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_fit_default_branch.fn";
    const c_path = "codegen_fit_default_branch.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_fit_default_branch.exe" else "codegen_fit_default_branch";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: `ast.FitStmt.has_default_branch` is constructed as
    // `undefined` in `parse_fit_statement` and was never actually assigned
    // anywhere the parser pushes a `_` catch-all branch -- its only reader
    // (`stmts_always_return`'s missing_return check) was reading
    // uninitialized memory, giving unpredictable true/false results run to
    // run. Found via a multi-file compiler-shaped torture test (a
    // recursive-descent parser's `parse_factor()`, whose whole body is one
    // `fit` with a `_` catch-all) that spuriously warned
    // "may reach the end of its body without returning a value" despite
    // every arm returning. Now explicitly initialized false and flipped
    // true when a `_` branch is actually parsed. This test's real value is
    // the manually-verified absence of that warning (this harness doesn't
    // capture compiler diagnostics); it also locks in correct compilation
    // and runtime behavior for the pattern.
    const input =
        "imp std.c.io;\n" ++
        "enum Token { Num(num), Ident, Plus, Minus, Star, Slash, LParen, RParen, Eof }\n" ++
        "fun classify(Token t) num {\n" ++
        "  fit t {\n" ++
        "    Token.Num(n) -> { ret n; }\n" ++
        "    Token.Ident -> { ret 1; }\n" ++
        "    _ -> { ret 0; }\n" ++
        "  }\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  printf(\"%lld %lld %lld\\n\", classify(Token.Num(5)), classify(Token.Ident), classify(Token.Eof));\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("5 1 0\n", stdout);
}

test "multi-file compiler-shaped torture program: lexer+parser+ast+eval+trace across 7 files" {
    const allocator = std.testing.allocator;
    const c_path = "torture_compiler.c";
    const exe_path = if (builtin.os.tag == .windows) "torture_compiler.exe" else "torture_compiler";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // examples/imports/torture_compiler/ is a genuine multi-module program
    // (token/lexer/ast/parser/eval/trace/main, split across 7 files) shaped
    // like a real self-hosted compiler's own source tree: a recursive
    // tagged-union AST built and walked across files, a Vec<Token>/
    // Map<str,dec> as generic collections, a constrained-generic recursive
    // linked compound with a generic quirk impl, private per-file helper
    // functions reusing names across files (`mk_bin`/`mk_num` in both
    // parser.fn and main.fn), a real recursive-descent parser returning
    // Result<Expr*> (Ok on success, Err on trailing garbage), `fit` on both
    // `chr` (operators/lexing) and `str` (builtin dispatch) subjects with
    // 4+ branches each, and a variable-arity `Call(str, Vec<Expr*>)` --
    // a generic container of POINTERS to the enum's own recursive type,
    // parsed with a real comma-separated argument list and reduced over in
    // the evaluator (`max`/`min`/`abs`, any arg count). It found seven real
    // compiler bugs across three rounds this way: Display not dispatching
    // through a pointer dereference, an uninitialized `has_default_branch`
    // field, unmangled private-function C names colliding across unrelated
    // files, `fit` on a `chr` subject silently matching only its FIRST
    // branch (a real miscompile), an enum-variant payload of a generic-
    // compound type failing to type-match its own declared type, and --
    // the big one -- a generic container instantiated with a POINTER type
    // argument (`Vec<Expr*>`) mangling to the SAME C name as `Vec<Expr>`
    // ("Vec__Expr" either way), so whichever (colliding) instantiation was
    // processed last silently won for every struct field, enum-payload
    // union, and monomorphized method parameter -- e.g. `push(T value)`
    // taking `Expr` by value instead of `Expr*`. Fixed by encoding each
    // generic argument's pointer depth into its mangled name
    // (`Vec__Expr_ptr1`), so distinct pointer-ness instantiates distinctly.
    // All fixed bugs are separately regression-tested above/below; this
    // test locks in the whole program (now using the REAL Vec<Expr*>
    // design that originally exposed the bug) still working end-to-end.
    var tp = try codegen.TranspileProcess.init(
        allocator,
        "examples/imports/torture_compiler/main.fn",
        "_ignored.c",
        .{ .outf = false, .preload_imports = false, .preload_std_imports = false, .emit_stderr = false },
    );
    var lex_proc = lexer.LexProcess.init(&tp);
    var parse_proc = ParseProcess.init(&tp);
    defer {
        lex_proc.deinit();
        tp.deinit();
    }
    try lex_proc.lex();
    try parse_proc.parse();
    try tp.transpile();

    const out = tp.get_output() orelse return error.NoOutput;
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings(
        "parsed result = 13.0\n" ++
            "parsed ast    = (- (+ 2 (* 3 4)) 1)\n" ++
            "call result   = 10.0\n" ++
            "call ast      = max((+ 2 3), min(10, 20), abs((- 0 9)))\n" ++
            "rejected      = unexpected trailing tokens after expression\n" ++
            "built result  = 49.0\n" ++
            "built ast     = (let x = 7 in (* x x))\n" ++
            "trace         = 3 -> 2 -> 1\n",
        stdout,
    );
}

test "fit on a chr subject checks every branch, not just the first (regression)" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_fit_chr_multi_branch.fn";
    const c_path = "codegen_fit_chr_multi_branch.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_fit_chr_multi_branch.exe" else "codegen_fit_chr_multi_branch";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: a REAL silent miscompile, not just a diagnostic
    // false-positive. `fit` on a `chr` subject lowers to a C `switch`
    // (an integral type), whose emitter dedupes `case` labels via
    // `fit_label_key`. That function's switch never had a `.Character`
    // arm (char literals are their own node type, not `.Number`), so every
    // char-literal branch fell to the "unrecognized node" fallback, which
    // keyed off `@intFromPtr(&label)` -- the address of a BY-VALUE
    // function parameter, frequently identical across separate calls from
    // the same call site. Every branch after the first got treated as a
    // "duplicate" of the first and silently DROPPED from the emitted
    // switch, so only the first branch's char ever matched; every other
    // char fell through to the catch-all with no compiler warning at all.
    // Found refactoring a lexer's char-dispatch if/elif chain into `fit`
    // (per the torture-test program's real char lexing) and seeing the
    // second-onward operators misclassify. Now `.Character` is handled
    // like `.Number`'s `cval` case, keyed by its actual value.
    const input =
        "imp std.c.io;\n" ++
        "fun classify(chr c) str {\n" ++
        "  fit c {\n" ++
        "    '+' -> { ret \"plus\"; }\n" ++
        "    '-' -> { ret \"minus\"; }\n" ++
        "    '*' -> { ret \"star\"; }\n" ++
        "    '/' -> { ret \"slash\"; }\n" ++
        "    _ -> { ret \"other\"; }\n" ++
        "  }\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  printf(\"%s %s %s %s %s\\n\", classify('+'), classify('-'), classify('*'), classify('/'), classify('x'));\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("plus minus star slash other\n", stdout);
}

test "an enum variant payload of a generic-compound type matches its own declared type" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_fit_payload_generic_compound.fn";
    const c_path = "codegen_fit_payload_generic_compound.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_fit_payload_generic_compound.exe" else "codegen_fit_payload_generic_compound";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: `fit_binding_type` resolved a destructured variant
    // payload's type via the bare `type_from_dtype`, which never populates
    // `mangled_name` -- so a payload of a generic-compound type (e.g.
    // `Call(str, Vec<num>)`'s `Vec<num>` field) type-checked as a
    // different, mangled_name-less CheckedType than the SAME `Vec<num>`
    // resolved anywhere else (e.g. a function parameter's declared type),
    // and passing the bound variable to such a function spuriously failed
    // as a type mismatch. Now goes through `type_from_dtype_with_mangled`
    // like every other resolved type.
    const input =
        "imp std.c.io;\n" ++
        "imp std.vec;\n" ++
        "enum E { A(str, Vec<num>) }\n" ++
        "fun consume(str name, Vec<num> v) num {\n" ++
        "  ret v.get(0);\n" ++
        "}\n" ++
        "fun handle(E e) num {\n" ++
        "  fit e {\n" ++
        "    E.A(name, items) -> { ret consume(name, items); }\n" ++
        "  }\n" ++
        "  ret -1;\n" ++
        "}\n" ++
        "fun main() num {\n" ++
        "  Vec<num> v;\n" ++
        "  v.init(4);\n" ++
        "  v.push(42);\n" ++
        "  printf(\"%lld\\n\", handle(E.A(\"x\", v)));\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout);
    try std.testing.expectEqualStrings("42\n", stdout);
}

test "a generic container instantiated with a pointer type argument mangles distinctly (Vec<T*>)" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_generic_pointer_arg_mangling.fn";
    const c_path = "codegen_generic_pointer_arg_mangling.c";
    const exe_path = if (builtin.os.tag == .windows) "codegen_generic_pointer_arg_mangling.exe" else "codegen_generic_pointer_arg_mangling";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, c_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, exe_path) catch {};

    // Regression: the big one. `append_mangled_type_depth`/
    // `append_mangled_type_with_subst_depth` never encoded a generic
    // argument's POINTER DEPTH in the mangled name -- `Vec<Node>` and
    // `Vec<Node*>` both mangled to the identical "Vec__Node", so both
    // instantiations collided into ONE emitted struct/method set, with
    // whichever instantiation was processed last silently winning. In
    // practice this meant a monomorphized method like `push(T value)`
    // could take `Node` BY VALUE instead of `Node*`, a real miscompile
    // (C errors like "passing 'Node *' to parameter of incompatible type
    // 'Node'"). Found via the torture-test program's original design (a
    // recursive AST's `Call` variant holding `Vec<Expr*>`). Fixed by
    // suffixing a nested (generic-arg-depth) pointer type with `_ptrN`
    // in its mangled name (`Vec__Node_ptr1`), so distinct pointer-ness
    // instantiates distinctly. Also exercises `Vec<T>` used with BOTH a
    // plain and a pointer argument in the SAME program, which is exactly
    // the scenario that used to collide.
    const input2 =
        "imp std.c.io;\n" ++
        "imp std.c.mem;\n" ++
        "imp std.vec;\n" ++
        "compound Node { num value; }\n" ++
        "fun main() num {\n" ++
        "  Vec<Node> plain;\n" ++
        "  plain.init(4);\n" ++
        "  Node a;\n" ++
        "  a.value = 7;\n" ++
        "  plain.push(a);\n" ++
        "  Vec<Node*> ptrs;\n" ++
        "  ptrs.init(4);\n" ++
        "  Node* n = malloc(sizeof(Node));\n" ++
        "  n.value = 42;\n" ++
        "  ptrs.push(n);\n" ++
        "  Node got_plain = plain.get(0);\n" ++
        "  Node* got_ptr = ptrs.get(0);\n" ++
        "  printf(\"%lld %lld\\n\", got_plain.value, got_ptr.value);\n" ++
        "  ret 0;\n" ++
        "}\n";

    const out_owned2 = try runTranspile(allocator, ifilepath, input2);
    defer allocator.free(out_owned2);
    {
        const c_file = try std.Io.Dir.cwd().createFile(std.testing.io, c_path, .{ .truncate = true });
        defer c_file.close(std.testing.io);
        try c_file.writeStreamingAll(std.testing.io, out_owned2);
    }
    try compileWithZigCc(allocator, c_path, exe_path);
    const stdout2 = try runExeWithEnv(allocator, exe_path, &.{});
    defer allocator.free(stdout2);
    try std.testing.expectEqualStrings("7 42\n", stdout2);
}
