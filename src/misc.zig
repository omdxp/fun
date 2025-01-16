const std = @import("std");
const mem = std.mem;

/// Checks if the given character is an alphabetic letter.
///
/// This function returns `true` if the provided character is an alphabetic letter
/// (either uppercase or lowercase), otherwise it returns `false`.
///
/// Parameters:
/// - `c`: The character to check.
///
/// Returns:
/// - `bool`: `true` if the character is an alphabetic letter, otherwise `false`.
pub fn is_alpha(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

/// Checks if the given character is a numeric digit.
///
/// This function returns `true` if the provided character is a numeric digit
/// (i.e., between '0' and '9'), otherwise it returns `false`.
///
/// Parameters:
/// - `c`: The character to check.
///
/// Returns:
/// - `bool`: `true` if the character is a numeric digit, otherwise `false`.
pub fn is_number(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Checks if the given string is a datatype keyword.
///
/// This function checks if the provided string matches any of the predefined.
///
/// Parameters:
/// - `str`: The string to check.
///
/// Returns:
/// - `bool`: `true` if the string is a datatype keyword, otherwise `false`.
pub fn keyword_is_datatype(str: []const u8) bool {
    // TODO: more to add later
    return mem.eql(u8, "num", str) or mem.eql(u8, "str", str) or
        mem.eql(u8, "bin", str) or mem.eql(u8, "chr", str);
}

/// Checks if the given string is a keyword.
///
/// This function checks if the provided string matches any of the predefined
/// keywords..
///
/// Parameters:
/// - `str`: The string to check.
///
/// Returns:
/// - `bool`: `true` if the string is a keyword, otherwise `false`.
pub fn is_keyword(str: []const u8) bool {
    // TODO: more to add later
    return mem.eql(u8, "imp", str) or mem.eql(u8, "fun", str) or
        mem.eql(u8, "num", str) or mem.eql(u8, "str", str) or
        mem.eql(u8, "if", str) or mem.eql(u8, "elif", str) or
        mem.eql(u8, "else", str) or mem.eql(u8, "bin", str) or
        mem.eql(u8, "true", str) or mem.eql(u8, "false", str) or
        mem.eql(u8, "fit", str) or mem.eql(u8, "ret", str) or
        mem.eql(u8, "chr", str);
}

/// Checks if an operator is treated as a single unit.
///
/// This function checks if the given operator is treated as a single unit
/// in the context of the transpilation process.
///
/// Returns:
/// - `bool`: `true` if the operator is treated as a single unit, otherwise `false`.
///
/// Parameters:
/// - `op (u8)`: The operator to check.
pub fn op_treated_as_one(op: u8) bool {
    return op == '(' or op == '[' or op == ',' or op == '.' or op == '*';
}

/// Checks if an operator is a single character operator.
///
/// This function checks if the given operator is a single character operator
/// in the context of the transpilation process.
///
/// Returns:
/// - `bool`: `true` if the operator is a single character operator, otherwise `false`.
///
/// Parameters:
/// - `op (u8)`: The operator to check.
pub fn is_single_operator(op: u8) bool {
    return op == '+' or op == '-' or op == '/' or op == '*' or op == '=' or
        op == '>' or op == '<' or op == '|' or op == '&' or op == '^' or
        op == '%' or op == '~' or op == '!' or op == '(' or op == '[' or
        op == ',' or op == '.';
}

/// Checks if an operator is valid.
///
/// This function checks if the given operator string matches any of the valid operators
/// defined for the transpilation process.
///
/// Returns:
/// - `bool`: `true` if the operator is valid, otherwise `false`.
///
/// Parameters:
/// - `op ([]const u8)`: The operator string to check.
pub fn op_valid(op: []const u8) bool {
    return mem.eql(u8, "+", op) or mem.eql(u8, "-", op) or mem.eql(u8, "*", op) or mem.eql(u8, "/", op) or
        mem.eql(u8, "!", op) or mem.eql(u8, "^", op) or mem.eql(u8, "+=", op) or mem.eql(u8, "-=", op) or
        mem.eql(u8, "*=", op) or mem.eql(u8, "/=", op) or mem.eql(u8, ">>", op) or
        mem.eql(u8, ">>=", op) or mem.eql(u8, "<<", op) or mem.eql(u8, "<<=", op) or
        mem.eql(u8, ">", op) or mem.eql(u8, "<", op) or mem.eql(u8, ">=", op) or mem.eql(u8, "<=", op) or
        mem.eql(u8, "||", op) or mem.eql(u8, "&&", op) or mem.eql(u8, "|", op) or mem.eql(u8, "&", op) or
        mem.eql(u8, "++", op) or mem.eql(u8, "--", op) or mem.eql(u8, "=", op) or mem.eql(u8, "!=", op) or
        mem.eql(u8, "==", op) or mem.eql(u8, "(", op) or mem.eql(u8, "[", op) or
        mem.eql(u8, ",", op) or mem.eql(u8, ".", op) or mem.eql(u8, "...", op) or mem.eql(u8, "~", op) or
        mem.eql(u8, "%", op);
}

/// Checks if a character is a hexadecimal digit.
///
/// This function checks if the given character is a valid hexadecimal digit (0-9, a-f).
///
/// Returns:
/// - `bool`: `true` if the character is a hexadecimal digit, otherwise `false`.
///
/// Parameters:
/// - `c (u8)`: The character to check.
pub fn is_hex_number(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'b');
}

/// Converts an escape character to its corresponding value.
///
/// This function takes an escape character and returns its corresponding character value.
/// For example, the escape character 'n' is converted to the newline character '\n'.
///
/// Returns:
/// - `u8`: The character corresponding to the escape character, or `0` if the escape character is not recognized.
///
/// Parameters:
/// - `c (u8)`: The escape character to convert.
pub fn get_escape_char(c: u8) u8 {
    return switch (c) {
        'n' => '\n',
        '\\' => '\\',
        't' => '\t',
        '\'' => '\'',
        else => 0,
    };
}
