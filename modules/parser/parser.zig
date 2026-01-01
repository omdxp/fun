const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const codegen = @import("codegen");
const TranspileError = codegen.TranspileError;
const lexer = @import("lexer");
const LexError = lexer.LexError;
const token = lexer.token;
const ast = @import("ast");
const expressionable = ast.expressionable;
const utils = @import("utils");
const semantics = @import("semantics");
const dtype = semantics.dtype;
const scope = semantics.scope;
const symbol = semantics.symbol;

/// Errors that can occur during parsing process.
pub const ParseError = error{
    /// Error indicating an invalid symbol.
    InvalidSymbol,
    /// Error indicating an invalid keyword.
    InvalidKeyword,
    /// Error indicating an invalid datatype.
    InvalidDataType,
    /// Error indicating an invalid token.
    InvalidToken,
    /// Error indicating an invalid identifier.
    InvalidIdentifier,
    /// Error indicating an invalid operand.
    InvalidOperand,
    /// Error indicating an invalid statement.
    InvalidStatement,
    /// Error indicating an invalid string.
    InvalidString,
} || TranspileError || LexError;

/// Represents the parsing process in the transpiler.
///
/// This struct handles the parsing process within the transpiler, including
/// the associated transpilation process and methods for parsing.
pub const ParseProcess = struct {
    /// The transpilation process associated with the parsing process.
    transpile_proc: *codegen.TranspileProcess,
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
    pub fn init(transpile_proc: *codegen.TranspileProcess) Self {
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
    fn expect_sym(self: *Self, c: u8) ParseError!void {
        const t = self.token_next();
        if (t == null or t.?.type != .Symbol or t.?.data.cval != c) {
            self.transpile_proc.err("expected symbol '{c}'", .{c});
            return ParseError.InvalidSymbol;
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
    fn expect_op(self: *Self, op: []const u8) ParseError!void {
        const t = self.token_next();
        if (t == null or t.?.type != .Operator or !mem.eql(u8, op, t.?.data.sval.items)) {
            self.transpile_proc.err("expected operator '{s}'", .{op});
            return ParseError.InvalidOperator;
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
    fn expect_keyword(self: *Self, keyword: []const u8) ParseError!void {
        const t = self.token_next();
        if (t == null or t.?.type != .Keyword or !mem.eql(u8, keyword, t.?.data.sval.items)) {
            self.transpile_proc.err("expected keyword '{s}'", .{keyword});
            return ParseError.InvalidKeyword;
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
    fn create_node(self: *Self, n: *ast.Node) ParseError!void {
        var is_bound = false;
        var binded: ast.BindedNode = .{
            .owner = null,
            .function = null,
        };
        if (self.parser_current_body) |body| {
            if (body.binded != null) {
                const owner = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                    std.debug.print("Error creating node: {s}", .{@errorName(e)});
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(owner);
                owner.* = body;
                // Binded nodes are only used for context; avoid copying ownership-bearing fields.
                owner.*.binded = null;
                owner.*.data = null;
                owner.*.node_variant = null;
                binded.owner = owner;
                is_bound = true;
            }
        }
        if (self.parser_current_function) |func| {
            const function = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                std.debug.print("Error creating node: {s}", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(function);
            function.* = func;
            // Binded nodes are only used for context; avoid copying ownership-bearing fields.
            function.*.binded = null;
            function.*.data = null;
            function.*.node_variant = null;
            binded.function = function;
            is_bound = true;
        }
        if (is_bound) {
            const b = self.transpile_proc.allocator.create(ast.BindedNode) catch |e| {
                std.debug.print("Error creating node: {s}", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(b);
            b.*.function = binded.function;
            b.*.owner = binded.owner;
            n.binded = b;
        } else {
            n.binded = null;
        }
        self.transpile_proc.nodes.push(n.*) catch |e| {
            std.debug.print("Error adding node to list: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
    }

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
    fn new_scope_entity(self: *Self, node: *ast.Node, flags: scope.ScopeEntityFlags) ParseError!*scope.ScopeEntity {
        var entity = self.transpile_proc.allocator.create(scope.ScopeEntity) catch |e| {
            std.debug.print("Error creating scope entity: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(entity);
        entity.node = node;
        entity.flags = flags;
        entity.name = switch (node.type) {
            .Identifier => node.data.?.sval.items,
            .Function => node.data.?.sval.items,
            .Variable => node.node_variant.?.variable.name.items,
            else => "",
        };
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
    fn ignore_nl_or_comment(self: *Self, t: *?token.Token) void {
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
    fn token_peek_next(self: *Self) ?token.Token {
        var next_token = self.transpile_proc.tokens.peek_no_increment();
        self.ignore_nl_or_comment(&next_token);
        const peek_token = self.transpile_proc.tokens.peek_no_increment();
        self.transpile_proc.current_token = peek_token;
        return peek_token;
    }

    /// Peeks at the Nth next non-skippable token without incrementing.
    ///
    /// `n = 0` is equivalent to `token_peek_next()`.
    fn token_peek_n(self: *Self, n: usize) ?token.Token {
        var idx: isize = self.transpile_proc.tokens.pindex;
        var seen: usize = 0;
        while (true) {
            const t = self.transpile_proc.tokens.at(@intCast(idx)) orelse return null;
            if (!token.is_nl_or_comment_or_newline_separator(t)) {
                if (seen == n) return t;
                seen += 1;
            }
            idx += 1;
        }
    }

    /// Peeks the previous non-skippable token (relative to the most recently consumed token).
    fn token_peek_prev(self: *Self) ?token.Token {
        var idx: isize = @as(isize, @intCast(self.transpile_proc.tokens.pindex)) - 2;
        while (idx >= 0) : (idx -= 1) {
            const t = self.transpile_proc.tokens.at(@intCast(idx)) orelse return null;
            if (!token.is_nl_or_comment_or_newline_separator(t)) return t;
        }
        return null;
    }

    /// Retrieves the next token.
    ///
    /// This function peeks at the next token without incrementing the token stream's position.
    /// It ignores newline or comment tokens and updates the current position if a valid token is found.
    ///
    /// Returns:
    /// - `!?token.Token`: The next token, or `null` if there are no more tokens.
    fn token_next(self: *Self) ?token.Token {
        var next_token = self.transpile_proc.tokens.peek_no_increment();
        self.ignore_nl_or_comment(&next_token);
        if (next_token != null) {
            self.transpile_proc.pos = next_token.?.pos;
            self.parser_last_token = next_token.?;
        }
        next_token = self.transpile_proc.tokens.peek();
        self.transpile_proc.current_token = next_token;
        return next_token;
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
    fn next_token_is_symbol(self: *Self, c: u8) bool {
        const t = self.token_peek_next();
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
    fn parse_statement(self: *Self, hist: *utils.History) ParseError!void {
        var t = self.token_peek_next();
        if (t == null) {
            self.transpile_proc.err("unexpected end of file", .{});
            return ParseError.FileReadError;
        }
        if (t.?.type == .Keyword) {
            return try self.parse_keyword(hist);
        }

        // User-defined type variable declarations start with an identifier datatype, e.g.:
        // `Point p;`, `Point p = ...;`, `Point* p;`, `Point** p = ...;`
        // Detect `<Identifier> [* ...] <Identifier>` and parse it as a variable declaration.
        if (t.?.type == .Identifier) {
            var off: usize = 1;
            while (true) {
                const tn = self.token_peek_n(off);
                if (tn == null) break;
                if (tn.?.type == .Operator and mem.eql(u8, tn.?.data.sval.items, "*")) {
                    off += 1;
                    continue;
                }
                break;
            }

            const t1 = self.token_peek_n(off);
            if (t1 != null and t1.?.type == .Identifier) {
                const dt = self.transpile_proc.allocator.create(dtype.DataType) catch |e| {
                    std.debug.print("Error creating DataType: {}\n", .{e});
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(dt);
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
        }

        if (t.?.type == .Symbol and token.is_symbol(t, '{')) {
            return try self.parse_body(hist);
        }
        try self.parse_expressionable_root(hist);
        t = self.token_peek_next();
        if (t.?.type == .Symbol and t.?.data.cval != ';') {
            return try self.parse_symbol();
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
    fn parse_body_multiple_statements(self: *Self, hist: *utils.History) ParseError!void {
        var stmts = utils.Vector(*ast.Node).init(self.transpile_proc.allocator);
        try self.make_body_node();
        var body_node = self.node_pop();
        // `make_body_node()` already created a binded context for this body (via `create_node`).
        // Do not overwrite `binded.owner` here; doing so can orphan the previous owner allocation.
        if (self.parser_current_body) |body| {
            const has_owner = body_node.?.binded != null and body_node.?.binded.?.owner != null;
            if (!has_owner) {
                const owner = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                    std.debug.print("Error creating node: {s}", .{@errorName(e)});
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(owner);
                owner.* = body;
                // Binded nodes are only used for context; avoid copying ownership-bearing fields.
                owner.*.binded = null;
                owner.*.data = null;
                owner.*.node_variant = null;
                if (body_node.?.binded != null) {
                    body_node.?.binded.?.owner = owner;
                } else {
                    body_node.?.binded = self.transpile_proc.allocator.create(ast.BindedNode) catch |e| {
                        std.debug.print("Error creating node: {s}", .{@errorName(e)});
                        return ParseError.MemoryAllocationFailed;
                    };
                    errdefer self.transpile_proc.allocator.destroy(body_node.?.binded.?);
                    body_node.?.binded.?.owner = owner;
                    body_node.?.binded.?.function = null;
                }
            }
        } else if (body_node.?.binded != null) {
            body_node.?.binded.?.owner = null;
        }
        self.parser_current_body = body_node.?;

        const lbrace_token = self.token_peek_next();
        try self.expect_sym('{');
        body_node.?.pos = if (lbrace_token) |t| t.pos else body_node.?.pos;
        var last_stmt_type: ?ast.NodeType = null;
        while (true) {
            const next_non_skippable = self.token_peek_n(0);
            if (next_non_skippable == null) {
                self.transpile_proc.err("unexpected end of file (expected '}}' to close body)", .{});
                return ParseError.FileReadError;
            }
            if (token.is_symbol(next_non_skippable, '}')) break;

            var hist_down = utils.History.down(self.transpile_proc.allocator, hist, hist.flags);
            defer hist_down.deinit();
            try self.parse_statement(&hist_down);
            const stmt_node = self.node_pop();
            if (stmt_node.?.type == .Function) {
                self.transpile_proc.err("invalid function statement", .{});
                return ParseError.InvalidStatement;
            }
            const stmt = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                std.debug.print("Error creating node: {s}", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(stmt);
            stmt.* = stmt_node.?;
            if (stmt.type == .StatementElseIf) {
                if (last_stmt_type == null or (last_stmt_type != .StatementIf and last_stmt_type != .StatementElseIf)) {
                    self.transpile_proc.err("invalid 'elif' statement position", .{});
                    return ParseError.InvalidKeyword;
                }
            } else if (stmt.type == .StatementElse) {
                if (last_stmt_type == null or (last_stmt_type != .StatementIf and last_stmt_type != .StatementElseIf)) {
                    self.transpile_proc.err("invalid 'else' statement position", .{});
                    return ParseError.InvalidKeyword;
                }
            }
            last_stmt_type = stmt.type;
            stmts.push(stmt) catch |e| {
                std.debug.print("Error adding node to vector: {s}", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
        }
        try self.expect_sym('}');
        if (body_node.?.binded != null) {
            if (body_node.?.binded.?.owner) |owner| {
                self.parser_current_body = owner.*;
            }
        }
        body_node.?.node_variant = .{ .body = .{ .statements = stmts } };
        self.transpile_proc.nodes.push(body_node.?) catch |e| {
            std.debug.print("Error adding node to list: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
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
    fn parse_body(self: *Self, hist: *utils.History) ParseError!void {
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
    fn parse_symbol(self: *Self) ParseError!void {
        if (self.next_token_is_symbol('{')) {
            var hist = utils.History.init(self.transpile_proc.allocator, .{ .is_global_scope = true });
            try self.parse_body(&hist);
            const body_node = self.node_pop();
            self.transpile_proc.nodes.push(body_node.?) catch |e| {
                std.debug.print("Error adding node to list: {s}", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            return;
        }
        self.transpile_proc.err("invalid symbol", .{});
        return ParseError.InvalidSymbol;
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
    fn next_token_is_operator(self: *Self, op: []const u8) bool {
        const t = self.token_peek_next();
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
    fn next_token_is_keyword(self: *Self, keyword: []const u8) bool {
        const t = self.token_peek_next();
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
    fn parse_get_pointer_depth(self: *Self) usize {
        var depth: u8 = 0;
        while (self.next_token_is_operator("*")) {
            depth += 1;
            _ = self.token_next();
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
    fn parse_datatype(self: *Self, dt: *dtype.DataType) ParseError!void {
        const dt_token = self.token_next();
        if (dt_token == null or (dt_token.?.type != .Keyword and dt_token.?.type != .Identifier)) {
            self.transpile_proc.err("expected datatype, got '{?}'", .{if (dt_token) |t| t.type else null});
            return ParseError.InvalidDataType;
        }
        const ptr_depth = self.parse_get_pointer_depth();
        if (ptr_depth > 0) {
            dt.*.flags.?.is_pointer = true;
            dt.*.pointer_depth = ptr_depth;
        }
        // Builtins use `dt.type`, user-defined types keep `.Unknown` and rely on `type_str`.
        if (dt_token.?.type == .Keyword and utils.keyword_is_datatype(dt_token.?.data.sval.items)) {
            dt.*.type = utils.get_datatype_type(dt_token.?.data.sval.items);
            if (dt.*.type.? == .Unknown) {
                self.transpile_proc.err("unknown datatype", .{});
                return ParseError.InvalidDataType;
            }
        } else {
            dt.*.type = .Unknown;
        }
        dt.*.type_str = std.ArrayList(u8).initCapacity(self.transpile_proc.allocator, dt_token.?.data.sval.items.len) catch |e| {
            std.debug.print("Error creating type string: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        dt.*.type_str.appendSlice(dt_token.?.data.sval.items) catch |e| {
            std.debug.print("Error appending to type string: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
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
    fn parse_single_token_to_node(self: *Self) ParseError!bool {
        const t = self.token_next();
        switch (t.?.type) {
            .Number => {
                switch (t.?.data) {
                    .llnum => |n| {
                        var number_node = ast.Node{
                            .type = .Number,
                            .pos = t.?.pos,
                            .data = .{ .llnum = n },
                        };
                        try self.create_node(&number_node);
                    },
                    .dnum => |n| {
                        var number_node = ast.Node{
                            .type = .Number,
                            .pos = t.?.pos,
                            .data = .{ .dnum = n },
                        };
                        try self.create_node(&number_node);
                    },
                    .cval => |c| {
                        var char_node = ast.Node{
                            .type = .Character,
                            .pos = t.?.pos,
                            .data = .{ .cval = c },
                        };
                        try self.create_node(&char_node);
                    },
                    else => {
                        self.transpile_proc.err("invalid number token", .{});
                        return ParseError.InvalidToken;
                    },
                }
            },
            .Identifier => {
                const prev = self.token_peek_prev();
                const is_member_access = prev != null and prev.?.type == .Operator and mem.eql(u8, prev.?.data.sval.items, ".");

                // `_` is a wildcard identifier (used by `fit` default branches).
                // It should be accepted even if it's not declared.
                if (!mem.eql(u8, t.?.data.sval.items, "_")) {
                    if (!is_member_access) {
                        if (self.transpile_proc.get_scope_entity(t.?.data.sval.items) == null) {
                            if (self.transpile_proc.get_symbol(t.?.data.sval.items) == null and self.transpile_proc.global_symbols.get(t.?.data.sval.items) == null) {
                                self.transpile_proc.err("unknown identifier '{s}'", .{t.?.data.sval.items});
                                return ParseError.InvalidIdentifier;
                            }
                        }
                    }
                }
                var ident_node = ast.Node{
                    .type = .Identifier,
                    .pos = t.?.pos,
                    .data = .{ .sval = t.?.data.sval },
                };
                try self.create_node(&ident_node);
            },
            .String => {
                var str_node = ast.Node{
                    .type = .String,
                    .pos = t.?.pos,
                    .data = .{ .sval = t.?.data.sval },
                };
                try self.create_node(&str_node);
            },
            .Boolean => {
                var bool_node = ast.Node{
                    .type = .Boolean,
                    .pos = t.?.pos,
                    .data = .{ .bval = t.?.data.bval },
                };
                try self.create_node(&bool_node);
            },
            else => {
                self.transpile_proc.err("expected single token, got '{?}'", .{t.?.type});
                return ParseError.InvalidToken;
            },
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
    fn parse_additional_expression(self: *Self) ParseError!void {
        const t = self.token_peek_next();
        if (t.?.type == .Operator) {
            var hist = utils.History.init(self.transpile_proc.allocator, .{});
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
    fn parse_for_parenthesis(self: *Self, hist: *utils.History) ParseError!void {
        const lparen_token = self.token_peek_next();
        try self.expect_op("(");
        var left_node: ?ast.Node = null;
        const tmp_node = self.transpile_proc.nodes.back();
        if (tmp_node != null and ast.node_is_value_type(tmp_node.?)) {
            left_node = tmp_node;
            _ = self.node_pop();
        }
        var exp_node = ast.Node{ .type = .Blank };
        if (!self.next_token_is_symbol(')')) {
            try self.parse_expressionable_root(hist);
            exp_node = self.node_pop().?;
        }
        try self.expect_sym(')');
        const exp = self.transpile_proc.allocator.create(ast.Node) catch |e| {
            std.debug.print("Error creating node: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(exp);
        exp.* = exp_node;
        self.transpile_proc.nodes.push(ast.Node{
            .type = .ExpressionParenthesis,
            .pos = if (lparen_token) |t| t.pos else null,
            .node_variant = .{ .paren = .{ .exp = exp } },
        }) catch |e| {
            std.debug.print("Error adding node to list: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        if (left_node != null) {
            const parenthesis_node = self.node_pop();
            const left = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                std.debug.print("Error creating node: {s}", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(left);
            left.* = left_node.?;
            const right = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                std.debug.print("Error creating node: {s}", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(right);
            right.* = parenthesis_node.?;
            self.transpile_proc.nodes.push(ast.Node{
                .type = .Expression,
                .pos = if (lparen_token) |t| t.pos else left.*.pos,
                .node_variant = .{
                    .exp = .{
                        .left = left,
                        .right = right,
                        .op = "()",
                    },
                },
            }) catch |e| {
                std.debug.print("Error adding node to list: {s}", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
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
    fn parse_for_comma(self: *Self, hist: *utils.History) ParseError!void {
        const comma_token = self.token_peek_next();
        _ = self.token_next(); // skip ,
        const left_node = self.node_pop();
        try self.parse_expressionable_root(hist);
        const right_node = self.node_pop();
        const left = self.transpile_proc.allocator.create(ast.Node) catch |e| {
            std.debug.print("Error creating node: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(left);
        left.* = left_node.?;
        const right = self.transpile_proc.allocator.create(ast.Node) catch |e| {
            std.debug.print("Error creating node: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(right);
        right.* = right_node.?;
        self.transpile_proc.nodes.push(ast.Node{
            .type = .Expression,
            .pos = if (comma_token) |t| t.pos else left.*.pos,
            .node_variant = .{
                .exp = .{
                    .left = left,
                    .right = right,
                    .op = ",",
                },
            },
        }) catch |e| {
            std.debug.print("Error adding node to list: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
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
    fn parse_for_bracket(self: *Self, hist: *utils.History) ParseError!void {
        // Only treat `[...]` as an indexing operation when there's a valid expressionable left operand.
        // Otherwise it's an array literal.
        const left_node = self.node_peek_expressionable_or_null();
        if (left_node != null) {
            _ = self.node_pop();
        }

        const lbracket_token = self.token_peek_next();
        try self.expect_op("[");
        try self.parse_expressionable_root(hist);
        try self.expect_sym(']');
        const exp_node = self.node_pop();
        const inner = self.transpile_proc.allocator.create(ast.Node) catch |e| {
            std.debug.print("Error creating node: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(inner);
        inner.* = exp_node.?;
        self.transpile_proc.nodes.push(ast.Node{
            .type = .Bracket,
            .pos = if (lbracket_token) |t| t.pos else null,
            .node_variant = .{ .bracket = .{ .inner = inner } },
        }) catch |e| {
            std.debug.print("Error adding node to list: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        if (left_node != null) {
            const bracket_node = self.node_pop();
            const left = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                std.debug.print("Error creating node: {s}", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(left);
            left.* = left_node.?;
            const right = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                std.debug.print("Error creating node: {s}", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(right);
            right.* = bracket_node.?;
            self.transpile_proc.nodes.push(ast.Node{
                .type = .Expression,
                .pos = if (lbracket_token) |t| t.pos else left.*.pos,
                .node_variant = .{
                    .exp = .{
                        .left = left,
                        .right = right,
                        .op = "[]",
                    },
                },
            }) catch |e| {
                std.debug.print("Error adding node to list: {s}", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
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
    fn node_peek_expressionable_or_null(self: *Self) ?ast.Node {
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
    fn parse_for_indirection_unary(self: *Self) ParseError!void {
        const star_token = self.token_peek_next();
        const depth = self.parse_get_pointer_depth();
        var hist = utils.History.init(self.transpile_proc.allocator, .{ .expression_is_unary = true });
        defer hist.deinit();
        try self.parse_expressionable(&hist);
        const unary_operand_node = self.node_pop();
        const operand = self.transpile_proc.allocator.create(ast.Node) catch |e| {
            std.debug.print("Error creating node: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(operand);
        operand.* = unary_operand_node.?;
        self.transpile_proc.nodes.push(ast.Node{
            .type = .Unary,
            .pos = if (star_token) |t| t.pos else operand.*.pos,
            .node_variant = .{
                .unary = .{
                    .op = "*",
                    .operand = operand,
                },
            },
        }) catch |e| {
            std.debug.print("Error adding node to list: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        var unary_node = self.node_pop();
        unary_node.?.node_variant.?.unary.indirection = .{ .depth = depth };
        self.transpile_proc.nodes.push(unary_node.?) catch |e| {
            std.debug.print("Error adding node to list: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
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
    fn parse_for_normal_unary(self: *Self) ParseError!void {
        const unary_tok = self.token_next();
        const unary_op = unary_tok.?.data.sval.items;
        var hist = utils.History.init(self.transpile_proc.allocator, .{ .expression_is_unary = true });
        defer hist.deinit();
        try self.parse_expressionable(&hist);
        const unary_operand_node = self.node_pop();
        const operand = self.transpile_proc.allocator.create(ast.Node) catch |e| {
            std.debug.print("Error creating node: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(operand);
        operand.* = unary_operand_node.?;
        self.transpile_proc.nodes.push(ast.Node{
            .type = .Unary,
            .pos = unary_tok.?.pos,
            .node_variant = .{
                .unary = .{
                    .op = unary_op,
                    .operand = operand,
                },
            },
        }) catch |e| {
            std.debug.print("Error adding node to list: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
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
    fn parse_for_unary(self: *Self) ParseError!void {
        const t = self.token_peek_next();
        const unary_op = t.?.data.sval.items;
        if (utils.is_indirection_operator(unary_op)) {
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
    fn parse_for_left_operanded_unary(self: *Self, node_left: *ast.Node, unary_op: []const u8, op_pos: ?token.Pos) ParseError!void {
        self.transpile_proc.nodes.push(ast.Node{
            .type = .Unary,
            .pos = op_pos orelse node_left.*.pos,
            .node_variant = .{
                .unary = .{
                    .op = unary_op,
                    .operand = node_left,
                    .is_left_operanded_unary = true,
                },
            },
        }) catch |e| {
            std.debug.print("Error adding node to list: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
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
    fn make_expression_node(self: *Self, left_node: *ast.Node, right_node: *ast.Node, op: []const u8, op_pos: ?token.Pos) ParseError!void {
        const exp_node = self.transpile_proc.allocator.create(ast.Node) catch |e| {
            std.debug.print("Error creating node: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        defer self.transpile_proc.allocator.destroy(exp_node);
        const left = self.transpile_proc.allocator.create(ast.Node) catch |e| {
            std.debug.print("Error creating node: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(left);
        left.* = left_node.*;
        const right = self.transpile_proc.allocator.create(ast.Node) catch |e| {
            std.debug.print("Error creating node: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(right);
        right.* = right_node.*;
        exp_node.* = ast.Node{
            .type = .Expression,
            .pos = op_pos orelse left.*.pos orelse right.*.pos,
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
    fn make_body_node(self: *Self) ParseError!void {
        const body_node = self.transpile_proc.allocator.create(ast.Node) catch |e| {
            std.debug.print("Error creating body node: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(body_node);
        defer self.transpile_proc.allocator.destroy(body_node);
        body_node.* = ast.Node{
            .type = .Body,
            .pos = null,
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
    fn parse_node_shift_children_left(self: *Self, node: *ast.Node) ParseError!void {
        const exp = &node.*.node_variant.?.exp;
        const right_expr_ptr = exp.right orelse return;
        if (right_expr_ptr.*.type != .Expression) return;

        const right_exp = &right_expr_ptr.*.node_variant.?.exp;
        const op2 = right_exp.op;

        const a_ptr = exp.left orelse return;
        const b_ptr = right_exp.left orelse return;
        const c_ptr = right_exp.right orelse return;

        const new_left_expr = self.transpile_proc.allocator.create(ast.Node) catch |e| {
            std.debug.print("Error creating node: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(new_left_expr);
        new_left_expr.* = ast.Node{
            .type = .Expression,
            .pos = node.*.pos,
            .binded = null,
            .node_variant = .{
                .exp = .{
                    .left = a_ptr,
                    .right = b_ptr,
                    .op = exp.op,
                },
            },
        };

        // Rewrite: ((a op1 b) op2 c)
        exp.left = new_left_expr;
        exp.right = c_ptr;
        exp.op = op2;

        // Destroy the old right-expression container, without freeing moved children.
        right_exp.left = null;
        right_exp.right = null;
        self.transpile_proc.deinit_node(right_expr_ptr.*);
        self.transpile_proc.allocator.destroy(right_expr_ptr);
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
    fn parse_node_move_right_left_to_left(self: *Self, node: *ast.Node) ParseError!void {
        const exp = &node.*.node_variant.?.exp;
        const right_expr_ptr = exp.right orelse return;
        if (right_expr_ptr.*.type != .Expression) return;

        const right_exp = &right_expr_ptr.*.node_variant.?.exp;
        const op2 = right_exp.op;

        const a_ptr = exp.left orelse return;
        const b_ptr = right_exp.left orelse return;
        const c_ptr = right_exp.right orelse return;

        const completed = self.transpile_proc.allocator.create(ast.Node) catch |e| {
            std.debug.print("Error creating node: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(completed);
        completed.* = ast.Node{
            .type = .Expression,
            .pos = node.*.pos,
            .binded = null,
            .node_variant = .{
                .exp = .{
                    .left = a_ptr,
                    .right = b_ptr,
                    .op = exp.op,
                },
            },
        };

        exp.left = completed;
        exp.right = c_ptr;
        exp.op = op2;

        right_exp.left = null;
        right_exp.right = null;
        self.transpile_proc.deinit_node(right_expr_ptr.*);
        self.transpile_proc.allocator.destroy(right_expr_ptr);
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
    fn parse_reorder_expression(self: *Self, node: *ast.Node) ParseError!void {
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
    fn parse_normal_expression(self: *Self, hist: *utils.History) ParseError!void {
        var t = self.token_peek_next();
        const op = t.?.data.sval.items;
        const op_pos = t.?.pos;
        var node_left = self.node_peek_expressionable_or_null();
        if (node_left == null) {
            if (!utils.is_unary_operator(op)) {
                self.transpile_proc.err("expected left operand for '{s}' operator", .{op});
                return ParseError.InvalidOperand;
            }
            return try self.parse_for_unary();
        }
        _ = self.token_next(); // skip operator
        _ = self.node_pop();
        if (utils.is_left_operanded_unary_operator(op)) {
            return try self.parse_for_left_operanded_unary(&node_left.?, op, op_pos);
        }
        node_left.?.flags = .{ .inside_expression = true };
        t = self.token_peek_next();
        if (t.?.type == .Operator) {
            if (mem.eql(u8, t.?.data.sval.items, "(")) {
                var hist_down = utils.History.down(self.transpile_proc.allocator, hist, hist.flags);
                defer hist_down.deinit();
                hist_down.flags.parenthesis_not_function_call = true;
                try self.parse_for_parenthesis(&hist_down);
            } else if (utils.is_unary_operator(t.?.data.sval.items)) {
                try self.parse_for_unary();
            } else {
                self.transpile_proc.err("expected expressionable for '{s}' operator", .{op});
                return ParseError.InvalidOperand;
            }
        } else {
            var hist_down = utils.History.down(self.transpile_proc.allocator, hist, hist.flags);
            defer hist_down.deinit();
            try self.parse_expressionable(&hist_down);
        }
        var node_right = self.node_pop();
        node_right.?.flags = .{ .inside_expression = true };
        try self.make_expression_node(&node_left.?, &node_right.?, op, op_pos);
        var exp_node = self.node_pop();
        try self.parse_reorder_expression(&exp_node.?);
        self.transpile_proc.nodes.push(exp_node.?) catch |e| {
            std.debug.print("Error adding node to list: {s}", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
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
    fn parse_expression(self: *Self, hist: *utils.History) ParseError!bool {
        const t = self.token_peek_next();
        if (hist.flags.expression_is_unary and !utils.is_unary_operand_compatible(t.?)) {
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
    fn parse_identifier(self: *Self) ParseError!bool {
        const t = self.token_peek_next();
        if (t != null and t.?.type != .Identifier) {
            self.transpile_proc.err("expected identifier, got '{?}'", .{t.?.type});
            return ParseError.InvalidIdentifier;
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
        const t = self.token_peek_next();
        if (t != null and t.?.type != .String) {
            self.transpile_proc.err("expected string, got '{?}'", .{t.?.type});
            return ParseError.InvalidString;
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
    fn parse_expressionable_single(self: *Self, hist: *utils.History) ParseError!bool {
        const t = self.token_peek_next();
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
            .Identifier => blk: {
                // Support user-defined types at statement level: `Point p;`.
                // If the next token is a known type name and the following token looks like a declaration,
                // parse it as a variable declaration instead of an identifier expression.
                const name = t.?.data.sval.items;
                if (self.transpile_proc.get_symbol(name)) |sym| {
                    if (sym.type == .Node and sym.data != null) {
                        const n = sym.data.?.node;
                        if (n.type == .Compound or n.type == .Quirk) {
                            const t1 = self.token_peek_n(1);
                            if (t1 != null and (t1.?.type == .Identifier or (t1.?.type == .Operator and (mem.eql(u8, t1.?.data.sval.items, "*") or mem.eql(u8, t1.?.data.sval.items, "["))))) {
                                // Parse datatype + variable.
                                const dt = self.transpile_proc.allocator.create(dtype.DataType) catch |e| {
                                    std.debug.print("Error creating DataType: {}\n", .{e});
                                    return ParseError.MemoryAllocationFailed;
                                };
                                errdefer self.transpile_proc.allocator.destroy(dt);
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
                                break :blk true;
                            }
                        }
                    }
                }
                break :blk try self.parse_identifier();
            },
            .Keyword => {
                try self.parse_keyword(hist);
                return true;
            },
            .String => try self.parse_string(),
            else => false,
        };
    }

    fn parse_compound(self: *Self) ParseError!void {
        try self.expect_keyword("compound");

        const name_tok = self.token_next();
        if (name_tok == null or name_tok.?.type != .Identifier) {
            self.transpile_proc.err("expected identifier after 'compound'", .{});
            return ParseError.InvalidIdentifier;
        }

        var name = std.ArrayList(u8).initCapacity(self.transpile_proc.allocator, name_tok.?.data.sval.items.len) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer name.deinit();
        name.appendSlice(name_tok.?.data.sval.items) catch {
            return ParseError.MemoryAllocationFailed;
        };

        try self.expect_sym('{');

        var fields = utils.Vector(ast.CompoundField).init(self.transpile_proc.allocator);
        errdefer {
            for (fields.items()) |f| {
                f.name.deinit();
                f.dtype.type_str.deinit();
                if (f.dtype.array) |array| {
                    if (!array.brackets.is_empty()) {
                        for (array.brackets.items()) |bracket| self.transpile_proc.deinit_node(bracket);
                    }
                    array.brackets.deinit();
                }
                self.transpile_proc.allocator.destroy(f.dtype);
            }
            fields.deinit();
        }

        while (!self.next_token_is_symbol('}')) {
            // Parse field datatype
            const dt = self.transpile_proc.allocator.create(dtype.DataType) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(dt);
            dt.* = dtype.DataType{
                .array = null,
                .pointer_depth = 0,
                .type = .Unknown,
                .type_str = std.ArrayList(u8).init(self.transpile_proc.allocator),
                .flags = .{},
            };
            var hist_tmp = utils.History.init(self.transpile_proc.allocator, .{});
            defer hist_tmp.deinit();
            try self.parse_datatype(dt);
            // Allow array brackets after type name in field declarations.
            if (self.next_token_is_operator("[")) {
                try self.parse_array_brackets(dt, &hist_tmp);
            }

            // Parse one or more field names: `dec x, y;`
            var field_count: usize = 0;
            while (true) {
                const field_tok = self.token_next();
                if (field_tok == null or field_tok.?.type != .Identifier) {
                    self.transpile_proc.err("expected field name", .{});
                    return ParseError.InvalidIdentifier;
                }
                var fname = std.ArrayList(u8).initCapacity(self.transpile_proc.allocator, field_tok.?.data.sval.items.len) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer fname.deinit();
                fname.appendSlice(field_tok.?.data.sval.items) catch {
                    return ParseError.MemoryAllocationFailed;
                };

                // Each field owns its dtype (deep-copy type_str). For multi-name decls,
                // only allow non-array types (arrays require bracket AST cloning).
                if (field_count > 0 and dt.array != null) {
                    self.transpile_proc.err("array fields cannot be declared in a combined list; declare them separately", .{});
                    return ParseError.InvalidDataType;
                }

                const field_dt = self.transpile_proc.allocator.create(dtype.DataType) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(field_dt);
                field_dt.* = dt.*;
                field_dt.*.type_str = std.ArrayList(u8).initCapacity(self.transpile_proc.allocator, dt.type_str.items.len) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                field_dt.*.type_str.appendSlice(dt.type_str.items) catch {
                    return ParseError.MemoryAllocationFailed;
                };

                if (field_count > 0) {
                    field_dt.*.array = null;
                }

                fields.push(.{ .name = fname, .dtype = field_dt }) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                field_count += 1;

                if (!self.next_token_is_operator(",")) break;
                _ = self.token_next(); // skip comma
            }

            // Original dt storage is now unused; destroy it.
            dt.*.type_str.deinit();
            self.transpile_proc.allocator.destroy(dt);

            try self.expect_sym(';');
        }
        try self.expect_sym('}');

        const node = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer {
            self.transpile_proc.deinit_node(node.*);
            self.transpile_proc.allocator.destroy(node);
        }
        node.* = ast.Node{
            .type = .Compound,
            .pos = name_tok.?.pos,
            .node_variant = .{ .compound = .{ .name = name, .fields = fields } },
        };

        // Register as a symbol so it can be used as a datatype identifier.
        try self.transpile_proc.push_symbol(.{ .type = .Node, .name = node.*.node_variant.?.compound.name.items, .data = .{ .node = node.* }, .symbol_table = null });

        self.transpile_proc.nodes.push(node.*) catch {
            return ParseError.MemoryAllocationFailed;
        };
        self.transpile_proc.owned_nodes.append(node) catch {
            return ParseError.MemoryAllocationFailed;
        };
    }

    fn parse_quirk(self: *Self) ParseError!void {
        try self.expect_keyword("quirk");

        const name_tok = self.token_next();
        if (name_tok == null or name_tok.?.type != .Identifier) {
            self.transpile_proc.err("expected identifier after 'quirk'", .{});
            return ParseError.InvalidIdentifier;
        }

        var name = std.ArrayList(u8).initCapacity(self.transpile_proc.allocator, name_tok.?.data.sval.items.len) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer name.deinit();
        name.appendSlice(name_tok.?.data.sval.items) catch {
            return ParseError.MemoryAllocationFailed;
        };

        try self.expect_sym('{');

        var methods = utils.Vector(ast.QuirkMethodSig).init(self.transpile_proc.allocator);
        errdefer {
            for (methods.items()) |m| {
                m.name.deinit();
                m.rtype.type_str.deinit();
                for (m.args.items()) |a| {
                    a.name.deinit();
                    a.dtype.type_str.deinit();
                    if (a.dtype.array) |array| {
                        if (!array.brackets.is_empty()) {
                            for (array.brackets.items()) |bracket| self.transpile_proc.deinit_node(bracket);
                        }
                        array.brackets.deinit();
                    }
                    self.transpile_proc.allocator.destroy(a.dtype);
                }
                m.args.deinit();
            }
            methods.deinit();
        }

        while (!self.next_token_is_symbol('}')) {
            const mname_tok = self.token_next();
            if (mname_tok == null or mname_tok.?.type != .Identifier) {
                self.transpile_proc.err("expected method name", .{});
                return ParseError.InvalidIdentifier;
            }
            var mname = std.ArrayList(u8).initCapacity(self.transpile_proc.allocator, mname_tok.?.data.sval.items.len) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer mname.deinit();
            mname.appendSlice(mname_tok.?.data.sval.items) catch {
                return ParseError.MemoryAllocationFailed;
            };

            try self.expect_op("(");

            var args = utils.Vector(ast.QuirkArg).init(self.transpile_proc.allocator);
            errdefer args.deinit();
            while (!self.next_token_is_symbol(')')) {
                const adt = self.transpile_proc.allocator.create(dtype.DataType) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(adt);
                adt.* = dtype.DataType{ .type_str = std.ArrayList(u8).init(self.transpile_proc.allocator), .flags = .{} };
                var hist_tmp = utils.History.init(self.transpile_proc.allocator, .{});
                defer hist_tmp.deinit();
                try self.parse_datatype(adt);
                if (self.next_token_is_operator("[")) {
                    try self.parse_array_brackets(adt, &hist_tmp);
                }

                const aname_tok = self.token_next();
                if (aname_tok == null or aname_tok.?.type != .Identifier) {
                    self.transpile_proc.err("expected argument name", .{});
                    return ParseError.InvalidIdentifier;
                }
                var aname = std.ArrayList(u8).initCapacity(self.transpile_proc.allocator, aname_tok.?.data.sval.items.len) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer aname.deinit();
                aname.appendSlice(aname_tok.?.data.sval.items) catch {
                    return ParseError.MemoryAllocationFailed;
                };

                args.push(.{ .name = aname, .dtype = adt }) catch {
                    return ParseError.MemoryAllocationFailed;
                };

                if (!self.next_token_is_operator(",")) break;
                _ = self.token_next();
            }
            try self.expect_sym(')');

            // Optional return type; default to void.
            var rtype: dtype.DataType = .{ .type_str = std.ArrayList(u8).init(self.transpile_proc.allocator) };
            const rtok = self.token_peek_next();
            if (rtok != null and (rtok.?.type == .Keyword and utils.keyword_is_datatype(rtok.?.data.sval.items)) or rtok.?.type == .Identifier) {
                try self.parse_datatype(&rtype);
            } else {
                rtype.type = .Void;
                rtype.type_str.appendSlice("void") catch {
                    return ParseError.MemoryAllocationFailed;
                };
            }

            try self.expect_sym(';');
            methods.push(.{ .name = mname, .rtype = rtype, .args = args }) catch {
                return ParseError.MemoryAllocationFailed;
            };
        }

        try self.expect_sym('}');

        const node = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer {
            self.transpile_proc.deinit_node(node.*);
            self.transpile_proc.allocator.destroy(node);
        }
        node.* = ast.Node{
            .type = .Quirk,
            .pos = name_tok.?.pos,
            .node_variant = .{ .quirk = .{ .name = name, .methods = methods } },
        };

        // Register as a symbol so it can be used as a datatype identifier.
        try self.transpile_proc.push_symbol(.{ .type = .Node, .name = node.*.node_variant.?.quirk.name.items, .data = .{ .node = node.* }, .symbol_table = null });

        self.transpile_proc.nodes.push(node.*) catch {
            return ParseError.MemoryAllocationFailed;
        };
        self.transpile_proc.owned_nodes.append(node) catch {
            return ParseError.MemoryAllocationFailed;
        };
    }

    fn parse_impl(self: *Self) ParseError!void {
        try self.expect_keyword("impl");
        const type_tok = self.token_next();
        if (type_tok == null or type_tok.?.type != .Identifier) {
            self.transpile_proc.err("expected type name after 'impl'", .{});
            return ParseError.InvalidIdentifier;
        }
        const quirk_tok = self.token_next();
        if (quirk_tok == null or quirk_tok.?.type != .Identifier) {
            self.transpile_proc.err("expected quirk name after type name", .{});
            return ParseError.InvalidIdentifier;
        }

        var type_name = std.ArrayList(u8).initCapacity(self.transpile_proc.allocator, type_tok.?.data.sval.items.len) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer type_name.deinit();
        type_name.appendSlice(type_tok.?.data.sval.items) catch {
            return ParseError.MemoryAllocationFailed;
        };
        var quirk_name = std.ArrayList(u8).initCapacity(self.transpile_proc.allocator, quirk_tok.?.data.sval.items.len) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer quirk_name.deinit();
        quirk_name.appendSlice(quirk_tok.?.data.sval.items) catch {
            return ParseError.MemoryAllocationFailed;
        };

        try self.expect_sym('{');

        var methods = utils.Vector(*ast.Node).init(self.transpile_proc.allocator);
        errdefer {
            for (methods.items()) |m| {
                self.transpile_proc.deinit_node(m.*);
                self.transpile_proc.allocator.destroy(m);
            }
            methods.deinit();
        }

        // Parse methods with syntax similar to functions but without the leading `fun` keyword.
        // Example: `fun1() void { ... }`
        while (!self.next_token_is_symbol('}')) {
            const name_tok = self.token_next();
            if (name_tok == null or name_tok.?.type != .Identifier) {
                self.transpile_proc.err("expected method name in impl", .{});
                return ParseError.InvalidIdentifier;
            }

            // Build a regular function node with a generated name: `<Type>__<Quirk>__<method>`
            var fn_node = ast.Node{
                .type = .Function,
                .pos = name_tok.?.pos,
                .node_variant = .{ .function = .{} },
            };

            const gen_name = std.fmt.allocPrint(self.transpile_proc.allocator, "{s}__{s}__{s}", .{ type_name.items, quirk_name.items, name_tok.?.data.sval.items }) catch {
                return ParseError.MemoryAllocationFailed;
            };
            defer self.transpile_proc.allocator.free(gen_name);
            fn_node.node_variant.?.function.name = std.ArrayList(u8).initCapacity(self.transpile_proc.allocator, gen_name.len) catch {
                return ParseError.MemoryAllocationFailed;
            };
            fn_node.node_variant.?.function.name.?.appendSlice(gen_name) catch {
                return ParseError.MemoryAllocationFailed;
            };

            // Function scope.
            _ = try self.transpile_proc.new_scope();

            try self.expect_op("(");

            // Implicit `self` arg: `<Type>* self`
            const self_dt = self.transpile_proc.allocator.create(dtype.DataType) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(self_dt);
            self_dt.* = dtype.DataType{
                .array = null,
                .pointer_depth = 1,
                .type = .Unknown,
                .type_str = std.ArrayList(u8).init(self.transpile_proc.allocator),
                .flags = .{ .is_pointer = true },
            };
            self_dt.type_str.appendSlice(type_name.items) catch {
                return ParseError.MemoryAllocationFailed;
            };

            var self_name = std.ArrayList(u8).init(self.transpile_proc.allocator);
            errdefer self_name.deinit();
            self_name.appendSlice("self") catch {
                return ParseError.MemoryAllocationFailed;
            };

            const self_var_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(self_var_ptr);
            self_var_ptr.* = ast.Node{
                .type = .Variable,
                .pos = name_tok.?.pos,
                .node_variant = .{ .variable = .{ .name = self_name, .type = self_dt, .val = null } },
            };
            // Register `self` in scope for parsing identifier uses.
            const self_entity = try self.new_scope_entity(self_var_ptr, .{});
            self.transpile_proc.owned_scope_entities.append(self_entity) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer _ = self.transpile_proc.owned_scope_entities.pop();
            try self.transpile_proc.push_scope_entity(self_entity);

            var args = utils.Vector(*ast.Node).init(self.transpile_proc.allocator);
            args.push(self_var_ptr) catch {
                return ParseError.MemoryAllocationFailed;
            };

            // Parse additional explicit args (datatype name pairs), if any.
            var hist_args = utils.History.init(self.transpile_proc.allocator, .{});
            defer hist_args.deinit();
            while (!self.next_token_is_symbol(')')) {
                try self.parse_full_variable(&hist_args);
                const arg_node = self.node_pop();
                const arg_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(arg_ptr);
                arg_ptr.* = arg_node.?;
                args.push(arg_ptr) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                if (!self.next_token_is_operator(",")) break;
                _ = self.token_next();
            }
            try self.expect_sym(')');

            fn_node.node_variant.?.function.args = args;

            // Optional return type; default void.
            var rtype: dtype.DataType = .{ .type_str = std.ArrayList(u8).init(self.transpile_proc.allocator) };
            const rtok = self.token_peek_next();
            if (rtok != null and ((rtok.?.type == .Keyword and utils.keyword_is_datatype(rtok.?.data.sval.items)) or rtok.?.type == .Identifier)) {
                try self.parse_datatype(&rtype);
                fn_node.node_variant.?.function.rtype = rtype;
            }

            // Body
            if (self.next_token_is_symbol('{')) {
                var hist_body = utils.History.init(self.transpile_proc.allocator, .{ .inside_function_body = true });
                defer hist_body.deinit();
                try self.parse_body(&hist_body);
                const body_node = self.node_pop();
                const body_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(body_ptr);
                body_ptr.* = body_node.?;
                fn_node.node_variant.?.function.body = body_ptr;
            } else {
                try self.expect_sym(';');
            }

            // End function scope opened above.
            self.transpile_proc.finish_scope();

            const fn_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(fn_ptr);
            fn_ptr.* = fn_node;
            methods.push(fn_ptr) catch {
                return ParseError.MemoryAllocationFailed;
            };
        }

        try self.expect_sym('}');

        const node = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer {
            self.transpile_proc.deinit_node(node.*);
            self.transpile_proc.allocator.destroy(node);
        }
        node.* = ast.Node{
            .type = .Impl,
            .pos = type_tok.?.pos,
            .node_variant = .{ .impl = .{ .type_name = type_name, .quirk_name = quirk_name, .methods = methods } },
        };

        self.transpile_proc.nodes.push(node.*) catch {
            return ParseError.MemoryAllocationFailed;
        };
        self.transpile_proc.owned_nodes.append(node) catch {
            return ParseError.MemoryAllocationFailed;
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
    fn parse_expressionable(self: *Self, hist: *utils.History) ParseError!void {
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
    fn parse_expressionable_root(self: *Self, hist: *utils.History) ParseError!void {
        try self.parse_expressionable(hist);
        const n = self.node_pop();
        self.transpile_proc.nodes.push(n.?) catch |e| {
            std.debug.print("Error pushing node: {s}\n", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
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
    fn parse_array_brackets(self: *Self, dt: *dtype.DataType, hist: *utils.History) ParseError!void {
        var brackets = utils.Vector(ast.Node).init(self.transpile_proc.allocator);
        while (self.next_token_is_operator("[")) {
            const lbracket_token = self.token_peek_next();
            try self.expect_op("[");
            dt.*.flags.?.is_array = true;
            if (self.next_token_is_symbol(']')) {
                try self.expect_sym(']');
                break;
            }
            try self.parse_expressionable_root(hist);
            try self.expect_sym(']');
            const exp_node = self.node_pop();
            const exp = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(exp);
            exp.* = exp_node.?;
            self.transpile_proc.nodes.push(ast.Node{
                .type = .Bracket,
                .pos = if (lbracket_token) |t| t.pos else null,
                .node_variant = .{ .bracket = .{ .inner = exp } },
            }) catch |e| {
                std.debug.print("Error pushing node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            const bracket_node = self.node_pop();
            brackets.push(bracket_node.?) catch |e| {
                std.debug.print("Error pushing node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
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
    fn parse_variable(self: *Self, dt: *dtype.DataType, hist: *utils.History) ParseError!void {
        if (self.next_token_is_operator("[")) {
            try self.parse_array_brackets(dt, hist);
        }
        const ident_token = self.token_next();
        if (ident_token == null or ident_token.?.type != .Identifier) {
            self.transpile_proc.err("expected indentifier", .{});
            return ParseError.InvalidIdentifier;
        }

        // Variable nodes own their name string (and deinit it). Token strings are also deinitialized
        // by `TranspileProcess.deinit()`, so we must deep-copy here to avoid double-free.
        var name = std.ArrayList(u8).initCapacity(self.transpile_proc.allocator, ident_token.?.data.sval.items.len) catch |e| {
            std.debug.print("Error creating variable name: {s}\n", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer name.deinit();
        name.appendSlice(ident_token.?.data.sval.items) catch |e| {
            std.debug.print("Error appending to variable name: {s}\n", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        var value_node: ?ast.Node = null;
        const has_value = self.next_token_is_operator("=");
        if (has_value) {
            _ = self.token_next(); // skip =
            try self.parse_expressionable_root(hist);
            value_node = self.node_pop();
            const val = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(val);
            val.* = value_node.?;
            const node = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer {
                self.transpile_proc.deinit_node(node.*);
                self.transpile_proc.allocator.destroy(node);
            }
            node.* = ast.Node{
                .type = .Variable,
                .pos = ident_token.?.pos,
                .node_variant = .{
                    .variable = .{
                        .name = name,
                        .type = dt,
                        .val = val,
                    },
                },
            };
            // Ownership of `name` transferred to the node.
            name = std.ArrayList(u8).init(self.transpile_proc.allocator);
            const scope_entity = try self.new_scope_entity(node, .{});
            if (self.transpile_proc.get_scope_entity(scope_entity.name) != null) {
                self.transpile_proc.err("variable '{s}' already declared", .{scope_entity.name});
                return ParseError.VariableAlreadyDeclared;
            }
            self.transpile_proc.nodes.push(node.*) catch |e| {
                std.debug.print("Error pushing node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            self.transpile_proc.owned_nodes.append(node) catch |e| {
                std.debug.print("Error tracking node allocation: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer _ = self.transpile_proc.owned_nodes.pop();
            self.transpile_proc.owned_scope_entities.append(scope_entity) catch |e| {
                std.debug.print("Error tracking scope entity allocation: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer _ = self.transpile_proc.owned_scope_entities.pop();
            try self.transpile_proc.push_scope_entity(scope_entity);
        } else {
            const node = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer {
                self.transpile_proc.deinit_node(node.*);
                self.transpile_proc.allocator.destroy(node);
            }
            node.* = ast.Node{
                .type = .Variable,
                .pos = ident_token.?.pos,
                .node_variant = .{
                    .variable = .{
                        .name = name,
                        .type = dt,
                    },
                },
            };
            // Ownership of `name` transferred to the node.
            name = std.ArrayList(u8).init(self.transpile_proc.allocator);
            const scope_entity = try self.new_scope_entity(node, .{});
            self.transpile_proc.nodes.push(node.*) catch |e| {
                std.debug.print("Error pushing node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            self.transpile_proc.owned_nodes.append(node) catch |e| {
                std.debug.print("Error tracking node allocation: {s}\\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer _ = self.transpile_proc.owned_nodes.pop();
            self.transpile_proc.owned_scope_entities.append(scope_entity) catch |e| {
                std.debug.print("Error tracking scope entity allocation: {s}\\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer _ = self.transpile_proc.owned_scope_entities.pop();
            try self.transpile_proc.push_scope_entity(scope_entity);
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
    fn parse_full_variable(self: *Self, hist: *utils.History) ParseError!void {
        const dt = self.transpile_proc.allocator.create(dtype.DataType) catch |e| {
            std.debug.print("Error creating DataType: {s}\n", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(dt);
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
    fn parse_function_args(self: *Self, hist: *utils.History) ParseError!utils.Vector(*ast.Node) {
        var args = utils.Vector(*ast.Node).init(self.transpile_proc.allocator);
        while (!self.next_token_is_symbol(')')) {
            if (self.next_token_is_operator(".")) { // variadic
                for (0..3) |_| {
                    try self.expect_op(".");
                }
                self.transpile_proc.finish_scope();
                return args;
            }
            try self.parse_full_variable(hist);
            const arg_node = self.node_pop();
            const arg = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(arg);
            arg.* = arg_node.?;
            args.push(arg) catch |e| {
                std.debug.print("Error pushing node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            if (!self.next_token_is_operator(",")) {
                break;
            }
            _ = self.token_next(); // skip ,
        }
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
    fn parse_function(self: *Self) ParseError!void {
        _ = try self.transpile_proc.new_scope();
        _ = self.token_next(); // skip fun
        var function_node = ast.Node{
            .type = .Function,
            .pos = self.*.transpile_proc.*.pos,
            .node_variant = .{ .function = .{} },
        };
        // Initialize `dt` so optional fields are well-defined before `parse_datatype()`.
        // `parse_datatype()` will set `type`/`flags` and overwrite `type_str`.
        var dt: dtype.DataType = .{ .type_str = std.ArrayList(u8).init(self.transpile_proc.allocator) };
        const ident_token = self.token_next();
        if (ident_token.?.type != .Identifier) {
            self.transpile_proc.err("expected indentifier, got '{}'", .{ident_token.?.type});
            return ParseError.InvalidIdentifier;
        }
        // Function nodes must own their name buffer. Token sval buffers are owned by the token stream
        // and are deinitialized in `TranspileProcess.deinit()`.
        var fname = std.ArrayList(u8).initCapacity(self.transpile_proc.allocator, ident_token.?.data.sval.items.len) catch |e| {
            std.debug.print("Error creating function name: {s}\n", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer fname.deinit();
        fname.appendSlice(ident_token.?.data.sval.items) catch |e| {
            std.debug.print("Error appending to function name: {s}\n", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        function_node.node_variant.?.function.name = fname;
        self.parser_current_function = function_node;
        try self.expect_op("(");
        var hist_args = utils.History.init(self.transpile_proc.allocator, .{});
        defer hist_args.deinit();
        const args = try self.parse_function_args(&hist_args);
        try self.expect_sym(')');
        function_node.node_variant.?.function.args = args;
        const rtype_token = self.token_peek_next();
        if (rtype_token != null and rtype_token.?.type == .Keyword and utils.keyword_is_datatype(rtype_token.?.data.sval.items)) {
            try self.parse_datatype(&dt);
        } else {
            var type_str = std.ArrayList(u8).init(self.transpile_proc.allocator);
            type_str.appendSlice("void") catch |e| {
                std.debug.print("Error appending to type_str: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            dt = dtype.DataType{
                .type = .Void,
                .type_str = type_str,
            };
        }
        function_node.node_variant.?.function.rtype = dt;
        try self.transpile_proc.register_global_node_symbol(function_node);
        if (self.next_token_is_symbol('{')) {
            var hist_body = utils.History.init(self.transpile_proc.allocator, .{ .inside_function_body = true });
            defer hist_body.deinit();
            try self.parse_body(&hist_body);
            const body_node = self.node_pop();
            const body = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(body);
            body.* = body_node.?;
            function_node.node_variant.?.function.body = body;
        } else {
            try self.expect_sym(';');
        }
        self.parser_current_function = null;
        self.transpile_proc.nodes.push(function_node) catch |e| {
            std.debug.print("Error pushing node: {s}\n", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
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
    fn parse_return(self: *Self, hist: *utils.History) ParseError!void {
        const ret_token = self.token_peek_next();
        _ = self.token_next(); // skip ret
        if (self.next_token_is_symbol(';')) {
            try self.expect_sym(';');
            self.transpile_proc.nodes.push(ast.Node{
                .type = .StatementReturn,
                .pos = if (ret_token) |t| t.pos else null,
            }) catch |e| {
                std.debug.print("Error pushing node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            return;
        }
        try self.parse_expressionable_root(hist);
        const exp_node = self.node_pop();
        const exp = self.transpile_proc.allocator.create(ast.Node) catch |e| {
            std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(exp);
        exp.* = exp_node.?;
        self.transpile_proc.nodes.push(ast.Node{
            .type = .StatementReturn,
            .pos = if (ret_token) |t| t.pos else null,
            .node_variant = .{ .statement = .{ .return_stmt = exp } },
        }) catch |e| {
            std.debug.print("Error pushing node: {s}\n", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
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
    fn parse_elif_statement(self: *Self, hist: *utils.History) ParseError!void {
        if (self.next_token_is_keyword("elif")) {
            const elif_token = self.token_peek_next();
            if (self.parser_current_function == null) {
                self.transpile_proc.err("elif statement outside of function", .{});
                return ParseError.InvalidStatement;
            }
            _ = self.token_next(); // skip elif
            try self.parse_expressionable_root(hist);
            const condition_node = self.node_pop();
            if (condition_node.?.type == .Expression and mem.eql(u8, condition_node.?.node_variant.?.exp.op, "=")) {
                self.transpile_proc.err("expected expression, got assignment", .{});
                return ParseError.InvalidExpression;
            }
            const condition = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(condition);
            condition.* = condition_node.?;
            try self.parse_body(hist);
            const body_node = self.node_pop();
            const body = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(body);
            body.* = body_node.?;
            var elif_node = ast.Node{
                .type = .StatementElseIf,
                .pos = if (elif_token) |t| t.pos else null,
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
    fn parse_else_statement(self: *Self, hist: *utils.History) ParseError!void {
        if (self.next_token_is_keyword("else")) {
            const else_token = self.token_peek_next();
            if (self.parser_current_function == null) {
                self.transpile_proc.err("else statement outside of function", .{});
                return ParseError.InvalidStatement;
            }
            _ = self.token_next(); // skip else
            try self.parse_body(hist);
            const body_node = self.node_pop();
            const body = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(body);
            body.* = body_node.?;
            var else_node = ast.Node{
                .type = .StatementElse,
                .pos = if (else_token) |t| t.pos else null,
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
    fn parse_if_statement(self: *Self, hist: *utils.History) ParseError!void {
        const if_token = self.token_peek_next();
        try self.expect_keyword("if");
        if (self.parser_current_function == null) {
            self.transpile_proc.err("if statement outside of function", .{});
            return ParseError.InvalidStatement;
        }
        try self.parse_expressionable_root(hist);
        const condition_node = self.node_pop();
        if (condition_node.?.type == .Expression and mem.eql(u8, condition_node.?.node_variant.?.exp.op, "=")) {
            self.transpile_proc.err("expected expression, got assignment", .{});
            return ParseError.InvalidExpression;
        }
        const condition = self.transpile_proc.allocator.create(ast.Node) catch |e| {
            std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(condition);
        condition.* = condition_node.?;
        try self.parse_body(hist);
        const body_node = self.node_pop();
        const body = self.transpile_proc.allocator.create(ast.Node) catch |e| {
            std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(body);
        body.* = body_node.?;
        const if_node = self.transpile_proc.allocator.create(ast.Node) catch |e| {
            std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(if_node);
        defer self.transpile_proc.allocator.destroy(if_node);
        if_node.* = ast.Node{
            .type = .StatementIf,
            .pos = if (if_token) |t| t.pos else null,
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
    fn parse_fit_body(self: *Self, fit_node: *ast.Node, hist: *utils.History) ParseError!void {
        try self.expect_sym('{');
        fit_node.*.node_variant.?.statement.fit_stmt.branches = utils.Vector(ast.FitBranch).init(self.transpile_proc.allocator);
        while (!self.next_token_is_symbol('}')) {
            var hist_down = utils.History.down(self.transpile_proc.allocator, hist, hist.flags);
            defer hist_down.deinit();
            try self.parse_expressionable_root(&hist_down);
            const condition_node = self.node_pop();
            if (condition_node.?.type == .Expression and mem.eql(u8, condition_node.?.node_variant.?.exp.op, "=")) {
                self.transpile_proc.err("expected expression, got assignment", .{});
                return ParseError.InvalidExpression;
            }
            if (condition_node.?.type == .Identifier and mem.eql(u8, condition_node.?.data.?.sval.items, "_")) {
                // `_` is a special wildcard for the default branch. The parsed identifier node
                // is not part of the resulting AST (condition=null), so we must free it now.
                self.transpile_proc.deinit_node(condition_node.?);
                // default case after should be the last branch
                try self.expect_op("->");
                try self.parse_body(&hist_down);
                const body_node = self.node_pop();
                const body = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                    std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(body);
                body.* = body_node.?;
                fit_node.*.node_variant.?.statement.fit_stmt.branches.push(.{ .body = body, .condition = null }) catch |e| {
                    std.debug.print("Error pushing node: {s}\n", .{@errorName(e)});
                    return ParseError.MemoryAllocationFailed;
                };
                if (self.next_token_is_operator(",")) {
                    _ = self.token_next(); // skip ,
                }
                break;
            }

            const condition = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(condition);
            condition.* = condition_node.?;
            try self.expect_op("->");
            try self.parse_body(&hist_down);
            const body_node = self.node_pop();
            const body = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(body);
            body.* = body_node.?;
            fit_node.*.node_variant.?.statement.fit_stmt.branches.push(.{ .body = body, .condition = condition }) catch |e| {
                std.debug.print("Error pushing node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            if (self.next_token_is_operator(",")) {
                _ = self.token_next(); // skip ,
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
    fn parse_fit_statement(self: *Self, hist: *utils.History) ParseError!void {
        const fit_token = self.token_peek_next();
        var fit_node: ast.Node = .{
            .type = .StatementFit,
            .pos = if (fit_token) |t| t.pos else null,
            .node_variant = .{
                .statement = .{ .fit_stmt = undefined },
            },
        };
        hist.*.flags.in_fit_statement = true;
        try self.expect_keyword("fit");
        var new_hist = utils.History.init(self.transpile_proc.allocator, .{ .in_fit_statement = true });
        defer new_hist.deinit();
        try self.parse_expressionable_root(&new_hist);
        const condition_node = self.node_pop();
        const condition = self.transpile_proc.allocator.create(ast.Node) catch |e| {
            std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(condition);
        condition.* = condition_node.?;
        if (condition_node.?.type == .Expression) {
            condition.*.node_variant.?.exp.left = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(condition.*.node_variant.?.exp.left.?);
            condition.*.node_variant.?.exp.left.?.* = condition_node.?.node_variant.?.exp.left.?.*;
            condition.*.node_variant.?.exp.right = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(condition.*.node_variant.?.exp.right.?);
            condition.*.node_variant.?.exp.right.?.* = condition_node.?.node_variant.?.exp.right.?.*;
            condition.*.node_variant.?.exp.op = condition_node.?.node_variant.?.exp.op;
        }
        fit_node.node_variant.?.statement.fit_stmt.exp = condition;
        try self.parse_fit_body(&fit_node, &new_hist);
        self.transpile_proc.nodes.push(fit_node) catch |e| {
            std.debug.print("Error pushing node: {s}\n", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
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
    fn parse_import(self: *Self) ParseError!void {
        _ = self.token_next(); // skip imp
        const folder_token = self.token_next();
        if (folder_token.?.type != .Identifier) {
            self.transpile_proc.err("expected folder identifier, got '{?}'", .{folder_token.?.type});
            return ParseError.InvalidIdentifier;
        }

        const import_pos = folder_token.?.pos;

        var import_name = std.ArrayList(u8).init(self.transpile_proc.allocator);
        defer import_name.deinit();
        import_name.appendSlice(folder_token.?.data.sval.items) catch |e| {
            std.debug.print("Error appending to import_name: {s}\n", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };

        while (true) {
            const next_token = self.token_peek_next();
            if (next_token == null or next_token.?.type != .Operator or !utils.is_access_operator(next_token.?.data.sval.items)) {
                break; // Stop if there's no dot operator
            }

            _ = self.token_next(); // skip dot
            const part_token = self.token_next();
            if (part_token.?.type != .Identifier) {
                self.transpile_proc.err("expected identifier after '.', got '{?}'", .{part_token.?.type});
                return ParseError.InvalidIdentifier;
            }
            import_name.append('.') catch |e| {
                std.debug.print("Error appending to import_name: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            import_name.appendSlice(part_token.?.data.sval.items) catch |e| {
                std.debug.print("Error appending to import_name: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
        }

        try self.expect_sym(';');
        const path = import_name.toOwnedSlice() catch |e| {
            std.debug.print("Error converting import_name to OwnedSlice: {s}\n", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.free(path);

        const import_node = ast.Node{
            .type = .Import,
            .pos = import_pos,
            .node_variant = .{ .import = .{ .path = path } },
        };

        // Preload imported function names so identifier validation during parsing works.
        // Standard library imports are handled specially.
        if (!std.mem.startsWith(u8, path, "std.")) {
            try self.transpile_proc.preload_import_global_symbols(import_node, path);
        }

        self.transpile_proc.nodes.push(import_node) catch |e| {
            std.debug.print("Error pushing node: {s}\n", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };

        // Standard library imports may provide names (e.g. printf) that should be
        // usable in the current module, but must not participate in cross-module
        // duplicate detection.
        if (mem.eql(u8, path, "std.io")) {
            if (self.transpile_proc.get_symbol("printf") == null) {
                try self.transpile_proc.push_symbol(.{
                    .type = symbol.SymbolType.NativeFunction,
                    .name = "printf",
                    .data = null,
                    .symbol_table = null,
                });
            }
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
    /// - `hist (*utils.History)`: The history context for the parse operation.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    fn parse_keyword(self: *Self, hist: *utils.History) ParseError!void {
        const t = self.token_peek_next();
        const sval = t.?.data.sval.items;
        if (utils.keyword_is_datatype(sval)) {
            const dt = self.transpile_proc.allocator.create(dtype.DataType) catch |e| {
                std.debug.print("Error creating DataType: {}\n", .{e});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(dt);
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
        } else if (mem.eql(u8, "compound", sval)) {
            return try self.parse_compound();
        } else if (mem.eql(u8, "quirk", sval)) {
            return try self.parse_quirk();
        } else if (mem.eql(u8, "impl", sval)) {
            return try self.parse_impl();
        } else if (mem.eql(u8, "fun", sval)) {
            return try self.parse_function();
        } else if (mem.eql(u8, "for", sval)) {
            return try self.parse_for_statement(hist);
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
        } else if (mem.eql(u8, "break", sval)) {
            _ = self.token_next(); // skip break
            self.transpile_proc.nodes.push(ast.Node{ .type = .StatementBreak, .pos = t.?.pos }) catch |e| {
                std.debug.print("Error pushing node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            try self.expect_sym(';');
            return;
        } else if (mem.eql(u8, "continue", sval)) {
            _ = self.token_next(); // skip continue
            self.transpile_proc.nodes.push(ast.Node{ .type = .StatementContinue, .pos = t.?.pos }) catch |e| {
                std.debug.print("Error pushing node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            try self.expect_sym(';');
            return;
        } else if (mem.eql(u8, "true", sval)) {
            self.transpile_proc.nodes.push(ast.Node{
                .type = .Boolean,
                .pos = self.*.transpile_proc.*.pos,
                .node_variant = .{ .boolean = .{ .val = true } },
            }) catch |e| {
                std.debug.print("Error pushing node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            return;
        } else if (mem.eql(u8, "false", sval)) {
            self.transpile_proc.nodes.push(ast.Node{
                .type = .Boolean,
                .pos = self.*.transpile_proc.*.pos,
                .node_variant = .{ .boolean = .{ .val = false } },
            }) catch |e| {
                std.debug.print("Error pushing node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            return;
        }

        self.transpile_proc.err("invalid keyword", .{});
    }

    fn alloc_node_copy_shallow(self: *Self, node: ast.Node) ParseError!*ast.Node {
        const out = self.transpile_proc.allocator.create(ast.Node) catch |e| {
            std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(out);
        out.* = node;
        if (node.type == .Expression) {
            if (node.node_variant.?.exp.left) |left| {
                out.*.node_variant.?.exp.left = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                    std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(out.*.node_variant.?.exp.left.?);
                out.*.node_variant.?.exp.left.?.* = left.*;
            }
            if (node.node_variant.?.exp.right) |right| {
                out.*.node_variant.?.exp.right = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                    std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(out.*.node_variant.?.exp.right.?);
                out.*.node_variant.?.exp.right.?.* = right.*;
            }
            out.*.node_variant.?.exp.op = node.node_variant.?.exp.op;
        }
        return out;
    }

    fn push_loop_scope_entity(self: *Self, entity: *scope.ScopeEntity) ParseError!void {
        if (self.transpile_proc.get_scope_entity(entity.name) != null) {
            self.transpile_proc.err("variable '{s}' already declared", .{entity.name});
            return ParseError.VariableAlreadyDeclared;
        }
        self.transpile_proc.push_scope_entity(entity) catch |e| {
            std.debug.print("Error pushing scope entity: {s}\n", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
    }

    fn parse_for_statement(self: *Self, hist: *utils.History) ParseError!void {
        const for_token = self.token_peek_next();
        try self.expect_keyword("for");
        if (self.parser_current_function == null) {
            self.transpile_proc.err("for statement outside of function", .{});
            return ParseError.InvalidStatement;
        }

        const first = self.token_next();
        if (first == null or first.?.type != .Identifier) {
            self.transpile_proc.err("expected identifier after 'for'", .{});
            return ParseError.InvalidIdentifier;
        }

        var index_name: ?[]const u8 = null;
        var item_name: []const u8 = first.?.data.sval.items;
        var used_double_colon = false;

        if (self.next_token_is_operator(",")) {
            index_name = item_name;
            _ = self.token_next(); // skip ,
            const second = self.token_next();
            if (second == null or second.?.type != .Identifier) {
                self.transpile_proc.err("expected identifier after ',' in for loop", .{});
                return ParseError.InvalidIdentifier;
            }
            item_name = second.?.data.sval.items;
            try self.expect_op("::");
            used_double_colon = true;
        } else {
            try self.expect_op(":");
        }

        try self.parse_expressionable_root(hist);
        const iterable_node = self.node_pop().?;

        // Parse body in a loop scope (so loop variables are valid identifiers).
        _ = try self.transpile_proc.new_scope();

        var index_entity: ?scope.ScopeEntity = null;
        var item_entity: ?scope.ScopeEntity = null;

        if (iterable_node.type == .Expression and std.mem.eql(u8, iterable_node.node_variant.?.exp.op, "..")) {
            if (used_double_colon) {
                self.transpile_proc.err("range for loop does not support 'i, item ::' form", .{});
                return ParseError.InvalidStatement;
            }
            item_entity = .{ .flags = .{ .on_stack = true }, .node = null, .name = item_name };
            try self.push_loop_scope_entity(&item_entity.?);
        } else {
            // For now, iterable for-loops require an identifier (array variable).
            if (iterable_node.type != .Identifier) {
                self.transpile_proc.err("for-each loops currently require an array identifier", .{});
                return ParseError.InvalidExpression;
            }
            if (index_name) |iname| {
                index_entity = .{ .flags = .{ .on_stack = true }, .node = null, .name = iname };
                try self.push_loop_scope_entity(&index_entity.?);
            }
            item_entity = .{ .flags = .{ .on_stack = true }, .node = null, .name = item_name };
            try self.push_loop_scope_entity(&item_entity.?);
        }

        try self.parse_body_multiple_statements(hist);
        self.transpile_proc.finish_scope();
        const body_node = self.node_pop().?;

        // Transfer ownership of the already-allocated AST subtrees into the for-statement.
        const body_ptr = self.transpile_proc.allocator.create(ast.Node) catch |e| {
            std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(body_ptr);
        body_ptr.* = body_node;

        var for_node = ast.Node{ .type = .StatementFor, .pos = if (for_token) |t| t.pos else null };
        if (iterable_node.type == .Expression and std.mem.eql(u8, iterable_node.node_variant.?.exp.op, "..")) {
            const range_ptr = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(range_ptr);
            range_ptr.* = iterable_node;
            for_node.node_variant = .{ .statement = .{ .for_stmt = .{ .range = .{ .index_name = item_name, .range = range_ptr, .body = body_ptr } } } };
        } else {
            const iterable_ptr = self.transpile_proc.allocator.create(ast.Node) catch |e| {
                std.debug.print("Error creating node: {s}\n", .{@errorName(e)});
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(iterable_ptr);
            iterable_ptr.* = iterable_node;
            for_node.node_variant = .{ .statement = .{ .for_stmt = .{ .iter = .{ .index_name = index_name, .item_name = item_name, .iterable = iterable_ptr, .body = body_ptr } } } };
        }

        try self.create_node(&for_node);
    }

    /// Parses a global keyword token.
    ///
    /// This function initializes a `History` instance with global scope
    /// and calls the `parse_keyword` function to handle the keyword parsing.
    ///
    /// Errors:
    /// - Returns an error if initializing the history or parsing the keyword fails.
    fn parse_global_keyword(self: *Self) ParseError!void {
        var hist = utils.History.init(
            self.transpile_proc.allocator,
            .{ .is_global_scope = true },
        );
        defer hist.deinit();

        try self.parse_keyword(&hist);
        const n = self.node_pop();
        if (n.?.type != .Function) {
            try self.transpile_proc.register_global_node_symbol(n.?);
        }
        self.transpile_proc.nodes.push(n.?) catch |e| {
            std.debug.print("Error pushing node: {s}\n", .{@errorName(e)});
            return ParseError.MemoryAllocationFailed;
        };
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
    fn next(self: *Self) ParseError!bool {
        const t = self.token_peek_next();
        if (t == null) {
            return false;
        }
        try switch (t.?.type) {
            .Number, .Identifier, .String => {
                var hist = utils.History.init(self.transpile_proc.allocator, .{});
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
    pub fn parse(self: *Self) ParseError!void {
        _ = try self.transpile_proc.init_root_scope();
        defer self.transpile_proc.deinit_root_scope();
        while (try self.next()) {}
    }
};
