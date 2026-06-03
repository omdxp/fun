const std = @import("std");
const fs = std.fs;
const ParseProcess = @import("parser").ParseProcess;
const lexer = @import("lexer");
const codegen = @import("codegen");
const ast = @import("ast");

test "ParseProcess parse_function" {
    const ifilepath = "ParseProcess_parse_function.fn";
    const ofilepath = "ParseProcess_parse_function.c";
    // Mock input file
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input = "fun test() { ret; }";
        try file.writeStreamingAll(std.testing.io, input);
    }

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);

    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
    }

    try lex_proc.lex();
    try parse_proc.parse();
    const nodes = transpile_proc.nodes.items();
    try std.testing.expectEqual(1, nodes.len);
    try std.testing.expectEqual(nodes[0].type, .Function);
    try std.testing.expectEqualStrings("test", nodes[0].node_variant.?.function.name.?.items);

    // Delete test files
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}

test "ParseProcess parse_async_function" {
    const ifilepath = "ParseProcess_parse_async_function.fn";
    const ofilepath = "ParseProcess_parse_async_function.c";
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input = "async fun test() { ret; }";
        try file.writeStreamingAll(std.testing.io, input);
    }

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);

    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
    }

    try lex_proc.lex();
    try parse_proc.parse();
    const nodes = transpile_proc.nodes.items();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(ast.NodeType.Function, nodes[0].type);
    try std.testing.expect(nodes[0].node_variant.?.function.is_async);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}

test "ParseProcess parse_async_impl_method" {
    const ifilepath = "ParseProcess_parse_async_impl_method.fn";
    const ofilepath = "ParseProcess_parse_async_impl_method.c";
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input =
            "compound Counter { num base; }\n" ++
            "impl Counter {\n" ++
            "  async add(num x) num { ret self.base + x; }\n" ++
            "}\n";
        try file.writeStreamingAll(std.testing.io, input);
    }

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);

    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
    }

    try lex_proc.lex();
    try parse_proc.parse();

    const nodes = transpile_proc.nodes.items();
    try std.testing.expectEqual(@as(usize, 2), nodes.len);
    try std.testing.expectEqual(ast.NodeType.Compound, nodes[0].type);
    try std.testing.expectEqual(ast.NodeType.Impl, nodes[1].type);

    const methods = nodes[1].node_variant.?.impl.methods.items();
    try std.testing.expectEqual(@as(usize, 1), methods.len);
    try std.testing.expectEqual(ast.NodeType.Function, methods[0].type);
    try std.testing.expect(methods[0].node_variant.?.function.is_async);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}

test "ParseProcess parse_async_quirk_method" {
    const ifilepath = "ParseProcess_parse_async_quirk_method.fn";
    const ofilepath = "ParseProcess_parse_async_quirk_method.c";
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input =
            "quirk AsyncQ {\n" ++
            "  async get() num;\n" ++
            "}\n";
        try file.writeStreamingAll(std.testing.io, input);
    }

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);

    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
    }

    try lex_proc.lex();
    try parse_proc.parse();

    const nodes = transpile_proc.nodes.items();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(ast.NodeType.Quirk, nodes[0].type);

    const methods = nodes[0].node_variant.?.quirk.methods.items();
    try std.testing.expectEqual(@as(usize, 1), methods.len);
    try std.testing.expect(methods[0].is_async);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}

test "ParseProcess parse_await_expression" {
    const ifilepath = "ParseProcess_parse_await_expression.fn";
    const ofilepath = "ParseProcess_parse_await_expression.c";
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input =
            "fun inc(num x) num { ret x + 1; }\n" ++
            "fun main() {\n" ++
            "  num y = await inc(41);\n" ++
            "  ret y;\n" ++
            "}\n";
        try file.writeStreamingAll(std.testing.io, input);
    }

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);

    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
    }

    try lex_proc.lex();
    try parse_proc.parse();
    const nodes = transpile_proc.nodes.items();
    try std.testing.expectEqual(@as(usize, 2), nodes.len);
    try std.testing.expectEqual(ast.NodeType.Function, nodes[0].type);
    try std.testing.expectEqual(ast.NodeType.Function, nodes[1].type);

    const main_body = nodes[1].node_variant.?.function.body.?;
    const stmts = main_body.node_variant.?.body.statements.items();
    try std.testing.expect(stmts.len >= 1);
    try std.testing.expectEqual(ast.NodeType.Variable, stmts[0].type);
    const val = stmts[0].node_variant.?.variable.val.?;
    try std.testing.expectEqual(ast.NodeType.Unary, val.type);
    try std.testing.expectEqualStrings("await", val.node_variant.?.unary.op);
    const awaited = val.node_variant.?.unary.operand;
    try std.testing.expectEqual(ast.NodeType.Expression, awaited.type);
    try std.testing.expectEqualStrings("()", awaited.node_variant.?.exp.op);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}

test "ParseProcess parses variadic function declaration" {
    const ifilepath = "ParseProcess_parse_variadic_function.fn";
    const ofilepath = "ParseProcess_parse_variadic_function.c";
    // Mock input file
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input = "fun v(num a, ...) num;";
        try file.writeStreamingAll(std.testing.io, input);
    }

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);

    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
    }

    try lex_proc.lex();
    try parse_proc.parse();
    const nodes = transpile_proc.nodes.items();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(ast.NodeType.Function, nodes[0].type);
    try std.testing.expect(nodes[0].node_variant.?.function.is_variadic);

    // Delete test files
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}

test "ParseProcess parse_return" {
    const ifilepath = "ParseProcess_parse_return.fn";
    const ofilepath = "ParseProcess_parse_return.c";
    // Mock input file
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input = "ret 42;";
        try file.writeStreamingAll(std.testing.io, input);
    }

    // const allocator = std.testing.allocator;
    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);

    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
    }

    try lex_proc.lex();
    try parse_proc.parse();
    const nodes = transpile_proc.nodes.items();
    try std.testing.expectEqual(1, nodes.len);
    try std.testing.expectEqual(nodes[0].type, .StatementReturn);

    // Delete test files
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}

test "ParseProcess parse_expression" {
    const ifilepath = "ParseProcess_parse_expression.fn";
    const ofilepath = "ParseProcess_parse_expression.c";
    // Mock input file
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input = "1 + 2 * 3";
        try file.writeStreamingAll(std.testing.io, input);
    }

    // const allocator = std.testing.allocator;
    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);

    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
    }

    try lex_proc.lex();
    try parse_proc.parse();
    const nodes = transpile_proc.nodes.items();
    try std.testing.expectEqual(1, nodes.len);
    try std.testing.expectEqual(nodes[0].type, .Expression);

    // Delete test files
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}

test "ParseProcess parses array literal vs indexing" {
    const ifilepath = "ParseProcess_array_literal_vs_index.fn";
    const ofilepath = "ParseProcess_array_literal_vs_index.c";

    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input =
            "fun main() {\n" ++
            "  num[] arr = [1, 2, 3];\n" ++
            "  num x = arr[0];\n" ++
            "}\n";
        try file.writeStreamingAll(std.testing.io, input);
    }

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);

    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
    }

    try lex_proc.lex();
    try parse_proc.parse();

    const nodes = transpile_proc.nodes.items();
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(ast.NodeType.Function, nodes[0].type);

    const fun_body = nodes[0].node_variant.?.function.body.?;
    try std.testing.expectEqual(ast.NodeType.Body, fun_body.type);

    const stmts = fun_body.node_variant.?.body.statements.items();
    try std.testing.expect(stmts.len >= 2);

    const arr_decl = stmts[0].*;
    try std.testing.expectEqual(ast.NodeType.Variable, arr_decl.type);
    const arr_val = arr_decl.node_variant.?.variable.val.?;
    try std.testing.expectEqual(ast.NodeType.Bracket, arr_val.type);

    const x_decl = stmts[1].*;
    try std.testing.expectEqual(ast.NodeType.Variable, x_decl.type);
    const x_val = x_decl.node_variant.?.variable.val.?;
    try std.testing.expectEqual(ast.NodeType.Expression, x_val.type);
    try std.testing.expectEqualStrings("[]", x_val.node_variant.?.exp.op);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}

test "ParseProcess parses if condition with == operator" {
    const ifilepath = "ParseProcess_if_condition_eq.fn";
    const ofilepath = "ParseProcess_if_condition_eq.c";

    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input =
            "fun main() {\n" ++
            "  num n = 0;\n" ++
            "  if n == 0 { ret; }\n" ++
            "}\n";
        try file.writeStreamingAll(std.testing.io, input);
    }

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);

    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
    }

    try lex_proc.lex();
    try parse_proc.parse();

    const nodes = transpile_proc.nodes.items();
    const fun_body = nodes[0].node_variant.?.function.body.?;
    const stmts = fun_body.node_variant.?.body.statements.items();
    // var decl + if
    try std.testing.expect(stmts.len >= 2);
    try std.testing.expectEqual(ast.NodeType.StatementIf, stmts[1].type);
    const cond = stmts[1].node_variant.?.statement.if_stmt.condition;
    try std.testing.expectEqual(ast.NodeType.Expression, cond.type);
    try std.testing.expectEqualStrings("==", cond.node_variant.?.exp.op);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}

test "ParseProcess parse returns error on malformed input (no crash)" {
    const ifilepath = "ParseProcess_parse_malformed_missing_semicolon.fn";
    const ofilepath = "ParseProcess_parse_malformed_missing_semicolon.c";

    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        // Missing ';' after variable declaration.
        const input =
            "fun main() {\n" ++
            "  num x = 1\n" ++
            "  ret;\n" ++
            "}\n";
        try file.writeStreamingAll(std.testing.io, input);
    }

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);

    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
    }

    try lex_proc.lex();
    if (parse_proc.parse()) |_| {
        try std.testing.expect(false);
    } else |_| {
        // Any parse error is acceptable; the key requirement is that we do not crash.
    }

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}

test "ParseProcess parse returns error on malformed dot (no crash)" {
    const ifilepath = "ParseProcess_parse_malformed_dot.fn";
    const ofilepath = "ParseProcess_parse_malformed_dot.c";

    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        // Missing identifier after '.'
        const input =
            "imp std.;\n" ++
            "fun main() {\n" ++
            "  ret;\n" ++
            "}\n";
        try file.writeStreamingAll(std.testing.io, input);
    }

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);

    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
    }

    try lex_proc.lex();
    if (parse_proc.parse()) |_| {
        try std.testing.expect(false);
    } else |_| {
        // Any parse error is acceptable; the key requirement is that we do not crash.
    }

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}

test "ParseProcess parse returns error on malformed binary expression rhs (no crash)" {
    const ifilepath = "ParseProcess_parse_malformed_binary_rhs.fn";
    const ofilepath = "ParseProcess_parse_malformed_binary_rhs.c";

    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input =
            "fun main() {\n" ++
            "  num x = 1 + ;\n" ++
            "  ret;\n" ++
            "}\n";
        try file.writeStreamingAll(std.testing.io, input);
    }

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);

    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
    }

    try lex_proc.lex();
    if (parse_proc.parse()) |_| {
        try std.testing.expect(false);
    } else |_| {
        // Any parse error is acceptable; the key requirement is that we do not crash.
    }

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}

test "ParseProcess parse returns error on malformed fit dot branch (no crash)" {
    const ifilepath = "ParseProcess_parse_malformed_fit_dot_branch.fn";
    const ofilepath = "ParseProcess_parse_malformed_fit_dot_branch.c";

    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input =
            "fun main() {\n" ++
            "  num x = 1;\n" ++
            "  fit x {\n" ++
            "    . -> { ret; },\n" ++
            "  }\n" ++
            "}\n";
        try file.writeStreamingAll(std.testing.io, input);
    }

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);

    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
    }

    try lex_proc.lex();
    if (parse_proc.parse()) |_| {
        try std.testing.expect(false);
    } else |_| {
        // Any parse error is acceptable; the key requirement is that we do not crash.
    }

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}

// ---------------------------------------------------------------------------
// Lookahead index tests.
//
// `token_peek_n` / `token_peek_prev_n` / `token_peek_prev_stream_n` were rewritten
// to resolve the n-th significant (non-newline/comment) token through an O(1)
// rank index instead of an O(n) linear rescan. These tests pin down that the new
// implementation returns *exactly* the same tokens as a naive linear scan, for
// every cursor position and offset, and that the index is correctly rebuilt when
// the token stream is structurally mutated (the `Vector.generation` bump).
// ---------------------------------------------------------------------------

const lexer_mod = @import("lexer");
const tok_mod = lexer_mod.token;

/// Two tokens are "the same token" if they have the same type and source
/// position. (Position uniquely identifies a token within a single lexed
/// stream, which is all these tests compare.)
fn sameToken(a: ?tok_mod.Token, b: ?tok_mod.Token) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.type == b.?.type and
        a.?.pos.line == b.?.pos.line and
        a.?.pos.col == b.?.pos.col and
        a.?.pos.start_col == b.?.pos.start_col;
}

/// Reference linear scan for the *previous* n-th significant token, scanning
/// down from `exclusive_end - 1`. Mirrors the original loop bodies of
/// `token_peek_prev_n` / `token_peek_prev_stream_n`.
fn refPrev(items: []tok_mod.Token, exclusive_end: isize, n: usize) ?tok_mod.Token {
    var idx: isize = exclusive_end - 1;
    var seen: usize = 0;
    while (idx >= 0) : (idx -= 1) {
        const t = items[@intCast(idx)];
        if (tok_mod.is_nl_or_comment_or_newline_separator(t)) continue;
        if (seen == n) return t;
        seen += 1;
    }
    return null;
}

test "lookahead: token_peek_n matches linear scan at every cursor and offset" {
    const ifilepath = "lookahead_peek_n.fn";
    const ofilepath = "lookahead_peek_n.c";
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        // Deliberately dense with newlines + comments (the skippable tokens) and
        // generics/declarations (where the O(n^2) used to bite).
        const input =
            "// leading comment\n" ++
            "compound Box<T> {\n" ++
            "  // a field\n" ++
            "  T value;\n" ++
            "\n\n" ++
            "  num count;\n" ++
            "}\n" ++
            "fun main() {\n" ++
            "  Box<num> b; // trailing\n" ++
            "  num x = 1 + 2 * 3;\n" ++
            "  ret;\n" ++
            "}\n";
        try file.writeStreamingAll(std.testing.io, input);
    }
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath) catch {};

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = false });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);
    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
    }
    try lex_proc.lex();

    const total = transpile_proc.tokens.items().len;
    try std.testing.expect(total > 0);

    // For every cursor position, the O(1) and linear results must agree for all n.
    var cursor: usize = 0;
    while (cursor <= total) : (cursor += 1) {
        parse_proc.testSetCursor(cursor);
        var n: usize = 0;
        while (n <= total) : (n += 1) {
            const fast = parse_proc.testPeekN(n);
            const slow = parse_proc.testPeekNLinear(n);
            if (!sameToken(fast, slow)) {
                std.debug.print("mismatch at cursor={d} n={d}\n", .{ cursor, n });
                try std.testing.expect(false);
            }
            // Once both run off the end, larger n stays null — stop early.
            if (fast == null and slow == null) break;
        }
    }
}

test "lookahead: prev variants match linear scan at every cursor and offset" {
    const ifilepath = "lookahead_prev.fn";
    const ofilepath = "lookahead_prev.c";
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input =
            "fun f() {\n" ++
            "  // comment\n" ++
            "  num a = sizeof(num);\n" ++
            "\n" ++
            "  num b = a + 1;\n" ++
            "}\n";
        try file.writeStreamingAll(std.testing.io, input);
    }
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath) catch {};

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = false });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);
    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
    }
    try lex_proc.lex();

    const items = transpile_proc.tokens.items();
    const total = items.len;

    var cursor: usize = 0;
    while (cursor <= total) : (cursor += 1) {
        parse_proc.testSetCursor(cursor);
        const pidx: isize = @intCast(cursor);
        var n: usize = 0;
        while (n <= total) : (n += 1) {
            // token_peek_prev_n scans from pindex-2 inclusive => exclusive_end = pindex-1.
            const prev_n_fast = parse_proc.testPeekPrevN(n);
            const prev_n_ref = refPrev(items, pidx - 1, n);
            try std.testing.expect(sameToken(prev_n_fast, prev_n_ref));

            // token_peek_prev_stream_n scans from pindex-1 inclusive => exclusive_end = pindex.
            const prev_s_fast = parse_proc.testPeekPrevStreamN(n);
            const prev_s_ref = refPrev(items, pidx, n);
            try std.testing.expect(sameToken(prev_s_fast, prev_s_ref));

            if (prev_n_fast == null and prev_s_fast == null) break;
        }
    }
}

test "lookahead: index is rebuilt after a structural token-stream mutation" {
    const ifilepath = "lookahead_mutation.fn";
    const ofilepath = "lookahead_mutation.c";
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input = "num a = 1 + 2;\n";
        try file.writeStreamingAll(std.testing.io, input);
    }
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath) catch {};

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = false });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);
    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
    }
    try lex_proc.lex();

    parse_proc.testSetCursor(0);
    // Warm the lookahead table.
    const first_before = parse_proc.testPeekN(0);
    try std.testing.expect(first_before != null);
    const gen_before = transpile_proc.tokens.generation;

    // Insert a synthetic significant token at the front, copying an existing
    // token so its data is valid. push_at must bump `generation`, which forces
    // the lookahead table to rebuild on the next peek.
    const dup = transpile_proc.tokens.items()[0];
    try transpile_proc.tokens.push_at(0, dup);
    try std.testing.expect(transpile_proc.tokens.generation != gen_before);

    parse_proc.testSetCursor(0);
    // After the rebuild, the O(1) and linear results must still agree, proving
    // the table was invalidated and recomputed rather than serving stale data.
    const total = transpile_proc.tokens.items().len;
    var n: usize = 0;
    while (n < total) : (n += 1) {
        try std.testing.expect(sameToken(parse_proc.testPeekN(n), parse_proc.testPeekNLinear(n)));
    }
}

/// Builds a generic-heavy program with `n` typed declarations of the form that
/// used to trigger the O(n^2) lookahead (qualified/generic type names at
/// statement start). Returns owned source the caller must free.
fn buildGenericHeavySource(allocator: std.mem.Allocator, n: usize) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try buf.appendSlice("compound Pair<A, B> { A first; B second; }\n");
    try buf.appendSlice("fun main() {\n");
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // A nested-generic typed declaration — the shape that hammered
        // skip_generic_args_tokens + the looks_like_decl lookahead.
        try buf.appendSlice("  Pair<Pair<num, num>, num> v");
        try buf.print("{d}", .{i});
        try buf.appendSlice(";\n");
    }
    try buf.appendSlice("  ret;\n}\n");
    return buf.toOwnedSlice();
}

fn parseSourceNanos(allocator: std.mem.Allocator, src: []const u8, tag: []const u8) !u64 {
    const ifilepath = tag;
    const ofilepath_buf = try std.fmt.allocPrint(allocator, "{s}.c", .{tag});
    defer allocator.free(ofilepath_buf);
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, src);
    }
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath_buf) catch {};

    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath_buf, .{ .outf = false });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);
    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
    }
    try lex_proc.lex();
    const start: i128 = std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds;
    parse_proc.parse() catch {}; // shape, not validity, is what we time
    const end: i128 = std.Io.Clock.Timestamp.now(std.testing.io, .real).raw.nanoseconds;
    return @intCast(end - start);
}

test "lookahead: generic-heavy parse scales sub-quadratically" {
    const allocator = std.testing.allocator;

    const small_n: usize = 200;
    const big_n: usize = 800; // 4x the statements

    const small_src = try buildGenericHeavySource(allocator, small_n);
    defer allocator.free(small_src);
    const big_src = try buildGenericHeavySource(allocator, big_n);
    defer allocator.free(big_src);

    // Best-of-3 to damp scheduler noise.
    var small_ns: u64 = std.math.maxInt(u64);
    var big_ns: u64 = std.math.maxInt(u64);
    var r: usize = 0;
    while (r < 3) : (r += 1) {
        small_ns = @min(small_ns, try parseSourceNanos(allocator, small_src, "scale_small.fn"));
        big_ns = @min(big_ns, try parseSourceNanos(allocator, big_src, "scale_big.fn"));
    }

    // With the O(1) lookahead, 4x the input should cost roughly ~4x the time.
    // The old O(n^2) scan would cost ~16x. Allow generous slack (10x) so the
    // test is a regression guard against quadratic blowup, not a tight benchmark.
    // Guard against a zero/near-zero small measurement on very fast machines.
    const small_floor: u64 = @max(small_ns, 1);
    const ratio_x100 = (big_ns * 100) / small_floor;
    if (ratio_x100 > 1000) {
        std.debug.print(
            "generic-heavy parse scaled {d}.{d:0>2}x for 4x input (small={d}ns big={d}ns) — possible O(n^2) regression\n",
            .{ ratio_x100 / 100, ratio_x100 % 100, small_ns, big_ns },
        );
        try std.testing.expect(false);
    }
}
