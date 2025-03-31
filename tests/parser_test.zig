const std = @import("std");
const fs = std.fs;
const ParseProcess = @import("parser").ParseProcess;
const lexer = @import("lexer");
const codegen = @import("codegen");

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
