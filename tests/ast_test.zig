const std = @import("std");
const ast = @import("ast");
const utils = @import("utils");

test "ast predicates classify nodes correctly" {
    _ = utils;

    const num_node = ast.Node{ .type = .Number };
    const id_node = ast.Node{ .type = .Identifier };
    const str_node = ast.Node{ .type = .String };
    const bool_node = ast.Node{ .type = .Boolean };

    const paren_node = ast.Node{
        .type = .ExpressionParenthesis,
        .node_variant = .{ .paren = .{ .exp = @constCast(&num_node) } },
    };

    const unary_node = ast.Node{
        .type = .Unary,
        .node_variant = .{ .unary = .{ .op = "-", .operand = @constCast(&num_node) } },
    };

    const assign_node = ast.Node{
        .type = .Expression,
        .node_variant = .{ .exp = .{ .op = "=", .left = @constCast(&id_node), .right = @constCast(&num_node) } },
    };

    const eq_node = ast.Node{
        .type = .Expression,
        .node_variant = .{ .exp = .{ .op = "==", .left = @constCast(&id_node), .right = @constCast(&num_node) } },
    };

    const index_inner = ast.Node{ .type = .Bracket, .node_variant = .{ .bracket = .{ .inner = @constCast(&num_node) } } };
    const index_node = ast.Node{
        .type = .Expression,
        .node_variant = .{ .exp = .{ .op = "[]", .left = @constCast(&id_node), .right = @constCast(&index_inner) } },
    };

    try std.testing.expect(ast.node_is_expressionable(num_node));
    try std.testing.expect(ast.node_is_expressionable(id_node));
    try std.testing.expect(ast.node_is_expressionable(str_node));
    try std.testing.expect(ast.node_is_expressionable(bool_node));
    try std.testing.expect(ast.node_is_expressionable(unary_node));
    try std.testing.expect(ast.node_is_expressionable(paren_node));

    try std.testing.expect(ast.node_is_value_type(num_node));
    try std.testing.expect(ast.node_is_value_type(id_node));
    try std.testing.expect(ast.node_is_value_type(str_node));
    try std.testing.expect(ast.node_is_value_type(unary_node));
    try std.testing.expect(ast.node_is_value_type(paren_node));

    try std.testing.expect(ast.node_is_expression(assign_node, "="));
    try std.testing.expect(ast.node_is_assignment(assign_node));
    try std.testing.expect(!ast.node_is_assignment(eq_node));

    try std.testing.expect(ast.node_is_array(index_node));
    try std.testing.expect(ast.node_is_expression(index_node, "[]"));
}
