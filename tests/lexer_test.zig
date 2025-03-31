const std = @import("std");
const fs = std.fs;
const LexProcess = @import("lexer").LexProcess;
const token = @import("lexer").token;
const codegen = @import("codegen");

test "LexProcess initialization" {
    const ifilepath = "LexProcess_initialization.fn";
    const ofilepath = "LexProcess_initialization.c";
    // Mock input file
    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        const input = "dummy";
        try file.writeAll(input);
    }

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = LexProcess.init(&transpile_proc);

    defer transpile_proc.deinit();
    defer lex_proc.deinit();

    try std.testing.expect(transpile_proc.tokens.items().len == 0);
    try std.testing.expect(lex_proc.transpile_proc == &transpile_proc);
    try std.testing.expect(lex_proc.curr_exp_count == 0);
    try std.testing.expect(lex_proc.parenthesis_buf == null);
    try std.testing.expect(lex_proc.arg_str_buf == null);

    // Delete test files
    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}

test "LexProcess next_char" {
    const ifilepath = "LexProcess_next_char.fn";
    const ofilepath = "LexProcess_next_char.c";
    // Mock input file
    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        const input = "abc\n";
        try file.writeAll(input);
    }

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = LexProcess.init(&transpile_proc);

    defer transpile_proc.deinit();
    defer lex_proc.deinit();

    try std.testing.expectEqual('a', (try lex_proc.next_char()).?);
    try std.testing.expectEqual('b', (try lex_proc.next_char()).?);
    try std.testing.expectEqual('c', (try lex_proc.next_char()).?);
    try std.testing.expectEqual('\n', (try lex_proc.next_char()).?);
    try std.testing.expect(try lex_proc.next_char() == null);

    // Delete test files
    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}

test "LexProcess peek_char" {
    const ifilepath = "LexProcess_peek_char.fn";
    const ofilepath = "LexProcess_peek_char.c";
    // Mock input file
    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        const input = "abc";
        try file.writeAll(input);
    }

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = LexProcess.init(&transpile_proc);

    defer transpile_proc.deinit();
    defer lex_proc.deinit();

    try std.testing.expectEqual('a', (try lex_proc.peek_char()).?);
    try std.testing.expectEqual('a', (try lex_proc.peek_char()).?);
    _ = try lex_proc.next_char();
    try std.testing.expectEqual('b', (try lex_proc.peek_char()).?);

    // Delete test files
    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}

test "LexProcess push_char" {
    const ifilepath = "LexProcess_push_char.fn";
    const ofilepath = "LexProcess_push_char.c";
    // Mock input file
    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        const input = "abc";
        try file.writeAll(input);
    }

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = LexProcess.init(&transpile_proc);

    defer transpile_proc.deinit();
    defer lex_proc.deinit();

    _ = try lex_proc.next_char();
    _ = try lex_proc.next_char();
    try lex_proc.push_char('b');
    try std.testing.expectEqual('b', (try lex_proc.next_char()).?);

    // Delete test files
    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}

test "LexProcess comment" {
    const ifilepath = "LexProcess_comment.fn";
    const ofilepath = "LexProcess_comment.c";
    // Mock input file
    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        const input = "// This is a comment\n";
        try file.writeAll(input);
    }

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = LexProcess.init(&transpile_proc);

    defer transpile_proc.deinit();
    defer lex_proc.deinit();

    try lex_proc.lex();
    const t = transpile_proc.tokens.items()[0];
    try std.testing.expectEqual(t.type, .Comment);
    try std.testing.expectEqualStrings(" This is a comment", t.data.sval.items);

    // Delete test files
    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}

test "LexProcess string" {
    const ifilepath = "LexProcess_string.fn";
    const ofilepath = "LexProcess_string.c";
    // Mock input file
    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        const input = "\"Hello, World!\"";
        try file.writeAll(input);
    }

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = LexProcess.init(&transpile_proc);

    defer transpile_proc.deinit();
    defer lex_proc.deinit();

    try lex_proc.lex();
    const t = transpile_proc.tokens.items()[0];
    try std.testing.expectEqual(t.type, .String);
    try std.testing.expectEqualStrings("Hello, World!", t.data.sval.items);

    // Delete test files
    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}

test "LexProcess number" {
    const ifilepath = "LexProcess_number.fn";
    const ofilepath = "LexProcess_number.c";
    // Mock input file
    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        const input = "12345";
        try file.writeAll(input);
    }

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = LexProcess.init(&transpile_proc);

    defer transpile_proc.deinit();
    defer lex_proc.deinit();

    try lex_proc.lex();
    const t = transpile_proc.tokens.items()[0];
    try std.testing.expectEqual(t.type, .Number);
    try std.testing.expectEqual(t.data.llnum, 12345);

    // Delete test files
    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}

test "LexProcess lex" {
    const ifilepath = "LexProcess_lex.fn";
    const ofilepath = "LexProcess_lex.c";
    // Mock input file
    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        const input = "123 + 456 // comment\n\"string\"";
        try file.writeAll(input);
    }

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = LexProcess.init(&transpile_proc);

    defer transpile_proc.deinit();
    defer lex_proc.deinit();

    try lex_proc.lex();

    try std.testing.expectEqual(6, transpile_proc.tokens.items().len);
    try std.testing.expectEqual(transpile_proc.tokens.items()[0].type, .Number);
    try std.testing.expectEqual(transpile_proc.tokens.items()[1].type, .Operator);
    try std.testing.expectEqual(transpile_proc.tokens.items()[2].type, .Number);
    try std.testing.expectEqual(transpile_proc.tokens.items()[3].type, .Comment);
    try std.testing.expectEqual(transpile_proc.tokens.items()[4].type, .NewLine);
    try std.testing.expectEqual(transpile_proc.tokens.items()[5].type, .String);
    // Delete test files
    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}
