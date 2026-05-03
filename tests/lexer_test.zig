const std = @import("std");
const fs = std.fs;
const LexProcess = @import("lexer").LexProcess;
const token = @import("lexer").token;
const codegen = @import("codegen");

/// Compatibility shim: ArrayList with embedded allocator (old-style managed API).
fn ArrayList(comptime T: type) type {
    return std.array_list.Managed(T);
}

test "LexProcess initialization" {
    const ifilepath = "LexProcess_initialization.fn";
    const ofilepath = "LexProcess_initialization.c";
    // Mock input file
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input = "dummy";
        try file.writeStreamingAll(std.testing.io, input);
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
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}

test "LexProcess next_char" {
    const ifilepath = "LexProcess_next_char.fn";
    const ofilepath = "LexProcess_next_char.c";
    // Mock input file
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input = "abc\n";
        try file.writeStreamingAll(std.testing.io, input);
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
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}

test "LexProcess peek_char" {
    const ifilepath = "LexProcess_peek_char.fn";
    const ofilepath = "LexProcess_peek_char.c";
    // Mock input file
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input = "abc";
        try file.writeStreamingAll(std.testing.io, input);
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
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}

test "LexProcess push_char" {
    const ifilepath = "LexProcess_push_char.fn";
    const ofilepath = "LexProcess_push_char.c";
    // Mock input file
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input = "abc";
        try file.writeStreamingAll(std.testing.io, input);
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
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}

test "LexProcess comment" {
    const ifilepath = "LexProcess_comment.fn";
    const ofilepath = "LexProcess_comment.c";
    // Mock input file
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input = "// This is a comment\n";
        try file.writeStreamingAll(std.testing.io, input);
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
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}

test "LexProcess string" {
    const ifilepath = "LexProcess_string.fn";
    const ofilepath = "LexProcess_string.c";
    // Mock input file
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input = "\"Hello, World!\"";
        try file.writeStreamingAll(std.testing.io, input);
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
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}

test "LexProcess number" {
    const ifilepath = "LexProcess_number.fn";
    const ofilepath = "LexProcess_number.c";
    // Mock input file
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input = "12345";
        try file.writeStreamingAll(std.testing.io, input);
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
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}

test "LexProcess lex" {
    const ifilepath = "LexProcess_lex.fn";
    const ofilepath = "LexProcess_lex.c";
    // Mock input file
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input = "123 + 456 // comment\n\"string\"";
        try file.writeStreamingAll(std.testing.io, input);
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
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}

test "LexProcess lexes multi-character operators" {
    const ifilepath = "LexProcess_multi_ops.fn";
    const ofilepath = "LexProcess_multi_ops.c";
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, ifilepath, .{ .read = true });
        defer file.close(std.testing.io);
        const input = "1==2!=3<=4>=5&&6||7..8...9->10";
        try file.writeStreamingAll(std.testing.io, input);
    }

    const allocator = std.testing.allocator;
    var transpile_proc = try codegen.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = LexProcess.init(&transpile_proc);
    defer {
        transpile_proc.deinit();
        lex_proc.deinit();
    }

    try lex_proc.lex();
    const toks = transpile_proc.tokens.items();

    // Expected token stream: N op N op N op N op N op N op N op N op N op N
    // Validate the operators in order.
    var ops = ArrayList([]const u8).init(allocator);
    defer ops.deinit();
    for (toks) |t| {
        if (t.type == .Operator) {
            try ops.append(t.data.sval.items);
        }
    }
    try std.testing.expectEqual(@as(usize, 9), ops.items.len);
    try std.testing.expectEqualStrings("==", ops.items[0]);
    try std.testing.expectEqualStrings("!=", ops.items[1]);
    try std.testing.expectEqualStrings("<=", ops.items[2]);
    try std.testing.expectEqualStrings(">=", ops.items[3]);
    try std.testing.expectEqualStrings("&&", ops.items[4]);
    try std.testing.expectEqualStrings("||", ops.items[5]);
    try std.testing.expectEqualStrings("..", ops.items[6]);
    try std.testing.expectEqualStrings("...", ops.items[7]);
    try std.testing.expectEqualStrings("->", ops.items[8]);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, ifilepath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, ofilepath);
}
