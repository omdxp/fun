const std = @import("std");
const fs = std.fs;
const ParseProcess = @import("parser").ParseProcess;
const lexer = @import("lexer");
const codegen = @import("codegen");

fn runTranspileWithWarnings(allocator: std.mem.Allocator, input_path: []const u8, input: []const u8) !struct { out: []const u8, warnings: ?[]const u8 } {
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, input_path, .{ .read = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, input);
    }

    var transpile_proc = try codegen.TranspileProcess.init(allocator, input_path, "_ignored.c", .{ .outf = false });
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
    const out_owned = try allocator.dupe(u8, out);
    errdefer allocator.free(out_owned);

    const warnings_owned = if (transpile_proc.get_warnings()) |w|
        try allocator.dupe(u8, w)
    else
        null;

    return .{ .out = out_owned, .warnings = warnings_owned };
}

test "diagnostic: returning address of local warns" {
    const allocator = std.testing.allocator;
    const ifilepath = "return_local_ptr_warn.fn";

    const input =
        "fun bad() num* {\n" ++
        "  num x = 1;\n" ++
        "  ret &x;\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings != null);
    try std.testing.expect(std.mem.indexOf(u8, res.warnings.?, "returning address of local variable") != null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "diagnostic: returning pointer local does not warn" {
    const allocator = std.testing.allocator;
    const ifilepath = "return_local_ptr_ok.fn";

    const input =
        "fun ok() num* {\n" ++
        "  num* p = 0;\n" ++
        "  ret p;\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings == null);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
}

test "diagnostic: allow return_local_ptr suppresses warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "return_local_ptr_allow.fn";

    const input =
        "fun bad() num* {\n" ++
        "  allow return_local_ptr, \"intentional local pointer escape for migration\";\n" ++
        "  num x = 1;\n" ++
        "  ret &x;\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings == null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: expect return_local_ptr suppresses warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "return_local_ptr_expect.fn";

    const input =
        "fun bad() num* {\n" ++
        "  expect return_local_ptr, \"known edge-case while refactoring\";\n" ++
        "  num x = 1;\n" ++
        "  ret &x;\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings == null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: unmet expect return_local_ptr fails" {
    const allocator = std.testing.allocator;
    const ifilepath = "return_local_ptr_expect_unmet.fn";

    const input =
        "fun ok() num* {\n" ++
        "  expect return_local_ptr, \"should fail when warning disappears\";\n" ++
        "  num* p = 0;\n" ++
        "  ret p;\n" ++
        "}\n";

    const res = runTranspileWithWarnings(allocator, ifilepath, input) catch |err| {
        try std.testing.expectEqual(codegen.TranspileError.UnmetWarningExpectation, err);
        std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
        return;
    };
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(false);
}
