const std = @import("std");
const mem = std.mem;
const token = @import("./token.zig");
const transpiler = @import("./transpiler.zig");

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
    /// - `u8`: The next character read from the input file.
    ///
    /// Errors:
    /// - Returns an error if reading from the input file fails.
    pub fn next_char(self: *Self) !u8 {
        self.transpile_proc.pos.col += 1;
        var buffer: [1]u8 = undefined;
        _ = try self.transpile_proc.ifile.read(buffer[0..]);
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
    /// - `u8`: The next character in the input file.
    ///
    /// Errors:
    /// - Returns an error if reading from or seeking in the input file fails.
    pub fn peek_char(self: *Self) !u8 {
        const pos = try self.transpile_proc.ifile.seekableStream().getPos();
        var buffer: [1]u8 = undefined;
        _ = try self.transpile_proc.ifile.read(buffer[0..]);
        try self.transpile_proc.ifile.seekTo(pos);
        return buffer[0];
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
