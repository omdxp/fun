const std = @import("std");
const fs = std.fs;
const ParseProcess = @import("parser").ParseProcess;
const lexer = @import("lexer");
const codegen = @import("codegen");

fn runTranspileWithWarnings(allocator: std.mem.Allocator, input_path: []const u8, input: []const u8, emit_unused_warnings: bool) !struct { out: []const u8, warnings: ?[]const u8 } {
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, input_path, .{ .read = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, input);
    }

    var transpile_proc = try codegen.TranspileProcess.init(allocator, input_path, "_ignored.c", .{ .outf = false, .emit_unused_warnings = emit_unused_warnings });
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

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, false);
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

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, false);
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

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, false);
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

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, false);
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

    const res = runTranspileWithWarnings(allocator, ifilepath, input, false) catch |err| {
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

test "diagnostic: unreachable code warns" {
    const allocator = std.testing.allocator;
    const ifilepath = "unreachable_code_warn.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() num {\n" ++
        "  ret 0;\n" ++
        "  printf(\"never\\n\");\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, false);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings != null);
    try std.testing.expect(std.mem.indexOf(u8, res.warnings.?, "statement is unreachable because the previous statement always exits the current scope") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: allow unreachable_code suppresses warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "unreachable_code_allow.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() num {\n" ++
        "  ret 0;\n" ++
        "  allow unreachable_code, \"leave disabled branch nearby during refactor\";\n" ++
        "  printf(\"never\\n\");\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, false);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings == null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: expect unreachable_code suppresses warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "unreachable_code_expect.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() num {\n" ++
        "  ret 0;\n" ++
        "  expect unreachable_code, \"tracked dead path until cleanup\";\n" ++
        "  printf(\"never\\n\");\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, false);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings == null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: unmet expect unreachable_code fails" {
    const allocator = std.testing.allocator;
    const ifilepath = "unreachable_code_expect_unmet.fn";

    const input =
        "fun main() num {\n" ++
        "  expect unreachable_code, \"should fail once dead code is removed\";\n" ++
        "  ret 0;\n" ++
        "}\n";

    const res = runTranspileWithWarnings(allocator, ifilepath, input, false) catch |err| {
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

test "diagnostic: assert constant warns" {
    const allocator = std.testing.allocator;
    const ifilepath = "assert_constant_warn.fn";

    const input =
        "fun main() void {\n" ++
        "  assert true, \"kept while debugging\";\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, false);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings != null);
    try std.testing.expect(std.mem.indexOf(u8, res.warnings.?, "assert condition is always true") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: allow assert_constant suppresses warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "assert_constant_allow.fn";

    const input =
        "fun main() void {\n" ++
        "  allow assert_constant, \"temporary debug assertion left in place\";\n" ++
        "  assert true, \"kept while debugging\";\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, false);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings == null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: expect assert_constant suppresses warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "assert_constant_expect.fn";

    const input =
        "fun main() void {\n" ++
        "  expect assert_constant, \"tracked until the debug assertion is removed\";\n" ++
        "  assert true, \"kept while debugging\";\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, false);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings == null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: unmet expect assert_constant fails" {
    const allocator = std.testing.allocator;
    const ifilepath = "assert_constant_expect_unmet.fn";

    const input =
        "fun main() void {\n" ++
        "  expect assert_constant, \"should fail when the redundant assert disappears\";\n" ++
        "}\n";

    const res = runTranspileWithWarnings(allocator, ifilepath, input, false) catch |err| {
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

test "diagnostic: unused local variable warns" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_variable_warn.fn";

    const input =
        "fun demo() void {\n" ++
        "  num value = 1;\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings != null);
    try std.testing.expect(std.mem.indexOf(u8, res.warnings.?, "unused variable 'value'") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: allow unused_variable suppresses warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_variable_allow.fn";

    const input =
        "fun main() void {\n" ++
        "  allow unused_variable, \"temporary scaffolding\";\n" ++
        "  num value = 1;\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings == null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: expect unused_variable suppresses warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_variable_expect.fn";

    const input =
        "fun main() void {\n" ++
        "  expect unused_variable, \"tracked temporary local\";\n" ++
        "  num value = 1;\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings == null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: unmet expect unused_variable fails" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_variable_expect_unmet.fn";

    const input =
        "fun main() void {\n" ++
        "  expect unused_variable, \"should fail when the local becomes used\";\n" ++
        "  num value = 1;\n" ++
        "  _ = value;\n" ++
        "}\n";

    const res = runTranspileWithWarnings(allocator, ifilepath, input, true) catch |err| {
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

test "diagnostic: unused import warns" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_import_warn.fn";

    const input =
        "imp std.option;\n" ++
        "fun main() void {}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings != null);
    try std.testing.expect(std.mem.indexOf(u8, res.warnings.?, "unused import 'std.option'") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: allow unused_import suppresses warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_import_allow.fn";

    const input =
        "allow unused_import, \"placeholder import while sketching the API\";\n" ++
        "imp std.option;\n" ++
        "fun main() void {}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings == null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: expect unused_import suppresses warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_import_expect.fn";

    const input =
        "expect unused_import, \"tracked unused import until the call site lands\";\n" ++
        "imp std.option;\n" ++
        "fun main() void {}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings == null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: unmet expect unused_import fails" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_import_expect_unmet.fn";

    const input =
        "expect unused_import, \"should fail when the import becomes used\";\n" ++
        "imp std.option;\n" ++
        "fun main() void {\n" ++
        "  Option<num> value = some(1);\n" ++
        "  _ = value;\n" ++
        "}\n";

    const res = runTranspileWithWarnings(allocator, ifilepath, input, true) catch |err| {
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

test "diagnostic: unused private function warns" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_function_warn.fn";

    const input =
        "fun helper() num {\n" ++
        "  ret 1;\n" ++
        "}\n" ++
        "fun main() void {}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings != null);
    try std.testing.expect(std.mem.indexOf(u8, res.warnings.?, "unused function 'helper'") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: allow unused_function suppresses warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_function_allow.fn";

    const input =
        "allow unused_function, \"temporary helper while the caller is being wired\";\n" ++
        "fun helper() num {\n" ++
        "  ret 1;\n" ++
        "}\n" ++
        "fun main() void {}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings == null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: expect unused_function suppresses warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_function_expect.fn";

    const input =
        "expect unused_function, \"tracked helper pending its first call site\";\n" ++
        "fun helper() num {\n" ++
        "  ret 1;\n" ++
        "}\n" ++
        "fun main() void {}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings == null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: unmet expect unused_function fails" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_function_expect_unmet.fn";

    const input =
        "expect unused_function, \"should fail when the helper becomes used\";\n" ++
        "fun helper() num {\n" ++
        "  ret 1;\n" ++
        "}\n" ++
        "fun main() void {\n" ++
        "  _ = helper();\n" ++
        "}\n";

    const res = runTranspileWithWarnings(allocator, ifilepath, input, true) catch |err| {
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

test "diagnostic: unused private compound warns" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_compound_warn.fn";

    const input =
        "compound Hidden {\n" ++
        "  num value;\n" ++
        "}\n" ++
        "fun main() void {}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings != null);
    try std.testing.expect(std.mem.indexOf(u8, res.warnings.?, "unused compound 'Hidden'") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: allow unused_compound suppresses warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_compound_allow.fn";

    const input =
        "allow unused_compound, \"temporary private type during refactor\";\n" ++
        "compound Hidden {\n" ++
        "  num value;\n" ++
        "}\n" ++
        "fun main() void {}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings == null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: expect unused_compound suppresses warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_compound_expect.fn";

    const input =
        "expect unused_compound, \"tracked private type pending external use\";\n" ++
        "compound Hidden {\n" ++
        "  num value;\n" ++
        "}\n" ++
        "fun main() void {}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings == null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: unmet expect unused_compound fails" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_compound_expect_unmet.fn";

    const input =
        "expect unused_compound, \"should fail when the compound becomes used\";\n" ++
        "compound Hidden {\n" ++
        "  num value;\n" ++
        "}\n" ++
        "fun main() void {\n" ++
        "  Hidden hidden = Hidden{value = 1};\n" ++
        "  _ = hidden;\n" ++
        "}\n";

    const res = runTranspileWithWarnings(allocator, ifilepath, input, true) catch |err| {
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
