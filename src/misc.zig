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
        pub fn at(self: *Self, index: usize) T {
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
