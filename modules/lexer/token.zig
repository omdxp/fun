const std = @import("std");
const mem = std.mem;
const semantics = @import("semantics");
const dtype = semantics.dtype;

/// Compatibility shim: ArrayList with embedded allocator (old-style managed API).
fn ArrayList(comptime T: type) type {
    return std.array_list.Managed(T);
}

/// Represents the different types of tokens that can be encountered in the source code.
pub const TokenType = enum {
    /// An identifier, such as a variable or function name.
    Identifier,
    /// A reserved keyword in the language.
    Keyword,
    /// An operator, such as +, -, *, /, etc.
    Operator,
    /// A symbol, such as parentheses, braces, etc.
    Symbol,
    /// A numeric literal.
    Number,
    /// A string literal.
    String,
    /// A boolean literal.
    Boolean,
    /// A comment.
    Comment,
    /// A newline character.
    NewLine,
};

/// Represents the different types of numeric literals.
pub const NumberType = enum {
    /// A normal integer.
    Normal,
    /// A long integer.
    Long,
    /// A floating-point number.
    Float,
    /// A double-precision floating-point number.
    Double,
};

/// Represents the data associated with a token. This can be one of several types.
pub const TokenData = union(enum) {
    /// A single character value.
    cval: u8,
    /// A string value.
    sval: ArrayList(u8),
    /// An integer value.
    inum: c_int,
    /// A long integer value.
    lnum: c_long,
    /// A long long integer value.
    llnum: c_longlong,
    /// A double-precision floating-point value.
    dnum: f64,
    /// A boolean value.
    bval: bool,
};

/// Represents the position of a token in the source code.
pub const Pos = struct {
    /// The line number where the token is located.
    line: u32,
    /// The column number where the token starts.
    col: u32,
    /// The starting column number of the token.
    start_col: u32,
    /// The ending column number of the token.
    end_col: u32,
    /// The ending line number of the token span.
    ///
    /// For most tokens this is the same as `line`, but for tokens that cross
    /// a newline boundary (e.g. a NewLine token) it will differ.
    end_line: u32 = 0,
    /// The name of the file where the token is located.
    filename: []const u8,
};

/// Represents a token in the source code, including its type and associated data.
pub const Token = struct {
    /// The type of the token.
    type: TokenType,
    /// The data associated with the token.
    data: TokenData,
    /// The span (start and end positions) of the token.
    pos: Pos,
    /// The type of the numeric literal, if the token is a number.
    num: ?struct {
        /// The type of the number.
        type: NumberType,
    } = null,
    /// Indicates if the token is preceded by whitespace.
    whitespace: bool = false,
    /// The text between brackets, if the token is within brackets.
    between_brackets: ?[]const u8 = null,
    /// The text between arguments, if the token is within arguments.
    between_args: ?[]const u8 = null,
};

/// Checks if a token is an operator with a specific value.
///
/// This function checks if the given token is not null, is of type `Operator`,
/// and if its data matches the provided value.
///
/// Returns:
/// - `bool`: `true` if the token is an operator with the specified value, otherwise `false`.
///
/// Parameters:
/// - `token (?Token)`: The token to check.
/// - `val ([]const u8)`: The value to compare the token's data against.
pub fn is_operator(token: ?Token, val: []const u8) bool {
    return token != null and token.?.type == .Operator and mem.eql(u8, token.?.data.sval.items, val);
}

/// Checks if a token is a keyword with a specific value.
///
/// This function checks if the given token is not null, is of type `Keyword`,
/// and if its data matches the provided value.
///
/// Returns:
/// - `bool`: `true` if the token is a keyword with the specified value, otherwise `false`.
///
/// Parameters:
/// - `token (?Token)`: The token to check.
/// - `val ([]const u8)`: The value to compare the token's data against.
pub fn is_keyword(token: ?Token, val: []const u8) bool {
    return token != null and token.?.type == .Keyword and mem.eql(u8, token.?.data.sval.items, val);
}

/// Checks if a token is a symbol with a specific value.
///
/// This function checks if the given token is not null, is of type `Symbol`,
/// and if its data matches the provided value.
///
/// Parameters:
/// - `token (?Token)`: The token to check.
/// - `val (u8)`: The value to compare the token's data against.
///
/// Returns:
/// - `bool`: `true` if the token is a symbol with the specified value, otherwise `false`.
pub fn is_symbol(token: ?Token, val: u8) bool {
    return token != null and token.?.type == .Symbol and token.?.data.cval == val;
}

/// Checks if a token is a newline, comment, or newline separator.
///
/// This function checks if the given token is not null and is either a newline,
/// a comment, or a newline separator (backslash).
///
/// Parameters:
/// - `token (?Token)`: The token to check.
///
/// Returns:
/// - `bool`: `true` if the token is a newline, comment, or newline separator, otherwise `false`.
pub fn is_nl_or_comment_or_newline_separator(token: ?Token) bool {
    if (token == null) {
        return false;
    }

    return token.?.type == .NewLine or
        token.?.type == .Comment or is_symbol(token, '\\');
}
