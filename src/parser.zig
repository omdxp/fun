const std = @import("std");
const mem = std.mem;
const transpiler = @import("./transpiler.zig");
const token = @import("./token.zig");
const ast = @import("./ast.zig");
const misc = @import("./misc.zig");
const history = @import("./history.zig");
const dtype = @import("./dtype.zig");

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
            self.transpile_proc.error_message("expected symbol");
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
            self.transpile_proc.error_message("expected operator");
        }
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

    /// Parses a symbol token.
    ///
    /// This function checks if the next token is the '{' symbol. If so, it pops the last
    /// node from the node stack and pushes it back. If the next token is not '{', it logs
    /// an error message indicating an invalid symbol.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails or if pushing the node fails.
    fn parse_symbol(self: *Self) !void {
        if (try self.next_token_is_symbol('{')) {
            // TODO: parse body
            const body_node = self.node_pop();
            try self.transpile_proc.nodes.push(body_node.?);
        }
        self.transpile_proc.error_message("invalid symbol");
    }

    fn token_next_is_operator(self: *Self, op: []const u8) !bool {
        const t = try self.token_peek_next();
        return token.is_operator(t, op);
    }

    fn parse_get_pointer_depth(self: *Self) !usize {
        var depth: u8 = 0;
        while (try self.token_next_is_operator("*")) {
            depth += 1;
            _ = try self.token_next();
        }
        return depth;
    }

    fn parse_datatype(self: *Self, dt: *dtype.DataType) !void {
        const dt_token = try self.token_next();
        const ptr_depth = try self.parse_get_pointer_depth();
        if (ptr_depth > 0) {
            dt.*.flags.?.is_pointer = true;
            dt.*.pointer_depth = ptr_depth;
        }
        dt.*.type = misc.get_datatype_type(dt_token.?.data.sval.items);
        if (dt.*.type.? == .Unknown) {
            self.transpile_proc.error_message("unknown datatype");
        }
        dt.*.type_str = dt_token.?.data.sval;
    }

    fn parse_single_token_to_node(self: *Self) !bool {
        const t = try self.token_next();
        switch (t.?.type) {
            .Number => try self.transpile_proc.nodes.push(ast.Node{
                .type = .Number,
                .data = .{ .llnum = t.?.data.llnum },
            }),
            .Identifier => try self.transpile_proc.nodes.push(ast.Node{
                .type = .Identifier,
                .data = .{ .sval = t.?.data.sval },
            }),
            .String => try self.transpile_proc.nodes.push(ast.Node{
                .type = .String,
                .data = .{ .sval = t.?.data.sval },
            }),
            else => self.transpile_proc.error_message("expected single token"),
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
        try self.transpile_proc.nodes.push(ast.Node{
            .type = .ExpressionParenthesis,
            .node_variant = .{ .paren = .{ .exp = &exp_node } },
        });
        if (left_node != null) {
            var parenthesis_node = self.node_pop();
            try self.transpile_proc.nodes.push(ast.Node{
                .type = .Expression,
                .node_variant = .{
                    .exp = .{
                        .left = &left_node.?,
                        .right = &parenthesis_node.?,
                        .op = "()",
                    },
                },
            });
        }
        try self.parse_additional_expression();
    }

    fn parse_for_comma(self: *Self, hist: *history.History) !void {
        _ = try self.token_next(); // skip ,
        var left_node = self.node_pop();
        try self.parse_expressionable_root(hist);
        var right_node = self.node_pop();
        try self.transpile_proc.nodes.push(ast.Node{
            .type = .Expression,
            .node_variant = .{
                .exp = .{
                    .left = &left_node.?,
                    .right = &right_node.?,
                    .op = ",",
                },
            },
        });
    }

    fn parse_for_bracket(self: *Self, hist: *history.History) !void {
        var left_node = self.transpile_proc.nodes.back();
        if (left_node != null) {
            _ = self.node_pop();
        }
        try self.expect_op("[");
        try self.parse_expressionable_root(hist);
        try self.expect_sym(']');
        var exp_node = self.node_pop();
        try self.transpile_proc.nodes.push(ast.Node{
            .type = .Bracket,
            .node_variant = .{ .bracket = .{ .inner = &exp_node.? } },
        });
        if (left_node != null) {
            var bracket_node = self.node_pop();
            try self.transpile_proc.nodes.push(ast.Node{
                .type = .Expression,
                .node_variant = .{
                    .exp = .{
                        .left = &left_node.?,
                        .right = &bracket_node.?,
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
        var unary_operand_node = self.node_pop();
        try self.transpile_proc.nodes.push(ast.Node{
            .type = .Unary,
            .node_variant = .{
                .unary = .{
                    .op = "*",
                    .operand = &unary_operand_node.?,
                },
            },
        });
        var unary_node = self.node_pop();
        unary_node.?.node_variant.?.unary.indirection.?.depth = depth;
        try self.transpile_proc.nodes.push(unary_node.?);
    }

    fn parse_for_unary(self: *Self) !void {
        const t = try self.token_peek_next();
        const unary_op = t.?.data.sval.items;
        if (misc.is_indirection_operator(unary_op)) {
            try self.parse_for_indirection_unary();
            return;
        }
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

    fn parse_normal_expression(self: *Self, hist: *history.History) !void {
        var t = try self.token_peek_next();
        const op = t.?.data.sval.items;
        var node_left = try self.node_peek_expressionable_or_null();
        if (node_left == null) {
            if (!misc.is_unary_operator(node_left.?.data.?.sval.items)) {
                self.transpile_proc.error_message("expected left operand");
            }
            try self.parse_for_unary();
            return;
        }
        _ = try self.token_next(); // skip operator
        _ = self.node_pop();
        if (misc.is_left_operanded_unary_operator(op)) {
            try self.parse_for_left_operanded_unary(&node_left.?, op);
            return;
        }
        node_left.?.flags.?.inside_expression = true;
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
                self.transpile_proc.error_message("expected expressionable");
            }
        } else {
            var hist_down = history.History.down(self.allocator, hist, hist.flags);
            defer hist_down.deinit();
            try self.parse_expressionable(&hist_down);
        }
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

    fn parse_expressionable_single(self: *Self, hist: *history.History) !bool {
        const t = try self.token_peek_next();
        if (t == null) {
            return false;
        }
        return try switch (t.?.type) {
            .Number => self.parse_single_token_to_node(),
            .Operator => self.parse_expression(hist),
            else => unreachable,
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

    fn parse_variable(self: *Self, hist: *history.History) !void {
        var dt: ?dtype.DataType = null;
        try self.parse_datatype(&dt.?);

        const ident_token = try self.token_next();
        if (ident_token.?.type != .Identifier) {
            self.transpile_proc.error_message("expected indentifier");
        }

        // TODO: parse array brackets
        var value_node: ?ast.Node = null;

        if (try self.token_next_is_operator("=")) {
            _ = try self.token_next(); // skip =
            try self.parse_expressionable_root(hist);
            value_node = self.node_pop();
        }
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
    fn parse_keyword(self: *Self, hist: *history.History) !void {
        const t = try self.token_peek_next();
        const sval = t.?.data.sval.items;
        if (misc.keyword_is_datatype(sval)) {
            try self.parse_variable(hist);
            return;
        }

        if (mem.eql(u8, "imp", sval)) {
            @compileError("TODO: parse imp keyword");
        } else if (mem.eql(u8, "fun", sval)) {
            @compileError("TODO: parse fun keyword");
        } else if (mem.eql(u8, "if", sval)) {
            @compileError("TODO: parse if keyword");
        } else if (mem.eql(u8, "fit", sval)) {
            @compileError("TODO: parse fit keyword");
        } else if (mem.eql(u8, "ret", sval)) {
            @compileError("TODO: parse ret keyword");
        }

        self.transpile_proc.error_message("invalid keyword");
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
            .Number, .Identifier, .String => {},
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
        var node: ?ast.Node = null;
        while (try self.next()) {
            node = self.transpile_proc.nodes.back();
            if (node == null) break;
            try self.transpile_proc.nodes.push(node.?);
        }
    }
};
