const std = @import("std");
const heap = std.heap;
const token = @import("./token.zig");
const transpiler = @import("./transpiler.zig");
const lexer = @import("./lexer.zig");
const parser = @import("./parser.zig");
const global_allocator = heap.page_allocator;

pub fn main() !void {
    const ifilepath = "./test.fn";
    const ofilepath = "./test.c";

    var tp = try transpiler.TranspileProcess.init(
        global_allocator,
        ifilepath,
        ofilepath,
        .{ .outf = true },
    );
    var lp = lexer.LexProcess.init(
        global_allocator,
        &tp,
    );
    var pp = parser.ParseProcess.init(
        global_allocator,
        &tp,
    );
    defer {
        tp.deinit();
        lp.deinit();
    }

    try lp.lex();
    try tp.tokens.push_slice(lp.tokens.items());
    try pp.parse();

    for (tp.nodes.items()) |n| {
        std.debug.print("node type: {}, ", .{n.type});
        switch (n.type) {
            .Variable => {
                const variable = n.node_variant.?.variable;
                std.debug.print("name: {s}, dtype: {s}, ", .{ variable.name.items, variable.type.type_str.?.items });
                switch (variable.val.type) {
                    .String => std.debug.print("val: '{s}'\n", .{variable.val.data.?.sval.items}),
                    else => unreachable,
                }
            },
            .Number => {
                const number = n.data.?.llnum;
                std.debug.print("llnum: {}\n", .{number});
            },
            else => unreachable,
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
