const std = @import("std");
const fs = std.fs;
const lexer = @import("lexer");
const ParseProcess = @import("parser").ParseProcess;
const codegen = @import("codegen");

fn runTranspile(allocator: std.mem.Allocator, input_path: []const u8, input: []const u8) ![]const u8 {
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
    // Copy it so it remains valid after deinit.
    return allocator.dupe(u8, out);
}

test "if/elif/else transpiles" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_if_elif_else.fn";

    const input =
        "imp std.io;\n" ++
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

    try fs.cwd().deleteFile(ifilepath);
}

test "array indexing expression transpiles" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_index.fn";

    const input =
        "imp std.io;\n" ++
        "fun main() {\n" ++
        "  num[] arr = [1, 2, 3];\n" ++
        "  num x = arr[1];\n" ++
        "  printf(\"%d\\n\", x);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int arr[] = {1, 2, 3};") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "arr[1]") != null);

    try fs.cwd().deleteFile(ifilepath);
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

    try fs.cwd().deleteFile(ifilepath);
}
