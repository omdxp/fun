const std = @import("std");
const heap = std.heap;
const token = @import("./token.zig");
const transpiler = @import("./transpiler.zig");
const lexer = @import("./lexer.zig");
const parser = @import("./parser.zig");
pub const global_allocator = heap.page_allocator;

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
                std.debug.print("name: {s}, dtype: {s}, ", .{ variable.name.items, variable.type.type_str.items });
                switch (variable.val.?.type) {
                    .String => std.debug.print("val: '{s}'\n", .{variable.val.?.*.data.?.sval.items}),
                    .Number => std.debug.print("val: {}\n", .{variable.val.?.*.data.?.llnum}),
                    .Expression => std.debug.print("val: {s}\n", .{variable.val.?.*.node_variant.?.exp.op}),
                    else => unreachable,
                }
            },
            .Number => {
                const number = n.data.?.llnum;
                std.debug.print("llnum: {}\n", .{number});
            },
            .Expression => {
                const expression = n.node_variant.?.exp;
                std.debug.print("op: {s}, ", .{expression.op});
                switch (expression.left.?.*.type) {
                    .Number => std.debug.print("left: {}\n", .{expression.left.?.*.data.?.llnum}),
                    .Variable => std.debug.print("left: {s}\n", .{expression.left.?.*.node_variant.?.variable.name.items}),
                    .Expression => std.debug.print("left: {s}\n", .{expression.left.?.*.node_variant.?.exp.op}),
                    .Identifier => std.debug.print("left: {s}\n", .{expression.left.?.*.data.?.sval.items}),
                    else => unreachable,
                }
            },
            .Function => {
                const function = n.node_variant.?.function;
                std.debug.print("name: {s}, rtype: {s}, ", .{ function.name.?.items, function.rtype.?.type_str.items });
                std.debug.print("args: ", .{});
                for (function.args.?.items()) |arg| {
                    switch (arg.type) {
                        .Variable => std.debug.print("[{s} {s}], ", .{ arg.node_variant.?.variable.type.type_str.items, arg.node_variant.?.variable.name.items }),
                        .Expression => {},
                        else => unreachable,
                    }
                }
                if (function.body != null) {
                    switch (function.body.?.type) {
                        .Body => {
                            std.debug.print("body:\n", .{});
                            for (function.body.?.node_variant.?.body.statements.items()) |stmt| {
                                switch (stmt.type) {
                                    .Variable => {
                                        switch (stmt.node_variant.?.variable.val.?.type) {
                                            .String => std.debug.print("  variable: {s} = '{s}'\n", .{ stmt.node_variant.?.variable.name.items, stmt.node_variant.?.variable.val.?.*.data.?.sval.items }),
                                            .Number => std.debug.print("  variable: {s} = {}\n", .{ stmt.node_variant.?.variable.name.items, stmt.node_variant.?.variable.val.?.*.data.?.llnum }),
                                            .Expression => std.debug.print("  variable: {s} = {s}\n", .{ stmt.node_variant.?.variable.name.items, stmt.node_variant.?.variable.val.?.*.node_variant.?.exp.op }),
                                            else => unreachable,
                                        }
                                    },
                                    .Expression => std.debug.print("  expression: {s}\n", .{stmt.node_variant.?.exp.op}),
                                    .StatementReturn => std.debug.print("  return\n", .{}),
                                    else => unreachable,
                                }
                            }
                        },
                        else => std.debug.print("body: none\n", .{}),
                    }
                }
                std.debug.print("\n", .{});
            },
            else => unreachable,
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
