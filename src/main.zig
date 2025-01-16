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
            .String => {
                defer t.data.sval.deinit();
                std.debug.print("sval: '{s}', whitespace: {}\n", .{ t.data.sval.items, t.whitespace });
            },
            .Operator => {
                defer t.data.sval.deinit();
                std.debug.print("sval: '{s}', whitespace: {}\n", .{ t.data.sval.items, t.whitespace });
            },
            .Symbol => std.debug.print("cval: '{c}', whitespace: {}\n", .{ t.data.cval, t.whitespace }),
            .Comment => {
                defer t.data.sval.deinit();
                std.debug.print("sval: '{s}', whitespace: {}\n", .{ t.data.sval.items, t.whitespace });
            },
            .Identifier => {
                defer t.data.sval.deinit();
                std.debug.print("sval: '{s}', whitespace: {}\n", .{ t.data.sval.items, t.whitespace });
            },
            .Keyword => {
                defer t.data.sval.deinit();
                std.debug.print("sval: '{s}', whitespace: {}\n", .{ t.data.sval.items, t.whitespace });
            },
            .Number => std.debug.print("llnum: '{}', type: {}, whitespace: {}\n", .{ t.data.llnum, t.num.?.type, t.whitespace }),
            .NewLine => std.debug.print("whitespace: {}\n", .{t.whitespace}),
        }
    }
}
