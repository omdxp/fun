const std = @import("std");
const mem = std.mem;
const token = @import("./token.zig");
const transpiler = @import("./transpiler.zig");
const main = @import("./main.zig");
const misc = @import("./misc.zig");

/// `LexProcess` represents the state and configuration of a lexical analysis process.
pub const LexProcess = struct {
    /// `tokens` is a list of tokens generated during lexical analysis.
    tokens: std.ArrayList(token.Token),
    /// `transpile_proc` is a pointer to the associated transpilation process.
    transpile_proc: *transpiler.TranspileProcess,
    /// `curr_exp_count` is the current expression count.
    curr_exp_count: u8,
    /// `parenthesis_buf` is a buffer for storing parenthesis characters.
    parenthesis_buf: []const u8,
    /// `arg_str_buf` is a buffer for storing argument strings.
    arg_str_buf: []const u8,

    const Self = @This();

    /// Initializes a new instance of `LexProcess`.
    ///
    /// This function initializes the token list with the provided allocator and sets up
    /// the lexical analysis process with the given transpilation process.
    ///
    /// Parameters:
    /// - `allocator`: The memory allocator to use for the token list.
    /// - `transpile_proc`: A pointer to the associated transpilation process.
    ///
    /// Returns:
    /// - `Self`: A new instance of `LexProcess`.
    pub fn init(allocator: mem.Allocator, transpile_proc: *transpiler.TranspileProcess) Self {
        return Self{
            .tokens = std.ArrayList(token.Token).init(allocator),
            .transpile_proc = transpile_proc,
            .curr_exp_count = 0,
            .parenthesis_buf = "",
            .arg_str_buf = "",
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
    pub fn next_char(self: *Self) !?u8 {
        self.transpile_proc.pos.col += 1;
        var buffer: [1]u8 = undefined;
        const readBytes = try self.transpile_proc.ifile.read(buffer[0..]);
        if (readBytes == 0) {
            return null;
        }

        const c = buffer[0];
        if (c == '\n') {
            self.transpile_proc.pos.line += 1;
            self.transpile_proc.pos.col = 1;
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
    pub fn peek_char(self: *Self) !?u8 {
        const pos = try self.transpile_proc.ifile.seekableStream().getPos();
        var buffer: [1]u8 = undefined;
        const readBytes = try self.transpile_proc.ifile.read(buffer[0..]);
        try self.transpile_proc.ifile.seekTo(pos);
        return if (readBytes == 0) null else buffer[0];
    }

    /// Writes a character to the input file.
    ///
    /// This function writes the given character to the input file associated with the
    /// transpilation process.
    ///
    /// Parameters:
    /// - `c`: The character to write to the input file.
    ///
    /// Errors:
    /// - Returns an error if writing to the input file fails.
    pub fn push_char(self: *Self, c: u8) !void {
        var buffer: [1]u8 = [_]u8{c};
        _ = try self.transpile_proc.ifile.write(buffer[0..]);
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
    fn lex_getc_if(self: *Self, buffer: *std.ArrayList(u8), exp: fn (u8) bool) !void {
        while (true) {
            const c = try self.peek_char();
            if (!exp(c.?)) break;
            try buffer.append(c.?);
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
    fn token_make_comment(self: *Self) !token.Token {
        var buffer = std.ArrayList(u8).init(main.global_allocator);
        defer buffer.deinit();
        try self.lex_getc_if(&buffer, struct {
            fn call(_c: u8) bool {
                return _c != '\n';
            }
        }.call);

        var sval = std.ArrayList(u8).init(main.global_allocator);
        try sval.appendSlice(buffer.items);
        return token.Token{
            .type = .Comment,
            .data = .{
                .sval = sval,
            },
        };
    }

    /// Handles comment tokens in the input file.
    ///
    /// This function checks for comment tokens in the input file and processes them.
    ///
    /// Returns:
    /// - `?token.Token`: A comment token if one is found, otherwise `null`.
    ///
    /// Errors:
    /// - Returns an error if reading from the input file fails.
    fn handle_comment(self: *Self) !?token.Token {
        const c = try self.peek_char();
        if (c == '/') {
            _ = try self.next_char();
            if (try self.peek_char() == '/') {
                _ = try self.next_char();
                return try self.token_make_comment();
            }

            try self.push_char('/');
            return null; // TODO: deal with operator or strings
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
    fn handle_whitespace(self: *Self) anyerror!?token.Token {
        var last_token = self.tokens.getLastOrNull();
        if (last_token != null) {
            _ = self.tokens.pop();
            last_token.?.whitespace = true;
            try self.tokens.append(last_token.?);
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
    fn token_make_newline(self: *Self) !token.Token {
        _ = try self.next_char();
        return token.Token{
            .type = .NewLine,
            .data = .{ .cval = '\n' },
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
    fn token_make_identifier_or_keyword(self: *Self) !?token.Token {
        var buffer = std.ArrayList(u8).init(main.global_allocator);
        defer buffer.deinit();
        try self.lex_getc_if(&buffer, struct {
            fn call(_c: u8) bool {
                return misc.is_alpha(_c) or misc.is_number(_c) or _c == '_';
            }
        }.call);

        var sval = std.ArrayList(u8).init(main.global_allocator);
        try sval.appendSlice(buffer.items);
        if (misc.is_keyword(buffer.items)) {
            return token.Token{
                .type = .Keyword,
                .data = .{ .sval = sval },
            };
        }

        return token.Token{
            .type = .Identifier,
            .data = .{ .sval = sval },
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
    fn read_special_token(self: *Self) !?token.Token {
        const c = try self.peek_char();
        if (misc.is_alpha(c.?) or c.? == '_') {
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
    fn read_number_str(self: *Self) !std.ArrayList(u8) {
        var buffer = std.ArrayList(u8).init(main.global_allocator);
        try self.lex_getc_if(&buffer, struct {
            fn call(_c: u8) bool {
                return misc.is_number(_c);
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
    fn read_number(self: *Self) !c_longlong {
        const s = try self.read_number_str();
        defer s.deinit();

        const number: c_longlong = std.fmt.parseInt(c_longlong, s.items, 10) catch {
            self.transpile_proc.error_message("failed to parse number");
            return 0;
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
    fn token_make_number_for_value(self: *Self, num: c_longlong) !?token.Token {
        const pc = try self.peek_char();
        const num_type = self.number_type(pc.?);
        if (num_type != .Normal) {
            _ = try self.next_char();
        }

        return token.Token{
            .type = .Number,
            .data = .{ .llnum = num },
            .num = .{ .type = num_type },
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
    fn token_make_number(self: *Self) !?token.Token {
        return self.token_make_number_for_value(try self.read_number());
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
    fn token_make_symbol(self: *Self) !?token.Token {
        const c = try self.peek_char();
        _ = try self.next_char();
        return token.Token{
            .type = .Symbol,
            .data = .{ .cval = c.? },
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
    fn read_op_flush_back_keep_first(self: *Self, buffer: *std.ArrayList(u8)) !void {
        var i = buffer.items.len - 1;
        while (i >= 0) {
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
    fn read_op(self: *Self) !std.ArrayList(u8) {
        var buffer = std.ArrayList(u8).init(main.global_allocator);
        var single_operator = true;
        var op = try self.next_char();
        try buffer.append(op.?);
        var pc = try self.peek_char();
        if (op.? == '*' and pc.? == '=') {
            pc = try self.peek_char();
            try buffer.append(pc.?);
            _ = try self.next_char();
            single_operator = false;
        } else if (!misc.op_treated_as_one(op.?)) {
            for (0..2) |_| {
                op = try self.peek_char();
                if (misc.is_single_operator(op.?)) {
                    try buffer.append(op.?);
                    _ = try self.next_char();
                    single_operator = false;
                }
            }
        }

        if (!single_operator) {
            if (!misc.op_valid(buffer.items)) {
                try self.read_op_flush_back_keep_first(&buffer);
            }
        } else if (!misc.op_valid(buffer.items)) {
            self.transpile_proc.error_message("operator not valid");
        }

        return buffer;
    }

    /// Creates an operator or string token from the input file.
    ///
    /// This function reads an operator from the input file and creates an operator or string token.
    ///
    /// Returns:
    /// - `!token.Token`: The created operator or string token.
    ///
    /// Errors:
    /// - Returns an error if reading the operator or creating the token fails.
    fn token_make_operator_or_string(self: *Self) !token.Token {
        const sval = try self.read_op();
        return token.Token{
            .type = .Operator,
            .data = .{ .sval = sval },
        };
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
                self.transpile_proc.error_message("invalid binary number");
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
    fn token_make_special_number_binary(self: *Self) !?token.Token {
        _ = try self.next_char(); // skip special character 'b'
        const number_str = try self.read_number_str();
        defer number_str.deinit();
        self.validate_binary_string(number_str.items);
        const number: c_longlong = std.fmt.parseInt(c_longlong, number_str.items, 2) catch {
            self.transpile_proc.error_message("failed to parse number");
            return null;
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
    fn read_hex_number_str(self: *Self) !std.ArrayList(u8) {
        var buffer = std.ArrayList(u8).init(main.global_allocator);
        try self.lex_getc_if(&buffer, struct {
            fn call(_c: u8) bool {
                return misc.is_hex_number(_c);
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
    fn token_make_number_hexadecimal(self: *Self) !?token.Token {
        _ = try self.next_char(); // skip special character 'x'
        const number_str = try self.read_hex_number_str();
        const number: c_longlong = std.fmt.parseInt(c_longlong, number_str.items, 16) catch {
            self.transpile_proc.error_message("failed to parse number");
            return null;
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
    fn token_make_special_number(self: *Self) !?token.Token {
        var t: ?token.Token = null;
        const last_token = self.tokens.getLastOrNull();
        if (last_token == null or !(last_token.?.type == .Number and last_token.?.data.llnum == 0)) {
            return try self.token_make_identifier_or_keyword();
        }

        _ = self.tokens.pop(); // popping the first 0 (.eg [0]b0001)
        const c = try self.peek_char();
        switch (c.?) {
            'b' => t = try self.token_make_special_number_binary(),
            'x' => t = try self.token_make_number_hexadecimal(),
            else => self.transpile_proc.error_message("character not valid for special numbers"),
        }

        return t;
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
    fn read_next_token(self: *Self) !?token.Token {
        var t = try self.handle_comment();
        if (t != null) {
            return t;
        }

        const c = try self.peek_char();
        if (c == null) {
            return t;
        }

        switch (c.?) {
            '+', '-', '*', '>', '<', '^', '%', '!', '=', '~', '|', '&', '(', '[', ',', '.' => t = try self.token_make_operator_or_string(),
            '{', '}', ';', ')', ']' => t = try self.token_make_symbol(),
            '0'...'9' => t = try self.token_make_number(),
            'b', 'x' => t = try self.token_make_special_number(),
            '\n' => t = try self.token_make_newline(),
            ' ', '\t' => t = try self.handle_whitespace(),
            else => {
                t = try self.read_special_token();
                if (t == null) {
                    self.transpile_proc.error_message("unexpected token");
                }
            },
        }

        return t;
    }

    /// Lexes the input and appends tokens to the `tokens` array.
    ///
    /// This function reads tokens from the input using `read_next_token` and appends
    /// them to the `tokens` array until no more tokens are available.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    pub fn lex(self: *Self) !void {
        var t = try self.read_next_token();
        while (t != null) {
            try self.tokens.append(t.?);
            t = try self.read_next_token();
        }
    }

    /// Deinitializes the lexical analysis process.
    ///
    /// This function deinitializes the token list used by the lexical analysis process.
    ///
    /// Parameters:
    /// - `self`: The instance of the lexical analysis process to deinitialize.
    ///
    /// Returns:
    /// - This function does not return any value.
    pub fn deinit(self: Self) void {
        self.tokens.deinit();
    }
};
