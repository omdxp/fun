const std = @import("std");
const cli = @import("cli");
const codegen = @import("codegen");
const lexer = @import("lexer");
const parser = @import("parser");

fn expectFileParses(allocator: std.mem.Allocator, path: []const u8) !void {
    var tp = try codegen.TranspileProcess.init(
        allocator,
        path,
        "__fmt_parse_unused__.c",
        .{ .exec = false, .outf = false, .ast = false },
    );
    defer tp.deinit();
    var lp = lexer.LexProcess.init(&tp);
    defer lp.deinit();
    var pp = parser.ParseProcess.init(&tp);

    try lp.lex();
    try pp.parse();
}

fn writeTempFnFile(allocator: std.mem.Allocator, prefix: []const u8, contents: []const u8) ![]const u8 {
    const ts = std.time.nanoTimestamp();
    const name = try std.fmt.allocPrint(allocator, "{s}_{d}.fn", .{ prefix, ts });
    errdefer allocator.free(name);

    const f = try std.fs.cwd().createFile(name, .{ .read = true });
    defer f.close();
    try f.writeAll(contents);
    return name;
}

fn makeTempDir(allocator: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    const ts = std.time.nanoTimestamp();
    const name = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ prefix, ts });
    errdefer allocator.free(name);
    try std.fs.cwd().makePath(name);
    return name;
}

fn writeFileInDir(allocator: std.mem.Allocator, dir: []const u8, rel: []const u8, contents: []const u8) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ dir, rel });
    errdefer allocator.free(path);

    if (std.fs.path.dirname(path)) |pdir| {
        try std.fs.cwd().makePath(pdir);
    }

    const f = try std.fs.cwd().createFile(path, .{ .read = true });
    defer f.close();
    try f.writeAll(contents);
    return path;
}

fn deleteTreeIfExists(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
}

test "-fmt formats file in-place" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun  add(num a,num b) num{ret a+b;}\n" ++
        "//comment\n" ++
        "if true{ret 1;}else{ret 2;}\n";

    const path = try writeTempFnFile(allocator, "fmt", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    const expected =
        "fun add(num a, num b) num {\n" ++
        "  ret a + b;\n" ++
        "}\n" ++
        "// comment\n" ++
        "if true {\n" ++
        "  ret 1;\n" ++
        "} else {\n" ++
        "  ret 2;\n" ++
        "}\n";

    try std.testing.expectEqualStrings(expected, got);
}

test "-fmt keeps a blank line between functions" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun a() num{ret 1;}fun b() num{ret 2;}\n";

    const path = try writeTempFnFile(allocator, "fmt_two", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    const expected =
        "fun a() num {\n" ++
        "  ret 1;\n" ++
        "}\n" ++
        "\n" ++
        "fun b() num {\n" ++
        "  ret 2;\n" ++
        "}\n";

    try std.testing.expectEqualStrings(expected, got);
}

test "-fmt preserves blank lines in function bodies" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun main() num{\n" ++
        "num x=1;\n" ++
        "\n" ++
        "num y=2;\n" ++
        "\n" ++
        "\n" ++
        "ret x+y;\n" ++
        "}\n";

    const path = try writeTempFnFile(allocator, "fmt_body_blank", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    // Preserve blank lines between statements (normalize 2+ newlines to a blank line).
    const expected =
        "fun main() num {\n" ++
        "  num x = 1;\n" ++
        "\n" ++
        "  num y = 2;\n" ++
        "\n" ++
        "  ret x + y;\n" ++
        "}\n";
    try std.testing.expectEqualStrings(expected, got);
}

test "-fmt preserves blank lines between top-level constructs" {
    const allocator = std.testing.allocator;

    const ugly =
        "compound A{num x;}\n" ++
        "\n" ++
        "quirk Q{f() num;}\n" ++
        "\n" ++
        "impl A as Q {f() num{ret self.x;}}\n" ++
        "\n" ++
        "fun main(){}\n";

    const path = try writeTempFnFile(allocator, "fmt_top_blank", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    const expected =
        "compound A {\n" ++
        "  num x;\n" ++
        "}\n" ++
        "\n" ++
        "quirk Q {\n" ++
        "  f() num;\n" ++
        "}\n" ++
        "\n" ++
        "impl A as Q {\n" ++
        "  f() num {\n" ++
        "    ret self.x;\n" ++
        "  }\n" ++
        "}\n" ++
        "\n" ++
        "fun main() {\n" ++
        "}\n";
    try std.testing.expectEqualStrings(expected, got);
}

test "-fmt formats pointer and address-of spacing" {
    const allocator = std.testing.allocator;

    const ugly =
        "compound User{raw* p;}\n" ++
        "fun main() void{User user;User * u2=& user;raw * buf=malloc(10);num x=1;num y=2;ret x*y;}\n";

    const path = try writeTempFnFile(allocator, "fmt_ptr", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    const expected =
        "compound User {\n" ++
        "  raw* p;\n" ++
        "}\n" ++
        "\n" ++
        "fun main() void {\n" ++
        "  User user;\n" ++
        "  User* u2 = &user;\n" ++
        "  raw* buf = malloc(10);\n" ++
        "  num x = 1;\n" ++
        "  num y = 2;\n" ++
        "  ret x * y;\n" ++
        "}\n";

    try std.testing.expectEqualStrings(expected, got);
}

test "-fmt groups imports and globals at top" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun main() num{ret 0;}\n" ++
        "imp std.c.io;\n" ++
        "num x=1;\n" ++
        "imp foo.bar;\n" ++
        "num y=2;\n";

    const path = try writeTempFnFile(allocator, "fmt_groups", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    const expected =
        "imp std.c.io;\n" ++
        "imp foo.bar;\n" ++
        "\n" ++
        "num x = 1;\n" ++
        "num y = 2;\n" ++
        "\n" ++
        "fun main() num {\n" ++
        "  ret 0;\n" ++
        "}\n";

    try std.testing.expectEqualStrings(expected, got);
}

test "-fmt formats parent traversal imports" {
    const allocator = std.testing.allocator;

    const ugly =
        "imp std.c.io;\n" ++
        "imp .. defs.user;\n" ++
        "imp ..  defs.greeter;\n" ++
        "imp .... defs.greeter;\n" ++
        "fun main() void{ }\n";

    const path = try writeTempFnFile(allocator, "fmt_imp_parent", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    const expected =
        "imp std.c.io;\n" ++
        "imp ..defs.user;\n" ++
        "imp ..defs.greeter;\n" ++
        "imp ....defs.greeter;\n" ++
        "\n" ++
        "fun main() void {\n" ++
        "}\n";

    try std.testing.expectEqualStrings(expected, got);
}

test "-fmt formats lowercase type pointers in signatures" {
    const allocator = std.testing.allocator;

    const ugly =
        "compound tm{num tm_sec;}\n" ++
        "fun mktime(tm * t) num;\n" ++
        "fun gmtime(num* timep) tm *;\n";

    const path = try writeTempFnFile(allocator, "fmt_tm_ptr", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    const expected =
        "compound tm {\n" ++
        "  num tm_sec;\n" ++
        "}\n" ++
        "\n" ++
        "fun mktime(tm* t) num;\n" ++
        "fun gmtime(num* timep) tm*;\n";

    try std.testing.expectEqualStrings(expected, got);
}

test "-fmt keeps generic pointer signatures glued" {
    const allocator = std.testing.allocator;

    const ugly =
        "compound Box<T>{T value;}\n" ++
        "fun get(Box<num> * p) num;\n" ++
        "fun put(Box<num>* p,num v) num;\n";

    const path = try writeTempFnFile(allocator, "fmt_generic_ptr", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    const expected =
        "compound Box<T> {\n" ++
        "  T value;\n" ++
        "}\n" ++
        "\n" ++
        "fun get(Box<num>* p) num;\n" ++
        "fun put(Box<num>* p, num v) num;\n";

    try std.testing.expectEqualStrings(expected, got);
    try expectFileParses(allocator, path);
}

test "-fmt keeps generic compound literals tight after ret" {
    const allocator = std.testing.allocator;

    const ugly =
        "compound Box<T>{T v;}\n" ++
        "fun pack(Box<num> q) Box<num>{ret Box < num >{v = q};}\n";

    const path = try writeTempFnFile(allocator, "fmt_generic_compound_ret", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    const expected =
        "compound Box<T> {\n" ++
        "  T v;\n" ++
        "}\n" ++
        "\n" ++
        "fun pack(Box<num> q) Box<num> {\n" ++
        "  ret Box<num>{v = q};\n" ++
        "}\n";

    try std.testing.expectEqualStrings(expected, got);
    try expectFileParses(allocator, path);
}

test "-fmt keeps space after await before parenthesized receiver" {
    const allocator = std.testing.allocator;

    const ugly =
        "compound Box{num v;}\n" ++
        "fun pack(Box q) Box{ret q;}\n" ++
        "async fun f() num{Box q;num out=await(pack(q)).v;ret out;}\n";

    const path = try writeTempFnFile(allocator, "fmt_await_paren", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    const expected =
        "compound Box {\n" ++
        "  num v;\n" ++
        "}\n" ++
        "\n" ++
        "fun pack(Box q) Box {\n" ++
        "  ret q;\n" ++
        "}\n" ++
        "async fun f() num {\n" ++
        "  Box q;\n" ++
        "  num out = await (pack(q)).v;\n" ++
        "  ret out;\n" ++
        "}\n";

    try std.testing.expectEqualStrings(expected, got);
    try expectFileParses(allocator, path);
}

test "-fmt keeps pointer-to-pointer spacing and assignment spacing" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun use(raw **args) num{raw** local=args;ret 0;}\n";

    const path = try writeTempFnFile(allocator, "fmt_ptr_ptr", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    const expected =
        "fun use(raw** args) num {\n" ++
        "  raw** local = args;\n" ++
        "  ret 0;\n" ++
        "}\n";

    try std.testing.expectEqualStrings(expected, got);
    try expectFileParses(allocator, path);
}

test "-fmt-all formats local imports recursively (skips std.*)" {
    const allocator = std.testing.allocator;

    const dir = try makeTempDir(allocator, "fmt_all");
    defer {
        deleteTreeIfExists(dir);
        allocator.free(dir);
    }

    // main.fn imports a local module and std.io (std import should be skipped).
    const main_path = try writeFileInDir(
        allocator,
        dir,
        "main.fn",
        "imp foo.bar; imp std.c.io; fun  main() num{ret 0;}\n",
    );
    defer allocator.free(main_path);

    const imported_path = try writeFileInDir(
        allocator,
        dir,
        "foo/bar.fn",
        "fun  add(num a,num b) num{ret a+b;}\n",
    );
    defer allocator.free(imported_path);

    try cli.format_file_and_imports_in_place(allocator, main_path);

    const got_main = try std.fs.cwd().readFileAlloc(allocator, main_path, 1024 * 1024);
    defer allocator.free(got_main);
    try std.testing.expect(std.mem.indexOf(u8, got_main, "imp foo.bar;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got_main, "imp std.c.io;\n") != null);

    const got_import = try std.fs.cwd().readFileAlloc(allocator, imported_path, 1024 * 1024);
    defer allocator.free(got_import);
    const expected_imported =
        "fun add(num a, num b) num {\n" ++
        "  ret a + b;\n" ++
        "}\n";
    try std.testing.expectEqualStrings(expected_imported, got_import);
}

test "-fmt output still parses (quirks/ops)" {
    const allocator = std.testing.allocator;

    const ugly =
        "imp std.c.io;\n" ++
        "compound Point{num x;num y;}\n" ++
        "quirk Shape{area() num;translate(num dx,num dy);}\n" ++
        "compound Rectangle{Point a;Point b;}\n" ++
        "impl Rectangle as Shape {area() num{num w=self.b.x-self.a.x;num h=self.b.y-self.a.y;ret w*h;}translate(num dx,num dy){self.a.x+=dx;self.a.y+=dy;}}\n" ++
        "fun main(){Rectangle r;Shape s=&r;printf(\"%d\\n\",s.area());}\n";

    const path = try writeTempFnFile(allocator, "fmt_parse", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);
    try expectFileParses(allocator, path);
}

test "-fmt removes if-condition parentheses" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun main() num{\n" ++
        "num x=1;\n" ++
        "if(x<0){ret 0;}\n" ++
        "if((x<0)||(x>10)){ret 1;}\n" ++
        "ret 2;\n" ++
        "}\n";

    const path = try writeTempFnFile(allocator, "fmt_if_paren", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    // Outer parens are removed; ensure a space after `if`.
    // Inner parens may remain for grouping in complex conditions.
    try std.testing.expect(std.mem.indexOf(u8, got, "if(") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "if x") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "||") != null);
}

test "-fmt keeps parentheses for single-statement if" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun main() num{\n" ++
        "num w=1;\n" ++
        "if w < 0 w = -w;\n" ++
        "ret 0;\n" ++
        "}\n";

    const path = try writeTempFnFile(allocator, "fmt_if_single_stmt", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);
    try expectFileParses(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "if (") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, ") w") != null);
}

test "-fmt never introduces scientific notation" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun main() num{\n" ++
        "ret 3.14159;\n" ++
        "}\n";

    const path = try writeTempFnFile(allocator, "fmt_float", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "3.14159") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "3.14159e") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "3.14159E") == null);
}

test "-fmt preserves explicit decimal literal spelling" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun main() {\n" ++
        "\tlet a = [1.0, 2.00, 3.0];\n" ++
        "\tlet b = 42.0;\n" ++
        "}\n";

    const path = try writeTempFnFile(allocator, "fmt_dec_spell", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);
    try expectFileParses(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "[1.0, 2.00, 3.0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "42.0") != null);
}

test "-fmt preserves explicit decimal literal spelling broadly" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun main() dec {\n" ++
        "\tlet x = 3.0 + 4.00;\n" ++
        "\tlet y = (10.0/2.00) * 1.50;\n" ++
        "\tret x + y + 0.0;\n" ++
        "}\n";

    const path = try writeTempFnFile(allocator, "fmt_dec_spell_broad", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);
    try expectFileParses(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "3.0 + 4.00") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "10.0 / 2.00") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "* 1.50") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "+ 0.0") != null);
}

test "-fmt-all has cycle protection" {
    const allocator = std.testing.allocator;

    const dir = try makeTempDir(allocator, "fmt_cycle");
    defer {
        deleteTreeIfExists(dir);
        allocator.free(dir);
    }

    const a_path = try writeFileInDir(
        allocator,
        dir,
        "a.fn",
        "imp b; fun a() num{ret 1;}\n",
    );
    defer allocator.free(a_path);

    const b_path = try writeFileInDir(
        allocator,
        dir,
        "b.fn",
        "imp a; fun b() num{ret 2;}\n",
    );
    defer allocator.free(b_path);

    try cli.format_file_and_imports_in_place(allocator, a_path);

    const got_a = try std.fs.cwd().readFileAlloc(allocator, a_path, 1024 * 1024);
    defer allocator.free(got_a);
    try std.testing.expect(std.mem.indexOf(u8, got_a, "fun a() num") != null);

    const got_b = try std.fs.cwd().readFileAlloc(allocator, b_path, 1024 * 1024);
    defer allocator.free(got_b);
    try std.testing.expect(std.mem.indexOf(u8, got_b, "fun b() num") != null);
}

test "-fmt keeps space after ret before unary reference" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun bad() num*{num x=123;ret&x;}\n";

    const path = try writeTempFnFile(allocator, "fmt_ret_ref", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    const expected =
        "fun bad() num* {\n" ++
        "  num x = 123;\n" ++
        "  ret &x;\n" ++
        "}\n";

    try std.testing.expectEqualStrings(expected, got);
}

test "-fmt keeps space before unary minus after comparisons" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun f(num x) bin{if x<=-1000000000{ret true;}ret false;}\n";

    const path = try writeTempFnFile(allocator, "fmt_cmp_unary_minus", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    const expected =
        "fun f(num x) bin {\n" ++
        "  if x <= -1000000000 {\n" ++
        "    ret true;\n" ++
        "  }\n" ++
        "  ret false;\n" ++
        "}\n";

    try std.testing.expectEqualStrings(expected, got);
    try expectFileParses(allocator, path);
}

test "-fmt nested generics keep closing brackets tight" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun f() Result<Vec<str>>{Result<Vec<str>> r;ret r;}\n";

    const path = try writeTempFnFile(allocator, "fmt_generic_close", ugly);
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, path);

    const got = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "Result<Vec<str>>") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "Result<Vec<str >>") == null);
}
