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
    defer tp.deinit();

    var lp = lexer.LexProcess.init(
        global_allocator,
        ifilepath,
        &tp,
    );
    defer lp.deinit();
}
