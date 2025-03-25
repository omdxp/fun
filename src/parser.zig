const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const transpiler = @import("./transpiler.zig");
const lexer = @import("./lexer.zig");
const token = @import("./token.zig");
const ast = @import("./ast.zig");
const misc = @import("./misc.zig");
const history = @import("./history.zig");
const dtype = @import("./dtype.zig");
const expressionable = @import("./expressionable.zig");
const scope = @import("./scope.zig");

/// Represents the parsing process in the transpiler.
///
/// This struct handles the parsing process within the transpiler, including
/// the associated transpilation process and methods for parsing.
pub const ParseProcess = struct {
    /// The transpilation process associated with the parsing process.
    transpile_proc: *transpiler.TranspileProcess,
    /// The last token processed by the parser.
    parser_last_token: token.Token = undefined,
    /// The current body node being processed by the parser.
    parser_current_body: ?ast.Node = null,
    /// The current function node being processed by the parser.
    parser_current_function: ?ast.Node = null,

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
    pub fn init(transpile_proc: *transpiler.TranspileProcess) Self {
        return Self{
            .transpile_proc = transpile_proc,
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

    /// Expects the next token to be a specific keyword.
    ///
    /// This function retrieves the next token and checks if it matches the specified keyword (`keyword`).
    /// If the next token is not the expected keyword, it logs an error message indicating that
    /// the expected keyword was not found.
    ///
    /// Parameters:
    /// - `self`: The instance of the parser.
    /// - `keyword ( []const u8 )`: The expected keyword.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    /// - Logs an error message if the next token is not the expected keyword.
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
        var is_bound = false;
        var binded: ast.BindedNode = .{
            .owner = null,
            .function = null,
        };
        if (self.parser_current_body) |body| {
            if (body.binded != null) {
                const owner = try self.transpile_proc.allocator.create(ast.Node);
                owner.* = body;
                binded.owner = owner;
                is_bound = true;
            }
        }
        if (self.parser_current_function) |func| {
            const function = try self.transpile_proc.allocator.create(ast.Node);
            function.* = func;
            binded.function = function;
            is_bound = true;
        }
        if (is_bound) {
            const b = try self.transpile_proc.allocator.create(ast.BindedNode);
            b.*.function = binded.function;
            b.*.owner = binded.owner;
            n.binded = b;
        } else {
            n.binded = null;
        }
        try self.transpile_proc.nodes.push(n.*);
    }

    /// Creates a new scope entity.
    ///
    /// This function initializes a new scope entity with the provided node and flags.
    ///
    /// Parameters:
    /// - `self`: The instance of the parser.
    /// - `node (*ast.Node)`: The node to associate with the scope entity.
    /// - `flags (scope.ScopeEntityFlags)`: The flags to set for the scope entity.
    ///
    /// Returns:
    /// - `*scope.ScopeEntity`: The initialized scope entity.
    ///
    /// Errors:
    /// - Returns an error if creating the scope entity fails.
    fn new_scope_entity(self: *Self, node: *ast.Node, flags: scope.ScopeEntityFlags) !*scope.ScopeEntity {
        var entity = try self.transpile_proc.allocator.create(scope.ScopeEntity);
        entity.node = node;
        entity.flags = flags;
        return entity;
    }

    /// Retrieves the last entity from the current scope, stopping at the global scope.
    ///
    /// This function retrieves the last entity from the current scope, stopping at the global scope.
    ///
    /// Parameters:
    /// - `self`: The instance of the parser.
    ///
    /// Returns:
    /// - `*scope.ScopeEntity`: The last entity from the current scope, or `null` if not found.
    fn scope_last_entity_stop_global_scope(self: *Self) *scope.ScopeEntity {
        return self.transpile_proc.last_scope_entity_stop_at(self.transpile_proc.scope.?.root);
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
            self.parser_last_token = next_token.?;
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

    /// Parses a statement.
    ///
    /// This function peeks at the next token and determines if it is a keyword.
    /// If it is a keyword, it parses it accordingly. Otherwise, it parses an expressionable root.
    /// It also handles symbols and ensures the statement ends with a semicolon.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_statement(self: *Self, hist: *history.History) !void {
        var t = try self.token_peek_next();
        if (t == null) {
            self.transpile_proc.err("unexpected end of file", .{});
        }
        if (t.?.type == .Keyword) {
            return try self.parse_keyword(hist);
        }
        if (t.?.type == .Symbol and token.is_symbol(t, '{')) {
            return try self.parse_body(hist);
        }
        try self.parse_expressionable_root(hist);
        t = try self.token_peek_next();
        if (t.?.type == .Symbol and t.?.data.cval != ';') {
            try self.parse_symbol();
            return;
        }
        try self.expect_sym(';');
    }

    /// Parses multiple statements within a body.
    ///
    /// This function initializes a vector to hold statement nodes and creates a body node.
    /// It processes each statement within the body, handling nested history contexts, and
    /// ensures proper closure of the body with a closing brace. The resulting body node is added
    /// to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_body_multiple_statements(self: *Self, hist: *history.History) !void {
        var stmts = misc.Vector(*ast.Node).init(self.transpile_proc.allocator);
        try self.make_body_node();
        var body_node = self.node_pop();
        if (self.parser_current_body) |body| {
            const owner = try self.transpile_proc.allocator.create(ast.Node);
            owner.* = body;
            if (body_node.?.binded != null) {
                body_node.?.binded.?.owner = owner;
            } else {
                body_node.?.binded = try self.transpile_proc.allocator.create(ast.BindedNode);
                body_node.?.binded.?.owner = owner;
                body_node.?.binded.?.function = null;
            }
        } else {
            if (body_node.?.binded != null) {
                body_node.?.binded.?.owner = null;
            }
        }
        self.parser_current_body = body_node.?;
        try self.expect_sym('{');
        var last_stmt_type: ?ast.NodeType = null;
        while (!try self.next_token_is_symbol('}')) {
            var hist_down = history.History.down(self.transpile_proc.allocator, hist, hist.flags);
            defer hist_down.deinit();
            try self.parse_statement(&hist_down);
            const stmt_node = self.node_pop();
            const stmt = try self.transpile_proc.allocator.create(ast.Node);
            stmt.* = stmt_node.?;
            if (stmt.type == .StatementElseIf) {
                if (last_stmt_type == null or (last_stmt_type != .StatementIf and last_stmt_type != .StatementElseIf)) {
                    self.transpile_proc.err("invalid 'elif' statement position", .{});
                }
            } else if (stmt.type == .StatementElse) {
                if (last_stmt_type == null or (last_stmt_type != .StatementIf and last_stmt_type != .StatementElseIf)) {
                    self.transpile_proc.err("invalid 'else' statement position", .{});
                }
            }
            last_stmt_type = stmt.type;
            try stmts.push(stmt);
        }
        try self.expect_sym('}');
        if (body_node.?.binded != null) {
            if (body_node.?.binded.?.owner) |owner| {
                self.parser_current_body = owner.*;
            }
        }
        body_node.?.node_variant = .{ .body = .{ .statements = stmts } };
        try self.transpile_proc.nodes.push(body_node.?);
    }

    /// Parses a body.
    ///
    /// This function parses multiple statements within a body by delegating to
    /// `parse_body_multiple_statements`.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    fn parse_body(self: *Self, hist: *history.History) anyerror!void {
        _ = try self.transpile_proc.new_scope();
        try self.parse_body_multiple_statements(hist);
        self.transpile_proc.finish_scope();
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
            var hist = history.History.init(self.transpile_proc.allocator, .{ .is_global_scope = true });
            try self.parse_body(&hist);
            const body_node = self.node_pop();
            try self.transpile_proc.nodes.push(body_node.?);
        }
        self.transpile_proc.err("invalid symbol", .{});
    }

    /// Checks if the next token is an operator.
    ///
    /// This function peeks at the next token and checks if it matches the specified
    /// operator. It returns `true` if the next token is the expected operator, `false` otherwise.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `op`: The operator as a byte slice.
    ///
    /// Returns:
    /// - `bool`: `true` if the next token is the expected operator, `false` otherwise.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    fn next_token_is_operator(self: *Self, op: []const u8) !bool {
        const t = try self.token_peek_next();
        return token.is_operator(t, op);
    }

    /// Checks if the next token is a keyword.
    ///
    /// This function peeks at the next token and checks if it matches the specified
    /// keyword. It returns `true` if the next token is the expected keyword, `false` otherwise.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `keyword`: The keyword as a byte slice.
    ///
    /// Returns:
    /// - `bool`: `true` if the next token is the expected keyword, `false` otherwise.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    fn next_token_is_keyword(self: *Self, keyword: []const u8) !bool {
        const t = try self.token_peek_next();
        return token.is_keyword(t, keyword);
    }

    /// Gets the pointer depth.
    ///
    /// This function checks the next tokens to determine the depth of pointers (`*`),
    /// incrementing the depth for each pointer token found. It returns the total pointer depth.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Returns:
    /// - `usize`: The total depth of pointers.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    fn parse_get_pointer_depth(self: *Self) !usize {
        var depth: u8 = 0;
        while (try self.next_token_is_operator("*")) {
            depth += 1;
            _ = try self.token_next();
        }
        return depth;
    }

    /// Parses a datatype.
    ///
    /// This function expects a datatype keyword and retrieves its pointer depth,
    /// type, and type string. If the datatype is unknown, it logs an error message.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `dt`: A pointer to the datatype being parsed.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    /// - Logs an error message if the next token is not a datatype keyword.
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
        dt.*.type_str = try std.ArrayList(u8).initCapacity(self.transpile_proc.allocator, dt_token.?.data.sval.items.len);
        try dt.*.type_str.appendSlice(dt_token.?.data.sval.items);
    }

    /// Parses a single token to a node.
    ///
    /// This function processes a single token, such as a number, identifier, string,
    /// or boolean, and converts it to the corresponding AST node. If the token is not
    /// of an expected type, it logs an error message.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Returns:
    /// - `bool`: `true` if a single token was successfully parsed, `false` otherwise.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    /// - Logs an error message if the next token is not of an expected type.
    fn parse_single_token_to_node(self: *Self) !bool {
        const t = try self.token_next();
        switch (t.?.type) {
            .Number => {
                var number_node = ast.Node{
                    .type = .Number,
                    .pos = self.*.transpile_proc.*.pos,
                    .data = .{ .llnum = t.?.data.llnum },
                };
                try self.create_node(&number_node);
            },
            .Identifier => {
                var ident_node = ast.Node{
                    .type = .Identifier,
                    .pos = self.*.transpile_proc.*.pos,
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
                    .pos = self.*.transpile_proc.*.pos,
                    .data = .{ .bval = t.?.data.bval },
                };
                try self.create_node(&bool_node);
            },
            else => self.transpile_proc.err("expected single token, got '{?}'", .{t.?.type}),
        }
        return true;
    }

    /// Parses additional expressions.
    ///
    /// This function checks if the next token is an operator and, if so,
    /// processes it as part of an additional expression.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    fn parse_additional_expression(self: *Self) !void {
        const t = try self.token_peek_next();
        if (t.?.type == .Operator) {
            var hist = history.History.init(self.transpile_proc.allocator, .{});
            defer hist.deinit();
            try self.parse_expressionable(&hist);
        }
    }

    /// Parses a parenthesis expression.
    ///
    /// This function expects a parenthesis expression, including handling
    /// of left nodes, expressionable roots, and proper closing of the parenthesis.
    /// It adds the resulting parenthesis expression node to the list of nodes
    /// to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
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
        const exp = try self.transpile_proc.allocator.create(ast.Node);
        exp.* = exp_node;
        if (exp_node.type == .Expression) {
            exp.*.node_variant.?.exp.left = try self.transpile_proc.allocator.create(ast.Node);
            exp.*.node_variant.?.exp.left.?.* = exp_node.node_variant.?.exp.left.?.*;
            exp.*.node_variant.?.exp.right = try self.transpile_proc.allocator.create(ast.Node);
            exp.*.node_variant.?.exp.right.?.* = exp_node.node_variant.?.exp.right.?.*;
            exp.*.node_variant.?.exp.op = exp_node.node_variant.?.exp.op;
        }
        try self.transpile_proc.nodes.push(ast.Node{
            .type = .ExpressionParenthesis,
            .pos = self.*.transpile_proc.*.pos,
            .node_variant = .{ .paren = .{ .exp = exp } },
        });
        if (left_node != null) {
            const parenthesis_node = self.node_pop();
            const left = try self.transpile_proc.allocator.create(ast.Node);
            left.* = left_node.?;
            const right = try self.transpile_proc.allocator.create(ast.Node);
            right.* = parenthesis_node.?;
            try self.transpile_proc.nodes.push(ast.Node{
                .type = .Expression,
                .pos = self.*.transpile_proc.*.pos,
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

    /// Parses a comma-separated expression.
    ///
    /// This function processes a comma-separated expression, creating and adding
    /// the resulting expression node to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    fn parse_for_comma(self: *Self, hist: *history.History) !void {
        _ = try self.token_next(); // skip ,
        const left_node = self.node_pop();
        try self.parse_expressionable_root(hist);
        const right_node = self.node_pop();
        const left = try self.transpile_proc.allocator.create(ast.Node);
        left.* = left_node.?;
        const right = try self.transpile_proc.allocator.create(ast.Node);
        right.* = right_node.?;
        try self.transpile_proc.nodes.push(ast.Node{
            .type = .Expression,
            .pos = self.*.transpile_proc.*.pos,
            .node_variant = .{
                .exp = .{
                    .left = left,
                    .right = right,
                    .op = ",",
                },
            },
        });
    }

    /// Parses a bracket expression.
    ///
    /// This function expects a bracket expression, including handling of left nodes,
    /// expressionable roots, and proper closing of the bracket. It adds the resulting
    /// bracket expression node to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_for_bracket(self: *Self, hist: *history.History) !void {
        const left_node = self.transpile_proc.nodes.back();
        if (left_node != null) {
            _ = self.node_pop();
        }
        try self.expect_op("[");
        try self.parse_expressionable_root(hist);
        try self.expect_sym(']');
        const exp_node = self.node_pop();
        const inner = try self.transpile_proc.allocator.create(ast.Node);
        inner.* = exp_node.?;
        if (exp_node.?.type == .Expression) {
            inner.*.node_variant.?.exp.left = try self.transpile_proc.allocator.create(ast.Node);
            inner.*.node_variant.?.exp.left.?.* = exp_node.?.node_variant.?.exp.left.?.*;
            inner.*.node_variant.?.exp.right = try self.transpile_proc.allocator.create(ast.Node);
            inner.*.node_variant.?.exp.right.?.* = exp_node.?.node_variant.?.exp.right.?.*;
            inner.*.node_variant.?.exp.op = exp_node.?.node_variant.?.exp.op;
        }
        try self.transpile_proc.nodes.push(ast.Node{
            .type = .Bracket,
            .pos = self.*.transpile_proc.*.pos,
            .node_variant = .{ .bracket = .{ .inner = inner } },
        });
        if (left_node != null) {
            const bracket_node = self.node_pop();
            const left = try self.transpile_proc.allocator.create(ast.Node);
            left.* = left_node.?;
            const right = try self.transpile_proc.allocator.create(ast.Node);
            right.* = bracket_node.?;
            try self.transpile_proc.nodes.push(ast.Node{
                .type = .Expression,
                .pos = self.*.transpile_proc.*.pos,
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

    /// Peeks at the expressionable node on top of the stack.
    ///
    /// This function returns the node on top of the stack if it is expressionable,
    /// or `null` otherwise.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Returns:
    /// - `?ast.Node`: The expressionable node on top of the stack, or `null` if not found.
    ///
    /// Errors:
    /// - Returns an error if accessing the node stack fails.
    fn node_peek_expressionable_or_null(self: *Self) !?ast.Node {
        const n = self.transpile_proc.nodes.back();
        return if (n != null and ast.node_is_expressionable(n.?)) n.? else null;
    }

    /// Parses an indirection unary expression.
    ///
    /// This function processes an indirection unary expression by retrieving the
    /// pointer depth and creating the corresponding unary node with the operand.
    /// It adds the resulting unary node to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_for_indirection_unary(self: *Self) !void {
        const depth = try self.parse_get_pointer_depth();
        var hist = history.History.init(self.transpile_proc.allocator, .{ .expression_is_unary = true });
        defer hist.deinit();
        try self.parse_expressionable(&hist);
        const unary_operand_node = self.node_pop();
        const operand = try self.transpile_proc.allocator.create(ast.Node);
        operand.* = unary_operand_node.?;
        try self.transpile_proc.nodes.push(ast.Node{
            .type = .Unary,
            .pos = self.*.transpile_proc.*.pos,
            .node_variant = .{
                .unary = .{
                    .op = "*",
                    .operand = operand,
                },
            },
        });
        var unary_node = self.node_pop();
        unary_node.?.node_variant.?.unary.indirection = .{ .depth = depth };
        try self.transpile_proc.nodes.push(unary_node.?);
    }

    /// Parses a normal unary expression.
    ///
    /// This function processes a normal unary expression, creating the corresponding
    /// unary node with the operand and adding it to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_for_normal_unary(self: *Self) !void {
        const unary_op = (try self.token_next()).?.data.sval.items;
        var hist = history.History.init(self.transpile_proc.allocator, .{ .expression_is_unary = true });
        defer hist.deinit();
        try self.parse_expressionable(&hist);
        const unary_operand_node = self.node_pop();
        const operand = try self.transpile_proc.allocator.create(ast.Node);
        operand.* = unary_operand_node.?;
        try self.transpile_proc.nodes.push(ast.Node{
            .type = .Unary,
            .pos = self.*.transpile_proc.*.pos,
            .node_variant = .{
                .unary = .{
                    .op = unary_op,
                    .operand = operand,
                },
            },
        });
    }

    /// Parses a unary expression.
    ///
    /// This function processes a unary expression, determining if it is an indirection
    /// or normal unary expression, and then parsing it accordingly. It also handles
    /// additional expressions if present.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
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

    /// Parses a left-operanded unary expression.
    ///
    /// This function processes a left-operanded unary expression, creating the
    /// corresponding unary node with the left operand and operator, and adding
    /// it to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `node_left`: A pointer to the left operand node.
    /// - `unary_op`: The unary operator as a byte slice.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    fn parse_for_left_operanded_unary(self: *Self, node_left: *ast.Node, unary_op: []const u8) !void {
        try self.transpile_proc.nodes.push(ast.Node{
            .type = .Unary,
            .pos = self.*.transpile_proc.*.pos,
            .node_variant = .{
                .unary = .{
                    .op = unary_op,
                    .operand = node_left,
                    .is_left_operanded_unary = true,
                },
            },
        });
    }

    /// Creates an expression node.
    ///
    /// This function creates an expression node with the given left and right nodes
    /// and the specified operator. It then adds the expression node to the list of
    /// nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `left_node`: A pointer to the left node of the expression.
    /// - `right_node`: A pointer to the right node of the expression.
    /// - `op`: The operator as a byte slice.
    ///
    /// Errors:
    /// - Returns an error if creating the node fails.
    fn make_expression_node(self: *Self, left_node: *ast.Node, right_node: *ast.Node, op: []const u8) !void {
        const exp_node = try self.transpile_proc.allocator.create(ast.Node);
        defer self.transpile_proc.allocator.destroy(exp_node);
        const left = try self.transpile_proc.allocator.create(ast.Node);
        left.* = left_node.*;
        const right = try self.transpile_proc.allocator.create(ast.Node);
        right.* = right_node.*;
        exp_node.* = ast.Node{
            .type = .Expression,
            .pos = self.*.transpile_proc.*.pos,
            .node_variant = .{
                .exp = .{
                    .left = left,
                    .right = right,
                    .op = op,
                },
            },
        };
        try self.create_node(exp_node);
    }

    /// Creates a body node.
    ///
    /// This function creates a body node with the given statements and adds it
    /// to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Errors:
    /// - Returns an error if creating the node fails.
    fn make_body_node(self: *Self) !void {
        const body_node = try self.transpile_proc.allocator.create(ast.Node);
        defer self.transpile_proc.allocator.destroy(body_node);
        body_node.* = ast.Node{
            .type = .Body,
            .pos = self.*.transpile_proc.*.pos,
        };
        try self.create_node(body_node);
    }

    /// Gets the precedence for an operator.
    ///
    /// This function iterates through the operator precedence groups to find
    /// the precedence level of the given operator. It also sets the provided group
    /// pointer to the matching group.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `op`: The operator as a byte slice.
    /// - `group`: A pointer to the optional precedence group.
    ///
    /// Returns:
    /// - `i8`: The precedence level of the operator, or -1 if not found.
    fn parse_get_precedence_for_operator(_: *Self, op: []const u8, group: *?expressionable.OpPrecedenceGroup) i8 {
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

    /// Checks if the left operator has priority over the right operator.
    ///
    /// This function determines if the left operator has higher or equal precedence
    /// compared to the right operator, taking into account associativity.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `op_left`: The left operator as a byte slice.
    /// - `op_right`: The right operator as a byte slice.
    ///
    /// Returns:
    /// - `bool`: `true` if the left operator has priority, `false` otherwise.
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

    /// Shifts the children of an expression node to the left.
    ///
    /// This function rearranges the children of the given expression node,
    /// shifting them to the left to maintain proper precedence order.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `node`: A pointer to the expression node.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    fn parse_node_shift_children_left(self: *Self, node: *ast.Node) !void {
        const right_op = node.*.node_variant.?.exp.right.?.*.node_variant.?.exp.op;
        var new_exp_left_node = node.*.node_variant.?.exp.left.?.*;
        var new_exp_right_node = node.*.node_variant.?.exp.right.?.*.node_variant.?.exp.left.?.*;
        try self.make_expression_node(&new_exp_left_node, &new_exp_right_node, node.*.node_variant.?.exp.op);
        const new_left_operand = self.node_pop();
        const new_right_operand = node.*.node_variant.?.exp.right.?.*.node_variant.?.exp.right.?.*;
        const left = try self.transpile_proc.allocator.create(ast.Node);
        left.* = new_left_operand.?;
        const right = try self.transpile_proc.allocator.create(ast.Node);
        right.* = new_right_operand;
        node.*.node_variant.?.exp.left = left;
        node.*.node_variant.?.exp.right = right;
        node.*.node_variant.?.exp.op = right_op;
    }

    /// Moves the right-left child of an expression node to the left.
    ///
    /// This function rearranges the children of the given expression node,
    /// moving the right-left child to the left to maintain proper precedence order.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `node`: A pointer to the expression node.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    fn parse_node_move_right_left_to_left(self: *Self, node: *ast.Node) !void {
        try self.make_expression_node(
            node.*.node_variant.?.exp.left.?,
            node.*.node_variant.?.exp.right.?.*.node_variant.?.exp.left.?,
            node.*.node_variant.?.exp.op,
        );
        const completed_node = self.node_pop();
        const new_op = node.*.node_variant.?.exp.right.?.*.node_variant.?.exp.op;
        const left = try self.transpile_proc.allocator.create(ast.Node);
        left.* = completed_node.?;
        const right = try self.transpile_proc.allocator.create(ast.Node);
        right.* = node.*.node_variant.?.exp.right.?.*.node_variant.?.exp.right.?.*;
        node.*.node_variant.?.exp.left = left;
        node.*.node_variant.?.exp.right = right;
        node.*.node_variant.?.exp.op = new_op;
    }

    /// Reorders an expression node for proper precedence.
    ///
    /// This function recursively reorders the children of the given expression node
    /// to maintain proper operator precedence.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `node`: A pointer to the expression node.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
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

    /// Parses a normal expression.
    ///
    /// This function parses a normal expression by handling operators,
    /// expressionable tokens, and rearranging nodes as needed to maintain
    /// proper precedence.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
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
                var hist_down = history.History.down(self.transpile_proc.allocator, hist, hist.flags);
                defer hist_down.deinit();
                hist_down.flags.parenthesis_not_function_call = true;
                try self.parse_for_parenthesis(&hist_down);
            } else if (misc.is_unary_operator(t.?.data.sval.items)) {
                try self.parse_for_unary();
            } else {
                self.transpile_proc.err("expected expressionable for '{s}' operator", .{op});
            }
        } else {
            var hist_down = history.History.down(self.transpile_proc.allocator, hist, hist.flags);
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

    /// Parses an expression.
    ///
    /// This function parses an expression, handling different types of tokens
    /// such as parenthesis, commas, brackets, and operators. It rearranges nodes
    /// as needed to maintain proper precedence.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Returns:
    /// - `bool`: `true` if an expression was successfully parsed, `false` otherwise.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
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

    /// Parses an identifier token.
    ///
    /// This function peeks at the next token and checks if it is an identifier.
    /// If it is not an identifier, it logs an error message. It then parses the token
    /// to a node if it is valid.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    /// - Logs an error message if the next token is not an identifier.
    fn parse_identifier(self: *Self) !bool {
        const t = try self.token_peek_next();
        if (t != null and t.?.type != .Identifier) {
            self.transpile_proc.err("expected identifier, got '{?}'", .{t.?.type});
        }
        return try self.parse_single_token_to_node();
    }

    /// Parses a string token.
    ///
    /// This function peeks at the next token and checks if it is a string.
    /// If it is not a string, it logs an error message. It then parses the token
    /// to a node if it is valid.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    /// - Logs an error message if the next token is not a string.
    fn parse_string(self: *Self) !bool {
        const t = try self.token_peek_next();
        if (t != null and t.?.type != .String) {
            self.transpile_proc.err("expected string, got '{?}'", .{t.?.type});
        }
        return try self.parse_single_token_to_node();
    }

    /// Parses a single expressionable token.
    ///
    /// This function peeks at the next token and attempts to parse it if it is
    /// a number, boolean, operator, identifier, keyword, or string. It handles
    /// specific cases within a fit statement.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Returns:
    /// - `bool`: `true` if a token was successfully parsed, `false` otherwise.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    /// - Logs an error message if any expected token is not found.
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

    /// Parses multiple expressionable tokens.
    ///
    /// This function continues to parse tokens until no more expressionable tokens
    /// are found.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    fn parse_expressionable(self: *Self, hist: *history.History) anyerror!void {
        while (try self.parse_expressionable_single(hist)) {}
    }

    /// Parses the root of an expressionable token.
    ///
    /// This function parses expressionable tokens and adds the resulting node
    /// to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    fn parse_expressionable_root(self: *Self, hist: *history.History) anyerror!void {
        try self.parse_expressionable(hist);
        const n = self.node_pop();
        try self.transpile_proc.nodes.push(n.?);
    }

    /// Parses array brackets.
    ///
    /// This function processes array bracket tokens, updating the datatype with
    /// array information and adding bracket nodes to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `dt`: A pointer to the datatype being parsed.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_array_brackets(self: *Self, dt: *dtype.DataType, hist: *history.History) !void {
        var brackets = misc.Vector(ast.Node).init(self.transpile_proc.allocator);
        while (try self.next_token_is_operator("[")) {
            try self.expect_op("[");
            dt.*.flags.?.is_array = true;
            if (try self.next_token_is_symbol(']')) {
                try self.expect_sym(']');
                break;
            }
            try self.parse_expressionable_root(hist);
            try self.expect_sym(']');
            const exp_node = self.node_pop();
            const exp = try self.transpile_proc.allocator.create(ast.Node);
            exp.* = exp_node.?;
            if (exp_node.?.type == .Expression) {
                exp.*.node_variant.?.exp.left = try self.transpile_proc.allocator.create(ast.Node);
                exp.*.node_variant.?.exp.left.?.* = exp_node.?.node_variant.?.exp.left.?.*;
                exp.*.node_variant.?.exp.right = try self.transpile_proc.allocator.create(ast.Node);
                exp.*.node_variant.?.exp.right.?.* = exp_node.?.node_variant.?.exp.right.?.*;
                exp.*.node_variant.?.exp.op = exp_node.?.node_variant.?.exp.op;
            }
            try self.transpile_proc.nodes.push(ast.Node{
                .type = .Bracket,
                .pos = self.transpile_proc.*.pos,
                .node_variant = .{ .bracket = .{ .inner = exp } },
            });
            const bracket_node = self.node_pop();
            try brackets.push(bracket_node.?);
        }
        if (brackets.count > 0) {
            dt.*.array = .{ .brackets = brackets };
        }
    }

    /// Parses a variable declaration.
    ///
    /// This function processes variable declaration tokens, including array brackets
    /// and assignment. It adds the variable node to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `dt`: A pointer to the datatype being parsed.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_variable(self: *Self, dt: *dtype.DataType, hist: *history.History) !void {
        if (try self.next_token_is_operator("[")) {
            try self.parse_array_brackets(dt, hist);
        }
        const ident_token = try self.token_next();
        if (ident_token == null or ident_token.?.type != .Identifier) {
            self.transpile_proc.err("expected indentifier", .{});
        }
        var value_node: ?ast.Node = null;
        const has_value = try self.next_token_is_operator("=");
        if (has_value) {
            _ = try self.token_next(); // skip =
            try self.parse_expressionable_root(hist);
            value_node = self.node_pop();
            const val = try self.transpile_proc.allocator.create(ast.Node);
            val.* = value_node.?;
            if (value_node.?.type == .Expression) {
                val.*.node_variant.?.exp.left = try self.transpile_proc.allocator.create(ast.Node);
                val.*.node_variant.?.exp.left.?.* = value_node.?.node_variant.?.exp.left.?.*;
                val.*.node_variant.?.exp.right = try self.transpile_proc.allocator.create(ast.Node);
                val.*.node_variant.?.exp.right.?.* = value_node.?.node_variant.?.exp.right.?.*;
                val.*.node_variant.?.exp.op = value_node.?.node_variant.?.exp.op;
            }
            var node = ast.Node{
                .type = .Variable,
                .pos = self.*.transpile_proc.*.pos,
                .node_variant = .{
                    .variable = .{
                        .name = ident_token.?.data.sval,
                        .type = dt,
                        .val = val,
                    },
                },
            };
            const scope_entity = try self.new_scope_entity(&node, .{});
            try self.transpile_proc.push_scope_entity(scope_entity);
            try self.transpile_proc.nodes.push(node);
        } else {
            var node = ast.Node{
                .type = .Variable,
                .pos = self.*.transpile_proc.*.pos,
                .node_variant = .{
                    .variable = .{
                        .name = ident_token.?.data.sval,
                        .type = dt,
                    },
                },
            };
            const scope_entity = try self.new_scope_entity(&node, .{});
            try self.transpile_proc.push_scope_entity(scope_entity);
            try self.transpile_proc.nodes.push(node);
        }
    }

    /// Parses a full variable declaration.
    ///
    /// This function processes the datatype and the variable declaration,
    /// adding the variable node to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    fn parse_full_variable(self: *Self, hist: *history.History) !void {
        const dt = try self.transpile_proc.allocator.create(dtype.DataType);
        dt.* = dtype.DataType{
            .array = null,
            .pointer_depth = 0,
            .type = .Unknown,
            .type_str = std.ArrayList(u8).init(self.transpile_proc.allocator),
            .flags = .{},
        };
        try self.parse_datatype(dt);
        try self.parse_variable(dt, hist);
    }

    /// Parses function arguments.
    ///
    /// This function processes tokens representing function arguments,
    /// including handling of variadic arguments, and returns a vector of argument nodes.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Returns:
    /// - `misc.Vector(*ast.Node)`: A vector of argument nodes.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    fn parse_function_args(self: *Self, hist: *history.History) !misc.Vector(*ast.Node) {
        _ = try self.transpile_proc.new_scope();
        var args = misc.Vector(*ast.Node).init(self.transpile_proc.allocator);
        while (!try self.next_token_is_symbol(')')) {
            if (try self.next_token_is_operator(".")) { // variadic
                for (0..3) |_| {
                    try self.expect_op(".");
                }
                self.transpile_proc.finish_scope();
                return args;
            }
            try self.parse_full_variable(hist);
            const arg_node = self.node_pop();
            const arg = try self.transpile_proc.allocator.create(ast.Node);
            arg.* = arg_node.?;
            try args.push(arg);
            if (!try self.next_token_is_operator(",")) {
                break;
            }
            _ = try self.token_next(); // skip ,
        }
        self.transpile_proc.finish_scope();
        return args;
    }

    /// Parses a function declaration.
    ///
    /// This function expects the 'fun' keyword, followed by the function's name, arguments,
    /// return type, and body. It creates a function node and adds it to the list of nodes
    /// to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_function(self: *Self) !void {
        _ = try self.transpile_proc.new_scope();
        _ = try self.token_next(); // skip fun
        var function_node = ast.Node{
            .type = .Function,
            .pos = self.*.transpile_proc.*.pos,
            .node_variant = .{ .function = .{} },
        };
        var dt: dtype.DataType = undefined;
        const ident_token = try self.token_next();
        if (ident_token.?.type != .Identifier) {
            self.transpile_proc.err("expected indentifier, got '{}'", .{ident_token.?.type});
        }
        function_node.node_variant.?.function.name = ident_token.?.data.sval;
        self.parser_current_function = function_node;
        try self.expect_op("(");
        var hist_args = history.History.init(self.transpile_proc.allocator, .{});
        defer hist_args.deinit();
        const args = try self.parse_function_args(&hist_args);
        try self.expect_sym(')');
        function_node.node_variant.?.function.args = args;
        const rtype_token = try self.token_peek_next();
        if (rtype_token != null and rtype_token.?.type == .Keyword and misc.keyword_is_datatype(rtype_token.?.data.sval.items)) {
            try self.parse_datatype(&dt);
        } else {
            var type_str = std.ArrayList(u8).init(self.transpile_proc.allocator);
            try type_str.appendSlice("void");
            dt = dtype.DataType{
                .type = .Void,
                .type_str = type_str,
            };
        }
        function_node.node_variant.?.function.rtype = dt;
        if (try self.next_token_is_symbol('{')) {
            var hist_body = history.History.init(self.transpile_proc.allocator, .{ .inside_function_body = true });
            defer hist_body.deinit();
            try self.parse_body(&hist_body);
            const body_node = self.node_pop();
            const body = try self.transpile_proc.allocator.create(ast.Node);
            body.* = body_node.?;
            function_node.node_variant.?.function.body = body;
        } else {
            try self.expect_sym(';');
        }
        self.parser_current_function = null;
        try self.transpile_proc.nodes.push(function_node);
        self.transpile_proc.finish_scope();
    }

    /// Parses a return statement.
    ///
    /// This function expects the 'ret' keyword, followed by an optional expression, and a semicolon.
    /// It creates a return statement node and adds it to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_return(self: *Self, hist: *history.History) !void {
        _ = try self.token_next(); // skip ret
        if (try self.next_token_is_symbol(';')) {
            try self.expect_sym(';');
            try self.transpile_proc.nodes.push(ast.Node{
                .type = .StatementReturn,
                .pos = self.*.transpile_proc.*.pos,
            });
            return;
        }
        try self.parse_expressionable_root(hist);
        const exp_node = self.node_pop();
        const exp = try self.transpile_proc.allocator.create(ast.Node);
        exp.* = exp_node.?;
        if (exp.*.type == .Expression) {
            exp.*.node_variant.?.exp.left = try self.transpile_proc.allocator.create(ast.Node);
            exp.*.node_variant.?.exp.left.?.* = exp_node.?.node_variant.?.exp.left.?.*;
            exp.*.node_variant.?.exp.right = try self.transpile_proc.allocator.create(ast.Node);
            exp.*.node_variant.?.exp.right.?.* = exp_node.?.node_variant.?.exp.right.?.*;
            exp.*.node_variant.?.exp.op = exp_node.?.node_variant.?.exp.op;
        }
        try self.transpile_proc.nodes.push(ast.Node{
            .type = .StatementReturn,
            .pos = self.*.transpile_proc.*.pos,
            .node_variant = .{ .statement = .{ .return_stmt = exp } },
        });
        try self.expect_sym(';');
    }

    /// Parses an elif statement.
    ///
    /// This function expects the 'elif' keyword, followed by a condition expression and a body.
    /// It creates an elif statement node and adds it to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_elif_statement(self: *Self, hist: *history.History) !void {
        if (try self.next_token_is_keyword("elif")) {
            if (self.parser_current_function == null) {
                self.transpile_proc.err("elif statement outside of function", .{});
            }
            _ = try self.token_next(); // skip elif
            try self.parse_expressionable_root(hist);
            const condition_node = self.node_pop();
            const condition = try self.transpile_proc.allocator.create(ast.Node);
            condition.* = condition_node.?;
            if (condition_node.?.type == .Expression) {
                condition.*.node_variant.?.exp.left = try self.transpile_proc.allocator.create(ast.Node);
                condition.*.node_variant.?.exp.left.?.* = condition_node.?.node_variant.?.exp.left.?.*;
                condition.*.node_variant.?.exp.right = try self.transpile_proc.allocator.create(ast.Node);
                condition.*.node_variant.?.exp.right.?.* = condition_node.?.node_variant.?.exp.right.?.*;
                condition.*.node_variant.?.exp.op = condition_node.?.node_variant.?.exp.op;
            }
            try self.parse_body(hist);
            const body_node = self.node_pop();
            const body = try self.transpile_proc.allocator.create(ast.Node);
            body.* = body_node.?;
            var elif_node = ast.Node{
                .type = .StatementElseIf,
                .pos = self.*.transpile_proc.*.pos,
                .node_variant = .{ .statement = .{ .elif_stmt = .{ .condition = condition, .body = body } } },
            };
            try self.create_node(&elif_node);
        }
    }

    /// Parses an else statement.
    ///
    /// This function expects the 'else' keyword followed by a body. It creates an else statement
    /// node and adds it to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_else_statement(self: *Self, hist: *history.History) !void {
        if (try self.next_token_is_keyword("else")) {
            if (self.parser_current_function == null) {
                self.transpile_proc.err("else statement outside of function", .{});
            }
            _ = try self.token_next(); // skip else
            try self.parse_body(hist);
            const body_node = self.node_pop();
            const body = try self.transpile_proc.allocator.create(ast.Node);
            body.* = body_node.?;
            var else_node = ast.Node{
                .type = .StatementElse,
                .pos = self.*.transpile_proc.*.pos,
                .node_variant = .{ .statement = .{ .else_stmt = .{ .body = body } } },
            };
            try self.create_node(&else_node);
        }
    }

    /// Parses an if statement.
    ///
    /// This function expects the 'if' keyword, followed by a condition expression, a body,
    /// and optionally elif and else clauses. It creates an if statement node and adds it to
    /// the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_if_statement(self: *Self, hist: *history.History) !void {
        try self.expect_keyword("if");
        if (self.parser_current_function == null) {
            self.transpile_proc.err("if statement outside of function", .{});
        }
        try self.parse_expressionable_root(hist);
        const condition_node = self.node_pop();
        const condition = try self.transpile_proc.allocator.create(ast.Node);
        condition.* = condition_node.?;
        if (condition_node.?.type == .Expression) {
            condition.*.node_variant.?.exp.left = try self.transpile_proc.allocator.create(ast.Node);
            condition.*.node_variant.?.exp.left.?.* = condition_node.?.node_variant.?.exp.left.?.*;
            condition.*.node_variant.?.exp.right = try self.transpile_proc.allocator.create(ast.Node);
            condition.*.node_variant.?.exp.right.?.* = condition_node.?.node_variant.?.exp.right.?.*;
            condition.*.node_variant.?.exp.op = condition_node.?.node_variant.?.exp.op;
        }
        try self.parse_body(hist);
        const body_node = self.node_pop();
        const body = try self.transpile_proc.allocator.create(ast.Node);
        body.* = body_node.?;
        const if_node = try self.transpile_proc.allocator.create(ast.Node);
        defer self.transpile_proc.allocator.destroy(if_node);
        if_node.* = ast.Node{
            .type = .StatementIf,
            .pos = self.transpile_proc.*.pos,
            .node_variant = .{
                .statement = .{
                    .if_stmt = .{ .condition = condition, .body = body },
                },
            },
        };
        try self.create_node(if_node);
    }

    /// Parses the body of a fit statement.
    ///
    /// This function expects the body of a fit statement, starting with '{' and ending with '}'.
    /// It processes each branch within the body and adds it to the fit_node.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `fit_node`: A pointer to the fit statement node.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_fit_body(self: *Self, fit_node: *ast.Node, hist: *history.History) !void {
        try self.expect_sym('{');
        fit_node.*.node_variant.?.statement.fit_stmt.branches = misc.Vector(ast.FitBranch).init(self.transpile_proc.allocator);
        while (!try self.next_token_is_symbol('}')) {
            var hist_down = history.History.down(self.transpile_proc.allocator, hist, hist.flags);
            defer hist_down.deinit();
            try self.parse_expressionable_root(&hist_down);
            const condition_node = self.node_pop();
            const condition = try self.transpile_proc.allocator.create(ast.Node);
            if (condition_node.?.type == .Identifier and mem.eql(u8, condition_node.?.data.?.sval.items, "_")) {
                // default case after should be the last branch
                try self.expect_op("->");
                try self.parse_body(&hist_down);
                const body_node = self.node_pop();
                const body = try self.transpile_proc.allocator.create(ast.Node);
                body.* = body_node.?;
                try fit_node.*.node_variant.?.statement.fit_stmt.branches.push(.{ .body = body, .condition = null });
                if (try self.next_token_is_operator(",")) {
                    _ = try self.token_next(); // skip ,
                }
                break;
            }
            condition.* = condition_node.?;
            if (condition_node.?.type == .Expression) {
                condition.*.node_variant.?.exp.left = try self.transpile_proc.allocator.create(ast.Node);
                condition.*.node_variant.?.exp.left.?.* = condition_node.?.node_variant.?.exp.left.?.*;
                condition.*.node_variant.?.exp.right = try self.transpile_proc.allocator.create(ast.Node);
                condition.*.node_variant.?.exp.right.?.* = condition_node.?.node_variant.?.exp.right.?.*;
                condition.*.node_variant.?.exp.op = condition_node.?.node_variant.?.exp.op;
            }
            try self.expect_op("->");
            try self.parse_body(&hist_down);
            const body_node = self.node_pop();
            const body = try self.transpile_proc.allocator.create(ast.Node);
            body.* = body_node.?;
            try fit_node.*.node_variant.?.statement.fit_stmt.branches.push(.{ .body = body, .condition = condition });
            if (try self.next_token_is_operator(",")) {
                _ = try self.token_next(); // skip ,
            }
        }
        try self.expect_sym('}');
    }

    /// Parses a fit statement.
    ///
    /// This function expects the 'fit' keyword followed by an expression and a body.
    /// It creates a new fit statement node and adds it to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_fit_statement(self: *Self, hist: *history.History) !void {
        var fit_node: ast.Node = .{
            .type = .StatementFit,
            .node_variant = .{
                .statement = .{ .fit_stmt = undefined },
            },
        };
        hist.*.flags.in_fit_statement = true;
        try self.expect_keyword("fit");
        var new_hist = history.History.init(self.transpile_proc.allocator, .{ .in_fit_statement = true });
        defer new_hist.deinit();
        try self.parse_expressionable_root(&new_hist);
        const condition_node = self.node_pop();
        const condition = try self.transpile_proc.allocator.create(ast.Node);
        condition.* = condition_node.?;
        if (condition_node.?.type == .Expression) {
            condition.*.node_variant.?.exp.left = try self.transpile_proc.allocator.create(ast.Node);
            condition.*.node_variant.?.exp.left.?.* = condition_node.?.node_variant.?.exp.left.?.*;
            condition.*.node_variant.?.exp.right = try self.transpile_proc.allocator.create(ast.Node);
            condition.*.node_variant.?.exp.right.?.* = condition_node.?.node_variant.?.exp.right.?.*;
            condition.*.node_variant.?.exp.op = condition_node.?.node_variant.?.exp.op;
        }
        fit_node.node_variant.?.statement.fit_stmt.exp = condition;
        try self.parse_fit_body(&fit_node, &new_hist);
        try self.transpile_proc.nodes.push(fit_node);
    }

    /// Parses an import statement.
    ///
    /// This function expects an import statement, retrieves the folder and file identifiers,
    /// and adds the import node to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_import(self: *Self) !void {
        _ = try self.token_next(); // skip imp
        const folder_token = try self.token_next();
        if (folder_token.?.type != .Identifier) {
            self.transpile_proc.err("expected folder identifier, got '{?}'", .{folder_token.?.type});
        }
        var import_name = std.ArrayList(u8).init(self.transpile_proc.allocator);
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
            .pos = self.*.transpile_proc.*.pos,
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
            const dt = try self.transpile_proc.allocator.create(dtype.DataType);
            dt.* = dtype.DataType{
                .array = null,
                .pointer_depth = 0,
                .type = .Unknown,
                .type_str = std.ArrayList(u8).init(self.transpile_proc.allocator),
                .flags = .{},
            };
            try self.parse_datatype(dt);
            try self.parse_variable(dt, hist);
            try self.expect_sym(';');
            return;
        }

        if (mem.eql(u8, "imp", sval)) {
            return try self.parse_import();
        } else if (mem.eql(u8, "fun", sval)) {
            return try self.parse_function();
        } else if (mem.eql(u8, "if", sval)) {
            return try self.parse_if_statement(hist);
        } else if (mem.eql(u8, "elif", sval)) {
            return try self.parse_elif_statement(hist);
        } else if (mem.eql(u8, "else", sval)) {
            return try self.parse_else_statement(hist);
        } else if (mem.eql(u8, "fit", sval)) {
            return try self.parse_fit_statement(hist);
        } else if (mem.eql(u8, "ret", sval)) {
            return try self.parse_return(hist);
        } else if (mem.eql(u8, "true", sval)) {
            try self.transpile_proc.nodes.push(ast.Node{
                .type = .Boolean,
                .pos = self.*.transpile_proc.*.pos,
                .node_variant = .{ .boolean = .{ .val = true } },
            });
            return;
        } else if (mem.eql(u8, "false", sval)) {
            try self.transpile_proc.nodes.push(ast.Node{
                .type = .Boolean,
                .pos = self.*.transpile_proc.*.pos,
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
            self.transpile_proc.allocator,
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
                var hist = history.History.init(self.transpile_proc.allocator, .{});
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
        _ = try self.transpile_proc.init_root_scope();
        defer self.transpile_proc.deinit_root_scope();
        while (try self.next()) {}
    }
};

test "ParseProcess parse_function" {
    const ifilepath = "ParseProcess_parse_function.fn";
    const ofilepath = "ParseProcess_parse_function.c";
    // Mock input file
    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        const input = "fun test() { ret; }";
        try file.writeAll(input);
    }

    const allocator = std.testing.allocator;
    var transpile_proc = try transpiler.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);

    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
    }

    try lex_proc.lex();
    try parse_proc.parse();
    const nodes = transpile_proc.nodes.items();
    try std.testing.expectEqual(1, nodes.len);
    try std.testing.expectEqual(nodes[0].type, .Function);
    try std.testing.expectEqualStrings("test", nodes[0].node_variant.?.function.name.?.items);

    // Delete test files
    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}

test "ParseProcess parse_return" {
    const ifilepath = "ParseProcess_parse_return.fn";
    const ofilepath = "ParseProcess_parse_return.c";
    // Mock input file
    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        const input = "ret 42;";
        try file.writeAll(input);
    }

    // const allocator = std.testing.allocator;
    const allocator = std.testing.allocator;
    var transpile_proc = try transpiler.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);

    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
    }

    try lex_proc.lex();
    try parse_proc.parse();
    const nodes = transpile_proc.nodes.items();
    try std.testing.expectEqual(1, nodes.len);
    try std.testing.expectEqual(nodes[0].type, .StatementReturn);

    // Delete test files
    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}

test "ParseProcess parse_expression" {
    const ifilepath = "ParseProcess_parse_expression.fn";
    const ofilepath = "ParseProcess_parse_expression.c";
    // Mock input file
    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        const input = "1 + 2 * 3";
        try file.writeAll(input);
    }

    // const allocator = std.testing.allocator;
    const allocator = std.testing.allocator;
    var transpile_proc = try transpiler.TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    var lex_proc = lexer.LexProcess.init(&transpile_proc);
    var parse_proc = ParseProcess.init(&transpile_proc);

    defer {
        lex_proc.deinit();
        transpile_proc.deinit();
    }

    try lex_proc.lex();
    try parse_proc.parse();
    const nodes = transpile_proc.nodes.items();
    try std.testing.expectEqual(1, nodes.len);
    try std.testing.expectEqual(nodes[0].type, .Expression);

    // Delete test files
    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}
