const std = @import("std");
const fs = std.fs;
const ParseProcess = @import("parser").ParseProcess;
const lexer = @import("lexer");
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

test "for range transpiles" {
    const allocator = std.testing.allocator;
    const ifilepath = "for_range.fn";

    const input =
        "imp std.io;\n" ++
        "fun main() {\n" ++
        "  for i : 0..3 {\n" ++
        "    printf(\"%d\\n\", i);\n" ++
        "  }\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "for (int i = 0; i < 3; i++)") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "for array item transpiles" {
    const allocator = std.testing.allocator;
    const ifilepath = "for_array_item.fn";

    const input =
        "imp std.io;\n" ++
        "fun main() {\n" ++
        "  num[] arr = [1, 2, 3];\n" ++
        "  for item : arr {\n" ++
        "    printf(\"%d\\n\", item);\n" ++
        "  }\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int arr[] = {1, 2, 3};") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "for (int __fun_i = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int item = arr[__fun_i];") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "for array index and item transpiles" {
    const allocator = std.testing.allocator;
    const ifilepath = "for_array_index_item.fn";

    const input =
        "imp std.io;\n" ++
        "fun main() {\n" ++
        "  num[] arr = [1, 2, 3];\n" ++
        "  for i, item :: arr {\n" ++
        "    printf(\"arr[%d]=%d\\n\", i, item);\n" ++
        "  }\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "for (int i = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int item = arr[i];") != null);

    try fs.cwd().deleteFile(ifilepath);
}
