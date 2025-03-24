const std = @import("std");
const heap = std.heap;
const token = @import("./token.zig");
const transpiler = @import("./transpiler.zig");
const lexer = @import("./lexer.zig");
const parser = @import("./parser.zig");
const ast = @import("./ast.zig");

fn printIndent(writer: anytype, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        try writer.print("  ", .{});
    }
}

fn printNode(node: ast.Node, writer: anytype, depth: usize) !void {
    try printIndent(writer, depth);
    try writer.print("Node Type: {s}\n", .{@tagName(node.type)});

    switch (node.type) {
        .Expression => {
            if (node.node_variant != null and node.node_variant.?.exp.op.len > 0) {
                try printIndent(writer, depth + 1);
                try writer.print("Operator: {s}\n", .{node.node_variant.?.exp.op});
                if (node.node_variant.?.exp.left) |left| {
                    try printIndent(writer, depth + 1);
                    try writer.print("Left:\n", .{});
                    try printNode(left.*, writer, depth + 2);
                }
                if (node.node_variant.?.exp.right) |right| {
                    try printIndent(writer, depth + 1);
                    try writer.print("Right:\n", .{});
                    try printNode(right.*, writer, depth + 2);
                }
            }
        },
        .Function => {
            if (node.node_variant.?.function.name) |name| {
                try printIndent(writer, depth + 1);
                try writer.print("Name: {s}\n", .{name.items});
            }
            if (node.node_variant.?.function.args) |args| {
                try printIndent(writer, depth + 1);
                try writer.print("Arguments count: {d}\n", .{args.count});
                for (args.items(), 0..) |arg, i| {
                    try printIndent(writer, depth + 1);
                    try writer.print("Arg {d}:\n", .{i});
                    try printNode(arg.*, writer, depth + 2);
                }
            }
            if (node.node_variant.?.function.body) |body| {
                try printIndent(writer, depth + 1);
                try writer.print("Body:\n", .{});
                try printNode(body.*, writer, depth + 2);
            }
        },
        .Variable => {
            if (node.node_variant.?.variable.name.items.len > 0) {
                try printIndent(writer, depth + 1);
                try writer.print("Name: {s}\n", .{node.node_variant.?.variable.name.items});
            }
            if (node.node_variant.?.variable.type.type_str.items.len > 0) {
                try printIndent(writer, depth + 1);
                try writer.print("Type: {s}", .{node.node_variant.?.variable.type.type_str.items});
                if (node.node_variant.?.variable.type.flags.?.is_pointer) {
                    try writer.print(" (pointer depth: {d})", .{node.node_variant.?.variable.type.pointer_depth});
                }
                try writer.print("\n", .{});
            }
            if (node.node_variant.?.variable.val) |val| {
                try printIndent(writer, depth + 1);
                try writer.print("Value:\n", .{});
                try printNode(val.*, writer, depth + 2);
            }
        },
        .Number => {
            if (node.data) |data| {
                try printIndent(writer, depth + 1);
                try writer.print("Value: {d}\n", .{data.llnum});
            }
        },
        .String => {
            if (node.data) |data| {
                try printIndent(writer, depth + 1);
                try writer.print("Value: \"{s}\"\n", .{data.sval.items});
            }
        },
        .Identifier => {
            if (node.data) |data| {
                try printIndent(writer, depth + 1);
                try writer.print("Name: {s}\n", .{data.sval.items});
            }
        },
        .Body => {
            if (node.node_variant != null and node.node_variant.?.body.statements.count > 0) {
                try printIndent(writer, depth + 1);
                try writer.print("Statements count: {d}\n", .{node.node_variant.?.body.statements.count});
                for (node.node_variant.?.body.statements.items(), 0..) |stmt, i| {
                    try printIndent(writer, depth + 1);
                    try writer.print("Statement {d}:\n", .{i});
                    try printNode(stmt.*, writer, depth + 2);
                }
            }
        },
        .Import => {
            if (node.node_variant != null and node.node_variant.?.import.path.len > 0) {
                try printIndent(writer, depth + 1);
                try writer.print("Path: {s}\n", .{node.node_variant.?.import.path});
            }
        },
        .Unary => {
            if (node.node_variant != null) {
                try printIndent(writer, depth + 1);
                try writer.print("Operator: {s}\n", .{node.node_variant.?.unary.op});
                if (node.node_variant.?.unary.indirection) |ind| {
                    try printIndent(writer, depth + 1);
                    try writer.print("Indirection depth: {d}\n", .{ind.depth});
                }
                try printIndent(writer, depth + 1);
                try writer.print("Operand:\n", .{});
                try printNode(node.node_variant.?.unary.operand.*, writer, depth + 2);
            }
        },
        .Boolean => {
            if (node.node_variant != null) {
                try printIndent(writer, depth + 1);
                try writer.print("Value: {}\n", .{node.node_variant.?.boolean.val});
            }
        },
        .StatementIf => {
            if (node.node_variant != null) {
                try printIndent(writer, depth + 1);
                try writer.print("Condition:\n", .{});
                try printNode(node.node_variant.?.statement.if_stmt.condition.*, writer, depth + 2);
                try printIndent(writer, depth + 1);
                try writer.print("Body:\n", .{});
                try printNode(node.node_variant.?.statement.if_stmt.body.*, writer, depth + 2);
            }
        },
        .StatementElseIf => {
            if (node.node_variant != null) {
                try printIndent(writer, depth + 1);
                try writer.print("Condition:\n", .{});
                try printNode(node.node_variant.?.statement.elif_stmt.condition.*, writer, depth + 2);
                try printIndent(writer, depth + 1);
                try writer.print("Body:\n", .{});
                try printNode(node.node_variant.?.statement.elif_stmt.body.*, writer, depth + 2);
            }
        },
        .StatementElse => {
            if (node.node_variant != null) {
                try printIndent(writer, depth + 1);
                try writer.print("Body:\n", .{});
                try printNode(node.node_variant.?.statement.else_stmt.body.*, writer, depth + 2);
            }
        },
        .StatementFit => {
            if (node.node_variant != null) {
                try printIndent(writer, depth + 1);
                try writer.print("Expression:\n", .{});
                try printNode(node.node_variant.?.statement.fit_stmt.exp.*, writer, depth + 2);
                if (node.node_variant.?.statement.fit_stmt.branches.count > 0) {
                    try printIndent(writer, depth + 1);
                    try writer.print("Branches ({d}):\n", .{node.node_variant.?.statement.fit_stmt.branches.count});
                    for (node.node_variant.?.statement.fit_stmt.branches.items(), 0..) |branch, i| {
                        try printIndent(writer, depth + 2);
                        try writer.print("Branch {d}:\n", .{i});
                        if (branch.condition) |condition| {
                            try printIndent(writer, depth + 3);
                            try writer.print("Condition:\n", .{});
                            try printNode(condition.*, writer, depth + 4);
                        } else {
                            try printIndent(writer, depth + 3);
                            try writer.print("Default branch\n", .{});
                        }
                        try printIndent(writer, depth + 3);
                        try writer.print("Body:\n", .{});
                        try printNode(branch.body.*, writer, depth + 4);
                    }
                }
            }
        },
        .Bracket => {
            if (node.node_variant != null) {
                try printIndent(writer, depth + 1);
                try writer.print("Index:\n", .{});
                try printNode(node.node_variant.?.bracket.inner.*, writer, depth + 2);
            }
        },
        .ExpressionParenthesis => {
            if (node.node_variant != null) {
                try printIndent(writer, depth + 1);
                try writer.print("Inner:\n", .{});
                try printNode(node.node_variant.?.paren.exp.*, writer, depth + 2);
            }
        },
        .StatementReturn => {
            if (node.node_variant != null) {
                try printIndent(writer, depth + 1);
                try writer.print("Value:\n", .{});
                try printNode(node.node_variant.?.statement.return_stmt.*, writer, depth + 2);
            }
        },
        else => {
            // Print the node type for unhandled node types
            try printIndent(writer, depth + 1);
            try writer.print("(Unhandled node type details)\n", .{});
        },
    }
}

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

    // Print all nodes
    const stdout = std.io.getStdOut().writer();
    try stdout.print("\n=== AST Nodes ===\n", .{});
    for (tp.nodes.items(), 0..) |node, i| {
        try stdout.print("\nNode {d}:\n", .{i});
        try printNode(node, stdout, 0);
    }
}

test {
    std.testing.refAllDecls(@This());
}
