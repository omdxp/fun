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
    const ts = std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds;
    const name = try std.fmt.allocPrint(allocator, "{s}_{d}.fn", .{ prefix, ts });
    errdefer allocator.free(name);

    const f = try std.Io.Dir.cwd().createFile(std.testing.io, name, .{ .read = true });
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, contents);
    return name;
}

fn makeTempDir(allocator: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    const ts = std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds;
    const name = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ prefix, ts });
    errdefer allocator.free(name);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, name);
    return name;
}

fn writeFileInDir(allocator: std.mem.Allocator, dir: []const u8, rel: []const u8, contents: []const u8) ![]const u8 {
    const normalized_rel = try std.mem.replaceOwned(u8, allocator, rel, "/", std.fs.path.sep_str);
    defer allocator.free(normalized_rel);

    const path = try std.fs.path.join(allocator, &.{ dir, normalized_rel });
    errdefer allocator.free(path);

    if (std.fs.path.dirname(path)) |pdir| {
        try std.Io.Dir.cwd().createDirPath(std.testing.io, pdir);
    }

    const f = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .read = true });
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, contents);
    return path;
}

fn deleteTreeIfExists(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(std.testing.io, path) catch {};
}

test "-fmt formats file in-place" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun  add(num a,num b) num{ret a+b;}\n" ++
        "//comment\n" ++
        "if true{ret 1;}else{ret 2;}\n";

    const path = try writeTempFnFile(allocator, "fmt", ugly);
    defer {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
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
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
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
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
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
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
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
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
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
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
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

test "-fmt keeps unused warning controls attached to grouped imports and globals" {
    const allocator = std.testing.allocator;

    const ugly =
        "allow unused_import, \"keep attached\";\n" ++
        "imp std.option;\n" ++
        "allow unused_variable, \"keep attached\";\n" ++
        "num value=1;\n" ++
        "fun main(){}\n";

    const path = try writeTempFnFile(allocator, "fmt_warning_ctrl_groups", ugly);
    defer {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(got);

    const expected =
        "allow unused_import, \"keep attached\";\n" ++
        "imp std.option;\n" ++
        "\n" ++
        "allow unused_variable, \"keep attached\";\n" ++
        "num value = 1;\n" ++
        "\n" ++
        "fun main() {\n" ++
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
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
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
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
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
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
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
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
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
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
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
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
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

    try cli.format_file_and_imports_in_place(allocator, std.testing.io, main_path);

    const got_main = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, main_path, allocator, .limited(1024 * 1024));
    defer allocator.free(got_main);
    try std.testing.expect(std.mem.indexOf(u8, got_main, "imp foo.bar;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got_main, "imp std.c.io;\n") != null);

    const got_import = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, imported_path, allocator, .limited(1024 * 1024));
    defer allocator.free(got_import);
    const expected_imported =
        "fun add(num a, num b) num {\n" ++
        "  ret a + b;\n" ++
        "}\n";
    try std.testing.expectEqualStrings(expected_imported, got_import);
}

test "-fmt-check-all finds unformatted files recursively and skips generated dirs" {
    const allocator = std.testing.allocator;

    const dir = try makeTempDir(allocator, "fmt_check_all");
    defer {
        deleteTreeIfExists(dir);
        allocator.free(dir);
    }

    const formatted_path = try writeFileInDir(
        allocator,
        dir,
        "src/good.fn",
        "fun good() num {\n  ret 1;\n}\n",
    );
    defer allocator.free(formatted_path);

    const bad_path = try writeFileInDir(
        allocator,
        dir,
        "src/bad.fn",
        "fun  bad() num{ret 2;}\n",
    );
    defer allocator.free(bad_path);

    const nested_bad_path = try writeFileInDir(
        allocator,
        dir,
        "src/nested/worse.fn",
        "fun  worse() num{ret 3;}\n",
    );
    defer allocator.free(nested_bad_path);

    const ignored_build_path = try writeFileInDir(
        allocator,
        dir,
        "build/ignored.fn",
        "fun  ignored() num{ret 0;}\n",
    );
    defer allocator.free(ignored_build_path);

    const offenders = try cli.collect_unformatted_fun_files(allocator, std.testing.io, dir);
    defer cli.free_owned_paths(allocator, offenders);

    try std.testing.expectEqual(@as(usize, 2), offenders.len);
    try std.testing.expectEqualStrings(bad_path, offenders[0]);
    try std.testing.expectEqualStrings(nested_bad_path, offenders[1]);
}

test "-fmt-check-all uses a file input as the scan root parent" {
    const allocator = std.testing.allocator;

    const dir = try makeTempDir(allocator, "fmt_check_all_parent");
    defer {
        deleteTreeIfExists(dir);
        allocator.free(dir);
    }

    const main_path = try writeFileInDir(
        allocator,
        dir,
        "app/main.fn",
        "fun main() num {\n  ret 0;\n}\n",
    );
    defer allocator.free(main_path);

    const bad_path = try writeFileInDir(
        allocator,
        dir,
        "app/features/bad.fn",
        "fun  bad() num{ret 1;}\n",
    );
    defer allocator.free(bad_path);

    const offenders = try cli.collect_unformatted_fun_files(allocator, std.testing.io, main_path);
    defer cli.free_owned_paths(allocator, offenders);

    try std.testing.expectEqual(@as(usize, 1), offenders.len);
    try std.testing.expectEqualStrings(bad_path, offenders[0]);
}

test "-fmt preserves indexed for-range loop syntax" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun main(){let a=[1,2,3];for i,item :: a {println_fmt(\"%d %d\",i,item);}}\n";

    const path = try writeTempFnFile(allocator, "fmt_for_indexed", ugly);
    defer {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(got);

    const expected =
        "fun main() {\n" ++
        "  let a = [1, 2, 3];\n" ++
        "  for i, item :: a {\n" ++
        "    println_fmt(\"%d %d\", i, item);\n" ++
        "  }\n" ++
        "}\n";

    try std.testing.expectEqualStrings(expected, got);
}

test "-fmt preserves single-variable for-range loop syntax" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun main(){let items=[1,2,3];for i : items {println_fmt(\"%d\",i);}}\n";

    const path = try writeTempFnFile(allocator, "fmt_for_single", ugly);
    defer {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(got);

    const expected =
        "fun main() {\n" ++
        "  let items = [1, 2, 3];\n" ++
        "  for i : items {\n" ++
        "    println_fmt(\"%d\", i);\n" ++
        "  }\n" ++
        "}\n";

    try std.testing.expectEqualStrings(expected, got);
}

test "-fmt formats nested blocks with comment lines" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun main(){\n" ++
        "{\n" ++
        "defer println(\"done\");\n" ++
        "//comment about the block\n" ++
        "num value=1;\n" ++
        "println_fmt(\"%d\",value);\n" ++
        "}\n" ++
        "}\n";

    const path = try writeTempFnFile(allocator, "fmt_nested_block", ugly);
    defer {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(got);

    const expected =
        "fun main() {\n" ++
        "  {\n" ++
        "    defer println(\"done\");\n" ++
        "    // comment about the block\n" ++
        "    num value = 1;\n" ++
        "    println_fmt(\"%d\", value);\n" ++
        "  }\n" ++
        "}\n";

    try std.testing.expectEqualStrings(expected, got);
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
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);
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
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
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
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);
    try expectFileParses(allocator, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
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
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
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
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);
    try expectFileParses(allocator, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
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
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);
    try expectFileParses(allocator, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "3.0 + 4.00") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "10.0 / 2.00") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "* 1.50") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "+ 0.0") != null);
}

test "-fmt preserves hex and binary literal spelling (does not drop the '0' prefix)" {
    const allocator = std.testing.allocator;

    // Regression: a `0x`/`0b` literal's leading `0` is lexed as its OWN
    // token first, then popped and merged into the hex/binary token once
    // the `x`/`b` is seen. The merged token's position was left pointing at
    // the `x`/`b` (the position captured when THAT call to the lexer's
    // token reader started, which has no way to know about the earlier,
    // already-consumed `0`) instead of the original `0`. The formatter
    // slices the ORIGINAL SOURCE by token position to preserve numeric
    // literal notation exactly, so this silently corrupted `0x20`/`0b1010`
    // into `x20`/`b1010` -- invalid identifiers -- every time `-fmt` ran.
    const ugly =
        "fun main() num {\n" ++
        "\tnum a = 0x20;\n" ++
        "\tnum b = 0xFF;\n" ++
        "\tnum c = 0b1010;\n" ++
        "\tret a + b + c;\n" ++
        "}\n";

    const path = try writeTempFnFile(allocator, "fmt_hex_bin_spell", ugly);
    defer {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);
    try expectFileParses(allocator, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "0x20") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "0xFF") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "0b1010") != null);
    // The bug's exact failure mode: the leading '0' silently dropped.
    try std.testing.expect(std.mem.indexOf(u8, got, "num a = x20") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "num c = b1010") == null);
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

    try cli.format_file_and_imports_in_place(allocator, std.testing.io, a_path);

    const got_a = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, a_path, allocator, .limited(1024 * 1024));
    defer allocator.free(got_a);
    try std.testing.expect(std.mem.indexOf(u8, got_a, "fun a() num") != null);

    const got_b = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, b_path, allocator, .limited(1024 * 1024));
    defer allocator.free(got_b);
    try std.testing.expect(std.mem.indexOf(u8, got_b, "fun b() num") != null);
}

test "-fmt keeps space after ret before unary reference" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun bad() num*{num x=123;ret&x;}\n";

    const path = try writeTempFnFile(allocator, "fmt_ret_ref", ugly);
    defer {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
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
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
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
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "Result<Vec<str>>") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "Result<Vec<str >>") == null);
}

test "-fmt glues a pointer type in a non-last generic argument, and stays idempotent" {
    const allocator = std.testing.allocator;

    // Regression: `isPointerTypeStarContext` only recognized a generic
    // argument's pointer star as the LAST type argument (`Vec<Type*>`,
    // followed by `>`) -- a pointer type followed by ANOTHER argument
    // (`Result<Type*, Error>`, star followed by `,`) fell through to the
    // default spacing and kept a stray space before the star, even
    // though `in_decl_only_ctx` (a function's return-type position here)
    // already rules out any ambiguity with real multiplication.
    const ugly = "pub fun parse(str src) Result<Expr *, Error> {\n  ret ok(src);\n}\n";

    const path = try writeTempFnFile(allocator, "fmt_generic_ptr_midlist", ugly);
    defer {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "Result<Expr*, Error>") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "Expr *,") == null);

    // Idempotent: formatting the already-formatted output must not change it.
    try cli.format_file_in_place(allocator, std.testing.io, path);
    const got2 = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(got2);
    try std.testing.expectEqualStrings(got, got2);
}

test "-fmt keeps decl_block_depth correct across multiple impl methods" {
    const allocator = std.testing.allocator;

    // Regression: a closing `}` decremented decl_block_depth/enum_block_depth/
    // function_body_depth UNCONDITIONALLY (whichever was nonzero), instead of
    // only the ONE counter that particular brace had actually incremented. A
    // bare impl method with no explicit return type (`a() { }`) increments
    // ONLY function_body_depth on open -- but its closing `}` was ALSO
    // decrementing decl_block_depth, the ENCLOSING impl block's own counter,
    // one step too many. After the first such method, decl_block_depth hit 0
    // prematurely, so every method after it lost in_decl_only_ctx for its OWN
    // signature (visible here as a stray space before the generic pointer
    // star, and before the closing `>`, in the SECOND method's return type
    // only -- the first method in an impl never showed this).
    const ugly =
        "compound Lexer{num pos;}\n" ++
        "impl Lexer{a(){}\n" ++
        "next() Result<Option<num>, Error>{ret .Err(error_none());}}\n";

    const path = try writeTempFnFile(allocator, "fmt_impl_multi_method_depth", ugly);
    defer {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "Result<Option<num>, Error>") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "Error >") == null);

    // Idempotent: formatting the already-formatted output must not change it.
    try cli.format_file_in_place(allocator, std.testing.io, path);
    const got2 = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(got2);
    try std.testing.expectEqualStrings(got, got2);
}

test "-fmt keeps a pointer-typed enum variant payload glued when not the last payload" {
    const allocator = std.testing.allocator;

    // Regression: `in_decl_only_ctx` checked `decl_block_depth` (impl/
    // compound/quirk) but never `enum_block_depth` -- an enum variant's
    // payload list is JUST as much a declaration-only, type-list context,
    // but a pointer-typed payload followed by ANOTHER payload
    // (`Bin(chr, Expr*, Expr*)`, star followed by `,`) fell through to
    // non-declaration spacing and gained a stray space, even on input that
    // was ALREADY correctly spaced going in.
    const ugly = "enum Expr {\n  Neg(Expr*),\n  Bin(chr, Expr*, Expr*),\n}\n";

    const path = try writeTempFnFile(allocator, "fmt_enum_payload_ptr_midlist", ugly);
    defer {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "Bin(chr, Expr*, Expr*)") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "Expr *,") == null);

    // Idempotent: formatting the already-formatted output must not change it.
    try cli.format_file_in_place(allocator, std.testing.io, path);
    const got2 = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(got2);
    try std.testing.expectEqualStrings(got, got2);
}

test "-fmt constrained generic impl keeps colon tight" {
    const allocator = std.testing.allocator;

    const ugly =
        "compound Vec<T>{T[] data;num len;}\n" ++
        "impl Vec<T : num | dec>{sum() T{ret self.data[0];}}\n";

    const path = try writeTempFnFile(allocator, "fmt_impl_constraint_colon", ugly);
    defer {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "impl Vec<T: num | dec>") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "impl Vec<T : num | dec>") == null);
    try expectFileParses(allocator, path);
}

test "-fmt keeps a data-carrying enum variant payload on one line" {
    const allocator = std.testing.allocator;

    // Regression: a multi-type variant payload `Pair(num, num)` once had its inner
    // comma treated as a variant separator, splitting it across lines. The payload
    // comma must stay inline; only top-level variant-separator commas break.
    const ugly =
        "enum Val{I(num),Pair(num,num),Nil}\n";

    const path = try writeTempFnFile(allocator, "fmtenum", ugly);
    defer {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(got);

    const expected =
        "enum Val {\n" ++
        "  I(num),\n" ++
        "  Pair(num, num),\n" ++
        "  Nil\n" ++
        "}\n";

    try std.testing.expectEqualStrings(expected, got);
}

test "-fmt keeps a trailing comment inline and aligns a run of them" {
    const allocator = std.testing.allocator;

    const path = try writeTempFnFile(allocator, "fmtcomment", "enum E { Nil }\n");
    defer {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    // Author with trailing comments; a trailing comment must stay on the same line
    // as the code it follows (it once got pushed onto its own line), and a run of
    // consecutive trailing comments in a block aligns to a common column.
    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
        defer f.close(std.testing.io);
        try f.writeStreamingAll(
            std.testing.io,
            "enum E {\n" ++
                "  Number(num), // a\n" ++
                "  Pair(num, num), // bb\n" ++
                "  Nil // ccc\n" ++
                "}\n",
        );
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(got);

    // Comments stay inline and align one past the widest code line
    // (`  Pair(num, num),` is the widest at 17 chars).
    const expected =
        "enum E {\n" ++
        "  Number(num),    // a\n" ++
        "  Pair(num, num), // bb\n" ++
        "  Nil             // ccc\n" ++
        "}\n";

    try std.testing.expectEqualStrings(expected, got);
}

test "-fmt wraps a comma list that exceeds the line-width budget" {
    const allocator = std.testing.allocator;

    const ugly =
        "fun s(num a) num { ret a; }\n" ++
        "fun main() num {\n" ++
        "  printf(\"%lld %lld %lld %lld %lld %lld %lld %lld %lld %lld\\n\", 11, 22, 33, 44, 55, 66, 77, 88, 99, 100);\n" ++
        "  num x = s(1);\n" ++
        "  ret 0;\n" ++
        "}\n";

    const path = try writeTempFnFile(allocator, "fmtwrap", ugly);
    defer {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(got);

    // The long printf wraps one item per line; the short `s(1)` stays inline.
    try std.testing.expect(std.mem.indexOf(u8, got, "  printf(\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "    11,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "    100\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "  );\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "num x = s(1);") != null);
}

test "-fmt spaces a leading-dot enum shorthand after ret" {
    const allocator = std.testing.allocator;

    const ugly =
        "enum E { N(num), Nil }\n" ++
        "fun w(num n) E { ret .N(n); }\n";

    const path = try writeTempFnFile(allocator, "fmtshorthand", ugly);
    defer {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(got);

    // `ret .N(n)` keeps its space (it once glued to `ret.N`).
    try std.testing.expect(std.mem.indexOf(u8, got, "ret .N(n);") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "ret.N") == null);
}

test "-fmt keeps a space between ret/if/fit and a parenthesized sub-expression" {
    const allocator = std.testing.allocator;

    // `ret (status >> 8) & 255;` -- the leading paren here groups a
    // SUB-expression (there's more after the `)`), not a call/whole-condition
    // grouping. The statement-keyword spacing rule once treated any
    // keyword-then-`(` the same as an identifier-then-`(` (a call), gluing
    // `ret(status >> 8)` -- which reads as calling `ret` as a function.
    const ugly =
        "fun f(num status) num { ret (status >> 8) & 255; }\n" ++
        "fun g(num status) num { if (status & 127) == 0 { ret 1; } ret 0; }\n";

    const path = try writeTempFnFile(allocator, "fmtretparen", ugly);
    defer {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "ret (status >> 8) & 255;") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "ret(status") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "if (status & 127) == 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "if(status") == null);
}

test "-fmt spaces/indents a test block body and separates it from a preceding function" {
    const allocator = std.testing.allocator;

    // `test` is new (Phase 0.5): its `{` follows a STRING (the test's name),
    // not the `)`/identifier shapes `fun`/`compound`/etc. use, and its own
    // closing `}` wasn't recognized as needing a blank-line separator before
    // a FOLLOWING `test`/`fun` either -- both fixed in
    // `is_top_level_construct_keyword` and the block-brace detection.
    const ugly =
        "fun add(num a,num b) num {\n" ++
        "ret a+b;\n" ++
        "}\n" ++
        "test \"add works\"    {\n" ++
        "assert add(2,3)==5,\"expected 5\";\n" ++
        "}\n";

    const path = try writeTempFnFile(allocator, "fmttestblock", ugly);
    defer {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(got);

    try std.testing.expectEqualStrings(
        "fun add(num a, num b) num {\n" ++
            "  ret a + b;\n" ++
            "}\n" ++
            "\n" ++
            "test \"add works\" {\n" ++
            "  assert add(2, 3) == 5, \"expected 5\";\n" ++
            "}\n",
        got,
    );
}

test "-fmt keeps a pointer-dereference assignment correctly spaced inside a test block" {
    const allocator = std.testing.allocator;

    // Regression test: a `test { ... }` block's body was wrongly tracked as
    // a DECLARATION context (grouped with compound/quirk/impl for
    // `pending_decl_block_open`) rather than an executable-statement
    // context like a `fun`'s body -- since `test "name" {` has no `fun`
    // keyword and no `(...)` before its `{`, none of the existing
    // function-body detection matched it either, so `function_body_depth`
    // never got incremented inside one. That made `in_decl_only_ctx` true
    // for every statement in a test body, so a plain dereference-assignment
    // like `*p = f();` was formatted as if `*p` were a pointer-TYPE
    // annotation (`Type* name`), mangling it into `* p =f();` -- confirmed
    // directly: the identical statement inside an ordinary `fun` body
    // formatted correctly.
    const ugly =
        "compound Foo {\n" ++
        "num x;\n" ++
        "}\n" ++
        "fun foo_new() Foo {\n" ++
        "Foo f;\n" ++
        "f.x=1;\n" ++
        "ret f;\n" ++
        "}\n" ++
        "test \"repro\" {\n" ++
        "Foo* p=malloc(sizeof(Foo));\n" ++
        "*p=foo_new();\n" ++
        "assert p.x==1,\"expected 1\";\n" ++
        "}\n";

    const path = try writeTempFnFile(allocator, "fmttestderefassign", ugly);
    defer {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        allocator.free(path);
    }

    try cli.format_file_in_place(allocator, std.testing.io, path);

    const got = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(got);

    try std.testing.expectEqualStrings(
        "compound Foo {\n" ++
            "  num x;\n" ++
            "}\n" ++
            "\n" ++
            "fun foo_new() Foo {\n" ++
            "  Foo f;\n" ++
            "  f.x = 1;\n" ++
            "  ret f;\n" ++
            "}\n" ++
            "\n" ++
            "test \"repro\" {\n" ++
            "  Foo* p = malloc(sizeof(Foo));\n" ++
            "  *p = foo_new();\n" ++
            "  assert p.x == 1, \"expected 1\";\n" ++
            "}\n",
        got,
    );

    // Idempotent: reformatting the already-formatted output must be a no-op.
    try cli.format_file_in_place(allocator, std.testing.io, path);
    const got2 = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(got2);
    try std.testing.expectEqualStrings(got, got2);
}
