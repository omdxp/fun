const std = @import("std");
const fs = std.fs;
const lexer = @import("lexer");
const ParseProcess = @import("parser").ParseProcess;
const codegen = @import("codegen");
const cli = @import("cli");

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
    // Copy it so it remains valid after deinit.
    return allocator.dupe(u8, out);
}

test "if/elif/else transpiles" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_if_elif_else.fn";

    const input =
        "imp std.c.io;\n" ++
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
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  num[] arr = [1, 2, 3];\n" ++
        "  num x = arr[1];\n" ++
        "  printf(\"%d\\n\", x);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t arr[] = {1, 2, 3};") != null);
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

test "raw pointer maps to void*" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_raw_ptr.fn";

    const input =
        "fun id(raw* p) raw* { ret p; }\n" ++
        "fun main() { raw* x = id(0); }\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "void* id(void* p)") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "function definitions can be out of order (prototypes emitted)" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_fn_prototype_order.fn";

    const input =
        "imp std.c.io;\n" ++
        "fun main() {\n" ++
        "  foo();\n" ++
        "}\n" ++
        "fun foo() {\n" ++
        "  printf(\"ok\\n\");\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    const proto_idx = std.mem.indexOf(u8, out_owned, "void foo();") orelse return error.TestExpectedPrototype;
    const main_idx = std.mem.indexOf(u8, out_owned, "int main") orelse return error.TestExpectedMain;
    try std.testing.expect(proto_idx < main_idx);

    try fs.cwd().deleteFile(ifilepath);
}

test "aliased import calls transpile to qualified symbols" {
    const allocator = std.testing.allocator;
    const ifilepath = "examples/imports/alias_collision/main_codegen_alias.fn";
    defer fs.cwd().deleteFile(ifilepath) catch {};

    const input =
        "imp mod1 as one;\n" ++
        "imp mod2 as two;\n" ++
        "fun main() {\n" ++
        "  num a = one.pick();\n" ++
        "  num b = two.pick();\n" ++
        "  _ = a + b;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "one__pick(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "two__pick(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t one__pick()") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t two__pick()") != null);
}

test "aliased import supports public type and value access" {
    const allocator = std.testing.allocator;
    const mod_path = "codegen_alias_exports_mod.fn";
    const main_path = "codegen_alias_exports_main.fn";
    defer fs.cwd().deleteFile(mod_path) catch {};
    defer fs.cwd().deleteFile(main_path) catch {};

    {
        const mod_file = try fs.cwd().createFile(mod_path, .{ .read = true });
        defer mod_file.close();
        try mod_file.writeAll(
            "pub compound User {\n" ++
                "  num id;\n" ++
                "}\n" ++
                "pub num answer = 7;\n" ++
                "pub fun get_answer() num { ret answer; }\n",
        );
    }

    const input =
        "imp codegen_alias_exports_mod as m;\n" ++
        "fun main() {\n" ++
        "  m.User u;\n" ++
        "  u.id = m.answer;\n" ++
        "  num a = m.get_answer();\n" ++
        "  _ = u.id + a;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, main_path, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "User u") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "m__answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "m__get_answer(") != null);
}

test "aliased compound method calls use canonical impl" {
    const allocator = std.testing.allocator;
    const mod_path = "codegen_alias_compound_mod.fn";
    const main_path = "codegen_alias_compound_main.fn";
    defer fs.cwd().deleteFile(mod_path) catch {};
    defer fs.cwd().deleteFile(main_path) catch {};

    {
        const mod_file = try fs.cwd().createFile(mod_path, .{ .read = true });
        defer mod_file.close();
        try mod_file.writeAll(
            "pub compound Vec2 {\n" ++
                "  dec x;\n" ++
                "  dec y;\n" ++
                "}\n" ++
                "impl Vec2 {\n" ++
                "  pub len() dec { ret self.x + self.y; }\n" ++
                "}\n",
        );
    }

    const input =
        "imp codegen_alias_compound_mod as g;\n" ++
        "fun main() {\n" ++
        "  g.Vec2 v;\n" ++
        "  v.x = 1.0;\n" ++
        "  v.y = 2.0;\n" ++
        "  dec s = v.len();\n" ++
        "  _ = s;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, main_path, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "typedef struct Vec2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Vec2__len(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "g__Vec2__len(") == null);
}

test "aliased io.format with bare placeholder renders values" {
    const allocator = std.testing.allocator;
    const input_path = "codegen_alias_io_format_main.fn";
    const c_path = "codegen_alias_io_format_main.c";
    const out_path = "codegen_alias_io_format_out.txt";
    defer fs.cwd().deleteFile(input_path) catch {};
    defer fs.cwd().deleteFile(c_path) catch {};
    defer fs.cwd().deleteFile(out_path) catch {};

    const input =
        "imp std.io as io;\n" ++
        "fun main() {\n" ++
        "  str msg = io.format(\"Hello, {}!\", \"Alice\");\n" ++
        "  _ = io.write_all(\"codegen_alias_io_format_out.txt\", msg);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, input_path, input);
    defer allocator.free(out_owned);

    {
        const c_file = try fs.cwd().createFile(c_path, .{});
        defer c_file.close();
        try c_file.writeAll(out_owned);
    }

    try cli.compile_and_run(allocator, c_path, true, input_path, &.{});

    const got = try fs.cwd().readFileAlloc(allocator, out_path, 1024 * 1024);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("Hello, Alice!", got);
}

test "defer emits in LIFO order before return" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_defer_lifo.fn";

    const input =
        "fun a() { ret; }\n" ++
        "fun b() { ret; }\n" ++
        "fun foo() num {\n" ++
        "  defer a();\n" ++
        "  defer b();\n" ++
        "  ret 1;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    const b_pos_opt = std.mem.lastIndexOf(u8, out_owned, "b();");
    const a_pos_opt = std.mem.lastIndexOf(u8, out_owned, "a();");
    const ret_pos_opt = std.mem.lastIndexOf(u8, out_owned, "return 1;");
    try std.testing.expect(b_pos_opt != null);
    try std.testing.expect(a_pos_opt != null);
    try std.testing.expect(ret_pos_opt != null);
    const b_pos = b_pos_opt.?;
    const a_pos = a_pos_opt.?;
    const ret_pos = ret_pos_opt.?;
    try std.testing.expect(b_pos < a_pos);
    try std.testing.expect(a_pos < ret_pos);

    try fs.cwd().deleteFile(ifilepath);
}

test "defer block emits before function end" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_defer_block.fn";

    const input =
        "fun a() { ret; }\n" ++
        "fun b() { ret; }\n" ++
        "fun foo() {\n" ++
        "  defer {\n" ++
        "    a();\n" ++
        "    b();\n" ++
        "  }\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "a();") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "b();") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "enum types can be referenced before declaration" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_enum_after_main.fn";

    const input =
        "imp std.c.io;\n" ++
        "\n" ++
        "fun takesColor(Color c) num {\n" ++
        "  if c == .Blue { ret 1; }\n" ++
        "  ret 0;\n" ++
        "}\n" ++
        "\n" ++
        "fun main() {\n" ++
        "  num v = takesColor(.Blue);\n" ++
        "  printf(\"%d\\n\", v);\n" ++
        "}\n" ++
        "\n" ++
        "enum Color {\n" ++
        "  Red,\n" ++
        "  Blue,\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    // Ensure the enum variant constant made it through lowering/codegen.
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Color_Blue") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "std.time import adds time.h include" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_time.fn";

    const input =
        "imp std.c.time;\n" ++
        "fun main() { ret; }\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <time.h>") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "std.c.thread import adds pthread.h include" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_thread_c.fn";

    const input =
        "imp std.c.thread;\n" ++
        "fun main() { ret; }\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <pthread.h>") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "std.c.thread symbols are callable after import" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_thread_symbols.fn";

    const input =
        "imp std.c.thread;\n" ++
        "fun main() {\n" ++
        "  pthread_self();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "pthread_self()") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "transitive std.thread import emits pthread headers" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_transitive_std_thread.fn";

    const input =
        "imp std.thread;\n" ++
        "fun main() { ret; }\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <pthread.h>") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "std.thread helper lifecycle APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_thread_helpers.fn";

    const input =
        "imp std.thread;\n" ++
        "fun main() {\n" ++
        "  Thread t = thread_new();\n" ++
        "  _ = thread_start(&t, NULL, NULL);\n" ++
        "  _ = thread_join(&t, NULL);\n" ++
        "  _ = thread_detach(&t);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_start(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_join(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_detach(") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "std.sync helper lifecycle APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_sync_helpers.fn";

    const input =
        "imp std.sync;\n" ++
        "fun main() {\n" ++
        "  Mutex m = mutex_new();\n" ++
        "  CondVar c = condvar_new();\n" ++
        "  _ = mutex_init(&m);\n" ++
        "  _ = mutex_lock(&m);\n" ++
        "  _ = mutex_try_lock(&m);\n" ++
        "  _ = mutex_unlock(&m);\n" ++
        "  _ = condvar_init(&c);\n" ++
        "  _ = condvar_wait(&c, &m);\n" ++
        "  _ = condvar_timed_wait(&c, &m, NULL);\n" ++
        "  _ = condvar_signal(&c);\n" ++
        "  _ = condvar_broadcast(&c);\n" ++
        "  _ = condvar_destroy(&c);\n" ++
        "  _ = mutex_destroy(&m);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "mutex_init(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "mutex_lock(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "mutex_try_lock(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "mutex_unlock(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "mutex_destroy(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "condvar_init(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "condvar_wait(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "condvar_timed_wait(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "condvar_signal(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "condvar_broadcast(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "condvar_destroy(") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "transitive std.sync_runtime import emits pthread headers" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_transitive_std_sync_runtime.fn";

    const input =
        "imp std.sync_runtime;\n" ++
        "fun main() { ret; }\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <pthread.h>") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "std.sync_runtime lifecycle APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_sync_runtime_helpers.fn";

    const input =
        "imp std.sync_runtime;\n" ++
        "fun main() {\n" ++
        "  Mutex m = runtime_mutex_new();\n" ++
        "  CondVar c = runtime_condvar_new();\n" ++
        "  _ = runtime_mutex_init(&m);\n" ++
        "  _ = runtime_mutex_lock(&m);\n" ++
        "  _ = runtime_mutex_try_lock(&m);\n" ++
        "  _ = runtime_mutex_unlock(&m);\n" ++
        "  _ = runtime_condvar_init(&c);\n" ++
        "  _ = runtime_condvar_wait(&c, &m);\n" ++
        "  _ = runtime_condvar_timed_wait(&c, &m, NULL);\n" ++
        "  _ = runtime_condvar_signal(&c);\n" ++
        "  _ = runtime_condvar_broadcast(&c);\n" ++
        "  _ = runtime_condvar_destroy(&c);\n" ++
        "  _ = runtime_mutex_destroy(&m);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_mutex_new(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_condvar_new(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_mutex_init(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_mutex_lock(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_mutex_try_lock(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_mutex_unlock(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_mutex_destroy(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_condvar_init(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_condvar_wait(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_condvar_timed_wait(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_condvar_signal(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_condvar_broadcast(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_condvar_destroy(") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "std.sync_runtime backend selector APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_sync_runtime_backend.fn";

    const input =
        "imp std.sync_runtime;\n" ++
        "fun main() {\n" ++
        "  num id = sync_runtime_backend_id();\n" ++
        "  str name = sync_runtime_backend_name();\n" ++
        "  bin p = sync_runtime_backend_is_posix();\n" ++
        "  bin w = sync_runtime_backend_is_windows();\n" ++
        "  _ = id;\n" ++
        "  _ = name;\n" ++
        "  _ = p;\n" ++
        "  _ = w;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_runtime_backend_id(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_runtime_backend_name(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_runtime_backend_is_posix(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "sync_runtime_backend_is_windows(") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "transitive std.thread_runtime import emits pthread headers" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_transitive_std_thread_runtime.fn";

    const input =
        "imp std.thread_runtime;\n" ++
        "fun main() { ret; }\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <pthread.h>") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "std.thread_runtime lifecycle APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_thread_runtime_helpers.fn";

    const input =
        "imp std.thread_runtime;\n" ++
        "fun main() {\n" ++
        "  Thread t = runtime_thread_new();\n" ++
        "  _ = runtime_thread_start(&t, NULL, NULL);\n" ++
        "  _ = runtime_thread_join(&t, NULL);\n" ++
        "  _ = runtime_thread_detach(&t);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_thread_new(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_thread_start(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_thread_join(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "runtime_thread_detach(") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "std.thread_runtime backend selector APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_thread_runtime_backend.fn";

    const input =
        "imp std.thread_runtime;\n" ++
        "fun main() {\n" ++
        "  num id = thread_runtime_backend_id();\n" ++
        "  str name = thread_runtime_backend_name();\n" ++
        "  bin p = thread_runtime_backend_is_posix();\n" ++
        "  bin w = thread_runtime_backend_is_windows();\n" ++
        "  _ = id;\n" ++
        "  _ = name;\n" ++
        "  _ = p;\n" ++
        "  _ = w;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_runtime_backend_id(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_runtime_backend_name(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_runtime_backend_is_posix(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_runtime_backend_is_windows(") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "transitive std.channel import emits pthread headers" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_transitive_std_channel.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() { ret; }\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <pthread.h>") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "transitive std.thread_pool import emits pthread headers" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_transitive_std_thread_pool.fn";

    const input =
        "imp std.thread_pool;\n" ++
        "fun main() { ret; }\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <pthread.h>") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "std.thread_pool lifecycle APIs transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_thread_pool_lifecycle.fn";

    const input =
        "imp std.thread_pool;\n" ++
        "fun main() {\n" ++
        "  ThreadPool p = thread_pool_new(0);\n" ++
        "  _ = p.start_all(NULL, NULL);\n" ++
        "  _ = p.join_all(NULL);\n" ++
        "  _ = p.detach_all();\n" ++
        "  _ = p.count();\n" ++
        "  _ = p.is_ready();\n" ++
        "  _ = p.destroy();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "thread_pool_new(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "ThreadPool__start_all(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "ThreadPool__join_all(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "ThreadPool__detach_all(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "ThreadPool__count(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "ThreadPool__is_ready(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "ThreadPool__destroy(") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "std.channel send and recv transpile for num" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_send_recv.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> ch = channel_new(0);\n" ++
        "  _ = ch.send(7);\n" ++
        "  num out = ch.recv();\n" ++
        "  _ = out;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__send(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__recv(") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "std.channel buffered constructor and try_send transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_buffered.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> ch = channel_new_cap(0, 4);\n" ++
        "  _ = ch.try_send(1);\n" ++
        "  _ = ch.try_send(2);\n" ++
        "  num a = ch.recv();\n" ++
        "  num b = ch.recv();\n" ++
        "  _ = a + b;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "channel_new_cap__num") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__try_send(") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "std.channel timeout send and recv transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_timeout.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> ch = channel_new_cap(0, 1);\n" ++
        "  _ = ch.send_timeout(1, 0);\n" ++
        "  num out = 0;\n" ++
        "  _ = ch.recv_timeout_into(&out, 0);\n" ++
        "  num v = ch.recv_timeout(0);\n" ++
        "  _ = out + v;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <time.h>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__send_timeout(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__recv_timeout_into(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__recv_timeout(") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "std.channel select recv2 timeout transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_select2.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  _ = b.send(42);\n" ++
        "  num out = 0;\n" ++
        "  num idx = -1;\n" ++
        "  _ = a.select_recv_timeout_with(&b, &out, &idx, 10);\n" ++
        "  _ = out + idx;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_timeout_with(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_try_recv_with(") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "std.channel select recv3 fair timeout transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_select3_rr.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  Channel<num> c = channel_new(0);\n" ++
        "  _ = c.send(7);\n" ++
        "  num out = 0;\n" ++
        "  num idx = -1;\n" ++
        "  num next = 0;\n" ++
        "  _ = a.select_recv_timeout3_rr_with(&b, &c, &next, &out, &idx, 10);\n" ++
        "  _ = out + idx + next;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_timeout3_rr_with(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_try_recv3_rr_with(") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "std.channel select wait-slice tuning transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_select_wait_slice.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> ch = channel_new(0);\n" ++
        "  ch.set_select_wait_slice_ms(3);\n" ++
        "  num slice = ch.get_select_wait_slice_ms();\n" ++
        "  _ = slice;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__set_select_wait_slice_ms(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__get_select_wait_slice_ms(") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "std.channel select explicit wait-slice override transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_select_wait_slice_override.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  Channel<num> c = channel_new(0);\n" ++
        "  num out = 0;\n" ++
        "  num idx = -1;\n" ++
        "  num next = 0;\n" ++
        "  _ = a.select_recv_timeout_with_slice(&b, &out, &idx, 10, 2);\n" ++
        "  _ = a.select_recv_timeout3_rr_with_slice(&b, &c, &next, &out, &idx, 10, 2);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_timeout_with_slice(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_timeout3_rr_with_slice(") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "std.channel select explicit wait-slice and backoff override transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_select_tuning_override.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  Channel<num> c = channel_new(0);\n" ++
        "  num out = 0;\n" ++
        "  num idx = -1;\n" ++
        "  num next = 0;\n" ++
        "  _ = a.select_recv_timeout_with_tuning(&b, &out, &idx, 10, 2, 1);\n" ++
        "  _ = a.select_recv_timeout3_rr_with_tuning(&b, &c, &next, &out, &idx, 10, 2, 1);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_timeout_with_tuning(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_timeout3_rr_with_tuning(") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "std.channel select blocking tuning overrides transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_select_blocking_tuning_override.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  Channel<num> c = channel_new(0);\n" ++
        "  num out = 0;\n" ++
        "  num idx = -1;\n" ++
        "  num next = 0;\n" ++
        "  _ = a.select_recv_with_slice(&b, &out, &idx, 2);\n" ++
        "  _ = a.select_recv_with_tuning(&b, &out, &idx, 2, 1);\n" ++
        "  _ = a.select_recv3_rr_with_slice(&b, &c, &next, &out, &idx, 2);\n" ++
        "  _ = a.select_recv3_rr_with_tuning(&b, &c, &next, &out, &idx, 2, 1);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_with_slice(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv_with_tuning(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv3_rr_with_slice(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__select_recv3_rr_with_tuning(") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "std.channel select adaptive wait backoff transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_select_adaptive_wait.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  num out = 0;\n" ++
        "  num idx = -1;\n" ++
        "  _ = a.select_recv_timeout_with(&b, &out, &idx, 10);\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "channel_compute_wait_slice_ms(") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "std.channel select backoff-step tuning transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_std_channel_select_backoff_steps.fn";

    const input =
        "imp std.channel;\n" ++
        "fun main() {\n" ++
        "  Channel<num> ch = channel_new(0);\n" ++
        "  ch.set_select_wait_backoff_steps(4);\n" ++
        "  num steps = ch.get_select_wait_backoff_steps();\n" ++
        "  _ = steps;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__set_select_wait_backoff_steps(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Channel__num__get_select_wait_backoff_steps(") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "generic function specialization emits concrete names" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_generic_fn.fn";

    const input =
        "fun id<T>(T x) T { ret x; }\n" ++
        "fun main() {\n" ++
        "  num a = id(1);\n" ++
        "  str b = id(\"hi\");\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "id__num") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "id__str") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "id__T") == null);

    try fs.cwd().deleteFile(ifilepath);
}

test "assert emits abort and message" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_assert.fn";

    const input =
        "fun main() {\n" ++
        "  assert true, \"ok\";\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "fprintf(stderr, \"Assertion failed at ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "abort()") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "compounds + quirks + impl vtables transpile" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_quirk_vtable.fn";

    const input =
        "compound Point { num x; num y; }\n" ++
        "quirk HasX { getX() num; }\n" ++
        "impl Point as HasX {\n" ++
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
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int64_t x;") != null);

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
        "impl Point as Q1 { getX() num { ret self.x; } }\n" ++
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
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "__fun_coerce_Point_") != null);

    // Both should dispatch through the same canonical vtable/object shape.
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "a.vtable->getX") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "b.vtable->getX") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "asm statement transpiles" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_asm.fn";

    const input =
        "fun main() {\n" ++
        "  num x = 1;\n" ++
        "  num y = 0;\n" ++
        "  asm volatile (out y: \"=r\" = y; in x: \"r\" = x; clobber \"memory\") \"mov %[x], %[y]\";\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "__asm__ __volatile__") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "\"=r\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "\"memory\"") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "asm block preserves newlines" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_asm_block.fn";

    const input =
        "fun main() {\n" ++
        "  asm volatile {\n" ++
        "    mov x0, 0\n" ++
        "    mov x8, 93\n" ++
        "    svc 0\n" ++
        "  };\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "mov x0, 0\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "mov x8, 93\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "svc 0\\n") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "transitive std.net import emits socket headers" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_transitive_std_net.fn";

    const input =
        "imp std.net;\n" ++
        "fun main() {\n" ++
        "  ret;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <sys/socket.h>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <netinet/in.h>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <arpa/inet.h>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "#include <unistd.h>") != null);

    fs.cwd().deleteFile(ifilepath) catch {};
}

test "main num return emits exit status" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_main_num_return.fn";

    const input =
        "fun main() num {\n" ++
        "  ret 7;\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "int main") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "return (int)(7);") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "map compound key specialization symbols emit" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_map_compound_key.fn";

    const input =
        "imp stdlib.std.map;\n" ++
        "compound UserKey { num id; num region; }\n" ++
        "fun main() {\n" ++
        "  Map<UserKey, str> by_user;\n" ++
        "  by_user.init(8);\n" ++
        "  UserKey a = UserKey{id = 7, region = 1};\n" ++
        "  UserKey b = UserKey{id = 9, region = 2};\n" ++
        "  by_user.put(a, \"alice\");\n" ++
        "  by_user.put(b, \"bob\");\n" ++
        "  str out = by_user.get(a);\n" ++
        "  bin present = by_user.has(a);\n" ++
        "  by_user.remove(b);\n" ++
        "  if present == false { ret; }\n" ++
        "  if out == \"alice\" { ret; }\n" ++
        "  by_user.free();\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Map__UserKey__str") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Map__UserKey__str__init") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Map__UserKey__str__put") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Map__UserKey__str__get") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Map__UserKey__str__has") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Map__UserKey__str__remove") != null);

    try fs.cwd().deleteFile(ifilepath);
}

test "stdlib hot path stress transpiles" {
    const allocator = std.testing.allocator;
    const ifilepath = "codegen_stdlib_hot_stress.fn";

    const input =
        "imp stdlib.std.map;\n" ++
        "fun main() {\n" ++
        "  Map<num, str> m;\n" ++
        "  m.init(256);\n" ++
        "  num i = 0;\n" ++
        "  for i < 2000 {\n" ++
        "    m.put(i, \"v\");\n" ++
        "    i = i + 1;\n" ++
        "  }\n" ++
        "  i = 0;\n" ++
        "  for i < 1000 {\n" ++
        "    if m.has(i) == false {\n" ++
        "      ret;\n" ++
        "    }\n" ++
        "    i = i + 1;\n" ++
        "  }\n" ++
        "  m.remove(42);\n" ++
        "  str out = m.get(7);\n" ++
        "  if m.has(7) == true {\n" ++
        "    if out == \"v\" { ret; }\n" ++
        "  }\n" ++
        "}\n";

    const out_owned = try runTranspile(allocator, ifilepath, input);
    defer allocator.free(out_owned);

    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Map__num__str__put") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Map__num__str__has") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_owned, "Map__num__str__remove") != null);

    try fs.cwd().deleteFile(ifilepath);
}
