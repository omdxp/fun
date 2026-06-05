const std = @import("std");
const mem = std.mem;
const codegen = @import("codegen");
const TranspileError = codegen.TranspileError;
const utils = @import("utils");
pub const token = @import("token.zig");

/// Compatibility shim: ArrayList with embedded allocator (old-style managed API).
fn ArrayList(comptime T: type) type {
    return std.array_list.Managed(T);
}

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
    const AsmLexState = enum {
        none,
        scanning,
        raw_body_pending,
    };

    /// `transpile_proc` is a pointer to the associated transpilation process.
    transpile_proc: *codegen.TranspileProcess,
    /// `curr_exp_count` is the current expression count.
    curr_exp_count: isize,
    /// `parenthesis_buf` is a buffer for storing parenthesis characters.
    parenthesis_buf: ?ArrayList(u8) = null,
    /// `arg_str_buf` is a buffer for storing argument strings.
    arg_str_buf: ?ArrayList(u8) = null,

    /// Tracks whether we're currently scanning an `asm` statement.
    asm_state: AsmLexState = .none,
    /// Optional queued token used by raw asm block lexing (typically the closing `}`).
    queued_token: ?token.Token = null,

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
            .asm_state = .none,
            .queued_token = null,
        };
    }

    fn update_asm_state(self: *Self, t: token.Token) void {
        switch (self.asm_state) {
            .none => {
                if (t.type == .Keyword and mem.eql(u8, t.data.sval.items, "asm")) {
                    self.asm_state = .scanning;
                }
            },
            .scanning => {
                if (t.type == .Symbol and t.data.cval == '{') {
                    self.asm_state = .raw_body_pending;
                } else if (t.type == .Symbol and t.data.cval == ';') {
                    self.asm_state = .none;
                }
            },
            .raw_body_pending => {},
        }
    }

    fn token_make_asm_raw_body(self: *Self) LexError!token.Token {
        const start_line = self.transpile_proc.pos.line;
        const start_col = self.transpile_proc.pos.col;

        var buffer = ArrayList(u8).init(self.transpile_proc.allocator);
        var depth: usize = 1;
        var close_pos: ?token.Pos = null;

        while (true) {
            const char_line = self.transpile_proc.pos.line;
            const char_col = self.transpile_proc.pos.col;
            const c = try self.next_char();
            if (c == null) {
                self.transpile_proc.err("unexpected end of file in asm block", .{});
                return LexError.InvalidCharacter;
            }

            if (c.? == '{') {
                depth += 1;
                buffer.append(c.?) catch return LexError.MemoryAllocationFailed;
                continue;
            }

            if (c.? == '}') {
                depth -= 1;
                if (depth == 0) {
                    close_pos = .{
                        .line = char_line,
                        .col = char_col,
                        .start_col = char_col,
                        .end_col = char_col + 1,
                        .end_line = char_line,
                        .filename = self.transpile_proc.pos.filename,
                    };
                    break;
                }
                buffer.append(c.?) catch return LexError.MemoryAllocationFailed;
                continue;
            }

            buffer.append(c.?) catch return LexError.MemoryAllocationFailed;
        }

        const close_tok_pos = close_pos orelse {
            self.transpile_proc.err("unexpected end of file in asm block", .{});
            return LexError.InvalidCharacter;
        };

        self.queued_token = token.Token{
            .type = .Symbol,
            .data = .{ .cval = '}' },
            .pos = close_tok_pos,
        };

        return token.Token{
            .type = .String,
            .data = .{ .sval = buffer },
            .pos = .{
                .line = start_line,
                .col = start_col,
                .start_col = start_col,
                .end_col = close_tok_pos.start_col,
                .end_line = close_tok_pos.line,
                .filename = self.transpile_proc.pos.filename,
            },
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
        const readBytes = self.transpile_proc.ifile.readPositionalAll(self.transpile_proc.io, &buffer, self.transpile_proc.file_pos) catch {
            return LexError.FileReadError;
        };
        if (readBytes == 0) {
            return null;
        }
        self.transpile_proc.file_pos += 1;

        const c = buffer[0];

        // Advance cursor after reading a character.
        if (c == '\n') {
            self.transpile_proc.pos.line += 1;
            self.transpile_proc.pos.col = 1;
        } else {
            self.transpile_proc.pos.col += 1;
        }

        if (self.in_expression()) {
            self.parenthesis_buf.?.append(c) catch {
                return LexError.MemoryAllocationFailed;
            };
            if (self.arg_str_buf != null) {
                self.arg_str_buf.?.append(c) catch {
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
        var buffer: [1]u8 = undefined;
        const readBytes = self.transpile_proc.ifile.readPositionalAll(self.transpile_proc.io, &buffer, self.transpile_proc.file_pos) catch {
            return LexError.FileReadError;
        };
        // file_pos is NOT advanced — this is a non-consuming peek.
        return if (readBytes == 0) null else buffer[0];
    }

    /// Peeks the SECOND character ahead (at `file_pos + 1`) without advancing.
    /// Used for two-char lookahead such as distinguishing a leading-dot float
    /// literal (`.5`) from a member-access / range `.` operator.
    pub fn peek_char2(self: *Self) LexError!?u8 {
        var buffer: [1]u8 = undefined;
        const readBytes = self.transpile_proc.ifile.readPositionalAll(self.transpile_proc.io, &buffer, self.transpile_proc.file_pos + 1) catch {
            return LexError.FileReadError;
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
        if (self.transpile_proc.file_pos > 0) {
            self.transpile_proc.file_pos -= 1;
        }

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
    fn getc_if(self: *Self, buffer: *ArrayList(u8), exp: fn (u8) bool) LexError!void {
        while (true) {
            const c = try self.peek_char();
            if (c == null or !exp(c.?)) break;
            buffer.append(c.?) catch {
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
        var buffer = ArrayList(u8).init(self.transpile_proc.allocator);
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
            const nxt = try self.peek_char();
            if (nxt == '/') {
                _ = try self.next_char();
                return try self.token_make_comment();
            }
            if (nxt == '*') {
                _ = try self.next_char();
                return try self.token_make_block_comment();
            }
            try self.push_char('/');
            return try self.token_make_operator();
        }

        return null;
    }

    /// Creates a comment token from a `/* ... */` block comment. Consumes through
    /// the closing `*/`. An unterminated block comment (EOF before `*/`) is a clean
    /// lex error rather than a crash. Newlines inside the comment are advanced
    /// through `next_char`, which keeps line/column tracking correct.
    fn token_make_block_comment(self: *Self) LexError!token.Token {
        var buffer = ArrayList(u8).init(self.transpile_proc.allocator);
        const start_pos = self.transpile_proc.pos;
        while (true) {
            const ch = try self.next_char() orelse {
                self.transpile_proc.err("unterminated block comment (missing '*/')", .{});
                buffer.deinit();
                return LexError.InvalidExpression;
            };
            if (ch == '*' and (try self.peek_char()) == '/') {
                _ = try self.next_char(); // consume the closing '/'
                break;
            }
            buffer.append(ch) catch {
                buffer.deinit();
                return LexError.MemoryAllocationFailed;
            };
        }
        return token.Token{
            .type = .Comment,
            .data = .{ .sval = buffer },
            .pos = start_pos,
        };
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
            self.transpile_proc.tokens.push(last_token.?) catch {
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
        var buffer = ArrayList(u8).init(self.transpile_proc.allocator);
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
        if (c == null) {
            return null;
        }

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
    /// - `!ArrayList(u8)`: The buffer containing the numeric string.
    ///
    /// Errors:
    /// - Returns an error if reading characters or allocating the buffer fails.
    fn read_number_str(self: *Self) LexError!ArrayList(u8) {
        var buffer = ArrayList(u8).init(self.transpile_proc.allocator);
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

    fn token_make_number_from_string(self: *Self, number_str: []const u8) LexError!?token.Token {
        // A '.' OR an exponent ('e'/'E', e.g. "1e10" with no dot) makes this a
        // decimal literal -> parse as f64.
        const has_dot = std.mem.indexOfScalar(u8, number_str, '.') != null;
        const has_exp = std.mem.indexOfScalar(u8, number_str, 'e') != null or
            std.mem.indexOfScalar(u8, number_str, 'E') != null;
        if (has_dot or has_exp) {
            const v: f64 = std.fmt.parseFloat(f64, number_str) catch {
                self.transpile_proc.err("failed to parse number '{s}'", .{number_str});
                return LexError.InvalidNumber;
            };
            return token.Token{
                .type = .Number,
                .data = .{ .dnum = v },
                .num = .{ .type = .Double },
                .pos = self.transpile_proc.pos,
            };
        }

        const v: c_longlong = std.fmt.parseInt(c_longlong, number_str, 10) catch {
            self.transpile_proc.err("failed to parse number '{s}'", .{number_str});
            return LexError.InvalidNumber;
        };

        // Support suffixes like 10L and 10f.
        const pc = try self.peek_char();
        const num_type = if (pc != null) self.number_type(pc.?) else .Normal;
        if (num_type != .Normal) {
            _ = try self.next_char();
        }

        if (num_type == .Float) {
            return token.Token{
                .type = .Number,
                .data = .{ .dnum = @floatFromInt(v) },
                .num = .{ .type = .Float },
                .pos = self.transpile_proc.pos,
            };
        }

        return token.Token{
            .type = .Number,
            .data = .{ .llnum = v },
            .num = .{ .type = num_type },
            .pos = self.transpile_proc.pos,
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
        // Read the integer part. It may be EMPTY for a leading-dot literal (`.5`),
        // which `read_next_token` routes here only when a digit follows the '.'.
        var buffer = try self.read_number_str();
        defer buffer.deinit();

        // Leading-dot literal (`.5`): synthesize a leading "0" so the string is
        // "0.5" for parseFloat.
        if (buffer.items.len == 0) {
            buffer.append('0') catch {
                return LexError.MemoryAllocationFailed;
            };
        }

        // Decimal literals: <digits>.<digits>, or a trailing dot (`1.` -> "1.0").
        const pc = try self.peek_char();
        if (pc != null and pc.? == '.') {
            _ = try self.next_char();
            const after_dot = try self.peek_char();
            if (after_dot != null and utils.is_number(after_dot.?)) {
                buffer.append('.') catch {
                    return LexError.MemoryAllocationFailed;
                };

                const frac = try self.read_number_str();
                defer frac.deinit();
                buffer.appendSlice(frac.items) catch {
                    return LexError.MemoryAllocationFailed;
                };
            } else if (after_dot == null or
                !(utils.is_alpha(after_dot.?) or after_dot.? == '_' or after_dot.? == '.'))
            {
                // Trailing dot with no fraction (`1.`) not followed by an identifier
                // start OR another dot: a decimal literal "1.0". A following
                // letter/underscore (`1.foo`) stays integer + '.' (member access);
                // a following dot (`0..3`) is the range operator `..`, so we must
                // NOT swallow its first dot into a float.
                buffer.appendSlice(".0") catch {
                    return LexError.MemoryAllocationFailed;
                };
            } else {
                // Not a decimal (identifier or another dot follows): unread the '.'
                // so it lexes as the member-access / range operator.
                try self.push_char('.');
            }
        }

        // Optional exponent (`1e10`, `1.5e-3`, `2E+5`). Consumed only when real
        // digits follow; otherwise the 'e'/'E' is left to be lexed normally.
        try self.read_exponent(&buffer);

        return try self.token_make_number_from_string(buffer.items);
    }

    /// Consumes a floating-point exponent (`e`/`E`, optional `+`/`-`, digits) onto
    /// `buffer` when the lookahead forms a valid exponent. If it does not (no digit
    /// after the optional sign), every peeked character is pushed back so it lexes
    /// normally — e.g. an identifier `e` after a number is untouched.
    fn read_exponent(self: *Self, buffer: *ArrayList(u8)) LexError!void {
        const e = try self.peek_char();
        if (e == null or (e.? != 'e' and e.? != 'E')) return;
        _ = try self.next_char(); // tentatively consume 'e'/'E'

        const sign = try self.peek_char();
        var consumed_sign = false;
        if (sign != null and (sign.? == '+' or sign.? == '-')) {
            _ = try self.next_char();
            consumed_sign = true;
        }

        const d = try self.peek_char();
        if (d == null or !utils.is_number(d.?)) {
            // Not an exponent: unread what we consumed (sign first, then 'e').
            if (consumed_sign) try self.push_char(sign.?);
            try self.push_char(e.?);
            return;
        }

        buffer.append(e.?) catch return LexError.MemoryAllocationFailed;
        if (consumed_sign) {
            buffer.append(sign.?) catch return LexError.MemoryAllocationFailed;
        }
        const digits = try self.read_number_str();
        defer digits.deinit();
        buffer.appendSlice(digits.items) catch return LexError.MemoryAllocationFailed;
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
            self.parenthesis_buf = ArrayList(u8).init(self.transpile_proc.allocator);
        }

        const t = self.transpile_proc.tokens.back();
        if (t != null and (t.?.type == .Identifier or token.is_operator(t, ","))) {
            self.arg_str_buf = ArrayList(u8).init(self.transpile_proc.allocator);
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

        // Free expression buffers when we leave the outermost expression.
        if (self.curr_exp_count == 0) {
            if (self.parenthesis_buf) |*buf| {
                buf.deinit();
                self.parenthesis_buf = null;
            }
            if (self.arg_str_buf) |*buf| {
                buf.deinit();
                self.arg_str_buf = null;
            }
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
        if (c == null) return null;
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
    /// - `buffer (*ArrayList(u8))`: The buffer containing the characters to be pushed back.
    fn read_op_flush_back_keep_first(self: *Self, buffer: *ArrayList(u8)) LexError!void {
        // Keep the LONGEST valid operator prefix (maximal munch), not just the
        // first character. The greedy reader can over-consume — e.g. `>=-` from
        // `a >=-1` — producing an invalid operator; keeping only the first char
        // would collapse `>=` to `>` and lose the negative RHS (and the same `=-`
        // over-munch broke `enum E { A = -1 }`). We push back exactly the chars
        // past the longest valid prefix so they re-lex. For a genuinely single-char
        // operator only the 1-char prefix is valid, so the result is unchanged, and
        // we never push back MORE chars than the original "keep first" code did.
        var keep: usize = 1;
        var k: usize = buffer.items.len;
        while (k >= 1) : (k -= 1) {
            if (utils.op_valid(buffer.items[0..k])) {
                keep = k;
                break;
            }
        }
        // Push back from the end down to `keep` (exclusive of indices < keep).
        var bi: usize = buffer.items.len;
        while (bi > keep) {
            bi -= 1;
            _ = try self.push_char(buffer.items[bi]);
        }
        buffer.items.len = keep;
    }

    /// Reads an operator from the input file.
    ///
    /// This function reads an operator from the input file, handling different operator types
    /// and validating them.
    ///
    /// Returns:
    /// - `!ArrayList(u8)`: The buffer containing the operator string.
    ///
    /// Errors:
    /// - Returns an error if reading characters or validating the operator fails.
    fn read_op(self: *Self) LexError!ArrayList(u8) {
        var buffer = ArrayList(u8).init(self.transpile_proc.allocator);
        var single_operator = true;
        const op0 = (try self.next_char()) orelse {
            self.transpile_proc.err("unexpected end of file while reading operator", .{});
            return LexError.InvalidOperator;
        };
        buffer.append(op0) catch {
            return LexError.MemoryAllocationFailed;
        };
        const pc = try self.peek_char();
        // Always treat == as a single operator token, even with whitespace between
        if (op0 == '=') {
            var peek = pc;
            var ws = false;
            // Skip whitespace between '=' and '='
            while (peek != null and (peek.? == ' ' or peek.? == '\t')) {
                ws = true;
                _ = try self.next_char();
                peek = try self.peek_char();
            }
            if (peek != null and peek.? == '=') {
                buffer.append('=') catch {
                    return LexError.MemoryAllocationFailed;
                };
                _ = try self.next_char();
                single_operator = false;
            }
        } else if (op0 == '!' and pc != null and pc.? == '=') {
            buffer.append(pc.?) catch {
                return LexError.MemoryAllocationFailed;
            };
            _ = try self.next_char();
            single_operator = false;
        } else if (op0 == '*' and pc != null and pc.? == '=') {
            buffer.append(pc.?) catch {
                return LexError.MemoryAllocationFailed;
            };
            _ = try self.next_char();
            single_operator = false;
        } else if (!utils.op_treated_as_one(op0)) {
            for (0..2) |_| {
                const op = try self.peek_char();
                if (op == null) break;
                // Don't consume delimiters as part of a multi-char operator.
                // Otherwise sequences like `||(` become `||(` (invalid), triggering flush-back
                // logic and incorrectly splitting a valid operator into two tokens.
                if (op.? == '(' or op.? == '[' or op.? == ',') break;
                if (utils.is_single_operator(op.?)) {
                    buffer.append(op.?) catch {
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
            self.transpile_proc.err("operator '{s}' not valid", .{buffer.items});
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

        if (op != null and op.? == '(') {
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
    /// - `!ArrayList(u8)`: The buffer containing the hexadecimal string.
    ///
    /// Errors:
    /// - Returns an error if reading characters or allocating the buffer fails.
    fn read_hex_number_str(self: *Self) LexError!ArrayList(u8) {
        var buffer = ArrayList(u8).init(self.transpile_proc.allocator);
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
        defer number_str.deinit();
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
        if (c == null) {
            self.transpile_proc.tokens.push(last_token.?) catch {
                return LexError.MemoryAllocationFailed;
            };
            self.transpile_proc.err("unexpected end of file while reading special number", .{});
            return LexError.FileReadError;
        }
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
    /// - `buf (*ArrayList(u8))`: The buffer to append the number to.
    ///
    /// Errors:
    /// - Returns an error if reading the number or appending to the buffer fails.
    /// - Logs an error message if the number is outside the valid range (0 to 255).
    fn handle_escape_number(self: *Self, buf: *ArrayList(u8)) LexError!void {
        const num = try self.read_number();
        if (num > 255) {
            self.transpile_proc.err("characters must be between 0 and 255, got '{}'", .{num});
            return LexError.InvalidNumber;
        }

        buf.append(@intCast(num)) catch {
            return LexError.MemoryAllocationFailed;
        };
    }

    /// Handles an escape sequence and appends the corresponding character to the buffer.
    ///
    /// This function checks if the escape sequence represents a number or a special character
    /// and appends the corresponding character to the buffer.
    ///
    /// Parameters:
    /// - `buf (*ArrayList(u8))`: The buffer to append the character to.
    ///
    /// Errors:
    /// - Returns an error if reading the next character or appending to the buffer fails.
    fn handle_escape(self: *Self, buf: *ArrayList(u8)) LexError!void {
        const c = try self.peek_char();
        if (c == null) {
            self.transpile_proc.err("unexpected end of file while reading escape", .{});
            return LexError.FileReadError;
        }
        if (utils.is_number(c.?)) {
            try self.handle_escape_number(buf);
            return;
        }

        const ec = utils.get_escape_char(c.?) orelse {
            self.transpile_proc.err("unknown escape sequence '\\{c}'", .{c.?});
            return LexError.InvalidCharacter;
        };
        buf.append(ec) catch {
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
        var buffer = ArrayList(u8).init(self.transpile_proc.allocator);
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

            // Backslash starts an escape sequence. We pass escapes through
            // verbatim into the buffer (the emitted C string literal interprets
            // them — `\n`, `\t`, `\\`, `\0`, etc.). Critically, consuming the
            // escaped character here means an escaped quote `\"` does NOT
            // prematurely terminate the Fun string literal.
            if (c.? == '\\') {
                buffer.append(c.?) catch return LexError.MemoryAllocationFailed;
                const next = try self.next_char();
                if (next == null) {
                    self.transpile_proc.err("unexpected end of file while reading string", .{});
                    return LexError.FileReadError;
                }
                buffer.append(next.?) catch return LexError.MemoryAllocationFailed;
                continue;
            }

            buffer.append(c.?) catch {
                return LexError.MemoryAllocationFailed;
            };
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
        if (c == null) {
            self.transpile_proc.err("unexpected end of file while reading character", .{});
            return LexError.InvalidCharacter;
        }
        if (c.? == '\\') {
            c = try self.next_char();
            if (c == null) {
                self.transpile_proc.err("unexpected end of file while reading character escape", .{});
                return LexError.InvalidCharacter;
            }
            // Reject unrecognized escapes (e.g. '\q') with a clean error rather
            // than silently decoding them to NUL.
            c = utils.get_escape_char(c.?) orelse {
                self.transpile_proc.err("unknown escape sequence '\\{c}' in character literal", .{c.?});
                return LexError.InvalidCharacter;
            };
        }

        const nc = try self.next_char();
        if (nc == null) {
            self.transpile_proc.err("unexpected end of file while reading character", .{});
            return LexError.InvalidCharacter;
        }
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
        if (self.queued_token) |qt| {
            self.queued_token = null;
            self.transpile_proc.current_token = qt;
            self.update_asm_state(qt);
            return qt;
        }

        if (self.asm_state == .raw_body_pending) {
            const raw_tok = try self.token_make_asm_raw_body();
            self.asm_state = .none;
            self.transpile_proc.current_token = raw_tok;
            return raw_tok;
        }

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

        // Leading-dot float literal (`.5`): a '.' immediately followed by a digit
        // starts a number, not a member-access / range operator. We must look two
        // chars ahead because the single-char `switch` below would otherwise route
        // '.' to `token_make_operator`. `peek_char2` restores the position.
        if (c.? == '.') {
            if (try self.peek_char2()) |c2| {
                if (utils.is_number(c2)) {
                    return try self.token_make_number();
                }
            }
        }

        switch (c.?) {
            '"' => t = try self.token_make_string(),
            '\'' => t = try self.token_make_character(),
            '+', '-', '*', '>', '<', '^', '%', '!', '=', '~', '|', '&', '(', '[', ',', '.', ':', '#', '$' => t = try self.token_make_operator(),
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
            self.update_asm_state(t.?);
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
            self.transpile_proc.tokens.push(t.?) catch {
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
    pub fn deinit(self: *Self) void {
        if (self.parenthesis_buf) |*buf| {
            buf.deinit();
            self.parenthesis_buf = null;
        }
        if (self.arg_str_buf) |*buf| {
            buf.deinit();
            self.arg_str_buf = null;
        }
    }
};
