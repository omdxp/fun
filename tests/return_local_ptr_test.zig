const std = @import("std");
const fs = std.fs;
const ParseProcess = @import("parser").ParseProcess;
const lexer = @import("lexer");
const codegen = @import("codegen");

fn runTranspileWithWarnings(allocator: std.mem.Allocator, input_path: []const u8, input: []const u8) !struct { out: []const u8, warnings: ?[]const u8 } {
    {
        const file = try fs.cwd().createFile(input_path, .{ .read = true });
        defer file.close();
        try file.writeAll(input);
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

    try fs.cwd().deleteFile(ifilepath);
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

    try fs.cwd().deleteFile(ifilepath);
}
