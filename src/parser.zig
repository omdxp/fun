const std = @import("std");
const mem = std.mem;
const transpiler = @import("./transpiler.zig");
const token = @import("./token.zig");
const ast = @import("./ast.zig");
const misc = @import("./misc.zig");
const history = @import("./history.zig");

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
    fn next_token_is_symbol(self: *Self, c: u8) bool {
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
        if (self.next_token_is_symbol('{')) {
            // TODO: parse body
            const body_node = self.node_pop();
            try self.transpile_proc.nodes.push(body_node.?);
        }
        self.transpile_proc.error_message("invalid symbol");
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
    fn parse_keyword(self: *Self, _: *history.History) !void {
        const t = try self.token_peek_next();
        const sval = t.?.data.sval.items;
        if (misc.keyword_is_datatype(sval)) {
            // TODO: parse variable
            return;
        }

        if (mem.eql(u8, "imp", sval)) {
            // TODO: parse imp keyword
            return;
        } else if (mem.eql(u8, "fun", sval)) {
            // TODO: parse fun keyword
            return;
        } else if (mem.eql(u8, "if", sval)) {
            // TODO: parse if keyword
            return;
        } else if (mem.eql(u8, "fit", sval)) {
            // TODO: parse fit keyword
            return;
        } else if (mem.eql(u8, "ret", sval)) {
            // TODO: parse ret keyword
            return;
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
