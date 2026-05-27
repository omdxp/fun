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

fn runDiagOnlyWithWarnings(allocator: std.mem.Allocator, input_path: []const u8, input: []const u8) !?[]const u8 {
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, input_path, .{ .read = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, input);
    }

    var transpile_proc = try codegen.TranspileProcess.init(allocator, input_path, "_ignored.c", .{
        .exec = false,
        .outf = false,
        .diag_only = true,
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

    return if (transpile_proc.get_warnings()) |w|
        try allocator.dupe(u8, w)
    else
        null;
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

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "fit bin missing false warns in diag_only mode" {
    const allocator = std.testing.allocator;
    const ifilepath = "fit_bin_missing_false_diag_only.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  bin x = true;\n" ++
        "  fit x {\n" ++
        "    true -> { printf(\"T\\n\"); }\n" ++
        "  }\n" ++
        "}\n";

    const warnings = try runDiagOnlyWithWarnings(allocator, ifilepath, input);
    defer if (warnings) |w| allocator.free(w);

    try std.testing.expect(warnings != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings.?, "fit statement is not exhausted for bin condition (missing false branch)") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "fit allow fit_non_exhaustive suppresses warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "fit_bin_allow_warning.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  bin x = true;\n" ++
        "  allow fit_non_exhaustive, \"partial migration, keep behavior explicit\";\n" ++
        "  fit x {\n" ++
        "    true -> { printf(\"T\\n\"); }\n" ++
        "  }\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings == null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "fit expect fit_non_exhaustive suppresses warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "fit_bin_expect_warning.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  bin x = true;\n" ++
        "  expect fit_non_exhaustive, \"tracked non-exhaustive branch\";\n" ++
        "  fit x {\n" ++
        "    true -> { printf(\"T\\n\"); }\n" ++
        "  }\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings == null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "fit unmet expect fit_non_exhaustive fails" {
    const allocator = std.testing.allocator;
    const ifilepath = "fit_bin_expect_unmet.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  bin x = true;\n" ++
        "  expect fit_non_exhaustive, \"must fail if fit becomes exhaustive\";\n" ++
        "  fit x {\n" ++
        "    true -> { printf(\"T\\n\"); },\n" ++
        "    false -> { printf(\"F\\n\"); }\n" ++
        "  }\n" ++
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

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "fit bin default only no warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "fit_bin_default_only.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  bin x = true;\n" ++
        "  fit x {\n" ++
        "    _ -> { printf(\"D\\n\"); }\n" ++
        "  }\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings == null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "fit num missing default warns" {
    const allocator = std.testing.allocator;
    const ifilepath = "fit_num_missing_default_warns.fn";

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

    try std.testing.expect(res.warnings != null);
    try std.testing.expect(std.mem.indexOf(u8, res.warnings.?, "fit statement is not exhausted") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.warnings.?, "missing catch-all '_' branch") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "fit pointer missing default warns" {
    const allocator = std.testing.allocator;
    const ifilepath = "fit_ptr_missing_default_warns.fn";

    const input =
        "imp std.c.io;\n" ++
        "imp std.c.mem;\n\n" ++
        "fun main() {\n" ++
        "  raw* p = malloc(1);\n" ++
        "  fit p {\n" ++
        "    NULL -> { printf(\"null\\n\"); }\n" ++
        "  }\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings != null);
    try std.testing.expect(std.mem.indexOf(u8, res.warnings.?, "fit statement is not exhausted") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.warnings.?, "missing catch-all '_' branch") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "fit enum exhausted via all variants no warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "fit_enum_exhausted.fn";

    const input =
        "imp std.c.io;\n" ++
        "enum Color {\n" ++
        "  Red;\n" ++
        "  Green;\n" ++
        "  Blue;\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  Color c = Color.Red;\n" ++
        "  fit c {\n" ++
        "    Color.Red -> { printf(\"R\\n\"); },\n" ++
        "    Color.Green -> { printf(\"G\\n\"); },\n" ++
        "    Color.Blue -> { printf(\"B\\n\"); }\n" ++
        "  }\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings == null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "fit enum missing variant warns" {
    const allocator = std.testing.allocator;
    const ifilepath = "fit_enum_missing_variant.fn";

    const input =
        "imp std.c.io;\n" ++
        "enum Color {\n" ++
        "  Red;\n" ++
        "  Green;\n" ++
        "  Blue;\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  Color c = Color.Red;\n" ++
        "  fit c {\n" ++
        "    Color.Red -> { printf(\"R\\n\"); },\n" ++
        "    Color.Green -> { printf(\"G\\n\"); }\n" ++
        "  }\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings != null);
    try std.testing.expect(std.mem.indexOf(u8, res.warnings.?, "fit statement is not exhausted for enum") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "fit enum dot shorthand exhausted no warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "fit_enum_dot_shorthand_exhausted.fn";

    const input =
        "imp std.c.io;\n" ++
        "enum Color {\n" ++
        "  Red;\n" ++
        "  Green;\n" ++
        "  Blue;\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  Color c = .Red;\n" ++
        "  fit c {\n" ++
        "    .Red -> { printf(\"R\\n\"); },\n" ++
        "    .Green -> { printf(\"G\\n\"); },\n" ++
        "    .Blue -> { printf(\"B\\n\"); }\n" ++
        "  }\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings == null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}
