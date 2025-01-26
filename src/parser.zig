const std = @import("std");
const mem = std.mem;
const transpiler = @import("./transpiler.zig");
const token = @import("./token.zig");
const ast = @import("./ast.zig");
const misc = @import("./misc.zig");
const history = @import("./history.zig");
const dtype = @import("./dtype.zig");
const expressionable = @import("./expressionable.zig");

var parser_last_token: token.Token = undefined;
var parser_current_body: ast.Node = undefined;
var parser_current_function: ast.Node = undefined;

/// Represents the parsing process in the transpiler.
///
/// This struct handles the parsing process within the transpiler, including
/// the associated transpilation process and methods for parsing.
pub const ParseProcess = struct {
    /// The transpilation process associated with the parsing process.
    transpile_proc: *transpiler.TranspileProcess,
    /// The allocator to be used for memory allocation operations.
    allocator: mem.Allocator,

    const Self = @This();

    /// Initializes a new `ParseProcess` instance.
    ///
    /// This function creates and initializes a new instance of `ParseProcess` with the given transpilation process.
    ///
    /// Parameters:
    /// - `transpile_proc (*transpiler.TranspileProcess)`: The transpilation process to associate with the new `ParseProcess` instance.
    ///
    /// Returns:
    /// - `Self`: The initialized `ParseProcess` instance.
    pub fn init(allocator: mem.Allocator, transpile_proc: *transpiler.TranspileProcess) Self {
        return Self{
            .transpile_proc = transpile_proc,
            .allocator = allocator,
        };
    }

    /// Expects the next token to be a specific symbol.
    ///
    /// This function retrieves the next token and checks if it matches the specified symbol (`c`).
    /// If the next token is not the expected symbol, it logs an error message indicating that
    /// the expected symbol was not found.
    ///
    /// Parameters:
    /// - `c (u8)`: The expected symbol.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    /// - Logs an error message if the next token is not the expected symbol.
    fn expect_sym(self: *Self, c: u8) !void {
        const t = try self.token_next();
        if (t == null or t.?.type != .Symbol or t.?.data.cval != c) {
            self.transpile_proc.err("expected symbol '{c}'", .{c});
        }
    }

    /// Expects the next token to be a specific operator.
    ///
    /// This function retrieves the next token and checks if it matches the specified operator (`op`).
    /// If the next token is not the expected operator, it logs an error message indicating that
    /// the expected operator was not found.
    ///
    /// Parameters:
    /// - `op ( []const u8 )`: The expected operator.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    /// - Logs an error message if the next token is not the expected operator.
    fn expect_op(self: *Self, op: []const u8) !void {
        const t = try self.token_next();
        if (t == null or t.?.type != .Operator or !mem.eql(u8, op, t.?.data.sval.items)) {
            self.transpile_proc.err("expected operator '{s}'", .{op});
        }
    }

    fn expect_keyword(self: *Self, keyword: []const u8) !void {
        const t = try self.token_next();
        if (t == null or t.?.type != .Keyword or !mem.eql(u8, keyword, t.?.data.sval.items)) {
            self.transpile_proc.err("expected keyword '{s}'", .{keyword});
        }
    }

    /// Creates and initializes a new node in the transpiler's node list.
    ///
    /// This function sets the `owner` and `function` bindings of the provided node (`n`)
    /// and adds it to the transpiler's node list.
    ///
    /// Parameters:
    /// - `n (*ast.Node)`: The node to create and initialize.
    ///
    /// Errors:
    /// - Returns an error if adding the node to the node list fails.
    fn create_node(self: *Self, n: *ast.Node) !void {
        const owner = try self.allocator.create(ast.Node);
        owner.* = parser_current_body;
        const function = try self.allocator.create(ast.Node);
        function.* = parser_current_function;
        n.binded = .{
            .owner = owner,
            .function = function,
        };
        try self.transpile_proc.nodes.push(n.*);
    }

    /// Skips newline, comment, and newline separator tokens.
    ///
    /// This function skips tokens that are either newline, comment, or newline separator
    /// tokens by incrementing the token pointer until a non-skippable token is found.
    ///
    /// Parameters:
    /// - `t (*?token.Token)`: The token pointer to update.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    fn ignore_nl_or_comment(self: *Self, t: *?token.Token) !void {
        while (t.* != null and token.is_nl_or_comment_or_newline_separator(t.*)) {
            _ = self.transpile_proc.tokens.peek(); // skip token
            t.* = self.transpile_proc.tokens.peek_no_increment();
        }
    }

    /// Peeks at the next non-skippable token.
    ///
    /// This function peeks at the next token and skips any newline, comment, or
    /// newline separator tokens, returning the first non-skippable token.
    ///
    /// Returns:
    /// - `!?token.Token`: The next non-skippable token, or `null` if no such token exists.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    fn token_peek_next(self: *Self) !?token.Token {
        var next_token = self.transpile_proc.tokens.peek_no_increment();
        try self.ignore_nl_or_comment(&next_token);
        return self.transpile_proc.tokens.peek_no_increment();
    }

    /// Retrieves the next token.
    ///
    /// This function peeks at the next token without incrementing the token stream's position.
    /// It ignores newline or comment tokens and updates the current position if a valid token is found.
    ///
    /// Returns:
    /// - `!?token.Token`: The next token, or `null` if there are no more tokens.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    fn token_next(self: *Self) !?token.Token {
        var next_token = self.transpile_proc.tokens.peek_no_increment();
        try self.ignore_nl_or_comment(&next_token);
        if (next_token != null) {
            self.transpile_proc.pos = next_token.?.pos;
            parser_last_token = next_token.?;
        }
        return self.transpile_proc.tokens.peek();
    }

    /// Pops the last node from the transpiler's node stack.
    ///
    /// This function retrieves the last node from the transpiler's node stack,
    /// removes it from the stack, and returns the node.
    ///
    /// Returns:
    /// - `?ast.Node`: The last node in the stack, or `null` if the stack is empty.
    ///
    /// Parameters:
    /// - `self (*Self)`: The pointer to the current instance.
    fn node_pop(self: *Self) ?ast.Node {
        const last_node = self.transpile_proc.nodes.back();
        self.transpile_proc.nodes.pop();
        return last_node;
    }

    /// Checks if the next token is a specific symbol.
    ///
    /// This function peeks at the next token and checks if it matches the specified symbol.
    ///
    /// Parameters:
    /// - `c (u8)`: The symbol to check for.
    ///
    /// Returns:
    /// - `bool`: `true` if the next token is the specified symbol, otherwise `false`.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    fn next_token_is_symbol(self: *Self, c: u8) !bool {
        const t = try self.token_peek_next();
        return token.is_symbol(t, c);
    }

    fn parse_statement(self: *Self, hist: *history.History) !void {
        var t = try self.token_peek_next();
        if (t.?.type == .Keyword) {
            try self.parse_keyword(hist);
            return;
        }
        try self.parse_expressionable_root(hist);
        t = try self.token_peek_next();
        if (t.?.type == .Symbol and t.?.data.cval != ';') {
            try self.parse_symbol();
            return;
        }
        try self.expect_sym(';');
    }

    fn parse_body_multiple_statements(self: *Self, hist: *history.History) !void {
        var stmts = misc.Vector(*ast.Node).init(self.allocator);
        try self.make_body_node(misc.Vector(*ast.Node).init(self.allocator));
        var body_node = self.node_pop();
        const owner = try self.allocator.create(ast.Node);
        owner.* = parser_current_body;
        body_node.?.binded.?.owner = owner;
        parser_current_body = body_node.?;
        try self.expect_sym('{');
        while (!try self.next_token_is_symbol('}')) {
            var hist_down = history.History.down(self.allocator, hist, hist.flags);
            defer hist_down.deinit();
            try self.parse_statement(&hist_down);
            const stmt_node = self.node_pop();
            const stmt = try self.allocator.create(ast.Node);
            stmt.* = stmt_node.?;
            try stmts.push(stmt);
        }
        try self.expect_sym('}');
        parser_current_body = body_node.?.binded.?.owner.?.*;
        body_node.?.node_variant.?.body.statements = stmts;
        try self.transpile_proc.nodes.push(body_node.?);
    }

    fn parse_body(self: *Self, hist: *history.History) !void {
        try self.parse_body_multiple_statements(hist);
    }

    /// Parses a symbol token.
    ///
    /// This function checks if the next token is the '{' symbol. If so, it pops the last
    /// node from the node stack and pushes it back. If the next token is not '{', it logs
    /// an error message indicating an invalid symbol.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails or if pushing the node fails.
    fn parse_symbol(self: *Self) anyerror!void {
        if (try self.next_token_is_symbol('{')) {
            var hist = history.History.init(self.allocator, .{ .is_global_scope = true });
            try self.parse_body(&hist);
            const body_node = self.node_pop();
            try self.transpile_proc.nodes.push(body_node.?);
        }
        self.transpile_proc.err("invalid symbol", .{});
    }

    fn next_token_is_operator(self: *Self, op: []const u8) !bool {
        const t = try self.token_peek_next();
        return token.is_operator(t, op);
    }

    fn next_token_is_keyword(self: *Self, keyword: []const u8) !bool {
        const t = try self.token_peek_next();
        return token.is_keyword(t, keyword);
    }

    fn parse_get_pointer_depth(self: *Self) !usize {
        var depth: u8 = 0;
        while (try self.next_token_is_operator("*")) {
            depth += 1;
            _ = try self.token_next();
        }
        return depth;
    }

    fn parse_datatype(self: *Self, dt: *dtype.DataType) !void {
        const dt_token = try self.token_next();
        if (dt_token.?.type != .Keyword) {
            self.transpile_proc.err("expected datatype, got '{?}'", .{dt_token.?.type});
        }
        const ptr_depth = try self.parse_get_pointer_depth();
        if (ptr_depth > 0) {
            dt.*.flags.?.is_pointer = true;
            dt.*.pointer_depth = ptr_depth;
        }
        dt.*.type = misc.get_datatype_type(dt_token.?.data.sval.items);
        if (dt.*.type.? == .Unknown) {
            self.transpile_proc.err("unknown datatype", .{});
        }
        dt.*.type_str = dt_token.?.data.sval;
    }

    fn parse_single_token_to_node(self: *Self) !bool {
        const t = try self.token_next();
        switch (t.?.type) {
            .Number => {
                var number_node = ast.Node{
                    .type = .Number,
                    .data = .{ .llnum = t.?.data.llnum },
                };
                try self.create_node(&number_node);
            },
            .Identifier => {
                var ident_node = ast.Node{
                    .type = .Identifier,
                    .data = .{ .sval = t.?.data.sval },
                };
                try self.create_node(&ident_node);
            },
            .String => {
                var str_node = ast.Node{
                    .type = .String,
                    .data = .{ .sval = t.?.data.sval },
                };
                try self.create_node(&str_node);
            },
            .Boolean => {
                var bool_node = ast.Node{
                    .type = .Boolean,
                    .data = .{ .bval = t.?.data.bval },
                };
                try self.create_node(&bool_node);
            },
            else => self.transpile_proc.err("expected single token, got '{?}'", .{t.?.type}),
        }
        return true;
    }

    fn parse_additional_expression(self: *Self) !void {
        const t = try self.token_peek_next();
        if (t.?.type == .Operator) {
            var hist = history.History.init(self.allocator, .{});
            defer hist.deinit();
            try self.parse_expressionable(&hist);
        }
    }

    fn parse_for_parenthesis(self: *Self, hist: *history.History) !void {
        try self.expect_op("(");
        var left_node: ?ast.Node = null;
        const tmp_node = self.transpile_proc.nodes.back();
        if (tmp_node != null and ast.node_is_value_type(tmp_node.?)) {
            left_node = tmp_node;
            _ = self.node_pop();
        }
        var exp_node = ast.Node{ .type = .Blank };
        if (!try self.next_token_is_symbol(')')) {
            try self.parse_expressionable_root(hist);
            exp_node = self.node_pop().?;
        }
        try self.expect_sym(')');
        const exp = try self.allocator.create(ast.Node);
        exp.* = exp_node;
        try self.transpile_proc.nodes.push(ast.Node{
            .type = .ExpressionParenthesis,
            .node_variant = .{ .paren = .{ .exp = exp } },
        });
        if (left_node != null) {
            const parenthesis_node = self.node_pop();
            const left = try self.allocator.create(ast.Node);
            left.* = left_node.?;
            const right = try self.allocator.create(ast.Node);
            right.* = parenthesis_node.?;
            try self.transpile_proc.nodes.push(ast.Node{
                .type = .Expression,
                .node_variant = .{
                    .exp = .{
                        .left = left,
                        .right = right,
                        .op = "()",
                    },
                },
            });
        }
        try self.parse_additional_expression();
    }

    fn parse_for_comma(self: *Self, hist: *history.History) !void {
        _ = try self.token_next(); // skip ,
        const left_node = self.node_pop();
        try self.parse_expressionable_root(hist);
        const right_node = self.node_pop();
        const left = try self.allocator.create(ast.Node);
        left.* = left_node.?;
        const right = try self.allocator.create(ast.Node);
        right.* = right_node.?;
        try self.transpile_proc.nodes.push(ast.Node{
            .type = .Expression,
            .node_variant = .{
                .exp = .{
                    .left = left,
                    .right = right,
                    .op = ",",
                },
            },
        });
    }

    fn parse_for_bracket(self: *Self, hist: *history.History) !void {
        const left_node = self.transpile_proc.nodes.back();
        if (left_node != null) {
            _ = self.node_pop();
        }
        try self.expect_op("[");
        try self.parse_expressionable_root(hist);
        try self.expect_sym(']');
        const exp_node = self.node_pop();
        const inner = try self.allocator.create(ast.Node);
        inner.* = exp_node.?;
        try self.transpile_proc.nodes.push(ast.Node{
            .type = .Bracket,
            .node_variant = .{ .bracket = .{ .inner = inner } },
        });
        if (left_node != null) {
            const bracket_node = self.node_pop();
            const left = try self.allocator.create(ast.Node);
            left.* = left_node.?;
            const right = try self.allocator.create(ast.Node);
            right.* = bracket_node.?;
            try self.transpile_proc.nodes.push(ast.Node{
                .type = .Expression,
                .node_variant = .{
                    .exp = .{
                        .left = left,
                        .right = right,
                        .op = "[]",
                    },
                },
            });
        }
    }

    fn node_peek_expressionable_or_null(self: *Self) !?ast.Node {
        const n = self.transpile_proc.nodes.back();
        return if (n != null and ast.node_is_expressionable(n.?)) n.? else null;
    }

    fn parse_for_indirection_unary(self: *Self) !void {
        const depth = try self.parse_get_pointer_depth();
        var hist = history.History.init(self.allocator, .{ .expression_is_unary = true });
        defer hist.deinit();
        try self.parse_expressionable(&hist);
        const unary_operand_node = self.node_pop();
        const operand = try self.allocator.create(ast.Node);
        operand.* = unary_operand_node.?;
        try self.transpile_proc.nodes.push(ast.Node{
            .type = .Unary,
            .node_variant = .{
                .unary = .{
                    .op = "*",
                    .operand = operand,
                },
            },
        });
        var unary_node = self.node_pop();
        unary_node.?.node_variant.?.unary.indirection.?.depth = depth;
        try self.transpile_proc.nodes.push(unary_node.?);
    }

    fn parse_for_normal_unary(self: *Self) !void {
        const unary_op = (try self.token_next()).?.data.sval.items;
        var hist = history.History.init(self.allocator, .{ .expression_is_unary = true });
        defer hist.deinit();
        try self.parse_expressionable(&hist);
        const unary_operand_node = self.node_pop();
        const operand = try self.allocator.create(ast.Node);
        operand.* = unary_operand_node.?;
        try self.transpile_proc.nodes.push(ast.Node{
            .type = .Unary,
            .node_variant = .{
                .unary = .{
                    .op = unary_op,
                    .operand = operand,
                },
            },
        });
    }

    fn parse_for_unary(self: *Self) !void {
        const t = try self.token_peek_next();
        const unary_op = t.?.data.sval.items;
        if (misc.is_indirection_operator(unary_op)) {
            try self.parse_for_indirection_unary();
            return;
        }
        try self.parse_for_normal_unary();
        try self.parse_additional_expression();
    }

    fn parse_for_left_operanded_unary(self: *Self, node_left: *ast.Node, unary_op: []const u8) !void {
        try self.transpile_proc.nodes.push(ast.Node{
            .type = .Unary,
            .node_variant = .{
                .unary = .{
                    .op = unary_op,
                    .operand = node_left,
                    .is_left_operanded_unary = true,
                },
            },
        });
    }

    fn make_expression_node(self: *Self, left_node: *ast.Node, right_node: *ast.Node, op: []const u8) !void {
        var exp_node = ast.Node{
            .type = .Expression,
            .node_variant = .{
                .exp = .{
                    .left = left_node,
                    .right = right_node,
                    .op = op,
                },
            },
        };
        try self.create_node(&exp_node);
    }

    fn make_body_node(self: *Self, stmts: misc.Vector(*ast.Node)) !void {
        var body_node = ast.Node{ .type = .Body, .node_variant = .{ .body = .{ .statements = stmts } } };
        try self.create_node(&body_node);
    }

    fn parse_get_precedence_for_operator(_: Self, op: []const u8, group: *?expressionable.OpPrecedenceGroup) i8 {
        for (0..expressionable.TOTAL_OPERATOR_GROUPS) |i| {
            var j: u8 = 0;
            while (expressionable.op_precedence[i].operators[j] != null) {
                const _op = expressionable.op_precedence[i].operators[j];
                if (mem.eql(u8, _op.?, op)) {
                    group.* = expressionable.op_precedence[i];
                    return @intCast(i);
                }
                j += 1;
            }
        }
        return -1;
    }

    fn parse_left_has_priority(self: *Self, op_left: []const u8, op_right: []const u8) bool {
        var left_group: ?expressionable.OpPrecedenceGroup = null;
        var right_group: ?expressionable.OpPrecedenceGroup = null;
        if (mem.eql(u8, op_left, op_right)) {
            return false;
        }
        const left_prec = self.parse_get_precedence_for_operator(op_left, &left_group);
        const right_prec = self.parse_get_precedence_for_operator(op_right, &right_group);
        if (left_group.?.associativity == .RightToLeft) {
            return false;
        }
        return left_prec <= right_prec;
    }

    fn parse_node_shift_children_left(self: *Self, node: *ast.Node) !void {
        const right_op = node.*.node_variant.?.exp.right.?.*.node_variant.?.exp.op;
        var new_exp_left_node = node.*.node_variant.?.exp.left.?.*;
        var new_exp_right_node = node.*.node_variant.?.exp.right.?.*.node_variant.?.exp.left.?.*;
        try self.make_expression_node(&new_exp_left_node, &new_exp_right_node, node.*.node_variant.?.exp.op);
        const new_left_operand = self.node_pop();
        const new_right_operand = node.*.node_variant.?.exp.right.?.*.node_variant.?.exp.right.?.*;
        const left = try self.allocator.create(ast.Node);
        left.* = new_left_operand.?;
        const right = try self.allocator.create(ast.Node);
        right.* = new_right_operand;
        node.*.node_variant.?.exp.left = left;
        node.*.node_variant.?.exp.right = right;
        node.*.node_variant.?.exp.op = right_op;
    }

    fn parse_node_move_right_left_to_left(self: *Self, node: *ast.Node) !void {
        try self.make_expression_node(
            node.*.node_variant.?.exp.left.?,
            node.*.node_variant.?.exp.right.?.*.node_variant.?.exp.left.?,
            node.*.node_variant.?.exp.op,
        );
        const completed_node = self.node_pop();
        const new_op = node.*.node_variant.?.exp.right.?.*.node_variant.?.exp.op;
        const left = try self.allocator.create(ast.Node);
        left.* = completed_node.?;
        const right = try self.allocator.create(ast.Node);
        right.* = node.*.node_variant.?.exp.right.?.*.node_variant.?.exp.right.?.*;
        node.*.node_variant.?.exp.left = left;
        node.*.node_variant.?.exp.right = right;
        node.*.node_variant.?.exp.op = new_op;
    }

    fn parse_reorder_expression(self: *Self, node: *ast.Node) !void {
        if (node.*.type != .Expression) {
            return;
        }
        if (node.*.node_variant != null and node.*.node_variant.?.exp.left.?.*.type != .Expression and node.*.node_variant.?.exp.right != null and
            node.*.node_variant.?.exp.right.?.*.type != .Expression)
        {
            return;
        }
        if (node.*.node_variant != null and node.*.node_variant.?.exp.left.?.*.type != .Expression and node.*.node_variant.?.exp.right != null and
            node.*.node_variant.?.exp.right.?.*.type == .Expression)
        {
            const right_op = node.*.node_variant.?.exp.right.?.*.node_variant.?.exp.op;
            if (self.parse_left_has_priority(node.*.node_variant.?.exp.op, right_op)) {
                try self.parse_node_shift_children_left(node);
                try self.parse_reorder_expression(node.*.node_variant.?.exp.left.?);
                try self.parse_reorder_expression(node.*.node_variant.?.exp.right.?);
            }
        }
        if ((node.*.node_variant.?.exp.left != null and ast.node_is_array(node.*.node_variant.?.exp.left.?.*) and node.*.node_variant.?.exp.right != null and ast.node_is_assignment(node.*.node_variant.?.exp.right.?.*)) or
            ((ast.node_is_expression(node.*.node_variant.?.exp.left.?.*, "()") or
            ast.node_is_expression(node.*.node_variant.?.exp.left.?.*, "[]")) and
            ast.node_is_expression(node.*.node_variant.?.exp.right.?.*, ",")))
        {
            try self.parse_node_move_right_left_to_left(node);
        }
    }

    fn parse_normal_expression(self: *Self, hist: *history.History) !void {
        var t = try self.token_peek_next();
        const op = t.?.data.sval.items;
        var node_left = try self.node_peek_expressionable_or_null();
        if (node_left == null) {
            if (!misc.is_unary_operator(op)) {
                self.transpile_proc.err("expected left operand for '{s}' operator", .{op});
            }
            return try self.parse_for_unary();
        }
        _ = try self.token_next(); // skip operator
        _ = self.node_pop();
        if (misc.is_left_operanded_unary_operator(op)) {
            return try self.parse_for_left_operanded_unary(&node_left.?, op);
        }
        node_left.?.flags = .{ .inside_expression = true };
        t = try self.token_peek_next();
        if (t.?.type == .Operator) {
            if (mem.eql(u8, t.?.data.sval.items, "(")) {
                var hist_down = history.History.down(self.allocator, hist, hist.flags);
                defer hist_down.deinit();
                hist_down.flags.parenthesis_not_function_call = true;
                try self.parse_for_parenthesis(&hist_down);
            } else if (misc.is_unary_operator(t.?.data.sval.items)) {
                try self.parse_for_unary();
            } else {
                self.transpile_proc.err("expected expressionable for '{s}' operator", .{op});
            }
        } else {
            var hist_down = history.History.down(self.allocator, hist, hist.flags);
            defer hist_down.deinit();
            try self.parse_expressionable(&hist_down);
        }
        var node_right = self.node_pop();
        node_right.?.flags = .{ .inside_expression = true };
        try self.make_expression_node(&node_left.?, &node_right.?, op);
        var exp_node = self.node_pop();
        try self.parse_reorder_expression(&exp_node.?);
        try self.transpile_proc.nodes.push(exp_node.?);
    }

    fn parse_expression(self: *Self, hist: *history.History) !bool {
        const t = try self.token_peek_next();
        if (hist.flags.expression_is_unary and !misc.is_unary_operand_compatible(t.?)) {
            return false;
        }
        if (mem.eql(u8, "(", t.?.data.sval.items)) {
            try self.parse_for_parenthesis(hist);
        } else if (mem.eql(u8, ",", t.?.data.sval.items)) {
            try self.parse_for_comma(hist);
        } else if (mem.eql(u8, "[", t.?.data.sval.items)) {
            try self.parse_for_bracket(hist);
        } else {
            try self.parse_normal_expression(hist);
        }
        return true;
    }

    fn parse_identifier(self: *Self) !bool {
        const t = try self.token_peek_next();
        if (t != null and t.?.type != .Identifier) {
            self.transpile_proc.err("expected identifier, got '{?}'", .{t.?.type});
        }
        return try self.parse_single_token_to_node();
    }

    fn parse_string(self: *Self) !bool {
        const t = try self.token_peek_next();
        if (t != null and t.?.type != .String) {
            self.transpile_proc.err("expected string, got '{?}'", .{t.?.type});
        }
        return try self.parse_single_token_to_node();
    }

    fn parse_expressionable_single(self: *Self, hist: *history.History) !bool {
        const t = try self.token_peek_next();
        if (t == null) {
            return false;
        }
        hist.flags.inside_expression = true;
        return switch (t.?.type) {
            .Number, .Boolean => try self.parse_single_token_to_node(),
            .Operator => {
                if (hist.*.flags.in_fit_statement and mem.eql(u8, t.?.data.sval.items, "->")) {
                    return false;
                }
                return try self.parse_expression(hist);
            },
            .Identifier => try self.parse_identifier(),
            .Keyword => {
                try self.parse_keyword(hist);
                return true;
            },
            .String => try self.parse_string(),
            else => false,
        };
    }

    fn parse_expressionable(self: *Self, hist: *history.History) anyerror!void {
        while (try self.parse_expressionable_single(hist)) {}
    }

    fn parse_expressionable_root(self: *Self, hist: *history.History) anyerror!void {
        try self.parse_expressionable(hist);
        const n = self.node_pop();
        try self.transpile_proc.nodes.push(n.?);
    }

    fn parse_array_brackets(self: *Self, dt: *dtype.DataType, hist: *history.History) !void {
        dt.*.array.?.brackets = misc.Vector(ast.Node).init(self.allocator);
        while (try self.next_token_is_operator("[")) {
            try self.expect_op("[");
            if (try self.next_token_is_symbol(']')) {
                try self.expect_sym(']');
                break;
            }
            try self.parse_expressionable_root(hist);
            try self.expect_sym(']');
            const exp_node = self.node_pop();
            const exp = try self.allocator.create(ast.Node);
            exp.* = exp_node.?;
            try self.transpile_proc.nodes.push(ast.Node{
                .type = .Bracket,
                .node_variant = .{ .bracket = .{ .inner = exp } },
            });
            const bracket_node = self.node_pop();
            try dt.*.array.?.brackets.push(bracket_node.?);
            dt.*.flags.?.is_array = true;
        }
    }

    fn parse_variable(self: *Self, dt: *dtype.DataType, hist: *history.History) !void {
        if (try self.next_token_is_operator("[")) {
            try self.parse_array_brackets(dt, hist);
        }
        const ident_token = try self.token_next();
        if (ident_token.?.type != .Identifier) {
            self.transpile_proc.err("expected indentifier, got '{}'", .{ident_token.?.type});
        }
        var value_node: ?ast.Node = null;
        if (try self.next_token_is_operator("=")) {
            _ = try self.token_next(); // skip =
            try self.parse_expressionable_root(hist);
            value_node = self.node_pop();
        }
        const val = try self.allocator.create(ast.Node);
        if (value_node != null) {
            val.* = value_node.?;
        }
        try self.transpile_proc.nodes.push(ast.Node{
            .type = .Variable,
            .node_variant = .{
                .variable = .{
                    .name = ident_token.?.data.sval,
                    .type = dt.*,
                    .val = val,
                },
            },
        });
    }

    fn parse_full_variable(self: *Self, hist: *history.History) !void {
        var dt: dtype.DataType = undefined;
        try self.parse_datatype(&dt);
        try self.parse_variable(&dt, hist);
    }

    fn parse_function_args(self: *Self, hist: *history.History) !misc.Vector(*ast.Node) {
        var args = misc.Vector(*ast.Node).init(self.allocator);
        while (!try self.next_token_is_symbol(')')) {
            if (try self.next_token_is_operator(".")) { // variadic
                for (0..3) |_| {
                    try self.expect_op(".");
                }
                return args;
            }
            try self.parse_full_variable(hist);
            const arg_node = self.node_pop();
            const arg = try self.allocator.create(ast.Node);
            arg.* = arg_node.?;
            try args.push(arg);
            if (!try self.next_token_is_operator(",")) {
                break;
            }
            _ = try self.token_next(); // skip ,
        }
        return args;
    }

    fn parse_function(self: *Self) !void {
        _ = try self.token_next(); // skip fun
        var function_node: ast.Node = ast.Node{
            .type = .Function,
            .node_variant = .{ .function = .{} },
        };
        var dt: dtype.DataType = undefined;
        const ident_token = try self.token_next();
        if (ident_token.?.type != .Identifier) {
            self.transpile_proc.err("expected indentifier, got '{}'", .{ident_token.?.type});
        }
        function_node.node_variant.?.function.name = ident_token.?.data.sval;
        parser_current_function = function_node;
        try self.expect_op("(");
        var hist_args = history.History.init(self.allocator, .{});
        defer hist_args.deinit();
        const args = try self.parse_function_args(&hist_args);
        try self.expect_sym(')');
        function_node.node_variant.?.function.args = args;
        const rtype_token = try self.token_peek_next();
        if (rtype_token != null and rtype_token.?.type == .Keyword and misc.keyword_is_datatype(rtype_token.?.data.sval.items)) {
            try self.parse_datatype(&dt);
        } else {
            var type_str = std.ArrayList(u8).init(self.allocator);
            try type_str.appendSlice("void");
            dt = dtype.DataType{
                .type = .Void,
                .type_str = type_str,
            };
        }
        function_node.node_variant.?.function.rtype = dt;
        if (try self.next_token_is_symbol('{')) {
            var hist_body = history.History.init(self.allocator, .{});
            defer hist_body.deinit();
            try self.parse_body(&hist_body);
            const body_node = self.node_pop();
            const body = try self.allocator.create(ast.Node);
            body.* = body_node.?;
            function_node.node_variant.?.function.body = body;
        } else {
            try self.expect_sym(';');
        }
        parser_current_function = undefined;
        try self.transpile_proc.nodes.push(function_node);
    }

    fn parse_return(self: *Self, hist: *history.History) !void {
        _ = try self.token_next(); // skip ret
        if (try self.next_token_is_symbol(';')) {
            try self.expect_sym(';');
            try self.transpile_proc.nodes.push(ast.Node{
                .type = .StatementReturn,
            });
            return;
        }
        try self.parse_expressionable_root(hist);
        const exp_node = self.node_pop();
        const exp = try self.allocator.create(ast.Node);
        exp.* = exp_node.?;
        try self.transpile_proc.nodes.push(ast.Node{
            .type = .StatementReturn,
            .node_variant = .{ .statement = .{ .return_stmt = exp } },
        });
        try self.expect_sym(';');
    }

    fn parse_elif(self: *Self, hist: *history.History) !void {
        if (try self.next_token_is_keyword("elif")) {
            _ = try self.token_next(); // skip elif
            try self.parse_expressionable_root(hist);
            const condition_node = self.node_pop();
            const condition = try self.allocator.create(ast.Node);
            condition.* = condition_node.?;
            try self.parse_body(hist);
            const body_node = self.node_pop();
            const body = try self.allocator.create(ast.Node);
            body.* = body_node.?;
            try self.transpile_proc.nodes.push(ast.Node{
                .type = .StatementElseIf,
                .node_variant = .{ .statement = .{ .elif_stmt = .{ .condition = condition, .body = body } } },
            });
        }
    }

    fn parse_else(self: *Self, hist: *history.History) !void {
        if (try self.next_token_is_keyword("else")) {
            _ = try self.token_next(); // skip else
            try self.parse_body(hist);
            const body_node = self.node_pop();
            const body = try self.allocator.create(ast.Node);
            body.* = body_node.?;
            try self.transpile_proc.nodes.push(ast.Node{
                .type = .StatementElse,
                .node_variant = .{ .statement = .{ .else_stmt = .{ .body = body } } },
            });
        }
    }

    fn parse_if_statement(self: *Self, hist: *history.History) !void {
        try self.expect_keyword("if");
        try self.parse_expressionable_root(hist);
        const condition_node = self.node_pop();
        const condition = try self.allocator.create(ast.Node);
        condition.* = condition_node.?;
        try self.parse_body(hist);
        const body_node = self.node_pop();
        const body = try self.allocator.create(ast.Node);
        body.* = body_node.?;
        const if_node = ast.Node{
            .type = .StatementIf,
            .node_variant = .{
                .statement = .{
                    .if_stmt = .{ .condition = condition, .body = body },
                },
            },
        };
        try self.transpile_proc.nodes.push(if_node);
        try self.parse_elif(hist);
        try self.parse_else(hist);
    }

    fn parse_fit_body(self: *Self, fit_node: *ast.Node, hist: *history.History) !void {
        try self.expect_sym('{');
        fit_node.*.node_variant.?.statement.fit_stmt.branches = misc.Vector(ast.FitBranch).init(self.allocator);
        while (!try self.next_token_is_symbol('}')) {
            var hist_down = history.History.down(self.allocator, hist, hist.flags);
            defer hist_down.deinit();
            try self.parse_expressionable_root(&hist_down);
            const condition_node = self.node_pop();
            const condition = try self.allocator.create(ast.Node);
            if (condition_node.?.type == .Identifier and mem.eql(u8, condition_node.?.data.?.sval.items, "_")) {
                // default case after should be the last branch
                try self.expect_op("->");
                try self.parse_body(&hist_down);
                const body_node = self.node_pop();
                const body = try self.allocator.create(ast.Node);
                body.* = body_node.?;
                try fit_node.*.node_variant.?.statement.fit_stmt.branches.push(.{ .body = body, .condition = null });
                if (try self.next_token_is_operator(",")) {
                    _ = try self.token_next(); // skip ,
                }
                break;
            }
            condition.* = condition_node.?;
            try self.expect_op("->");
            try self.parse_body(&hist_down);
            const body_node = self.node_pop();
            const body = try self.allocator.create(ast.Node);
            body.* = body_node.?;
            try fit_node.*.node_variant.?.statement.fit_stmt.branches.push(.{ .body = body, .condition = condition });
            if (try self.next_token_is_operator(",")) {
                _ = try self.token_next(); // skip ,
            }
        }
        try self.expect_sym('}');
    }

    fn parse_fit_statement(self: *Self, hist: *history.History) !void {
        var fit_node: ast.Node = .{
            .type = .StatementFit,
            .node_variant = .{
                .statement = .{ .fit_stmt = undefined },
            },
        };
        hist.*.flags.in_fit_statement = true;
        try self.expect_keyword("fit");
        var new_hist = history.History.init(self.allocator, .{ .in_fit_statement = true });
        defer new_hist.deinit();
        try self.parse_expressionable_root(&new_hist);
        const condition_node = self.node_pop();
        const condition = try self.allocator.create(ast.Node);
        condition.* = condition_node.?;
        fit_node.node_variant.?.statement.fit_stmt.exp = condition;
        try self.parse_fit_body(&fit_node, &new_hist);
        try self.transpile_proc.nodes.push(fit_node);
    }

    fn parse_import(self: *Self) !void {
        _ = try self.token_next(); // skip imp
        const folder_token = try self.token_next();
        if (folder_token.?.type != .Identifier) {
            self.transpile_proc.err("expected folder identifier, got '{?}'", .{folder_token.?.type});
        }
        var import_name = std.ArrayList(u8).init(self.allocator);
        defer import_name.deinit();
        try import_name.appendSlice(folder_token.?.data.sval.items);

        const next_token = try self.token_peek_next();
        if (next_token != null and next_token.?.type == .Operator and misc.is_access_operator(next_token.?.data.sval.items)) {
            _ = try self.token_next(); // skip dot
            const file_token = try self.token_next();
            if (file_token.?.type != .Identifier) {
                self.transpile_proc.err("expected file identifier, got '{?}'", .{file_token.?.type});
            }
            try import_name.append('.');
            try import_name.appendSlice(file_token.?.data.sval.items);
        }

        try self.expect_sym(';');
        try self.transpile_proc.nodes.push(ast.Node{
            .type = .Import,
            .node_variant = .{ .import = .{ .path = try import_name.toOwnedSlice() } },
        });
    }

    /// Parses a keyword token.
    ///
    /// This function checks if the next token matches any known keywords.
    /// If the token is a datatype keyword, it proceeds to parse a variable.
    /// If the token matches other specific keywords,
    /// it handles each case accordingly. If the token doesn't match any valid keyword,
    /// it logs an error message indicating an invalid keyword.
    ///
    /// Parameters:
    /// - `hist (*history.History)`: The history context for the parse operation.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    fn parse_keyword(self: *Self, hist: *history.History) anyerror!void {
        const t = try self.token_peek_next();
        const sval = t.?.data.sval.items;
        if (misc.keyword_is_datatype(sval)) {
            var dt: dtype.DataType = undefined;
            try self.parse_datatype(&dt);
            try self.parse_variable(&dt, hist);
            try self.expect_sym(';');
            return;
        }

        if (mem.eql(u8, "imp", sval)) {
            return try self.parse_import();
        } else if (mem.eql(u8, "fun", sval)) {
            return try self.parse_function();
        } else if (mem.eql(u8, "if", sval)) {
            return try self.parse_if_statement(hist);
        } else if (mem.eql(u8, "fit", sval)) {
            return try self.parse_fit_statement(hist);
        } else if (mem.eql(u8, "ret", sval)) {
            return try self.parse_return(hist);
        } else if (mem.eql(u8, "true", sval)) {
            try self.transpile_proc.nodes.push(ast.Node{
                .type = .Boolean,
                .node_variant = .{ .boolean = .{ .val = true } },
            });
            return;
        } else if (mem.eql(u8, "false", sval)) {
            try self.transpile_proc.nodes.push(ast.Node{
                .type = .Boolean,
                .node_variant = .{ .boolean = .{ .val = false } },
            });
            return;
        }

        self.transpile_proc.err("invalid keyword", .{});
    }

    /// Parses a global keyword token.
    ///
    /// This function initializes a `History` instance with global scope
    /// and calls the `parse_keyword` function to handle the keyword parsing.
    ///
    /// Errors:
    /// - Returns an error if initializing the history or parsing the keyword fails.
    fn parse_global_keyword(self: *Self) !void {
        var hist = history.History.init(
            self.allocator,
            .{ .is_global_scope = true },
        );
        defer hist.deinit();

        try self.parse_keyword(&hist);
        const n = self.node_pop();
        try self.transpile_proc.nodes.push(n.?);
    }

    /// Processes the next token in the input.
    ///
    /// This function processes the next token, handling different token types
    /// and returning `true` if a valid token is found, or `false` if there are
    /// no more tokens.
    ///
    /// Returns:
    /// - `bool`: `true` if a valid token is found, otherwise `false`.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    fn next(self: *Self) !bool {
        const t = try self.token_peek_next();
        if (t == null) {
            return false;
        }
        try switch (t.?.type) {
            .Number, .Identifier, .String => {
                var hist = history.History.init(self.allocator, .{});
                defer hist.deinit();
                try self.parse_expressionable(&hist);
            },
            .Keyword => self.parse_global_keyword(),
            .Symbol => self.parse_symbol(),
            else => unreachable,
        };
        return true;
    }

    /// Parses the entire input sequence of tokens.
    ///
    /// This function repeatedly processes tokens until there are no more tokens
    /// to process.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    pub fn parse(self: *Self) !void {
        while (try self.next()) {}
    }
};
