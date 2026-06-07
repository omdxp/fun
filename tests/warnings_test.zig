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
