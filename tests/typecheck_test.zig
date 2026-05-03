const std = @import("std");
const fs = std.fs;
const ParseProcess = @import("parser").ParseProcess;
const lexer = @import("lexer");
const codegen = @import("codegen");

fn runTranspileExpectError(allocator: std.mem.Allocator, input_path: []const u8, input: []const u8) !void {
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, input_path, .{ .read = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, input);
    }

    var transpile_proc = try codegen.TranspileProcess.init(allocator, input_path, "_ignored.c", .{ .outf = false });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);

    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
        std.Io.Dir.cwd().deleteFile(std.testing.io, input_path) catch {};
    }

    try lex_proc.lex();
    try parse_proc.parse();

    // Should error during transpile() due to typecheck.
    _ = transpile_proc.transpile() catch return;

    return error.ExpectedFailure;
}

fn runTranspileExpectOk(allocator: std.mem.Allocator, input_path: []const u8, input: []const u8) !void {
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, input_path, .{ .read = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, input);
    }

    var transpile_proc = try codegen.TranspileProcess.init(allocator, input_path, "_ignored.c", .{ .outf = false });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);

    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
        std.Io.Dir.cwd().deleteFile(std.testing.io, input_path) catch {};
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

test "typecheck await requires async function context" {
    const input =
        "async fun inc(num a) num { ret a + 1; }\n" ++
        "fun main() {\n" ++
        "  num x = await inc(1);\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_await_requires_async_context.fn", input);
}

test "typecheck async call requires await" {
    const input =
        "async fun inc(num a) num { ret a + 1; }\n" ++
        "async fun main() {\n" ++
        "  num x = inc(1);\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_async_call_requires_await.fn", input);
}

test "typecheck await target must be async" {
    const input =
        "fun inc(num a) num { ret a + 1; }\n" ++
        "async fun main() {\n" ++
        "  num x = await inc(1);\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_await_target_must_be_async.fn", input);
}

test "typecheck async call with await is ok" {
    const input =
        "async fun inc(num a) num { ret a + 1; }\n" ++
        "async fun main() {\n" ++
        "  num x = await inc(1);\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_async_call_with_await_ok.fn", input);
}

test "typecheck let await async call is ok" {
    const input =
        "async fun inc(num a) num { ret a + 1; }\n" ++
        "async fun main() {\n" ++
        "  let out = await inc(41);\n" ++
        "  num verify = out + 1;\n" ++
        "  _ = verify;\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_let_await_async_call_ok.fn", input);
}

test "typecheck let async call requires await" {
    const input =
        "async fun inc(num a) num { ret a + 1; }\n" ++
        "async fun main() {\n" ++
        "  let out = inc(41);\n" ++
        "  _ = out;\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_let_async_call_requires_await.fn", input);
}

test "typecheck let await requires async function context" {
    const input =
        "async fun inc(num a) num { ret a + 1; }\n" ++
        "fun main() {\n" ++
        "  let out = await inc(41);\n" ++
        "  _ = out;\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_let_await_requires_async_context.fn", input);
}

test "typecheck let await target must be async" {
    const input =
        "fun inc(num a) num { ret a + 1; }\n" ++
        "async fun main() {\n" ++
        "  let out = await inc(41);\n" ++
        "  _ = out;\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_let_await_target_not_async.fn", input);
}

test "typecheck std.channel async wrappers with await are ok" {
    const input =
        "imp std.channel;\n" ++
        "async fun main() {\n" ++
        "  Channel<num> ch = channel_new_cap(0, 1);\n" ++
        "  num rc_send = await ch.send_async(7);\n" ++
        "  let out = await ch.recv_async();\n" ++
        "\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  _ = await b.send_async(9);\n" ++
        "  num sel = 0;\n" ++
        "  num idx = -1;\n" ++
        "  num rc_sel = await a.select_recv_with_async(&b, &sel, &idx);\n" ++
        "\n" ++
        "  _ = rc_send + out + rc_sel + sel + idx;\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_std_channel_async_wrappers_ok.fn", input);
}

test "typecheck std.channel async wrappers require await" {
    const input =
        "imp std.channel;\n" ++
        "async fun main() {\n" ++
        "  Channel<num> ch = channel_new(0);\n" ++
        "  num rc = ch.send_async(7);\n" ++
        "  _ = rc;\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_std_channel_async_wrappers_require_await.fn", input);
}

test "typecheck std.channel async forwarding APIs with await are ok" {
    const input =
        "imp std.channel;\n" ++
        "async fun main() {\n" ++
        "  Channel<num> src = channel_new_cap(0, 1);\n" ++
        "  Channel<num> dst = channel_new_cap(0, 1);\n" ++
        "  _ = await src.send_async(5);\n" ++
        "  num rc_forward = await src.forward_one_to_async(&dst, 20);\n" ++
        "  let moved = await dst.recv_async();\n" ++
        "\n" ++
        "  Channel<num> a = channel_new(0);\n" ++
        "  Channel<num> b = channel_new(0);\n" ++
        "  Channel<num> out = channel_new(0);\n" ++
        "  _ = await b.send_async(9);\n" ++
        "  num idx = -1;\n" ++
        "  num rc_select_forward = await a.select_forward_one_to_async(&b, &out, 20, &idx);\n" ++
        "  let selected = await out.recv_async();\n" ++
        "\n" ++
        "  _ = rc_forward + moved + rc_select_forward + selected + idx;\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_std_channel_async_forwarding_ok.fn", input);
}

test "typecheck std.channel async forwarding requires await" {
    const input =
        "imp std.channel;\n" ++
        "async fun main() {\n" ++
        "  Channel<num> src = channel_new(0);\n" ++
        "  Channel<num> dst = channel_new(0);\n" ++
        "  num rc = src.forward_one_to_async(&dst, 10);\n" ++
        "  _ = rc;\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_std_channel_async_forwarding_require_await.fn", input);
}

test "typecheck async method call requires await" {
    const input =
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "impl Counter {\n" ++
        "  async add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Counter c;\n" ++
        "  c.base = 1;\n" ++
        "  num out = c.add(2);\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_async_method_call_requires_await.fn", input);
}

test "typecheck await async method call is ok" {
    const input =
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "impl Counter {\n" ++
        "  async add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Counter c;\n" ++
        "  c.base = 1;\n" ++
        "  num out = await c.add(2);\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_await_async_method_ok.fn", input);
}

test "typecheck await async field method call is ok" {
    const input =
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "compound Holder {\n" ++
        "  Counter counter;\n" ++
        "}\n" ++
        "impl Counter {\n" ++
        "  async add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Holder h;\n" ++
        "  h.counter.base = 1;\n" ++
        "  num out = await h.counter.add(2);\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_await_async_field_method_ok.fn", input);
}

test "typecheck await async generic function is ok" {
    const input =
        "async fun id<T>(T x) T { ret x; }\n" ++
        "async fun main() {\n" ++
        "  num out = await id(2);\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_await_async_generic_function_ok.fn", input);
}

test "typecheck await async method in generic impl is ok" {
    const input =
        "compound Box<T> {\n" ++
        "  num pad;\n" ++
        "}\n" ++
        "impl Box<T> {\n" ++
        "  async forty_two() num { ret 42; }\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Box<num> b;\n" ++
        "  num out = await b.forty_two();\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_await_async_generic_method_ok.fn", input);
}

test "typecheck async quirk method call requires await" {
    const input =
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "quirk AsyncCounter {\n" ++
        "  async add(num x) num;\n" ++
        "}\n" ++
        "impl Counter as AsyncCounter {\n" ++
        "  async add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Counter c;\n" ++
        "  c.base = 1;\n" ++
        "  AsyncCounter q = &c;\n" ++
        "  num out = q.add(2);\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_async_quirk_method_requires_await.fn", input);
}

test "typecheck await async quirk method call is ok" {
    const input =
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "quirk AsyncCounter {\n" ++
        "  async add(num x) num;\n" ++
        "}\n" ++
        "impl Counter as AsyncCounter {\n" ++
        "  async add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Counter c;\n" ++
        "  c.base = 1;\n" ++
        "  AsyncCounter q = &c;\n" ++
        "  num out = await q.add(2);\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_await_async_quirk_method_ok.fn", input);
}

test "typecheck await async quirk field method call is ok" {
    const input =
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "quirk AsyncCounter {\n" ++
        "  async add(num x) num;\n" ++
        "}\n" ++
        "compound Holder {\n" ++
        "  AsyncCounter q;\n" ++
        "}\n" ++
        "impl Counter as AsyncCounter {\n" ++
        "  async add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Counter c;\n" ++
        "  c.base = 1;\n" ++
        "  Holder h = Holder{ q = &c };\n" ++
        "  num out = await h.q.add(2);\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_await_async_quirk_field_method_ok.fn", input);
}

test "typecheck await async quirk function-returned receiver method call is ok" {
    const input =
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "quirk AsyncCounter {\n" ++
        "  async add(num x) num;\n" ++
        "}\n" ++
        "impl Counter as AsyncCounter {\n" ++
        "  async add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "fun passthrough(AsyncCounter q) AsyncCounter {\n" ++
        "  ret q;\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Counter c;\n" ++
        "  c.base = 1;\n" ++
        "  AsyncCounter q = &c;\n" ++
        "  num out = await passthrough(q).add(2);\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_await_async_quirk_function_receiver_ok.fn", input);
}

test "typecheck await async quirk nested composite receiver method call is ok" {
    const input =
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "quirk AsyncCounter {\n" ++
        "  async add(num x) num;\n" ++
        "}\n" ++
        "compound Holder {\n" ++
        "  AsyncCounter q;\n" ++
        "}\n" ++
        "compound Wrap {\n" ++
        "  Holder h;\n" ++
        "}\n" ++
        "impl Counter as AsyncCounter {\n" ++
        "  async add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "fun wrap(AsyncCounter q) Wrap {\n" ++
        "  ret Wrap{ h = Holder{ q = q } };\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Counter c;\n" ++
        "  c.base = 1;\n" ++
        "  AsyncCounter q = &c;\n" ++
        "  num out = await wrap(q).h.q.add(2);\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_await_async_quirk_nested_receiver_ok.fn", input);
}

test "typecheck await async quirk generic wrapper receiver method call is ok" {
    const input =
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "quirk AsyncCounter {\n" ++
        "  async add(num x) num;\n" ++
        "}\n" ++
        "compound Box<T> {\n" ++
        "  T v;\n" ++
        "}\n" ++
        "impl Counter as AsyncCounter {\n" ++
        "  async add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "fun pack(AsyncCounter q) Box<AsyncCounter> {\n" ++
        "  ret Box<AsyncCounter>{ v = q };\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Counter c;\n" ++
        "  c.base = 1;\n" ++
        "  AsyncCounter q = &c;\n" ++
        "  num out = await pack(q).v.add(2);\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_await_async_quirk_generic_wrapper_receiver_ok.fn", input);
}

test "typecheck await async quirk helper pointer generic wrapper receiver method call is ok" {
    const input =
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "quirk AsyncCounter {\n" ++
        "  async add(num x) num;\n" ++
        "}\n" ++
        "compound Box<T> {\n" ++
        "  T v;\n" ++
        "}\n" ++
        "impl Counter as AsyncCounter {\n" ++
        "  async add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "fun ptr(Box<AsyncCounter>* b) Box<AsyncCounter>* {\n" ++
        "  ret b;\n" ++
        "}\n" ++
        "fun box(Box<AsyncCounter>* b) Box<AsyncCounter> {\n" ++
        "  ret *b;\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Counter c;\n" ++
        "  c.base = 1;\n" ++
        "  AsyncCounter q = &c;\n" ++
        "  Box<AsyncCounter> b = Box<AsyncCounter>{ v = q };\n" ++
        "  num out = await (box(ptr(&b)).v).add(2);\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_await_async_quirk_helper_ptr_generic_wrapper_receiver_ok.fn", input);
}

test "typecheck generic wrapper non-quirk receiver method call errors" {
    const input =
        "compound Box<T> {\n" ++
        "  T v;\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Box<num> b = Box<num>{ v = 1 };\n" ++
        "  num out = await b.v.add(2);\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_generic_wrapper_non_quirk_receiver_err.fn", input);
}

test "typecheck generic wrapper async receiver call requires await" {
    const input =
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "quirk AsyncCounter {\n" ++
        "  async add(num x) num;\n" ++
        "}\n" ++
        "compound Box<T> {\n" ++
        "  T v;\n" ++
        "}\n" ++
        "impl Counter as AsyncCounter {\n" ++
        "  async add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "fun pack(AsyncCounter q) Box<AsyncCounter> {\n" ++
        "  ret Box<AsyncCounter>{ v = q };\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Counter c;\n" ++
        "  c.base = 1;\n" ++
        "  AsyncCounter q = &c;\n" ++
        "  num out = pack(q).v.add(2);\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_generic_wrapper_async_call_requires_await.fn", input);
}

test "typecheck generic wrapper await non-async receiver errors" {
    const input =
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "quirk CounterOps {\n" ++
        "  add(num x) num;\n" ++
        "}\n" ++
        "compound Box<T> {\n" ++
        "  T v;\n" ++
        "}\n" ++
        "impl Counter as CounterOps {\n" ++
        "  add(num x) num { ret self.base + x; }\n" ++
        "}\n" ++
        "fun pack(CounterOps q) Box<CounterOps> {\n" ++
        "  ret Box<CounterOps>{ v = q };\n" ++
        "}\n" ++
        "async fun main() {\n" ++
        "  Counter c;\n" ++
        "  c.base = 1;\n" ++
        "  CounterOps q = &c;\n" ++
        "  num out = await pack(q).v.add(2);\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_generic_wrapper_await_non_async_err.fn", input);
}

test "typecheck quirk async signature mismatch errors" {
    const input =
        "compound Counter {\n" ++
        "  num base;\n" ++
        "}\n" ++
        "quirk AsyncCounter {\n" ++
        "  async add(num x) num;\n" ++
        "}\n" ++
        "impl Counter as AsyncCounter {\n" ++
        "  add(num x) num { ret self.base + x; }\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_quirk_async_sig_mismatch.fn", input);
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
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, lib_path, .{ .read = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, lib_input);
    }
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, lib_path) catch {};

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

test "pub compound from import works in compound init expression" {
    const lib_input =
        "pub compound User {\n" ++
        "  num id;\n" ++
        "  str name;\n" ++
        "}\n";

    const lib_path = "typecheck_pub_compound_lib.fn";
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, lib_path, .{ .read = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, lib_input);
    }
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, lib_path) catch {};

    const input =
        "imp typecheck_pub_compound_lib;\n" ++
        "fun main() {\n" ++
        "  User u = User{id = 1, name = \"Alice\"};\n" ++
        "  if u.id == 1 { ret; }\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_pub_compound_init.fn", input);
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
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, lib_path, .{ .read = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, lib_input);
    }
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, lib_path) catch {};

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
        "impl Data as Display {\n" ++
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

test "typecheck chained logical comparisons parse and typecheck" {
    const input =
        "fun main() {\n" ++
        "  str s = \"ab\";\n" ++
        "  num i = 0;\n" ++
        "  if s[i] == 'a' || s[i] == 'b' || s[i] == 'c' { ret; }\n" ++
        "  if s[i] != 'z' && s[i] != 'y' { ret; }\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_if_logic_chain_cmp_ok.fn", input);
}

test "typecheck std serde quirks with json" {
    const input =
        "imp stdlib.std.serde;\n" ++
        "imp stdlib.std.json;\n" ++
        "fun main() {\n" ++
        "  JsonObject j = json_object_init();\n" ++
        "  j.set(\"name\", \"fun\");\n" ++
        "  Serialize js = &j;\n" ++
        "  str json_text = to_string(js);\n" ++
        "\n" ++
        "  JsonObject j2 = json_object_init();\n" ++
        "  Deserialize jd = &j2;\n" ++
        "  from_string(jd, json_text);\n" ++
        "\n" ++
        "  if j2.get(\"name\") == \"fun\" { ret; }\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_std_serde_json_ok.fn", input);
}

test "typecheck std serde quirks with toml" {
    const input =
        "imp stdlib.std.serde;\n" ++
        "imp stdlib.std.toml;\n" ++
        "fun main() {\n" ++
        "  TomlDoc t = toml_doc_init();\n" ++
        "  t.set(\"channel\", \"stable\");\n" ++
        "  Serialize ts = &t;\n" ++
        "  str toml_text = to_string(ts);\n" ++
        "\n" ++
        "  TomlDoc t2 = toml_doc_init();\n" ++
        "  Deserialize td = &t2;\n" ++
        "  from_string(td, toml_text);\n" ++
        "\n" ++
        "  if t2.get(\"channel\") == \"stable\" { ret; }\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_std_serde_toml_ok.fn", input);
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
        "impl Point as HasX {\n" ++
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
        "impl Point as HasX {\n" ++
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
        "impl Point as Q {\n" ++
        "  a() num { ret 1; }\n" ++
        "}\n";
    try runTranspileExpectError(std.testing.allocator, "typecheck_quirk_impl_missing_methods.fn", input);
}

test "typecheck let inference covers compounds methods function returns and generics" {
    const input =
        "compound Point { num x; num y; }\n" ++
        "impl Point {\n" ++
        "  sum() num { ret self.x + self.y; }\n" ++
        "  shifted(num dx, num dy) Point { ret Point{x = self.x + dx, y = self.y + dy}; }\n" ++
        "}\n" ++
        "fun make_point(num x, num y) Point { ret Point{x = x, y = y}; }\n" ++
        "fun pick_first<T>(T a, T b) T { _ = b; ret a; }\n" ++
        "fun main() {\n" ++
        "  let from_compound_init = Point{x = 1, y = 2};\n" ++
        "  let from_function_return = make_point(10, 20);\n" ++
        "  let from_method_return = from_function_return.shifted(3, 4);\n" ++
        "  let from_method_num = from_method_return.sum();\n" ++
        "  let from_generic_num = pick_first(100, 200);\n" ++
        "  let from_generic_compound = pick_first(from_compound_init, from_function_return);\n" ++
        "  num total = from_method_num + from_generic_num + from_generic_compound.x;\n" ++
        "  if total > 0 { ret; }\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_let_infer_full_ok.fn", input);
}

test "typecheck generic inference after init regression is ok" {
    const input =
        "imp std.c.io;\n" ++
        "\n" ++
        "compound Box<T> {\n" ++
        "  T value;\n" ++
        "}\n" ++
        "\n" ++
        "compound Pair<L, R> {\n" ++
        "  L left;\n" ++
        "  R right;\n" ++
        "}\n" ++
        "\n" ++
        "fun make_box<T>(T x) Box<T> {\n" ++
        "  ret Box<T>{value = x};\n" ++
        "}\n" ++
        "\n" ++
        "fun make_pair<L, R>(L left, R right) Pair<L, R> {\n" ++
        "  ret Pair<L, R>{left = left, right = right};\n" ++
        "}\n" ++
        "\n" ++
        "fun pick_left<L, R>(Pair<L, R> p) L {\n" ++
        "  ret p.left;\n" ++
        "}\n" ++
        "\n" ++
        "fun swap_pair<L, R>(Pair<L, R> p) Pair<R, L> {\n" ++
        "  ret Pair<R, L>{left = p.right, right = p.left};\n" ++
        "}\n" ++
        "\n" ++
        "fun main() {\n" ++
        "  let nbox = Box{value = 7};\n" ++
        "  nbox.value += 1;\n" ++
        "  let sbox = make_box(\"hi\");\n" ++
        "  let pair = make_pair(nbox.value, sbox.value);\n" ++
        "  let swapped = swap_pair(pair);\n" ++
        "  let left_num = pick_left(pair);\n" ++
        "  let left_str = pick_left(swapped);\n" ++
        "  printf(\"nbox=%lld sbox=%s\\n\", nbox.value, sbox.value);\n" ++
        "  printf(\"pair=(%lld,%s) swapped=(%s,%lld)\\n\", pair.left, pair.right, swapped.left, swapped.right);\n" ++
        "  printf(\"picks=(%lld,%s)\\n\", left_num, left_str);\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_generic_inference_after_init_regression_ok.fn", input);
}

test "typecheck inferred generic field assignment mismatch errors" {
    const input =
        "compound Box<T> {\n" ++
        "  T value;\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  let nbox = Box{value = 7};\n" ++
        "  nbox.value = true;\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_generic_field_assign_mismatch_err.fn", input);
}

test "typecheck let inference edge cases ok" {
    const input =
        "compound Point { num x; num y; }\n" ++
        "fun make_point(num x, num y) Point { ret Point{x = x, y = y}; }\n" ++
        "fun min_num(num a, num b) num { if a < b { ret a; } ret b; }\n" ++
        "fun max_num(num a, num b) num { if a > b { ret a; } ret b; }\n" ++
        "fun abs_dec(dec x) dec { if x < 0 { ret -x; } ret x; }\n" ++
        "fun lerp_dec(num a, num b, dec t) dec { ret (a + b) + t; }\n" ++
        "fun main() {\n" ++
        "  let n = 42;\n" ++
        "  let d = 3.5;\n" ++
        "  let p = Point{x = 1, y = 2};\n" ++
        "  let p2 = make_point(3, 4);\n" ++
        "  let arr = [1, 2, 3];\n" ++
        "  let points = [Point{x = 0, y = 1}, Point{x = 2, y = 3}];\n" ++
        "  let mix_point = make_point(min_num(n, 10), max_num(n, 20));\n" ++
        "  let mix_points = [make_point(n, n + 1), make_point(n + 2, n + 3)];\n" ++
        "  let dec_mix = lerp_dec(n, n + 2, d) + abs_dec(d / 2);\n" ++
        "  let dec_mix2 = lerp_dec(n, n + 2, d + 1) / 2;\n" ++
        "  num n2 = n;\n" ++
        "  dec d2 = d;\n" ++
        "  Point p3 = p2;\n" ++
        "  let arr2 = arr;\n" ++
        "  Point p4 = mix_point;\n" ++
        "  dec d3 = dec_mix;\n" ++
        "  dec d4 = dec_mix2;\n" ++
        "  Point p5 = points[0];\n" ++
        "  Point p6 = mix_points[0];\n" ++
        "  num n3 = arr2[0];\n" ++
        "  num s = n2 + n3;\n" ++
        "  if s > 0 { ret; }\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_let_infer_edge_ok.fn", input);
}

test "typecheck let inference dec narrowing errors" {
    const input =
        "fun lerp_dec(num a, num b, dec t) dec { ret (a + b) + t; }\n" ++
        "fun main() {\n" ++
        "  let dec_mix2 = lerp_dec(1, 2, 0.5) / 2;\n" ++
        "  num bad = dec_mix2;\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_let_infer_dec_narrow_err.fn", input);
}

test "typecheck let cannot infer quirk type" {
    const input =
        "compound Point { num x; num y; }\n" ++
        "quirk HasX { get_x() num; }\n" ++
        "impl Point as HasX { get_x() num { ret self.x; } }\n" ++
        "fun as_hasx(Point* p) HasX { ret p; }\n" ++
        "fun main() {\n" ++
        "  Point p = Point{x = 1, y = 2};\n" ++
        "  let inferred_quirk = as_hasx(&p);\n" ++
        "  inferred_quirk.get_x();\n" ++
        "}\n";

    try runTranspileExpectError(std.testing.allocator, "typecheck_let_infer_quirk_err.fn", input);
}

test "typecheck enums behave as numeric values across contexts" {
    const input =
        "enum Color { Red, Green, Blue }\n" ++
        "fun main() {\n" ++
        "  Color c = Color.Red;\n" ++
        "  num n = Color.Blue;\n" ++
        "  c = n;\n" ++
        "  let inferred = Color.Green;\n" ++
        "  let mixed = inferred + 1;\n" ++
        "  if mixed > 1 { ret; }\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_enum_numeric_ok.fn", input);
}

test "typecheck map supports compound key operations" {
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
        "  str va = by_user.get(a);\n" ++
        "  str vb = by_user.get_or(UserKey{id = 99, region = 9}, \"missing\");\n" ++
        "  if by_user.has(a) {\n" ++
        "    by_user.remove(b);\n" ++
        "  }\n" ++
        "  if va == \"alice\" {\n" ++
        "    if vb == \"missing\" { ret; }\n" ++
        "  }\n" ++
        "  by_user.free();\n" ++
        "}\n";

    try runTranspileExpectOk(std.testing.allocator, "typecheck_map_compound_key_ok.fn", input);
}
