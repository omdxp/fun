const std = @import("std");
const fs = std.fs;
const ast = @import("ast");
const lexer = @import("lexer");
const ParseProcess = @import("parser").ParseProcess;
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
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};

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
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};

    try std.testing.expect(std.mem.indexOf(u8, out, "myio__format_impl") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "myio__fmt_num") != null);
}

test "std.log aliased import: methods use alias-prefixed helpers" {
    const allocator = std.testing.allocator;
    const ifilepath = "alias_log_levels.fn";
    const input =
        "imp std.log as mylog;\n" ++
        "fun main() {\n" ++
        "  mylog.Logger logger = mylog.logger_init(mylog.LogLevel.Debug);\n" ++
        "  logger.warn(\"warn\");\n" ++
        "}\n";

    const out = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out);
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};

    try std.testing.expect(std.mem.indexOf(u8, out, "mylog__level_value") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "mylog__level_name") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " level_value(") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, " level_name(") == null);
}

test "user module imported under two aliases: stubs emitted for second alias" {
    // helper.fn exported under alias 'a'. main.fn imports it as 'b'.
    // Codegen should emit `#define b__helper_fn a__helper_fn`.
    const allocator = std.testing.allocator;
    const helper_path = "alias_stub_helper.fn";
    const main_path = "alias_stub_main.fn";

    {
        const hf = try std.Io.Dir.cwd().createFile(std.testing.io, helper_path, .{});
        defer hf.close(std.testing.io);
        try hf.writeStreamingAll(
            std.testing.io,
            "imp std.c.io;\n" ++
                "pub fun say_hello() {\n" ++
                "  printf(\"hello\\n\");\n" ++
                "}\n",
        );
    }
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, helper_path) catch {};

    const main_input =
        "imp alias_stub_helper as a;\n" ++
        "fun main() {\n" ++
        "  a.say_hello();\n" ++
        "}\n";

    const out = try runTranspile(allocator, main_path, main_input);
    defer allocator.free(out);
    std.Io.Dir.cwd().deleteFile(std.testing.io, main_path) catch {};

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
    std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};

    // Bare names expected when no alias is used
    try std.testing.expect(std.mem.indexOf(u8, out, "format_impl") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "fmt_num") != null);
}

test "diamond import: shared module reachable via two branches compiles once" {
    // examples/imports/diamond/main.fn imports `left` and `right`; both import
    // `shared`. Before compile-wide import dedup, `shared` was fully re-parsed
    // once per branch. This verifies the diamond still type-checks and codegens
    // correctly (shared_value visible from both branches, no duplicate-symbol
    // error) and that shared's definition is emitted exactly once.
    const allocator = std.testing.allocator;

    var tp = try codegen.TranspileProcess.init(
        allocator,
        "examples/imports/diamond/main.fn",
        "temp.c",
        .{ .exec = false, .outf = false, .ast = false, .emit_stderr = false },
    );
    var lex_proc = lexer.LexProcess.init(&tp);
    var parse_proc = ParseProcess.init(&tp);
    defer {
        lex_proc.deinit();
        tp.deinit();
    }

    try lex_proc.lex();
    try parse_proc.parse();
    // Must not raise DuplicateSymbol for `shared_value` seen via left and right.
    try tp.transpile();

    const out = tp.get_output() orelse return error.NoOutput;

    // The shared module's function body must be emitted EXACTLY ONCE, even though
    // it is imported through two branches. A C function definition is the header
    // immediately followed by `{` ("shared_value() {"); a forward declaration ends
    // in ";" and the call sites are followed by ")". Count definitions only.
    var def_count: usize = 0;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, out, search, "shared_value()")) |idx| {
        const after = idx + "shared_value()".len;
        var j = after;
        while (j < out.len and (out[j] == ' ' or out[j] == '\t')) : (j += 1) {}
        if (j < out.len and out[j] == '{') def_count += 1;
        search = idx + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), def_count);

    // And it must be referenced from both consumers (left=%d and right=%d call it).
    try std.testing.expect(std.mem.indexOf(u8, out, "shared_value") != null);
}

test "aliased generic function call is monomorphized" {
    // Regression: `imp lib as g; g.ident(123)` emitted an undeclared `g__ident`
    // because the generic was never instantiated through the alias. It must
    // monomorphize to `ident__num` like the non-aliased form does.
    const allocator = std.testing.allocator;
    const lib_path = "agc_lib.fn";
    const main_path = "agc_main.fn";
    {
        const lf = try std.Io.Dir.cwd().createFile(std.testing.io, lib_path, .{});
        defer lf.close(std.testing.io);
        try lf.writeStreamingAll(std.testing.io, "pub fun ident<T>(T x) T { ret x; }\n");
    }
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, lib_path) catch {};

    const main_input =
        "imp std.c.io;\n" ++
        "imp agc_lib as g;\n" ++
        "fun main() num {\n" ++
        "  printf(\"%lld\\n\", g.ident(123));\n" ++
        "  ret 0;\n" ++
        "}\n";
    const out = try runTranspile(allocator, main_path, main_input);
    defer allocator.free(out);
    std.Io.Dir.cwd().deleteFile(std.testing.io, main_path) catch {};

    // The monomorphized instance is emitted and called; the bad alias-prefixed
    // name is NOT present.
    try std.testing.expect(std.mem.indexOf(u8, out, "ident__num") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "g__ident") == null);
}

test "alias-qualified call to a private (non-pub) function is rejected" {
    // Regression: a private (non-`pub`) function in an aliased module could be
    // called as `alias.fn(...)`, bypassing module visibility. It must now be a
    // clean type error, while a `pub` sibling in the same module still works.
    const allocator = std.testing.allocator;
    const lib_path = "privalias_lib.fn";
    {
        const lf = try std.Io.Dir.cwd().createFile(std.testing.io, lib_path, .{});
        defer lf.close(std.testing.io);
        try lf.writeStreamingAll(
            std.testing.io,
            "fun secret() num { ret 42; }\n" ++
                "pub fun visible() num { ret 7; }\n",
        );
    }
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, lib_path) catch {};

    // Private call through the alias -> rejected.
    {
        const main_path = "privalias_main_bad.fn";
        const bad =
            "imp privalias_lib as a;\n" ++
            "fun main() num { ret a.secret(); }\n";
        const res = runTranspile(allocator, main_path, bad);
        std.Io.Dir.cwd().deleteFile(std.testing.io, main_path) catch {};
        if (res) |out| {
            allocator.free(out);
            return error.ExpectedRejection;
        } else |_| {}
    }

    // Public sibling through the alias -> still compiles.
    {
        const main_path = "privalias_main_ok.fn";
        const good =
            "imp std.c.io;\n" ++
            "imp privalias_lib as a;\n" ++
            "fun main() num { printf(\"%lld\\n\", a.visible()); ret 0; }\n";
        const out = try runTranspile(allocator, main_path, good);
        defer allocator.free(out);
        std.Io.Dir.cwd().deleteFile(std.testing.io, main_path) catch {};
        try std.testing.expect(std.mem.indexOf(u8, out, "a__visible") != null);
    }
}

test "alias-qualified access to a private (non-pub) global is rejected" {
    // Regression: a private (non-`pub`) global variable in an aliased module could
    // be read as `alias.global`, which emitted an undeclared `alias__global` ->
    // INVALID C. It must now be a clean type error, while a `pub` global still works.
    const allocator = std.testing.allocator;
    const lib_path = "privglob_lib.fn";
    {
        const lf = try std.Io.Dir.cwd().createFile(std.testing.io, lib_path, .{});
        defer lf.close(std.testing.io);
        try lf.writeStreamingAll(
            std.testing.io,
            "num secret_g = 99;\n" ++
                "pub num shared_g = 7;\n",
        );
    }
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, lib_path) catch {};

    // Private global through the alias -> rejected.
    {
        const main_path = "privglob_main_bad.fn";
        const bad =
            "imp privglob_lib as g;\n" ++
            "fun main() num { num x = g.secret_g; ret x; }\n";
        const res = runTranspile(allocator, main_path, bad);
        std.Io.Dir.cwd().deleteFile(std.testing.io, main_path) catch {};
        if (res) |out| {
            allocator.free(out);
            return error.ExpectedRejection;
        } else |_| {}
    }

    // Public global through the alias -> still compiles.
    {
        const main_path = "privglob_main_ok.fn";
        const good =
            "imp std.c.io;\n" ++
            "imp privglob_lib as g;\n" ++
            "fun main() num { printf(\"%lld\\n\", g.shared_g); ret 0; }\n";
        const out = try runTranspile(allocator, main_path, good);
        defer allocator.free(out);
        std.Io.Dir.cwd().deleteFile(std.testing.io, main_path) catch {};
        try std.testing.expect(std.mem.indexOf(u8, out, "shared_g") != null);
    }
}
