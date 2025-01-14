const std = @import("std");
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
        .TranspileProcessOutf,
    );
    var lp = lexer.LexProcess.init(
        global_allocator,
        &tp,
    );
    defer {
        tp.deinit();
        lp.deinit();
    }

    try lp.lex();
    for (lp.tokens.items) |t| {
        std.debug.print("type: {}, ", .{t.type});
        switch (t.type) {
            .Comment => {
                defer t.data.sval.deinit();
                std.debug.print("sval: '{s}'\n", .{t.data.sval.items});
            },
            .NewLine => std.debug.print("cval: '{c}'\n", .{t.data.cval}),
            else => std.debug.print("Unhandled token type\n", .{}),
        }
    }
}
