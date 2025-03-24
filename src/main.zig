const std = @import("std");
const heap = std.heap;
const token = @import("./token.zig");
const transpiler = @import("./transpiler.zig");
const lexer = @import("./lexer.zig");
const parser = @import("./parser.zig");

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{ .thread_safe = true, .safety = true }){};
    defer _ = gpa.deinit();

    var arena = heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const global_allocator = arena.allocator();

    const ifilepath = "./test.fn";
    const ofilepath = "./test.c";

    var tp = try transpiler.TranspileProcess.init(
        global_allocator,
        ifilepath,
        ofilepath,
        .{ .outf = true },
    );
    var lp = lexer.LexProcess.init(&tp);
    var pp = parser.ParseProcess.init(&tp);
    defer {
        lp.deinit();
        tp.deinit();
    }

    try lp.lex();
    try pp.parse();
}

test {
    std.testing.refAllDecls(@This());
}
