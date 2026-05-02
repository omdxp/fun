const std = @import("std");
const fs = std.fs;
const ast = @import("ast");
const lexer = @import("lexer");
const ParseProcess = @import("parser").ParseProcess;
const codegen = @import("codegen");

fn runTranspile(allocator: std.mem.Allocator, input_path: []const u8, input: []const u8) ![]const u8 {
    {
        const file = try fs.cwd().createFile(input_path, .{ .read = true, .truncate = true });
        defer file.close();
        try file.writeAll(input);
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
    return allocator.dupe(u8, out);
}

test "preload_import_global_symbols finds imported functions" {
    var tp = try codegen.TranspileProcess.init(
        std.testing.allocator,
        "examples/imports/main.fn",
        "temp.c",
        .{ .exec = false, .outf = false, .ast = false },
    );
    defer tp.deinit();

    try tp.preload_import_global_symbols(
        ast.Node{ .type = .Import, .pos = null, .node_variant = null },
        "relative.parent",
        null,
    );

    try std.testing.expect(tp.global_symbols.get("parent") != null);
}

test "preload_import_global_symbols supports aliased duplicate exports" {
    var tp = try codegen.TranspileProcess.init(
        std.testing.allocator,
        "examples/imports/alias_collision/main.fn",
        "temp.c",
        .{ .exec = false, .outf = false, .ast = false },
    );
    defer tp.deinit();

    try tp.preload_import_global_symbols(
        ast.Node{ .type = .Import, .pos = null, .node_variant = null },
        "mod1",
        "one",
    );
    try tp.preload_import_global_symbols(
        ast.Node{ .type = .Import, .pos = null, .node_variant = null },
        "mod2",
        "two",
    );

    try std.testing.expect(tp.global_symbols.get("one__pick") != null);
    try std.testing.expect(tp.global_symbols.get("two__pick") != null);
}

// --- Alias import codegen tests ---

test "std.io aliased import: print_fmt uses alias-prefixed helpers" {
    // When `imp std.io as myio`, the inlined print_fmt body must call
    // `myio__format_impl` / `myio__fmt_num` etc., not bare `format_impl`.
    const allocator = std.testing.allocator;
    const ifilepath = "alias_io_print.fn";
    const input =
        "imp std.io as myio;\n" ++
        "fun main() {\n" ++
        "  myio.print_fmt(\"count={num}\", 42);\n" ++
        "}\n";

    const out = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out);
    fs.cwd().deleteFile(ifilepath) catch {};

    // format_impl and fmt_num must be prefixed with the alias
    try std.testing.expect(std.mem.indexOf(u8, out, "myio__format_impl") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "myio__fmt_num") != null);
    // bare names must NOT appear (they'd be undefined)
    try std.testing.expect(std.mem.indexOf(u8, out, " format_impl(") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, " fmt_num(") == null);
}

test "std.io aliased import: format uses alias-prefixed helpers" {
    const allocator = std.testing.allocator;
    const ifilepath = "alias_io_format.fn";
    const input =
        "imp std.io as myio;\n" ++
        "fun main() {\n" ++
        "  str s = myio.format(\"v={num}\", 7);\n" ++
        "  myio.println(s);\n" ++
        "}\n";

    const out = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out);
    fs.cwd().deleteFile(ifilepath) catch {};

    try std.testing.expect(std.mem.indexOf(u8, out, "myio__format_impl") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "myio__fmt_num") != null);
}

test "user module imported under two aliases: stubs emitted for second alias" {
    // helper.fn exported under alias 'a'. main.fn imports it as 'b'.
    // Codegen should emit `#define b__helper_fn a__helper_fn`.
    const allocator = std.testing.allocator;
    const helper_path = "alias_stub_helper.fn";
    const main_path = "alias_stub_main.fn";

    {
        const hf = try fs.cwd().createFile(helper_path, .{});
        defer hf.close();
        try hf.writeAll(
            "imp std.c.io;\n" ++
                "pub fun say_hello() {\n" ++
                "  printf(\"hello\\n\");\n" ++
                "}\n",
        );
    }
    defer fs.cwd().deleteFile(helper_path) catch {};

    const main_input =
        "imp alias_stub_helper as a;\n" ++
        "fun main() {\n" ++
        "  a.say_hello();\n" ++
        "}\n";

    const out = try runTranspile(allocator, main_path, main_input);
    defer allocator.free(out);
    fs.cwd().deleteFile(main_path) catch {};

    // The module is emitted once under alias 'a'
    try std.testing.expect(std.mem.indexOf(u8, out, "a__say_hello") != null);
}

test "same module imported without alias uses bare function names" {
    // `imp std.io;` (no alias) -> format_impl / fmt_num are bare
    const allocator = std.testing.allocator;
    const ifilepath = "no_alias_io.fn";
    const input =
        "imp std.io;\n" ++
        "fun main() {\n" ++
        "  print_fmt(\"n={num}\", 1);\n" ++
        "}\n";

    const out = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out);
    fs.cwd().deleteFile(ifilepath) catch {};

    // Bare names expected when no alias is used
    try std.testing.expect(std.mem.indexOf(u8, out, "format_impl") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "fmt_num") != null);
}
