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
    /// A comment.
    Comment,
    /// A newline character.
    NewLine,
};

/// Represents the data associated with a token. This can be one of several types.
pub const TokenData = union {
    /// A single character value.
    cval: u8,
    /// A string value.
    sval: []const u8,
    /// An integer value.
    inum: c_int,
    /// A long integer value.
    lnum: c_long,
    /// A long long integer value.
    llnum: c_longlong,
};

/// Represents the position of a token in the source code.
pub const Pos = struct {
    /// The line number where the token is located.
    line: u32,
    /// The column number where the token is located.
    col: u32,
    /// The name of the file where the token is located.
    filename: []const u8,
};

/// Represents a token in the source code, including its type and associated data.
pub const Token = struct {
    /// The type of the token.
    type: TokenType,
    /// The data associated with the token.
    data: TokenData,
};
