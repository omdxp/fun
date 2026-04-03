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
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        const input = "fun test() { ret; }";
        try file.writeAll(input);
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
    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}

test "ParseProcess parse_async_function" {
    const ifilepath = "ParseProcess_parse_async_function.fn";
    const ofilepath = "ParseProcess_parse_async_function.c";
    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        const input = "async fun test() { ret; }";
        try file.writeAll(input);
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

    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}

test "ParseProcess parse_async_impl_method" {
    const ifilepath = "ParseProcess_parse_async_impl_method.fn";
    const ofilepath = "ParseProcess_parse_async_impl_method.c";
    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        const input =
            "compound Counter { num base; }\n" ++
            "impl Counter {\n" ++
            "  async add(num x) num { ret self.base + x; }\n" ++
            "}\n";
        try file.writeAll(input);
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

    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}

test "ParseProcess parse_await_expression" {
    const ifilepath = "ParseProcess_parse_await_expression.fn";
    const ofilepath = "ParseProcess_parse_await_expression.c";
    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        const input =
            "fun inc(num x) num { ret x + 1; }\n" ++
            "fun main() {\n" ++
            "  num y = await inc(41);\n" ++
            "  ret y;\n" ++
            "}\n";
        try file.writeAll(input);
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

    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}

test "ParseProcess parses variadic function declaration" {
    const ifilepath = "ParseProcess_parse_variadic_function.fn";
    const ofilepath = "ParseProcess_parse_variadic_function.c";
    // Mock input file
    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        const input = "fun v(num a, ...) num;";
        try file.writeAll(input);
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
    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}

test "ParseProcess parse_return" {
    const ifilepath = "ParseProcess_parse_return.fn";
    const ofilepath = "ParseProcess_parse_return.c";
    // Mock input file
    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        const input = "ret 42;";
        try file.writeAll(input);
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
    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}

test "ParseProcess parse_expression" {
    const ifilepath = "ParseProcess_parse_expression.fn";
    const ofilepath = "ParseProcess_parse_expression.c";
    // Mock input file
    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        const input = "1 + 2 * 3";
        try file.writeAll(input);
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
    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}

test "ParseProcess parses array literal vs indexing" {
    const ifilepath = "ParseProcess_array_literal_vs_index.fn";
    const ofilepath = "ParseProcess_array_literal_vs_index.c";

    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        const input =
            "fun main() {\n" ++
            "  num[] arr = [1, 2, 3];\n" ++
            "  num x = arr[0];\n" ++
            "}\n";
        try file.writeAll(input);
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

    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}

test "ParseProcess parses if condition with == operator" {
    const ifilepath = "ParseProcess_if_condition_eq.fn";
    const ofilepath = "ParseProcess_if_condition_eq.c";

    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        const input =
            "fun main() {\n" ++
            "  num n = 0;\n" ++
            "  if n == 0 { ret; }\n" ++
            "}\n";
        try file.writeAll(input);
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

    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}

test "ParseProcess parse returns error on malformed input (no crash)" {
    const ifilepath = "ParseProcess_parse_malformed_missing_semicolon.fn";
    const ofilepath = "ParseProcess_parse_malformed_missing_semicolon.c";

    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        // Missing ';' after variable declaration.
        const input =
            "fun main() {\n" ++
            "  num x = 1\n" ++
            "  ret;\n" ++
            "}\n";
        try file.writeAll(input);
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

    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}

test "ParseProcess parse returns error on malformed dot (no crash)" {
    const ifilepath = "ParseProcess_parse_malformed_dot.fn";
    const ofilepath = "ParseProcess_parse_malformed_dot.c";

    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        // Missing identifier after '.'
        const input =
            "imp std.;\n" ++
            "fun main() {\n" ++
            "  ret;\n" ++
            "}\n";
        try file.writeAll(input);
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

    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}
