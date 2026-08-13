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

fn writeTestFile(path: []const u8, contents: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .read = true, .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, contents);
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

test "diagnostic: imported public function call marks non-aliased import used" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_import_public_function_call.fn";
    const helper_path = "unused_import_public_function_helper.fn";

    try writeTestFile(
        helper_path,
        "pub fun helper() num {\n" ++
            "  ret 1;\n" ++
            "}\n",
    );
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, helper_path) catch {};

    const input =
        "imp unused_import_public_function_helper;\n" ++
        "fun main() void {\n" ++
        "  _ = helper();\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};

    try std.testing.expect(res.warnings == null);
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

// ---------------------------------------------------------------------------
// unused_import false-positive regressions.
//
// `unused_import` previously fired even when the import WAS used, in three cases:
//   1. a type used only as a compound field type (never accessed in a body);
//   2. a C-binding doc module (std.c.def/limits) whose only "symbols" are
//      best-effort C macros hardcoded in the transpiler (NULL, INT_MAX, ...);
//   3. a re-export passthrough module (std.c.thread_windows) that declares
//      nothing and only forwards another import.
// Each test also guards the inverse (a genuinely unused import must still warn).
// ---------------------------------------------------------------------------

test "diagnostic: import used only as a compound field type is not unused" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_import_field_type.fn";

    // Map<str,str> is used only as a compound field; never accessed in a body.
    const input =
        "imp std.map;\n" ++
        "imp std.quirks;\n" ++
        "pub compound Holder {\n" ++
        "  Map<str, str> opts;\n" ++
        "}\n" ++
        "fun main() void {}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    if (res.warnings) |w| {
        try std.testing.expect(std.mem.indexOf(u8, w, "unused import 'std.map'") == null);
    }
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: an enum variant naming an imported type marks that import used" {
    const allocator = std.testing.allocator;
    const lib_path = "unused_import_enum_lib.fn";
    const ifilepath = "unused_import_enum_use.fn";

    // Regression: a file whose only mention of an imported enum is a variant
    // constant passed to a callee declared elsewhere was reported as not using
    // the import at all. The type name never appears in this file's own
    // declarations, so nothing else marked it.
    const lib_input =
        "imp std.io;\n" ++
        "pub fun take(Sink s) num {\n" ++
        "  _ = s;\n" ++
        "  ret 0;\n" ++
        "}\n";
    try writeTestFile(lib_path, lib_input);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, lib_path) catch {};

    const input =
        "imp unused_import_enum_lib;\n" ++
        "imp std.io;\n" ++
        "fun main() num {\n" ++
        "  ret take(Sink.Stdout);\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};

    if (res.warnings) |w| {
        try std.testing.expect(std.mem.indexOf(u8, w, "unused import 'std.io'") == null);
    }
}

test "diagnostic: an enum variant reached through an alias marks that import used" {
    const allocator = std.testing.allocator;
    const lib_path = "unused_import_alias_lib.fn";
    const ifilepath = "unused_import_alias_use.fn";

    // An aliased import is tracked by its alias, so marking the origin file
    // (which the unaliased path does) never reaches it.
    const lib_input =
        "imp std.io;\n" ++
        "pub fun take(Sink s) num {\n" ++
        "  _ = s;\n" ++
        "  ret 0;\n" ++
        "}\n";
    try writeTestFile(lib_path, lib_input);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, lib_path) catch {};

    const input =
        "imp unused_import_alias_lib;\n" ++
        "imp std.io as io;\n" ++
        "fun main() num {\n" ++
        "  ret take(io.Sink.Stdout);\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};

    if (res.warnings) |w| {
        try std.testing.expect(std.mem.indexOf(u8, w, "unused import") == null);
    }
}

test "diagnostic: genuinely unused std.map import still warns (false-negative guard)" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_import_map_unused.fn";

    // Imported but Map is never referenced anywhere.
    const input =
        "imp std.map;\n" ++
        "fun main() void {}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings != null);
    try std.testing.expect(std.mem.indexOf(u8, res.warnings.?, "unused import 'std.map'") != null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: std.c.def import used via NULL is not unused" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_import_cdef_used.fn";

    const input =
        "imp std.c.def;\n" ++
        "fun main() void {\n" ++
        "  raw* p = NULL;\n" ++
        "  _ = p;\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    if (res.warnings) |w| {
        try std.testing.expect(std.mem.indexOf(u8, w, "unused import 'std.c.def'") == null);
    }
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: std.c.limits import used via INT_MAX is not unused" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_import_climits_used.fn";

    const input =
        "imp std.c.limits;\n" ++
        "fun main() void {\n" ++
        "  num x = INT_MAX;\n" ++
        "  _ = x;\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    if (res.warnings) |w| {
        try std.testing.expect(std.mem.indexOf(u8, w, "unused import 'std.c.limits'") == null);
    }
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: genuinely unused std.c.def import still warns (false-negative guard)" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_import_cdef_unused.fn";

    // std.c.def imported but no def macro/type is used.
    const input =
        "imp std.c.def;\n" ++
        "fun main() void {\n" ++
        "  num x = 1;\n" ++
        "  _ = x;\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings != null);
    try std.testing.expect(std.mem.indexOf(u8, res.warnings.?, "unused import 'std.c.def'") != null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: re-export passthrough import (std.c.thread_windows) is not unused" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_import_reexport.fn";

    // std.c.thread_windows declares nothing of its own; it only re-exports
    // std.c.thread. Importing it is meaningful even with no own-name reference.
    const input =
        "imp std.c.thread_windows;\n" ++
        "fun main() void {}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    if (res.warnings) |w| {
        try std.testing.expect(std.mem.indexOf(u8, w, "unused import 'std.c.thread_windows'") == null);
    }
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: std.c.def import used via size_t type is not unused" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_import_cdef_sizet.fn";

    // size_t is a C typedef used in TYPE position (not a value). It resolves to a
    // numeric semantic type during parsing, so the import must still be marked
    // used via the typedef->module mapping in ensure_dtype_visible.
    const input =
        "imp std.c.def;\n" ++
        "fun main() void {\n" ++
        "  size_t n = 0;\n" ++
        "  n = n + 5;\n" ++
        "  _ = n;\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    if (res.warnings) |w| {
        try std.testing.expect(std.mem.indexOf(u8, w, "unused import 'std.c.def'") == null);
    }
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: std.c.time import used via time_t type is not unused" {
    const allocator = std.testing.allocator;
    const ifilepath = "unused_import_ctime_timet.fn";

    const input =
        "imp std.c.time;\n" ++
        "fun main() void {\n" ++
        "  time_t t = 0;\n" ++
        "  _ = t;\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    if (res.warnings) |w| {
        try std.testing.expect(std.mem.indexOf(u8, w, "unused import 'std.c.time'") == null);
    }
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: non-void function with no ret warns missing_return" {
    const allocator = std.testing.allocator;
    const ifilepath = "missing_return_none.fn";

    const input =
        "fun f(num x) num {\n" ++
        "  let y = x + 1;\n" ++
        "  _ = y;\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, false);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings != null);
    try std.testing.expect(std.mem.indexOf(u8, res.warnings.?, "without returning a value") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: ret only in if-branch warns missing_return" {
    const allocator = std.testing.allocator;
    const ifilepath = "missing_return_partial.fn";

    const input =
        "fun f(num x) num {\n" ++
        "  if x > 0 {\n" ++
        "    ret 1;\n" ++
        "  }\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, false);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings != null);
    try std.testing.expect(std.mem.indexOf(u8, res.warnings.?, "without returning a value") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: exhaustive if/else does not warn missing_return" {
    const allocator = std.testing.allocator;
    const ifilepath = "missing_return_ifelse_ok.fn";

    const input =
        "fun f(bin b) num {\n" ++
        "  if b {\n" ++
        "    ret 1;\n" ++
        "  } else {\n" ++
        "    ret 0;\n" ++
        "  }\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, false);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    if (res.warnings) |w| {
        try std.testing.expect(std.mem.indexOf(u8, w, "without returning a value") == null);
    }
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: infinite loop with ret does not warn missing_return" {
    const allocator = std.testing.allocator;
    const ifilepath = "missing_return_forloop_ok.fn";

    const input =
        "fun f(num x) num {\n" ++
        "  for true {\n" ++
        "    if x > 0 {\n" ++
        "      ret 1;\n" ++
        "    }\n" ++
        "    ret 0;\n" ++
        "  }\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, false);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    if (res.warnings) |w| {
        try std.testing.expect(std.mem.indexOf(u8, w, "without returning a value") == null);
    }
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: void function does not warn missing_return" {
    const allocator = std.testing.allocator;
    const ifilepath = "missing_return_void_ok.fn";

    const input =
        "fun f(num x) {\n" ++
        "  let y = x + 1;\n" ++
        "  _ = y;\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, false);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    if (res.warnings) |w| {
        try std.testing.expect(std.mem.indexOf(u8, w, "without returning a value") == null);
    }
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: allow missing_return suppresses warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "missing_return_allow.fn";

    const input =
        "fun f(num x) num {\n" ++
        "  allow missing_return, \"intentional fall-through for migration\";\n" ++
        "  let y = x + 1;\n" ++
        "  _ = y;\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, false);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    if (res.warnings) |w| {
        try std.testing.expect(std.mem.indexOf(u8, w, "without returning a value") == null);
    }
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: shared mutable capture across forked tasks warns (data race)" {
    const allocator = std.testing.allocator;
    const ifilepath = "conc_race_warn.fn";

    // `&counter` (a compound with no Mutex field) is forked into a mutating
    // async fn inside a loop -> unsynchronized shared mutable state race.
    const input =
        "compound Counter { num n; }\n" ++
        "async fun bump(Counter* c) { c.n = c.n + 1; }\n" ++
        "fun main() {\n" ++
        "  Counter counter;\n" ++
        "  counter.n = 0;\n" ++
        "  for i : 0..4 {\n" ++
        "    fork bump(&counter);\n" ++
        "  }\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings != null);
    try std.testing.expect(std.mem.indexOf(u8, res.warnings.?, "shared_mutable_capture_race") != null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: forking a Mutex-guarded compound does not warn" {
    const allocator = std.testing.allocator;
    const ifilepath = "conc_race_mutex_ok.fn";

    // A compound that carries a `Mutex` field is treated as self-synchronizing,
    // so sharing it across forked tasks must NOT warn.
    const input =
        "compound Mutex { num locked; }\n" ++
        "compound Safe { Mutex mu; num n; }\n" ++
        "async fun bump(Safe* s) { s.n = s.n + 1; }\n" ++
        "fun main() {\n" ++
        "  Safe s;\n" ++
        "  s.n = 0;\n" ++
        "  for i : 0..4 {\n" ++
        "    fork bump(&s);\n" ++
        "  }\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    if (res.warnings) |w| {
        try std.testing.expect(std.mem.indexOf(u8, w, "shared_mutable_capture_race") == null);
    }
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: read-only shared capture across forks does not warn" {
    const allocator = std.testing.allocator;
    const ifilepath = "conc_race_readonly_ok.fn";

    // The forked fn only READS through the pointer (no field write), so sharing
    // it is safe and must not warn.
    const input =
        "compound Counter { num n; }\n" ++
        "async fun peek(Counter* c) { let v = c.n; _ = v; }\n" ++
        "fun main() {\n" ++
        "  Counter counter;\n" ++
        "  counter.n = 0;\n" ++
        "  for i : 0..4 {\n" ++
        "    fork peek(&counter);\n" ++
        "  }\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    if (res.warnings) |w| {
        try std.testing.expect(std.mem.indexOf(u8, w, "shared_mutable_capture_race") == null);
    }
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: integer literal out of range for uN warns" {
    const allocator = std.testing.allocator;
    const ifilepath = "int_literal_range_warn.fn";

    // u2 holds 0..3; 5 overflows. Negative into unsigned and signed overflow too.
    const input =
        "fun main() {\n" ++
        "  u2 a = 5;\n" ++
        "  u8 b = -3;\n" ++
        "  i6 c = 100;\n" ++
        "  _ = a; _ = b; _ = c;\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings != null);
    try std.testing.expect(std.mem.indexOf(u8, res.warnings.?, "integer_literal_out_of_range") != null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: in-range integer literals for uN do not warn" {
    const allocator = std.testing.allocator;
    const ifilepath = "int_literal_range_ok.fn";

    // All within range: u8 0..255, i8 -128..127.
    const input =
        "fun main() {\n" ++
        "  u8 a = 200;\n" ++
        "  i8 b = -5;\n" ++
        "  u4 c = 15;\n" ++
        "  _ = a; _ = b; _ = c;\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    if (res.warnings) |w| {
        try std.testing.expect(std.mem.indexOf(u8, w, "integer_literal_out_of_range") == null);
    }
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: allow integer_literal_out_of_range suppresses the warning" {
    const allocator = std.testing.allocator;
    const ifilepath = "int_literal_range_allow.fn";

    const input =
        "fun main() {\n" ++
        "  allow integer_literal_out_of_range, \"intentional truncation\";\n" ++
        "  u2 a = 5;\n" ++
        "  _ = a;\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    if (res.warnings) |w| {
        try std.testing.expect(std.mem.indexOf(u8, w, "integer_literal_out_of_range") == null);
    }
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: blocking_fork_deadlock warns on wait_group_new(0) with fork-in-loop" {
    const allocator = std.testing.allocator;
    // Filename deliberately avoids the substring "blocking_fork_deadlock" --
    // it would otherwise appear in every warning's `Location:` line (the
    // filename is always printed), making the assertion below pass vacuously
    // regardless of which warning category actually fired.
    const ifilepath = "wg_zero_cap_no_add_warn.fn";

    // A WaitGroup created with a literal 0 (signal buffer capacity 1), never
    // grown via add(), that is done()'d from tasks forked in a loop is the
    // classic deadlock shape: the buffer stays clamped to capacity 1.
    const input =
        "imp std.task;\n" ++
        "imp std.io;\n" ++
        "async fun worker(WaitGroup* wg) {\n" ++
        "  defer wg.done();\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  WaitGroup wg = wait_group_new(0);\n" ++
        "  defer wg.destroy();\n" ++
        "  for i : 0..4 {\n" ++
        "    fork worker(&wg);\n" ++
        "  }\n" ++
        "  wg.wait();\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings != null);
    try std.testing.expect(std.mem.indexOf(u8, res.warnings.?, "[Warning:blocking_fork_deadlock]") != null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: blocking_fork_deadlock does NOT warn when add() grows the zero-cap WaitGroup" {
    const allocator = std.testing.allocator;
    const ifilepath = "wg_zero_cap_with_add_no_warn.fn";

    // Same zero-cap-in-a-fork-loop shape as above, but paired with add():
    // add() now grows the signalling channel to match, so this is no longer
    // the "clamped to capacity 1 forever" hazard the lint exists to catch.
    const input =
        "imp std.task;\n" ++
        "imp std.io;\n" ++
        "async fun worker(WaitGroup* wg) {\n" ++
        "  defer wg.done();\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  WaitGroup wg = wait_group_new(0);\n" ++
        "  defer wg.destroy();\n" ++
        "  for i : 0..4 {\n" ++
        "    wg.add(1);\n" ++
        "    fork worker(&wg);\n" ++
        "  }\n" ++
        "  wg.wait();\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    if (res.warnings) |w| {
        try std.testing.expect(std.mem.indexOf(u8, w, "[Warning:blocking_fork_deadlock]") == null);
    }
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: channel_capacity_overflow warns on over-send with no receiver" {
    const allocator = std.testing.allocator;
    const ifilepath = "channel_capacity_overflow_warn.fn";

    // 3 blocking sends into a capacity-1 channel with no receiver -> producer blocks.
    const input =
        "imp std.channel;\n" ++
        "imp std.io;\n" ++
        "fun main() {\n" ++
        "  let c = channel_new_cap(0, 1);\n" ++
        "  c <- 1;\n" ++
        "  c <- 2;\n" ++
        "  c <- 3;\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    try std.testing.expect(res.warnings != null);
    try std.testing.expect(std.mem.indexOf(u8, res.warnings.?, "channel_capacity_overflow") != null);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: channel within capacity does not warn" {
    const allocator = std.testing.allocator;
    const ifilepath = "channel_capacity_ok.fn";

    const input =
        "imp std.channel;\n" ++
        "imp std.io;\n" ++
        "fun main() {\n" ++
        "  let c = channel_new_cap(0, 4);\n" ++
        "  c <- 1;\n" ++
        "  c <- 2;\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    if (res.warnings) |w| {
        try std.testing.expect(std.mem.indexOf(u8, w, "channel_capacity_overflow") == null);
    }
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "diagnostic: over-send drained by a receive does not warn" {
    const allocator = std.testing.allocator;
    const ifilepath = "channel_capacity_drained_ok.fn";

    // Same channel is received-from, so the buffer drains -> no false positive.
    const input =
        "imp std.channel;\n" ++
        "imp std.io;\n" ++
        "fun main() {\n" ++
        "  let c = channel_new_cap(0, 1);\n" ++
        "  c <- 1;\n" ++
        "  let x = <- c;\n" ++
        "  c <- 2;\n" ++
        "  let y = <- c;\n" ++
        "  _ = x; _ = y;\n" ++
        "}\n";

    const res = try runTranspileWithWarnings(allocator, ifilepath, input, true);
    defer {
        allocator.free(res.out);
        if (res.warnings) |w| allocator.free(w);
    }

    if (res.warnings) |w| {
        try std.testing.expect(std.mem.indexOf(u8, w, "channel_capacity_overflow") == null);
    }
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}
