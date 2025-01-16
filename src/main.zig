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
            .String => std.debug.print("sval: '{s}', whitespace: {}\n", .{ t.data.sval.items, t.whitespace }),
            .Operator => std.debug.print("sval: '{s}', whitespace: {}\n", .{ t.data.sval.items, t.whitespace }),
            .Symbol => std.debug.print("cval: '{c}', whitespace: {}\n", .{ t.data.cval, t.whitespace }),
            .Comment => std.debug.print("sval: '{s}', whitespace: {}\n", .{ t.data.sval.items, t.whitespace }),
            .Identifier => std.debug.print("sval: '{s}', whitespace: {}\n", .{ t.data.sval.items, t.whitespace }),
            .Keyword => std.debug.print("sval: '{s}', whitespace: {}\n", .{ t.data.sval.items, t.whitespace }),
            .Number => switch (t.data) {
                .llnum => std.debug.print("llnum: '{}', type: {}, whitespace: {}\n", .{ t.data.llnum, t.num.?.type, t.whitespace }),
                .cval => std.debug.print("cval: '{c}', whitespace: {}\n", .{ t.data.cval, t.whitespace }),
                else => unreachable,
            },
            .NewLine => std.debug.print("whitespace: {}\n", .{t.whitespace}),
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
