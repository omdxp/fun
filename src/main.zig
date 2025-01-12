const std = @import("std");
const io = std.io;
const mem = std.mem;
const heap = std.heap;
const token = @import("./token.zig");
const transpiler = @import("./transpiler.zig");
const lexer = @import("./lexer.zig");
pub const global_allocator = heap.page_allocator;

pub fn main() !void {
    const ifilepath = "./test.fn";
    const ofilepath = "./test.c";

    var tp = try transpiler.TranspileProcess.init(
        global_allocator,
        ifilepath,
        ofilepath,
        0,
    );
    var lp = lexer.LexProcess.init(
        global_allocator,
        &tp,
    );
    defer tp.deinit();
    defer lp.deinit();

    for (0..5) |_| {
        std.debug.print("{}:{} -> ", .{ tp.pos.line, tp.pos.col });
        const c = try lp.next_char();
        const p = try lp.peek_char();
        std.debug.print("c = '{c}', p = '{c}'\n", .{ c, p });
    }

    try lp.push_char(';');
    try tp.ifile.seekTo(0);

    const buffer = try tp.ifile.readToEndAlloc(global_allocator, 2064);
    defer global_allocator.free(buffer);

    try tp.ofile.writeAll(buffer);
}
