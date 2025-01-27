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
            .Function => {
                const function = n.node_variant.?.function;
                std.debug.print("name: {s}, rtype: {s}, ", .{ function.name.?.items, function.rtype.?.type_str.items });
                std.debug.print("args: ", .{});
                for (function.args.?.items()) |arg| {
                    const is_array = arg.node_variant.?.variable.type.flags.?.is_array;
                    switch (arg.type) {
                        .Variable => std.debug.print("({s} {s}{s}), ", .{ arg.node_variant.?.variable.type.type_str.items, arg.node_variant.?.variable.name.items, if (is_array) "[]" else "" }),
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
                                            else => std.debug.print("  variable: {s} = {?}\n", .{ stmt.node_variant.?.variable.name.items, stmt.type }),
                                        }
                                    },
                                    .Expression => std.debug.print("  expression: {s}\n", .{stmt.node_variant.?.exp.op}),
                                    .StatementReturn => std.debug.print("  return\n", .{}),
                                    .StatementIf => {
                                        const if_stmt = stmt.node_variant.?.statement.if_stmt;
                                        switch (if_stmt.condition.*.type) {
                                            .Expression => std.debug.print("condition: {s}, ", .{if_stmt.condition.*.node_variant.?.exp.op}),
                                            .Boolean => std.debug.print("condition: {}\n", .{if_stmt.condition.*.data.?.bval}),
                                            else => unreachable,
                                        }
                                        std.debug.print("body: {?}\n", .{if_stmt.body.*.type});
                                    },
                                    .StatementElseIf => {
                                        const elif_stmt = stmt.node_variant.?.statement.elif_stmt;
                                        std.debug.print("condition: {s}, ", .{elif_stmt.condition.*.node_variant.?.exp.op});
                                        std.debug.print("body: {?}\n", .{elif_stmt.body.*.type});
                                    },
                                    .StatementElse => {
                                        const else_stmt = stmt.node_variant.?.statement.else_stmt;
                                        std.debug.print("body: {?}\n", .{else_stmt.body.*.type});
                                    },
                                    .StatementFit => {
                                        const fit_stmt = stmt.node_variant.?.statement.fit_stmt;
                                        switch (fit_stmt.exp.*.type) {
                                            .Expression => std.debug.print("condition: {s}, ", .{fit_stmt.exp.*.node_variant.?.exp.op}),
                                            .Boolean => std.debug.print("condition: {}\n", .{fit_stmt.exp.*.data.?.bval}),
                                            .Identifier => switch (fit_stmt.exp.*.data.?) {
                                                .sval => std.debug.print("condition: {s}\n", .{fit_stmt.exp.*.data.?.sval.items}),
                                                .cval => std.debug.print("condition: {c}\n", .{fit_stmt.exp.*.data.?.cval}),
                                                else => unreachable,
                                            },
                                            else => unreachable,
                                        }
                                        std.debug.print("has_default_branch: {}\n", .{fit_stmt.has_default_branch});
                                        for (fit_stmt.branches.items()) |branch| {
                                            if (branch.condition == null) {
                                                std.debug.print("branch: default\n", .{});
                                                std.debug.print("body: {?}, stmts: {}\n", .{ branch.body.*.type, branch.body.*.node_variant.?.body.statements.count });
                                                continue;
                                            }
                                            const condition = branch.condition.?;
                                            switch (condition.*.type) {
                                                .Number => std.debug.print("branch: {}\n", .{condition.*.data.?.llnum}),
                                                .Expression => std.debug.print("branch: {s}, ", .{condition.*.node_variant.?.exp.op}),
                                                .Boolean => std.debug.print("branch: {}\n", .{condition.*.data.?.bval}),
                                                .Identifier => switch (condition.*.data.?) {
                                                    .sval => std.debug.print("branch: {s}\n", .{condition.*.data.?.sval.items}),
                                                    .cval => std.debug.print("branch: {c}\n", .{condition.*.data.?.cval}),
                                                    else => unreachable,
                                                },
                                                else => unreachable,
                                            }
                                            std.debug.print("body: {?}, stmts: {}\n", .{ branch.body.*.type, branch.body.*.node_variant.?.body.statements.count });
                                        }
                                    },
                                    else => unreachable,
                                }
                            }
                        },
                        else => std.debug.print("body: none\n", .{}),
                    }
                }
                std.debug.print("\n", .{});
            },
            .Import => {
                const import = n.node_variant.?.import;
                std.debug.print("import: {s}\n", .{import.path});
            },
            .StatementIf => std.debug.print("if binded: {s}\n", .{n.binded.?.function.?.*.node_variant.?.function.name.?.items}),
            .StatementElseIf => std.debug.print("elif binded: {s}\n", .{n.binded.?.function.?.*.node_variant.?.function.name.?.items}),
            .StatementElse => std.debug.print("else binded: {s}\n", .{n.binded.?.function.?.*.node_variant.?.function.name.?.items}),
            else => unreachable,
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
