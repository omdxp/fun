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

test "fit bin missing false warns" {
    const allocator = std.testing.allocator;
    const ifilepath = "fit_bin_missing_false.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  bin x = true;\n" ++
        "  fit x {\n" ++
        "    true -> { printf(\"T\\n\"); }\n" ++
        "  }\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings != null);
    try std.testing.expect(std.mem.indexOf(u8, res.warnings.?, "fit statement is not exhausted for bin condition") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "fit bin exhausted via default no warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "fit_bin_default.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  bin x = true;\n" ++
        "  fit x {\n" ++
        "    true -> { printf(\"T\\n\"); },\n" ++
        "    _ -> { printf(\"D\\n\"); }\n" ++
        "  }\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings == null);

    try fs.cwd().deleteFile(ifilepath);
}

test "fit num no exhaustiveness warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "fit_num_no_warn.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  num x = 1;\n" ++
        "  fit x {\n" ++
        "    1 -> { printf(\"one\\n\"); }\n" ++
        "  }\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings == null);

    try fs.cwd().deleteFile(ifilepath);
}
