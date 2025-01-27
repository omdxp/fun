const std = @import("std");
const mem = std.mem;
const dtype = @import("./dtype.zig");
const token = @import("./token.zig");

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

/// Checks if the given character is a boolean keyword.
///
/// This function checks if the provided character is a boolean keyword.
///
/// Parameters:
/// - `str`: The string to check.
///
/// Returns:
/// - `bool`: `true` if the string is a boolean keyword, otherwise `false`.
pub fn is_boolean_keyword(str: []const u8) bool {
    return mem.eql(u8, "true", str) or mem.eql(u8, "false", str);
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
        mem.eql(u8, "%", op) or mem.eql(u8, "->", op);
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

/// Determines the data type from a string representation.
///
/// This function compares a given string (`dt`) against known data type representations
/// and returns the corresponding `DataTypeType` enum value. If the string does not match
/// any known data type, it returns `.Unknown`.
///
/// Returns:
/// - `dtype.DataTypeType`: The corresponding data type enum value. Possible values are:
///   - `.Chr`: If the string is `"chr"`.
///   - `.Str`: If the string is `"str"`.
///   - `.Num`: If the string is `"num"`.
///   - `.Bin`: If the string is `"bin"`.
///   - `.Unknown`: If the string does not match any known data type.
///
/// Parameters:
/// - `dt ( []const u8 )`: The string representation of the data type.
pub fn get_datatype_type(dt: []const u8) dtype.DataTypeType {
    if (mem.eql(u8, "chr", dt)) return .Chr;
    if (mem.eql(u8, "str", dt)) return .Str;
    if (mem.eql(u8, "num", dt)) return .Num;
    if (mem.eql(u8, "bin", dt)) return .Bin;
    return .Unknown;
}

/// Checks if the given operator is an access operator.
///
/// This function compares the given operator (`op`) to the access operator `"."`.
///
/// Returns:
/// - `bool`: `true` if the operator is `"."`, otherwise `false`.
///
/// Parameters:
/// - `op ( []const u8 )`: The operator to check.
pub fn is_access_operator(op: []const u8) bool {
    return mem.eql(u8, ".", op);
}

/// Checks if the given operator is an array operator.
///
/// This function compares the given operator (`op`) to the array operator `"[]"`.
///
/// Returns:
/// - `bool`: `true` if the operator is `"[]"`, otherwise `false`.
///
/// Parameters:
/// - `op ( []const u8 )`: The operator to check.
pub fn is_array_operator(op: []const u8) bool {
    return mem.eql(u8, "[]", op);
}

/// Checks if the given operator is a parenthesis.
///
/// This function compares the given operator (`op`) to the parenthesis operator `"("`.
///
/// Returns:
/// - `bool`: `true` if the operator is `"("`, otherwise `false`.
///
/// Parameters:
/// - `op ( []const u8 )`: The operator to check.
pub fn is_parenthesis(op: []const u8) bool {
    return mem.eql(u8, "(", op);
}

/// Checks if the given token is compatible with unary operands.
///
/// This function determines if the given token (`t`) is an access operator, array operator,
/// or parenthesis, and returns `true` if any of these conditions are met.
///
/// Returns:
/// - `bool`: `true` if the token is compatible with unary operands, otherwise `false`.
///
/// Parameters:
/// - `t ( token.Token )`: The token to check.
pub fn is_unary_operand_compatible(t: token.Token) bool {
    return is_access_operator(t.data.sval.items) or is_array_operator(t.data.sval.items) or is_parenthesis(t.data.sval.items);
}

/// Checks if the given operator is a unary operator.
///
/// This function compares the given operator (`op`) against known unary operators.
/// The unary operators checked are: `"-"`, `"+"`, `"!"`, `"~"`, `"*"`, `"&"`, `"++"`, `"--"`.
///
/// Returns:
/// - `bool`: `true` if the operator is a unary operator, otherwise `false`.
///
/// Parameters:
/// - `op ( []const u8 )`: The operator to check.
pub fn is_unary_operator(op: []const u8) bool {
    return mem.eql(u8, "-", op) or mem.eql(u8, "+", op) or
        mem.eql(u8, "!", op) or mem.eql(u8, "~", op) or
        mem.eql(u8, "*", op) or mem.eql(u8, "&", op) or
        mem.eql(u8, "++", op) or mem.eql(u8, "--", op);
}

/// Checks if the given operator is an indirection operator.
///
/// This function compares the given operator (`op`) to the indirection operator `"*"`.
///
/// Returns:
/// - `bool`: `true` if the operator is `"*"`, otherwise `false`.
///
/// Parameters:
/// - `op ( []const u8 )`: The operator to check.
pub fn is_indirection_operator(op: []const u8) bool {
    return mem.eql(u8, "*", op);
}

/// Checks if the given operator is a left-operanded unary operator.
///
/// This function compares the given operator (`op`) against known left-operanded unary operators.
/// The unary operators checked are: `"++"` and `"--"`.
///
/// Returns:
/// - `bool`: `true` if the operator is a left-operanded unary operator, otherwise `false`.
///
/// Parameters:
/// - `op ( []const u8 )`: The operator to check.
pub fn is_left_operanded_unary_operator(op: []const u8) bool {
    return mem.eql(u8, "++", op) or mem.eql(u8, "--", op);
}

/// Creates a generic Vector type with the specified element type.
///
/// This function defines a generic Vector type with various methods for manipulating
/// and accessing the elements in the vector.
///
/// Parameters:
/// - `T: type`: The element type for the Vector.
///
/// Returns:
/// - `type`: The defined Vector type.
pub fn Vector(comptime T: type) type {
    return struct {
        /// The internal ArrayList for storing elements.
        data: std.ArrayList(T),
        /// The peek index for accessing elements without removing them.
        pindex: usize = 0,
        /// The count of elements in the Vector.
        count: usize = 0,

        const Self = @This();

        /// Initializes a new Vector instance.
        ///
        /// Parameters:
        /// - `allocator (mem.Allocator)`: The allocator to use for memory allocation.
        ///
        /// Returns:
        /// - `Self`: The initialized Vector instance.
        pub fn init(allocator: mem.Allocator) Self {
            return Self{
                .data = std.ArrayList(T).init(allocator),
            };
        }

        /// Returns a slice of all elements in the Vector.
        ///
        /// This function provides access to the underlying array of elements in the Vector.
        ///
        /// Returns:
        /// - `[]T`: A slice of all elements in the Vector.
        pub fn items(self: Self) []T {
            return self.data.items;
        }

        /// Gets the element at the specified index.
        ///
        /// Parameters:
        /// - `index (usize)`: The index of the element to get.
        ///
        /// Returns:
        /// - `?T`: The element at the specified index, or `null` if the index is out of bounds.
        pub fn at(self: *Self, index: usize) ?T {
            if (index >= self.data.items.len) {
                return null;
            }
            return self.data.items[index];
        }

        /// Peeks at the element at the peek index without incrementing the index.
        ///
        /// Returns:
        /// - `?T`: The element at the peek index, or `null` if the index is out of bounds.
        pub fn peek_no_increment(self: *Self) ?T {
            return self.at(self.pindex);
        }

        /// Peeks at the element at the peek index and increments the peek index.
        ///
        /// Returns:
        /// - `?T`: The element at the peek index, or `null` if the index is out of bounds.
        pub fn peek(self: *Self) ?T {
            const res = self.peek_no_increment();
            if (res != null) {
                self.pindex += 1;
            }
            return res;
        }

        /// Pops off the last peeked element by decrementing the peek index.
        pub fn pop_last_peek(self: *Self) void {
            if (self.pindex > 0) {
                self.pindex -= 1;
            }
        }

        /// Sets the peek pointer to the specified index.
        ///
        /// Parameters:
        /// - `index (usize)`: The index to set the peek pointer to.
        pub fn set_peek_pointer(self: *Self, index: usize) void {
            self.pindex = index;
        }

        /// Sets the peek pointer to the end of the Vector.
        pub fn set_peek_pointer_end(self: *Self) void {
            self.pindex = self.data.items.len;
        }

        /// Pushes an element onto the Vector.
        ///
        /// Parameters:
        /// - `elem (T)`: The element to push onto the Vector.
        ///
        /// Errors:
        /// - Returns an error if the element could not be appended.
        pub fn push(self: *Self, elem: T) !void {
            try self.data.append(elem);
            self.count += 1;
        }

        /// Appends a slice of elements to the Vector.
        ///
        /// This function adds the elements from the provided slice to the end of the Vector.
        ///
        /// Parameters:
        /// - `elems ([]const T)`: The slice of elements to append to the Vector.
        ///
        /// Errors:
        /// - Returns an error if the elements could not be appended.
        ///
        /// Postcondition:
        /// - The count of elements in the Vector is increased by the length of the provided slice.
        pub fn push_slice(self: *Self, elems: []const T) !void {
            try self.data.appendSlice(elems);
            self.count += elems.len;
        }

        /// Inserts an element at the specified index in the Vector.
        ///
        /// Parameters:
        /// - `index (usize)`: The index to insert the element at.
        /// - `elem (T)`: The element to insert.
        ///
        /// Errors:
        /// - Returns an error if the element could not be inserted.
        pub fn push_at(self: *Self, index: usize, elem: T) !void {
            try self.data.insert(index, elem);
            self.count += 1;
        }

        /// Pops an element off the Vector.
        pub fn pop(self: *Self) void {
            if (self.count > 0) {
                self.count -= 1;
                _ = self.data.pop();
            }
        }

        /// Pops the last peeked element off the Vector.
        pub fn peek_pop(self: *Self) void {
            if (self.pindex > 0) {
                self.pindex -= 1;
                _ = self.data.pop();
                self.count -= 1;
            }
        }

        /// Gets the last element in the Vector.
        ///
        /// Returns:
        /// - `?T`: The last element in the Vector, or `null` if the Vector is empty.
        pub fn back(self: *Self) ?T {
            if (self.data.items.len == 0) {
                return null;
            }
            return self.data.items[self.data.items.len - 1];
        }

        /// Checks if the Vector is empty.
        ///
        /// Returns:
        /// - `bool`: `true` if the Vector is empty, otherwise `false`.
        pub fn is_empty(self: *Self) bool {
            return self.data.items.len == 0;
        }

        /// Clears the Vector, retaining its capacity.
        pub fn clear(self: *Self) void {
            self.data.clearRetainingCapacity();
            self.count = 0;
            self.pindex = 0;
        }

        /// Deinitializes the Vector, releasing its resources.
        pub fn deinit(self: Self) void {
            self.data.deinit();
        }
    };
}

test "Vector can be initialized and deinitialized" {
    const allocator = std.testing.allocator;
    var vec = Vector(u8).init(allocator);
    defer vec.deinit();

    try std.testing.expectEqual(0, vec.count);
    try std.testing.expectEqual(0, vec.pindex);
    try std.testing.expect(vec.is_empty());
}

test "Vector can push and retrieve elements" {
    const allocator = std.testing.allocator;
    var vec = Vector(u8).init(allocator);
    defer vec.deinit();

    try vec.push(42);
    try std.testing.expectEqual(1, vec.count);
    try std.testing.expectEqual(42, vec.back().?);
    try std.testing.expectEqual(42, vec.at(0).?);

    try vec.push(100);
    try std.testing.expectEqual(2, vec.count);
    try std.testing.expectEqual(100, vec.back().?);
    try std.testing.expectEqual(100, vec.at(1).?);
}

test "Vector can push slice and retrieve elements" {
    const allocator = std.testing.allocator;
    var vec = Vector(u8).init(allocator);
    defer vec.deinit();

    try vec.push_slice(&[_]u8{ 1, 2, 3, 4, 5 });
    try std.testing.expectEqual(5, vec.count);
    try std.testing.expectEqual(1, vec.at(0).?);
    try std.testing.expectEqual(5, vec.at(4).?);
}

test "Vector can peek and pop elements" {
    const allocator = std.testing.allocator;
    var vec = Vector(u8).init(allocator);
    defer vec.deinit();

    try vec.push(42);
    try vec.push(100);

    try std.testing.expectEqual(42, vec.peek().?);
    try std.testing.expectEqual(100, vec.peek().?);

    vec.pop_last_peek();
    try std.testing.expectEqual(100, vec.peek().?);

    vec.pop();
    try std.testing.expectEqual(1, vec.count);
    try std.testing.expectEqual(42, vec.back().?);

    vec.peek_pop();
    try std.testing.expectEqual(0, vec.count);
    try std.testing.expect(vec.is_empty());
}

test "Vector can clear elements" {
    const allocator = std.testing.allocator;
    var vec = Vector(u8).init(allocator);
    defer vec.deinit();

    try vec.push(42);
    try vec.push(100);
    try std.testing.expectEqual(2, vec.count);

    vec.clear();
    try std.testing.expectEqual(0, vec.count);
    try std.testing.expect(vec.is_empty());
}

test "Vector can set peek pointer" {
    const allocator = std.testing.allocator;
    var vec = Vector(u8).init(allocator);
    defer vec.deinit();

    try vec.push(42);
    try vec.push(100);

    vec.set_peek_pointer(1);
    try std.testing.expectEqual(100, vec.peek().?);

    vec.set_peek_pointer_end();
    try std.testing.expectEqual(null, vec.peek());
}

test "Vector can push at specific index" {
    const allocator = std.testing.allocator;
    var vec = Vector(u8).init(allocator);
    defer vec.deinit();

    try vec.push(42);
    try vec.push(100);
    try vec.push_at(1, 50);

    try std.testing.expectEqual(3, vec.count);
    try std.testing.expectEqual(42, vec.at(0).?);
    try std.testing.expectEqual(50, vec.at(1).?);
    try std.testing.expectEqual(100, vec.at(2).?);
}

test "Vector can retrieve items as slice" {
    const allocator = std.testing.allocator;
    var vec = Vector(u8).init(allocator);
    defer vec.deinit();

    try vec.push(42);
    try vec.push(100);

    const items = vec.items();
    try std.testing.expectEqual(2, items.len);
    try std.testing.expectEqual(42, items[0]);
    try std.testing.expectEqual(100, items[1]);
}

test "Vector can peek at element without incrementing the peek index" {
    const allocator = std.testing.allocator;
    var vec = Vector(u8).init(allocator);
    defer vec.deinit();

    try vec.push(42);
    try vec.push(100);

    const first_peek = vec.peek_no_increment();
    try std.testing.expectEqual(42, first_peek.?);
    try std.testing.expectEqual(42, vec.peek_no_increment().?);

    // Ensure that the peek index has not been incremented
    try std.testing.expectEqual(42, vec.peek().?); // This should still return 42 and increment the peek index

    const second_peek = vec.peek_no_increment();
    try std.testing.expectEqual(100, second_peek.?);
    try std.testing.expectEqual(100, vec.peek_no_increment().?);

    // Ensure that the peek index has only incremented by 1
    try std.testing.expectEqual(100, vec.peek().?); // This should now return 100 and increment the peek index
}
