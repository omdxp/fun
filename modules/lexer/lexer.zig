const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const codegen = @import("codegen");
const TranspileError = codegen.TranspileError;
const utils = @import("utils");
pub const token = @import("token.zig");

/// Errors that can occur during lexical analysis process.
pub const LexError = error{
    /// Error indicating invalid operator.
    InvalidOperator,
    /// Error indicating invalid number.
    InvalidNumber,
    /// Error indicating invalid expression.
    InvalidExpression,
    /// Error indicating invalid character.
    InvalidCharacter,
} || TranspileError;

/// `LexProcess` represents the state and configuration of a lexical analysis process.
pub const LexProcess = struct {
    /// `transpile_proc` is a pointer to the associated transpilation process.
    transpile_proc: *codegen.TranspileProcess,
    /// `curr_exp_count` is the current expression count.
    curr_exp_count: isize,
    /// `parenthesis_buf` is a buffer for storing parenthesis characters.
    parenthesis_buf: ?std.ArrayList(u8) = null,
    /// `arg_str_buf` is a buffer for storing argument strings.
    arg_str_buf: ?std.ArrayList(u8) = null,

    const Self = @This();

    /// Initializes a new instance of `LexProcess`.
    ///
    /// This function initializes the token list with the provided allocator and sets up
    /// the lexical analysis process with the given transpilation process.
    ///
    /// Parameters:
    /// - `allocator`: The memory allocator to use for memory allocation operations.
    /// - `transpile_proc`: A pointer to the associated transpilation process.
    ///
    /// Returns:
    /// - `Self`: A new instance of `LexProcess`.
    pub fn init(transpile_proc: *codegen.TranspileProcess) Self {
        return Self{
            .transpile_proc = transpile_proc,
            .curr_exp_count = 0,
        };
    }

    /// Reads the next character from the input file.
    ///
    /// This function reads the next character from the input file associated with the
    /// transpilation process and updates the current position. If the character is a newline,
    /// it also updates the line and column numbers.
    ///
    /// Returns:
    /// - `?u8`: The next character read from the input file, or `null` if the end of the file is reached.
    ///
    /// Errors:
    /// - Returns an error if reading from the input file fails.
    pub fn next_char(self: *Self) LexError!?u8 {
        var buffer: [1]u8 = undefined;
        const readBytes = self.transpile_proc.ifile.read(buffer[0..]) catch |e| {
            if (e == fs.File.ReadError.Unexpected) {
                return null;
            }
            std.debug.print("Error reading from file: {s}\n", .{@errorName(e)});
            return LexError.FileReadError;
        };
        if (readBytes == 0) {
            return null;
        }

        const c = buffer[0];

        // Advance cursor after reading a character.
        if (c == '\n') {
            self.transpile_proc.pos.line += 1;
            self.transpile_proc.pos.col = 1;
        } else {
            self.transpile_proc.pos.col += 1;
        }

        if (self.in_expression()) {
            self.parenthesis_buf.?.append(c) catch |e| {
                std.debug.print("Error appending to parenthesis buffer: {s}\n", .{@errorName(e)});
                return LexError.MemoryAllocationFailed;
            };
            if (self.arg_str_buf != null) {
                self.arg_str_buf.?.append(c) catch |e| {
                    std.debug.print("Error appending to argument string buffer: {s}\n", .{@errorName(e)});
                    return LexError.MemoryAllocationFailed;
                };
            }
        }

        return c;
    }

    /// Peeks at the next character in the input file without advancing the position.
    ///
    /// This function reads the next character from the input file associated with the
    /// transpilation process and then seeks back to the original position.
    ///
    /// Returns:
    /// - `?u8`: The next character in the input file, or `null` if the end of the file is reached.
    ///
    /// Errors:
    /// - Returns an error if reading from or seeking in the input file fails.
    pub fn peek_char(self: *Self) LexError!?u8 {
        const pos = self.transpile_proc.ifile.seekableStream().getPos() catch |e| {
            std.debug.print("Error getting position: {s}\n", .{@errorName(e)});
            return LexError.FileSeekError;
        };
        var buffer: [1]u8 = undefined;
        const readBytes = self.transpile_proc.ifile.read(buffer[0..]) catch |e| {
            if (e == fs.File.ReadError.Unexpected) {
                return null;
            }
            std.debug.print("Error reading from file: {s}\n", .{@errorName(e)});
            return LexError.FileReadError;
        };
        self.transpile_proc.ifile.seekTo(pos) catch |e| {
            std.debug.print("Error seeking in file: {s}\n", .{@errorName(e)});
            return LexError.FileSeekError;
        };
        return if (readBytes == 0) null else buffer[0];
    }

    /// Pushes a character back onto the input file stream.
    ///
    /// This function pushes the given character back onto the input file stream,
    /// effectively making it the next character to be read.
    ///
    /// Parameters:
    /// - `c`: The character to push back onto the input file stream.
    ///
    /// Errors:
    /// - Returns an error if seeking or writing to the input file fails.
    pub fn push_char(self: *Self, c: u8) LexError!void {
        const pos = self.transpile_proc.ifile.seekableStream().getPos() catch |e| {
            std.debug.print("Error getting position: {s}\n", .{@errorName(e)});
            return LexError.FileSeekError;
        };
        self.transpile_proc.ifile.seekTo(pos - 1) catch |e| {
            std.debug.print("Error seeking in file: {s}\n", .{@errorName(e)});
            return LexError.FileSeekError;
        };

        // IMPORTANT: do not write back into the user's source file.
        // `push_char` is meant to implement a simple "unread" for lookahead.
        // We only need to rewind the file cursor and update our tracked column.
        if (c == '\n') {
            // We currently never push back newlines. If that changes, we'd need
            // a way to restore the previous line length.
            self.transpile_proc.err("internal lexer error: attempted to push back newline", .{});
            return LexError.InvalidExpression;
        }
        if (self.transpile_proc.pos.col > 1) {
            self.transpile_proc.pos.col -= 1;
        }
    }

    /// Reads characters from the input file based on a given condition.
    ///
    /// This function reads characters from the input file and appends them to the
    /// specified buffer until the given condition is no longer met.
    ///
    /// Parameters:
    /// - `buffer`: The buffer to store the read characters.
    /// - `exp`: A function that defines the condition to be met for reading characters.
    ///
    /// Errors:
    /// - Returns an error if reading from the input file fails.
    fn getc_if(self: *Self, buffer: *std.ArrayList(u8), exp: fn (u8) bool) LexError!void {
        while (true) {
            const c = try self.peek_char();
            if (c == null or !exp(c.?)) break;
            buffer.append(c.?) catch |e| {
                std.debug.print("Error appending to buffer: {s}\n", .{@errorName(e)});
                return LexError.MemoryAllocationFailed;
            };
            _ = try self.next_char();
        }
    }

    /// Creates a comment token from the input file.
    ///
    /// This function reads characters from the input file to create a comment token.
    ///
    /// Returns:
    /// - `token.Token`: A new comment token.
    ///
    /// Errors:
    /// - Returns an error if reading from the input file fails.
    fn token_make_comment(self: *Self) LexError!token.Token {
        var buffer = std.ArrayList(u8).init(self.transpile_proc.allocator);
        try self.getc_if(&buffer, struct {
            fn call(_c: u8) bool {
                return _c != '\n' and _c != '\r';
            }
        }.call);

        return token.Token{
            .type = .Comment,
            .data = .{
                .sval = buffer,
            },
            .pos = self.transpile_proc.pos,
        };
    }

    /// Handles comment tokens in the input file.
    ///
    /// This function checks for comment tokens in the input file and processes them.
    ///
    /// Returns:
    /// - `!?token.Token`: A comment token if one is found, otherwise `null`.
    ///
    /// Errors:
    /// - Returns an error if reading from the input file fails.
    fn handle_comment(self: *Self) LexError!?token.Token {
        const c = try self.peek_char();
        if (c == '/') {
            _ = try self.next_char();
            if (try self.peek_char() == '/') {
                _ = try self.next_char();
                return try self.token_make_comment();
            }
            try self.push_char('/');
            return try self.token_make_operator();
        }

        return null;
    }

    /// Handles whitespace characters in the input file.
    ///
    /// This function processes whitespace characters by setting the `whitespace`
    /// property of the last token to `true` and then reading the next character.
    ///
    /// Returns:
    /// - `?token.Token`: The next token after handling whitespace, or `null` if no
    ///   more tokens are available.
    ///
    /// Errors:
    /// - Returns an error if reading the next character fails.
    fn handle_whitespace(self: *Self) LexError!?token.Token {
        var last_token = self.transpile_proc.tokens.back();
        if (last_token != null) {
            _ = self.transpile_proc.tokens.pop();
            last_token.?.whitespace = true;
            self.transpile_proc.tokens.push(last_token.?) catch |e| {
                std.debug.print("Error pushing token: {s}\n", .{@errorName(e)});
                return LexError.MemoryAllocationFailed;
            };
        }

        _ = try self.next_char();
        return self.read_next_token();
    }

    /// Creates a newline token from the input file.
    ///
    /// This function reads a newline character from the input file to create a newline token.
    ///
    /// Returns:
    /// - `token.Token`: A new newline token.
    ///
    /// Errors:
    /// - Returns an error if reading from the input file fails.
    fn token_make_newline(self: *Self) LexError!token.Token {
        _ = try self.next_char();
        return token.Token{
            .type = .NewLine,
            .data = .{ .cval = '\n' },
            .pos = self.transpile_proc.pos,
        };
    }

    /// Creates an identifier or keyword token from the input file.
    ///
    /// This function reads characters from the input file and appends them to a buffer
    /// until a non-alphanumeric character, digit, or underscore is encountered.
    /// It then checks if the collected characters form a keyword or an identifier and
    /// returns the corresponding token.
    ///
    /// Returns:
    /// - `!?token.Token`: The next token as either a keyword or an identifier, or `null` if no
    ///   valid token is found.
    ///
    /// Errors:
    /// - Returns an error if reading characters or allocating memory fails.
    fn token_make_identifier_or_keyword(self: *Self) LexError!?token.Token {
        var buffer = std.ArrayList(u8).init(self.transpile_proc.allocator);
        try self.getc_if(&buffer, struct {
            fn call(_c: u8) bool {
                return utils.is_alpha(_c) or utils.is_number(_c) or _c == '_';
            }
        }.call);

        if (utils.is_boolean_keyword(buffer.items)) {
            const bval = if (mem.eql(u8, "true", buffer.items)) true else false;
            buffer.deinit();
            return token.Token{
                .type = .Boolean,
                .data = .{ .bval = bval },
                .pos = self.transpile_proc.pos,
            };
        } else if (utils.is_keyword(buffer.items)) {
            return token.Token{
                .type = .Keyword,
                .data = .{ .sval = buffer },
                .pos = self.transpile_proc.pos,
            };
        }

        return token.Token{
            .type = .Identifier,
            .data = .{ .sval = buffer },
            .pos = self.transpile_proc.pos,
        };
    }

    /// Reads a special token from the input file.
    ///
    /// This function reads the next character from the input file and checks if it is
    /// an alphabetic character or an underscore. If it is, the function attempts to
    /// create an identifier or keyword token.
    ///
    /// Returns:
    /// - `!?token.Token`: The next token if the character is a valid special token, otherwise `null`.
    ///
    /// Errors:
    /// - Returns an error if reading the next character fails.
    fn read_special_token(self: *Self) LexError!?token.Token {
        const c = try self.peek_char();
        if (utils.is_alpha(c.?) or c.? == '_') {
            return self.token_make_identifier_or_keyword();
        }

        return null;
    }

    /// Reads a numeric string from the input file.
    ///
    /// This function reads characters from the input file that are considered numeric
    /// and stores them in a buffer.
    ///
    /// Returns:
    /// - `!std.ArrayList(u8)`: The buffer containing the numeric string.
    ///
    /// Errors:
    /// - Returns an error if reading characters or allocating the buffer fails.
    fn read_number_str(self: *Self) LexError!std.ArrayList(u8) {
        var buffer = std.ArrayList(u8).init(self.transpile_proc.allocator);
        try self.getc_if(&buffer, struct {
            fn call(_c: u8) bool {
                return utils.is_number(_c);
            }
        }.call);

        return buffer;
    }

    /// Parses a numeric string from the input file into a `c_longlong`.
    ///
    /// This function reads a numeric string from the input file and converts it into a `c_longlong`.
    ///
    /// Returns:
    /// - `!c_longlong`: The parsed number.
    ///
    /// Errors:
    /// - Returns an error if reading the numeric string or parsing the number fails.
    fn read_number(self: *Self) LexError!c_longlong {
        const s = try self.read_number_str();
        defer s.deinit();

        const number: c_longlong = std.fmt.parseInt(c_longlong, s.items, 10) catch {
            self.transpile_proc.err("failed to parse number '{s}'", .{s.items});
            return LexError.InvalidNumber;
        };
        return number;
    }

    /// Determines the type of number based on a character.
    ///
    /// This function checks the character to determine if it indicates a long integer or float.
    ///
    /// Returns:
    /// - `token.NumberType`: The determined number type.
    ///
    /// Parameters:
    /// - `c (u8)`: The character to check.
    fn number_type(_: *Self, c: u8) token.NumberType {
        return switch (c) {
            'L' => .Long,
            'f' => .Float,
            else => .Normal,
        };
    }

    /// Creates a number token for a given value.
    ///
    /// This function creates a number token based on the given numeric value and its type.
    ///
    /// Returns:
    /// - `!?token.Token`: The created number token, or `null` if creation fails.
    ///
    /// Errors:
    /// - Returns an error if reading the next character fails.
    ///
    /// Parameters:
    /// - `num (c_longlong)`: The numeric value to be tokenized.
    fn token_make_number_for_value(self: *Self, num: c_longlong) LexError!?token.Token {
        const pc = try self.peek_char();
        const num_type = if (pc != null) self.number_type(pc.?) else .Normal;
        if (num_type != .Normal) {
            _ = try self.next_char();
        }

        return token.Token{
            .type = .Number,
            .data = .{ .llnum = num },
            .num = .{ .type = num_type },
            .pos = self.transpile_proc.pos,
        };
    }

    /// Creates a number token from the input file.
    ///
    /// This function reads a number from the input file and creates a number token.
    ///
    /// Returns:
    /// - `!?token.Token`: The created number token, or `null` if creation fails.
    ///
    /// Errors:
    /// - Returns an error if reading the number or next character fails.
    fn token_make_number(self: *Self) LexError!?token.Token {
        return self.token_make_number_for_value(try self.read_number());
    }

    /// Starts a new expression context.
    ///
    /// This function increments the current expression count. If this is the first expression,
    /// it initializes the parenthesis buffer. Additionally, if the last token is an identifier
    /// or a comma operator, it initializes the argument string buffer.
    ///
    /// Parameters:
    /// - `self (*Self)`: The pointer to the current instance.
    fn start_expression(self: *Self) void {
        self.curr_exp_count += 1;
        if (self.curr_exp_count == 1) {
            self.parenthesis_buf = std.ArrayList(u8).init(self.transpile_proc.allocator);
        }

        const t = self.transpile_proc.tokens.back();
        if (t != null and (t.?.type == .Identifier or token.is_operator(t, ","))) {
            self.arg_str_buf = std.ArrayList(u8).init(self.transpile_proc.allocator);
        }
    }

    /// Checks if currently inside an expression.
    ///
    /// This function returns `true` if the current expression count is greater than zero,
    /// indicating that the process is currently inside an expression.
    ///
    /// Returns:
    /// - `bool`: `true` if the current expression count is greater than zero, otherwise `false`.
    fn in_expression(self: *Self) bool {
        return self.curr_exp_count > 0;
    }

    /// Finishes the current expression.
    ///
    /// This function decrements the current expression count. If the expression count
    /// goes below zero, it logs an error message indicating that an expression was closed
    /// without being opened.
    ///
    /// Errors:
    /// - Logs an error message if the expression count goes below zero.
    fn finish_expression(self: *Self) LexError!void {
        self.curr_exp_count -= 1;
        if (self.curr_exp_count < 0) {
            self.transpile_proc.err("expression was never opened", .{});
            return LexError.InvalidExpression;
        }
    }

    /// Creates a symbol token from the input file.
    ///
    /// This function reads the next character from the input file and creates a symbol token.
    ///
    /// Returns:
    /// - `!?token.Token`: The created symbol token, or `null` if creation fails.
    ///
    /// Errors:
    /// - Returns an error if reading the next character fails.
    fn token_make_symbol(self: *Self) LexError!?token.Token {
        const c = try self.peek_char();
        if (c.? == ')') {
            try self.finish_expression();
        }

        _ = try self.next_char();
        return token.Token{
            .type = .Symbol,
            .data = .{ .cval = c.? },
            .pos = self.transpile_proc.pos,
        };
    }

    /// Pushes back all but the first character in the buffer to the input file.
    ///
    /// This function pushes back all characters in the buffer except for the first one
    /// to the input file.
    ///
    /// Errors:
    /// - Returns an error if pushing a character back to the input file fails.
    ///
    /// Parameters:
    /// - `buffer (*std.ArrayList(u8))`: The buffer containing the characters to be pushed back.
    fn read_op_flush_back_keep_first(self: *Self, buffer: *std.ArrayList(u8)) LexError!void {
        var i = buffer.items.len - 1;
        while (i > 0) {
            _ = try self.push_char(buffer.items[i]);
            i -= 1;
        }
    }

    /// Reads an operator from the input file.
    ///
    /// This function reads an operator from the input file, handling different operator types
    /// and validating them.
    ///
    /// Returns:
    /// - `!std.ArrayList(u8)`: The buffer containing the operator string.
    ///
    /// Errors:
    /// - Returns an error if reading characters or validating the operator fails.
    fn read_op(self: *Self) LexError!std.ArrayList(u8) {
        var buffer = std.ArrayList(u8).init(self.transpile_proc.allocator);
        var single_operator = true;
        var op = try self.next_char();
        buffer.append(op.?) catch |e| {
            std.debug.print("Error appending to buffer: {s}\n", .{@errorName(e)});
            return LexError.MemoryAllocationFailed;
        };
        var pc = try self.peek_char();
        if (op.? == '*' and pc.? == '=') {
            pc = try self.peek_char();
            buffer.append(pc.?) catch |e| {
                std.debug.print("Error appending to buffer: {s}\n", .{@errorName(e)});
                return LexError.MemoryAllocationFailed;
            };
            _ = try self.next_char();
            single_operator = false;
        } else if (!utils.op_treated_as_one(op.?)) {
            for (0..2) |_| {
                op = try self.peek_char();
                if (utils.is_single_operator(op.?)) {
                    buffer.append(op.?) catch |e| {
                        std.debug.print("Error appending to buffer: {s}\n", .{@errorName(e)});
                        return LexError.MemoryAllocationFailed;
                    };
                    _ = try self.next_char();
                    single_operator = false;
                }
            }
        }

        if (!single_operator) {
            if (!utils.op_valid(buffer.items)) {
                try self.read_op_flush_back_keep_first(&buffer);
            }
        } else if (!utils.op_valid(buffer.items)) {
            self.transpile_proc.err("operator '{?}' not valid", .{op});
            return LexError.InvalidOperator;
        }

        return buffer;
    }

    /// Creates an operator token from the input file.
    ///
    /// This function reads an operator from the input file and creates an operator token.
    ///
    /// Returns:
    /// - `!token.Token`: The created operator token.
    ///
    /// Errors:
    /// - Returns an error if reading the operator or creating the token fails.
    fn token_make_operator(self: *Self) LexError!token.Token {
        const op = try self.peek_char();
        const sval = try self.read_op();
        const t = token.Token{
            .type = .Operator,
            .data = .{ .sval = sval },
            .pos = self.transpile_proc.pos,
        };

        if (op.? == '(') {
            self.start_expression();
        }

        return t;
    }

    /// Validates a binary string.
    ///
    /// This function checks if the given string contains only valid binary digits ('0' and '1').
    ///
    /// Errors:
    /// - Logs an error message if the string contains invalid binary digits.
    ///
    /// Parameters:
    /// - `str ([]const u8)`: The binary string to validate.
    fn validate_binary_string(self: *Self, str: []const u8) void {
        for (str) |c| {
            if (c != '1' and c != '0') {
                self.transpile_proc.err("invalid binary number", .{});
            }
        }
    }

    /// Creates a special number token from a binary string.
    ///
    /// This function reads a binary string from the input file, validates it, and creates
    /// a token representing the binary number.
    ///
    /// Returns:
    /// - `!token.Token`: The created binary number token.
    ///
    /// Errors:
    /// - Returns an error if reading the binary string or parsing the number fails.
    fn token_make_special_number_binary(self: *Self) LexError!?token.Token {
        _ = try self.next_char(); // skip special character 'b'
        const number_str = try self.read_number_str();
        defer number_str.deinit();
        self.validate_binary_string(number_str.items);
        const number: c_longlong = std.fmt.parseInt(c_longlong, number_str.items, 2) catch {
            self.transpile_proc.err("failed to parse number '{s}'", .{number_str.items});
            return LexError.InvalidNumber;
        };

        return self.token_make_number_for_value(number);
    }

    /// Reads a hexadecimal string from the input file.
    ///
    /// This function reads characters from the input file that are considered valid hexadecimal digits
    /// and stores them in a buffer.
    ///
    /// Returns:
    /// - `!std.ArrayList(u8)`: The buffer containing the hexadecimal string.
    ///
    /// Errors:
    /// - Returns an error if reading characters or allocating the buffer fails.
    fn read_hex_number_str(self: *Self) LexError!std.ArrayList(u8) {
        var buffer = std.ArrayList(u8).init(self.transpile_proc.allocator);
        try self.getc_if(&buffer, struct {
            fn call(_c: u8) bool {
                return utils.is_hex_number(_c);
            }
        }.call);

        return buffer;
    }

    /// Creates a hexadecimal number token.
    ///
    /// This function reads a hexadecimal string from the input file, converts it to a number,
    /// and creates a token representing the hexadecimal number.
    ///
    /// Returns:
    /// - `!?token.Token`: The created hexadecimal number token.
    ///
    /// Errors:
    /// - Returns an error if reading the hexadecimal string or parsing the number fails.
    fn token_make_number_hexadecimal(self: *Self) LexError!?token.Token {
        _ = try self.next_char(); // skip special character 'x'
        const number_str = try self.read_hex_number_str();
        const number: c_longlong = std.fmt.parseInt(c_longlong, number_str.items, 16) catch {
            self.transpile_proc.err("failed to parse number '{s}'", .{number_str.items});
            return LexError.InvalidNumber;
        };

        return self.token_make_number_for_value(number);
    }

    /// Creates a special number token based on a prefix.
    ///
    /// This function reads the special number prefix ('b' or 'x'), determines the number type,
    /// and creates the appropriate number token.
    ///
    /// Returns:
    /// - `!?token.Token`: The created special number token.
    ///
    /// Errors:
    /// - Returns an error if reading the prefix, creating the identifier or keyword token,
    ///   or creating the special number token fails.
    fn token_make_special_number(self: *Self) LexError!?token.Token {
        var t: ?token.Token = null;
        const last_token = self.transpile_proc.tokens.back();
        if (last_token == null or !(last_token.?.type == .Number and last_token.?.data.llnum == 0)) {
            return try self.token_make_identifier_or_keyword();
        }

        _ = self.transpile_proc.tokens.pop(); // popping the first 0 (.eg [0]b0001)
        const c = try self.peek_char();
        switch (c.?) {
            'b' => t = try self.token_make_special_number_binary(),
            'x' => t = try self.token_make_number_hexadecimal(),
            else => {
                self.transpile_proc.err("character '{c}' not valid for special numbers", .{c.?});
                return LexError.InvalidNumber;
            },
        }

        return t;
    }

    /// Handles an escape sequence representing a number and appends it to the buffer.
    ///
    /// This function reads a number from the input file, validates that it is within the
    /// range of 0 to 255, and appends it to the buffer.
    ///
    /// Parameters:
    /// - `buf (*std.ArrayList(u8))`: The buffer to append the number to.
    ///
    /// Errors:
    /// - Returns an error if reading the number or appending to the buffer fails.
    /// - Logs an error message if the number is outside the valid range (0 to 255).
    fn handle_escape_number(self: *Self, buf: *std.ArrayList(u8)) LexError!void {
        const num = try self.read_number();
        if (num > 255) {
            self.transpile_proc.err("characters must be between 0 and 255, got '{}'", .{num});
            return LexError.InvalidNumber;
        }

        buf.append(@intCast(num)) catch |e| {
            std.debug.print("Error appending to buffer: {s}\n", .{@errorName(e)});
            return LexError.MemoryAllocationFailed;
        };
    }

    /// Handles an escape sequence and appends the corresponding character to the buffer.
    ///
    /// This function checks if the escape sequence represents a number or a special character
    /// and appends the corresponding character to the buffer.
    ///
    /// Parameters:
    /// - `buf (*std.ArrayList(u8))`: The buffer to append the character to.
    ///
    /// Errors:
    /// - Returns an error if reading the next character or appending to the buffer fails.
    fn handle_escape(self: *Self, buf: *std.ArrayList(u8)) LexError!void {
        const c = try self.peek_char();
        if (utils.is_number(c.?)) {
            try self.handle_escape_number(buf);
            return;
        }

        const ec = utils.get_escape_char(c.?);
        buf.append(ec) catch |e| {
            std.debug.print("Error appending to buffer: {s}\n", .{@errorName(e)});
            return LexError.MemoryAllocationFailed;
        };
        _ = try self.next_char();
    }

    /// Creates a string token from the input file.
    ///
    /// This function reads characters from the input file until it encounters a closing quote (`"`),
    /// handling escape sequences, and creates a string token.
    ///
    /// Returns:
    /// - `!?token.Token`: The created string token, or `null` if creation fails.
    ///
    /// Errors:
    /// - Returns an error if reading characters or appending to the buffer fails.
    /// - Logs an error message if the end of file is reached unexpectedly.
    fn token_make_string(self: *Self) LexError!?token.Token {
        var buffer = std.ArrayList(u8).init(self.transpile_proc.allocator);
        _ = try self.next_char(); // skip '"'
        while (true) {
            const c = try self.next_char();
            if (c == null) {
                self.transpile_proc.err("unexpected end of file while reading string", .{});
                return LexError.FileReadError;
            }

            if (c.? == '"') {
                break;
            }

            // if (c.? == '\\') {
            //     try self.handle_escape(&buffer);
            // } else {
            buffer.append(c.?) catch |e| {
                std.debug.print("Error appending to buffer: {s}\n", .{@errorName(e)});
                return LexError.MemoryAllocationFailed;
            };
            // }
        }

        return token.Token{
            .type = .String,
            .data = .{ .sval = buffer },
            .pos = self.transpile_proc.pos,
        };
    }

    /// Creates a character token from the input file.
    ///
    /// This function reads characters from the input file to form a character token.
    /// It handles escape sequences and validates the format of the character literal.
    ///
    /// Returns:
    /// - `!?token.Token`: The created character token, or `null` if creation fails.
    ///
    /// Errors:
    /// - Returns an error if reading the next character fails or if the character format is invalid.
    /// - Logs an error message if the closing single quote (`'`) is missing.
    ///
    /// Parameters:
    /// - `self (*Self)`: The pointer to the current instance.
    fn token_make_character(self: *Self) LexError!?token.Token {
        _ = try self.next_char(); // skip "'"
        var c = try self.next_char();
        if (c.? == '\\') {
            c = try self.next_char();
            c = utils.get_escape_char(c.?);
        }

        const nc = try self.next_char();
        if (nc.? != '\'') {
            self.transpile_proc.err("expected ' got '{c}'", .{nc.?});
            return LexError.InvalidCharacter;
        }

        return token.Token{
            .type = .Number,
            .data = .{ .cval = c.? },
            .pos = self.transpile_proc.pos,
        };
    }

    /// Reads the next token from the input file.
    ///
    /// This function reads the next token from the input file, handling different token types
    /// such as comments and newlines.
    ///
    /// Returns:
    /// - `!?token.Token`: The next token if one is found, otherwise `null`.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    fn read_next_token(self: *Self) LexError!?token.Token {
        const start_line = self.transpile_proc.pos.line;
        const start_col = self.transpile_proc.pos.col;

        var t = try self.handle_comment();
        if (t != null) {
            t.?.pos.line = start_line;
            t.?.pos.col = start_col;
            t.?.pos.start_col = start_col;
            t.?.pos.end_line = self.transpile_proc.pos.line;
            t.?.pos.end_col = self.transpile_proc.pos.col;
            return t;
        }

        const c = try self.peek_char();
        if (c == null) {
            return t;
        }

        switch (c.?) {
            '"' => t = try self.token_make_string(),
            '\'' => t = try self.token_make_character(),
            '+', '-', '*', '>', '<', '^', '%', '!', '=', '~', '|', '&', '(', '[', ',', '.' => t = try self.token_make_operator(),
            '{', '}', ';', ')', ']' => t = try self.token_make_symbol(),
            '0'...'9' => t = try self.token_make_number(),
            'b', 'x' => t = try self.token_make_special_number(),
            '\n' => t = try self.token_make_newline(),
            ' ', '\t', '\r' => t = try self.handle_whitespace(),
            else => {
                t = try self.read_special_token();
                if (t == null) {
                    self.transpile_proc.err("unexpected token '{c}'", .{c.?});
                    return LexError.InvalidCharacter;
                }
            },
        }

        if (t != null) {
            t.?.pos.line = start_line;
            t.?.pos.col = start_col;
            t.?.pos.start_col = start_col;
            t.?.pos.end_line = self.transpile_proc.pos.line;
            t.?.pos.end_col = self.transpile_proc.pos.col;
        }

        self.transpile_proc.current_token = t;
        return t;
    }

    /// Lexes the input and appends tokens to the `tokens` array.
    ///
    /// This function reads tokens from the input using `read_next_token` and appends
    /// them to the `tokens` array until no more tokens are available.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    pub fn lex(self: *Self) LexError!void {
        var t = try self.read_next_token();
        while (t != null) {
            self.transpile_proc.tokens.push(t.?) catch |e| {
                std.debug.print("Error pushing token: {s}\n", .{@errorName(e)});
                return LexError.MemoryAllocationFailed;
            };
            t = try self.read_next_token();
        }
    }

    /// Deinitializes the current instance.
    ///
    /// This function deinitializes the current instance by:
    /// - Deinitializing the parenthesis buffer if it is not null.
    /// - Deinitializing the argument string buffer if it is not null.
    ///
    /// Parameters:
    /// - `self (Self)`: The current instance to deinitialize.
    pub fn deinit(self: Self) void {
        if (self.parenthesis_buf != null) self.parenthesis_buf.?.deinit();
        if (self.arg_str_buf != null) self.arg_str_buf.?.deinit();
    }
};
