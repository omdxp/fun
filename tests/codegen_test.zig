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

test "compounds + quirks + impl vtables transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_quirk_vtable.fn";

    const input =
        "compound Point { num x; num y; }\n" ++
        "quirk HasX { getX() num; }\n" ++
        "impl Point HasX {\n" ++
        "  getX() num { ret self.x; }\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  Point p;\n" ++
        "  p.x = 1;\n" ++
        "  HasX h = &p;\n" ++
        "  h = &p;\n" ++
        "  num v = h.getX();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "typedef struct Point") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int x;") != null);

    // Canonical quirk types and impl helpers use hashed names.
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "__fun_quirk_") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "_vtable") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "__fun_coerce_Point_") != null);

    // Coercion and dispatch.
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "HasX h = __fun_coerce_Point_") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "h = __fun_coerce_Point_") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "h.vtable->getX") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "h.self") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "pointer field access uses arrow" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_compound_ptr_field.fn";

    const input =
        "compound Point { num x; }\n" ++
        "fun main() {\n" ++
        "  Point p;\n" ++
        "  Point* pp = &p;\n" ++
        "  pp.x = 1;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "pp->x") != null);

    try fs.cwd().deleteFile(ifilepath);
}

fn extractFirstQuirkBaseName(out: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, out, "typedef struct __fun_quirk_") orelse return null;
    const sub = out[start..];
    const base_start = std.mem.indexOf(u8, sub, "__fun_quirk_") orelse return null;
    const after_prefix = sub[base_start..];
    const vtable_idx = std.mem.indexOf(u8, after_prefix, "_vtable") orelse return null;
    return after_prefix[0..vtable_idx];
}

test "structural quirks share canonical C type" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_quirk_structural_equiv.fn";

    const input =
        "compound Point { num x; }\n" ++
        "quirk Q1 { getX() num; }\n" ++
        "quirk Q2 { getX() num; }\n" ++
        "impl Point Q1 { getX() num { ret self.x; } }\n" ++
        "fun main() {\n" ++
        "  Point p;\n" ++
        "  Q1 a = &p;\n" ++
        "  Q2 b = &p;\n" ++
        "  num x = a.getX();\n" ++
        "  num y = b.getX();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    const base = extractFirstQuirkBaseName(out_owned) orelse return error.TestExpectedQuirkType;

    const q1_typedef = try std.fmt.allocPrint(allocator, "typedef {s} Q1;", .{base});
    defer allocator.free(q1_typedef);
    const q2_typedef = try std.fmt.allocPrint(allocator, "typedef {s} Q2;", .{base});
    defer allocator.free(q2_typedef);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, q1_typedef) != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, q2_typedef) != null);

    // Both should coerce via the same impl key (signature-canonicalized).
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Q1 a = __fun_coerce_Point_") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Q2 b = __fun_coerce_Point_") != null);

    // Both should dispatch through the same canonical vtable/object shape.
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "a.vtable->getX") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "b.vtable->getX") != null);

    try fs.cwd().deleteFile(ifilepath);
}
