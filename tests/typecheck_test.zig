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

test "typecheck call with two args ok" {
    const input =
        "fun add(num a, num b) num { ret a + b; }\n" ++
        "fun main() {\n" ++
        "  num x = add(1, 2);\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_arg_ok.fn", input);
}

test "typecheck enum dot shorthand in init/assign/compare" {
    const input =
        "enum Color {\n" ++
        "  Red;\n" ++
        "  Green;\n" ++
        "  Blue;\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  Color c = .Blue;\n" ++
        "  if c == .Blue {\n" ++
        "    c = .Green;\n" ++
        "  }\n" ++
        "  if c != .Red { ret; }\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_enum_dot_shorthand_ops.fn", input);
}

test "typecheck enum dot shorthand in call args" {
    const input =
        "enum Color {\n" ++
        "  Red;\n" ++
        "  Green;\n" ++
        "  Blue;\n" ++
        "}\n" ++
        "fun takes(Color c) {\n" ++
        "  ret;\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  takes(.Red);\n" ++
        "  takes(.Blue);\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_enum_dot_shorthand_call.fn", input);
}

test "typecheck variadic call allows extra args" {
    const input =
        "fun v(num a, ...) num { ret a; }\n" ++
        "fun main() {\n" ++
        "  num x = v(1, 2, 3);\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_variadic_ok.fn", input);
}

test "typecheck variadic call requires fixed args" {
    const input =
        "fun v(num a, ...) num { ret a; }\n" ++
        "fun main() {\n" ++
        "  num x = v();\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_variadic_too_few.fn", input);
}

test "typecheck variadic extra args still validated" {
    const input =
        "compound User {\n" ++
        "  num age;\n" ++
        "}\n" ++
        "fun v(num a, ...) num { ret a; }\n" ++
        "fun main() {\n" ++
        "  User user;\n" ++
        "  num x = v(1, user.missing);\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_variadic_extra_expr_validated.fn", input);
}

test "typecheck extern call args still validated" {
    const input =
        "compound User {\n" ++
        "  num age;\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  User user;\n" ++
        // `printf` is treated as a known extern even without an import/signature.
        "  printf(\"%d\\n\", user.missing);\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_extern_call_args_validated.fn", input);
}

test "typecheck sizeof builtin ok" {
    const input =
        "compound User {\n" ++
        "  num age;\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  num s = sizeof(User);\n" ++
        "  if s == 0 { ret; }\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_sizeof_ok.fn", input);
}

test "typecheck sizeof rejects non-type operand" {
    const input =
        "fun main() {\n" ++
        "  num s = sizeof(1);\n" ++
        "  ret;\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_sizeof_bad_operand.fn", input);
}

test "pub allows access across modules" {
    const lib_input =
        "pub compound PubType { num x; }\n" ++
        "pub fun pubFn() num { ret 1; }\n" ++
        "impl PubType {\n" ++
        "  pub get() num { ret self.x; }\n" ++
        "}\n";

    const lib_path = "typecheck_pub_lib.fn";
    {
        const file = try fs.cwd().createFile(lib_path, .{ .read = true });
        defer file.close();
        try file.writeAll(lib_input);
    }
    defer fs.cwd().deleteFile(lib_path) catch {};

    const input =
        "imp typecheck_pub_lib;\n" ++
        "fun main() {\n" ++
        "  PubType p;\n" ++
        "  p.x = 1;\n" ++
        "  num a = pubFn();\n" ++
        "  p.get();\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_pub_access.fn", input);
}

test "private declarations are not visible across modules" {
    const lib_input =
        "compound PrivType { num x; }\n" ++
        "fun privFn() num { ret 1; }\n" ++
        "impl PrivType {\n" ++
        "  get() num { ret self.x; }\n" ++
        "}\n";

    const lib_path = "typecheck_priv_lib.fn";
    {
        const file = try fs.cwd().createFile(lib_path, .{ .read = true });
        defer file.close();
        try file.writeAll(lib_input);
    }
    defer fs.cwd().deleteFile(lib_path) catch {};

    const input =
        "imp typecheck_priv_lib;\n" ++
        "fun main() {\n" ++
        "  PrivType p;\n" ++
        "  p.x = 1;\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_priv_access.fn", input);
}

test "typecheck missing field errors in plain impl body" {
    const input =
        "compound User {\n" ++
        "  num age;\n" ++
        "}\n" ++
        "impl User {\n" ++
        "  greet() {\n" ++
        "    num x = self.missing;\n" ++
        "    ret;\n" ++
        "  }\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  User u;\n" ++
        "  u.greet();\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_impl_missing_field.fn", input);
}

test "typecheck missing field errors in quirk impl body" {
    const input =
        "quirk Display {\n" ++
        "  show();\n" ++
        "}\n" ++
        "compound Data {\n" ++
        "  num id;\n" ++
        "}\n" ++
        "impl Data Display {\n" ++
        "  show() {\n" ++
        "    num x = self.missing;\n" ++
        "    ret;\n" ++
        "  }\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  Data d;\n" ++
        "  d.id = 1;\n" ++
        "  d.show();\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_quirk_impl_missing_field.fn", input);
}

test "typecheck zero-arg call ok" {
    const input =
        "fun foo() num { ret 1; }\n" ++
        "fun main() {\n" ++
        "  num x = foo();\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_zero_arg_call_ok.fn", input);
}

test "typecheck unknown function call errors" {
    const input =
        "fun main() {\n" ++
        "  missing();\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_unknown_fn_call.fn", input);
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

test "typecheck dec widening and promotion" {
    const input_ok =
        "fun add(dec a, dec b) dec { ret a + b; }\n" ++
        "fun main() {\n" ++
        "  dec x = 1;\n" ++
        "  dec y = 2.5;\n" ++
        "  dec z = x + y;\n" ++
        "  dec w = add(1, 2.0);\n" ++
        "  if 1.5 < 2 { ret; }\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_dec_ok.fn", input_ok);

    const input_err_narrow =
        "fun main() {\n" ++
        "  num x = 1.5;\n" ++
        "}\n";
    try runTranspileExpectError(std.testing.allocator, "typecheck_dec_narrow_err.fn", input_err_narrow);
}

test "typecheck dec modulo disallowed" {
    const input =
        "fun main() {\n" ++
        "  dec x = 5.0 % 2.0;\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_dec_mod_err.fn", input);
}

test "typecheck chr literal and variable" {
    const input =
        "fun main() {\n" ++
        "  chr c = 'A';\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_chr_ok.fn", input);
}

test "typecheck compound field access ok" {
    const input =
        "compound Point {\n" ++
        "  num x, y;\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  Point p;\n" ++
        "  num a = p.x;\n" ++
        "  ret;\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_compound_field_ok.fn", input);
}

test "typecheck compound field missing errors" {
    const input =
        "compound Point {\n" ++
        "  num x;\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  Point p;\n" ++
        "  num a = p.y;\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_compound_field_missing.fn", input);
}

test "typecheck quirk method call ok" {
    const input =
        "quirk HasX {\n" ++
        "  getX() num;\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  HasX h;\n" ++
        "  num a = h.getX();\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_quirk_method_ok.fn", input);
}

test "typecheck quirk coercion from impl ok" {
    const input =
        "compound Point {\n" ++
        "  num x;\n" ++
        "}\n" ++
        "quirk HasX {\n" ++
        "  getX() num;\n" ++
        "}\n" ++
        "impl Point HasX {\n" ++
        "  getX() num {\n" ++
        "    ret self.x;\n" ++
        "  }\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  Point p;\n" ++
        "  HasX h = &p;\n" ++
        "  num a = h.getX();\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_quirk_coerce_ok.fn", input);
}

test "typecheck concrete can call quirk impl method" {
    const input =
        "compound Point {\n" ++
        "  num x;\n" ++
        "}\n" ++
        "quirk HasX {\n" ++
        "  getX() num;\n" ++
        "}\n" ++
        "impl Point HasX {\n" ++
        "  getX() num {\n" ++
        "    ret self.x;\n" ++
        "  }\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  Point p;\n" ++
        "  p.x = 7;\n" ++
        "  num a = p.getX();\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_concrete_quirk_method_ok.fn", input);
}

test "typecheck quirk method arg type mismatch errors" {
    const input =
        "quirk Q {\n" ++
        "  foo(num a) void;\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  Q q;\n" ++
        "  q.foo(\"hi\");\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_quirk_method_arg_mismatch.fn", input);
}

test "typecheck quirk impl missing methods errors" {
    const input =
        "compound Point { num x; }\n" ++
        "quirk Q {\n" ++
        "  a() num;\n" ++
        "  b(num x) num;\n" ++
        "}\n" ++
        "impl Point Q {\n" ++
        "  a() num { ret 1; }\n" ++
        "}\n";
    try runTranspileExpectError(std.testing.allocator, "typecheck_quirk_impl_missing_methods.fn", input);
}
