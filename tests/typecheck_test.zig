const std = @import("std");
const fs = std.fs;
const ParseProcess = @import("parser").ParseProcess;
const lexer = @import("lexer");
const codegen = @import("codegen");

fn runTranspileExpectError(allocator: std.mem.Allocator, input_path: []const u8, input: []const u8) !void {
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
        fs.cwd().deleteFile(input_path) catch {};
    }

    try lex_proc.lex();
    try parse_proc.parse();

    // Should error during transpile() due to typecheck.
    _ = transpile_proc.transpile() catch return;

    return error.ExpectedFailure;
}

fn runTranspileExpectOk(allocator: std.mem.Allocator, input_path: []const u8, input: []const u8) !void {
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
        fs.cwd().deleteFile(input_path) catch {};
    }

    try lex_proc.lex();
    try parse_proc.parse();
    try transpile_proc.transpile();
}

test "typecheck variable init mismatch" {
    const input =
        "fun main() {\n" ++
        "  num x = \"hi\";\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_init_mismatch.fn", input);
}

test "typecheck return mismatch" {
    const input =
        "fun foo() num {\n" ++
        "  ret true;\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_return_mismatch.fn", input);
}

test "typecheck call wrong arg count" {
    const input =
        "fun add(num a, num b) num { ret a + b; }\n" ++
        "fun main() {\n" ++
        "  num x = add(1);\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_arg_count.fn", input);
}

test "typecheck call arg type mismatch" {
    const input =
        "fun add(num a, num b) num { ret a + b; }\n" ++
        "fun main() {\n" ++
        "  num x = add(1, \"x\");\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_arg_type.fn", input);
}

test "typecheck if condition must be bin" {
    const input =
        "fun main() {\n" ++
        "  if 1 { ret; }\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_if_cond.fn", input);
}

test "typecheck comparisons produce bin and are allowed in if" {
    const input =
        "fun main() {\n" ++
        "  num n = 1;\n" ++
        "  if n == 1 { ret; }\n" ++
        "  if n != 2 { ret; }\n" ++
        "  if n <= 3 { ret; }\n" ++
        "  if n >= 0 { ret; }\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_if_cmp_ok.fn", input);
}

test "typecheck logical operators require bin operands" {
    const input =
        "fun main() {\n" ++
        "  bin a = true;\n" ++
        "  bin b = false;\n" ++
        "  if a && b { ret; }\n" ++
        "  if a || b { ret; }\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_if_logic_ok.fn", input);
}

test "typecheck heterogeneous array literal errors" {
    const input =
        "fun main() {\n" ++
        "  num[] arr = [1, \"x\"];\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_array_hetero.fn", input);
}
