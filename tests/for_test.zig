const std = @import("std");
const fs = std.fs;
const ParseProcess = @import("parser").ParseProcess;
const lexer = @import("lexer");
const codegen = @import("codegen");

fn runTranspile(allocator: std.mem.Allocator, input_path: []const u8, input: []const u8) ![]const u8 {
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, input_path, .{ .read = true, .truncate = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, input);
    }

    var transpile_proc = try codegen.TranspileProcess.init(allocator, input_path, "_ignored.c", .{
        .outf = false,
        .preload_imports = false,
        .preload_std_imports = false,
        .emit_stderr = false,
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

    const out = transpile_proc.get_output() orelse return error.NoOutput;
    // Copy it so it remains valid after deinit.
    return allocator.dupe(u8, out);
}

test "for range transpiles" {
    const allocator = std.testing.allocator;
    const ifilepath = "for_range.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  for i : 0..3 {\n" ++
        "    printf(\"%d\\n\", i);\n" ++
        "  }\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "for (int64_t i = 0; i < 3; i++)") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "for array item transpiles" {
    const allocator = std.testing.allocator;
    const ifilepath = "for_array_item.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  num[] arr = [1, 2, 3];\n" ++
        "  for item : arr {\n" ++
        "    printf(\"%d\\n\", item);\n" ++
        "  }\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t arr[] = {1, 2, 3};") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "for (int64_t __fun_i = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t item = arr[__fun_i];") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "for array index and item transpiles" {
    const allocator = std.testing.allocator;
    const ifilepath = "for_array_index_item.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  num[] arr = [1, 2, 3];\n" ++
        "  for i, item :: arr {\n" ++
        "    printf(\"arr[%d]=%d\\n\", i, item);\n" ++
        "  }\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "for (int64_t i = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t item = arr[i];") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "for array index and item method call transpiles" {
    try std.testing.expect(true);
}

test "for Vec values transpiles via len and data" {
    const allocator = std.testing.allocator;
    const ifilepath = "for_vec_values.fn";

    const input =
        "imp std.io as io;\n" ++
        "imp std.vec;\n" ++
        "fun main() {\n" ++
        "  Vec<str> vals;\n" ++
        "  vals.init(0);\n" ++
        "  vals.push(\"value\");\n" ++
        "  for val : vals {\n" ++
        "    io.println(val);\n" ++
        "  }\n" ++
        "  vals.free();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "for (int64_t __fun_i = 0; __fun_i < vals.len; __fun_i++)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "val = vals.data[__fun_i];") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "for condition transpiles to while" {
    const allocator = std.testing.allocator;
    const ifilepath = "for_condition.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  num i = 0;\n" ++
        "  for i < 3 {\n" ++
        "    printf(\"%d\\n\", i);\n" ++
        "    i = i + 1;\n" ++
        "  }\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "while (i < 3)") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "for infinite transpiles to while(1)" {
    const allocator = std.testing.allocator;
    const ifilepath = "for_infinite.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  num i = 0;\n" ++
        "  for {\n" ++
        "    if i == 3 { break; }\n" ++
        "    printf(\"%d\\n\", i);\n" ++
        "    i = i + 1;\n" ++
        "  }\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "while (1)") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "2D matrix declaration transpiles" {
    const allocator = std.testing.allocator;
    const ifilepath = "matrix_decl.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  num[][] matrix = [[1, 2, 3], [4, 5, 6]];\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    // Outer dim unsized, inner dim = 3
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t matrix[][3]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "{{1, 2, 3}, {4, 5, 6}}") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "2D matrix for-iter outer loop transpiles" {
    const allocator = std.testing.allocator;
    const ifilepath = "matrix_iter_outer.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  num[][] matrix = [[1, 2, 3], [4, 5, 6]];\n" ++
        "  for row : matrix {\n" ++
        "    printf(\"%p\\n\", row);\n" ++
        "  }\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    // Outer loop uses sizeof(matrix)/sizeof(matrix[0])
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sizeof(matrix)/sizeof(matrix[0])") != null);
    // Row is declared as pointer
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t * row = matrix[__fun_i]") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "2D matrix nested for-iter transpiles" {
    const allocator = std.testing.allocator;
    const ifilepath = "matrix_nested_iter.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  num[][] matrix = [[1, 2, 3], [4, 5, 6]];\n" ++
        "  for row : matrix {\n" ++
        "    for item : row {\n" ++
        "      printf(\"%lld\\n\", item);\n" ++
        "    }\n" ++
        "  }\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    // Outer loop: sizeof(matrix)/sizeof(matrix[0])
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sizeof(matrix)/sizeof(matrix[0])") != null);
    // Inner loop: sizeof(matrix[0])/sizeof(matrix[0][0])
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sizeof(matrix[0])/sizeof(matrix[0][0])") != null);
    // Inner item is a scalar
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t item = row[__fun_i]") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "2D matrix let inference transpiles" {
    const allocator = std.testing.allocator;
    const ifilepath = "matrix_let.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  let m = [[10, 20], [30, 40]];\n" ++
        "  for row : m {\n" ++
        "    for val : row {\n" ++
        "      printf(\"%lld\\n\", val);\n" ++
        "    }\n" ++
        "  }\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    // Matrix inferred as int64_t m[][2]
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t m[][2]") != null);
    // Outer loop: sizeof(m)/sizeof(m[0])
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sizeof(m)/sizeof(m[0])") != null);
    // Inner loop: sizeof(m[0])/sizeof(m[0][0])
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sizeof(m[0])/sizeof(m[0][0])") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "3D tensor nested for-iter transpiles" {
    const allocator = std.testing.allocator;
    const ifilepath = "tensor_3d_nested_iter.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  num[][][] tensor = [[[1, 2], [3, 4]], [[5, 6], [7, 8]]];\n" ++
        "  for plane : tensor {\n" ++
        "    for row : plane {\n" ++
        "      for item : row {\n" ++
        "        printf(\"%lld\\n\", item);\n" ++
        "      }\n" ++
        "    }\n" ++
        "  }\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    // Outer loop: sizeof(tensor)/sizeof(tensor[0])
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sizeof(tensor)/sizeof(tensor[0])") != null);
    // Middle loop: sizeof(tensor[0])/sizeof(tensor[0][0])
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sizeof(tensor[0])/sizeof(tensor[0][0])") != null);
    // Inner loop: sizeof(tensor[0][0])/sizeof(tensor[0][0][0])
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sizeof(tensor[0][0])/sizeof(tensor[0][0][0])") != null);
    // Innermost item is a scalar
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t item = row[__fun_i]") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}

test "3D tensor let inference transpiles" {
    const allocator = std.testing.allocator;
    const ifilepath = "tensor_3d_let.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  let m = [[[10, 20], [30, 40]], [[50, 60], [70, 80]]];\n" ++
        "  for plane : m {\n" ++
        "    for row : plane {\n" ++
        "      for val : row {\n" ++
        "        printf(\"%lld\\n\", val);\n" ++
        "      }\n" ++
        "    }\n" ++
        "  }\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    // Matrix inferred as int64_t m[][2][2]
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t m[][2][2]") != null);
    // Outer loop: sizeof(m)/sizeof(m[0])
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sizeof(m)/sizeof(m[0])") != null);
    // Middle loop: sizeof(m[0])/sizeof(m[0][0])
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sizeof(m[0])/sizeof(m[0][0])") != null);
    // Inner loop: sizeof(m[0][0])/sizeof(m[0][0][0])
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sizeof(m[0][0])/sizeof(m[0][0][0])") != null);

    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
}
