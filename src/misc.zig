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
        mem.eql(u8, "bin", str);
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
        mem.eql(u8, "fit", str) or mem.eql(u8, "ret", str);
}
