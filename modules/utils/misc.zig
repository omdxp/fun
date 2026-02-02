const std = @import("std");
const mem = std.mem;
const dtype = @import("semantics").dtype;
const token = @import("lexer").token;
const ast = @import("ast");

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
    return mem.eql(u8, "void", str) or
        mem.eql(u8, "raw", str) or
        mem.eql(u8, "num", str) or mem.eql(u8, "dec", str) or mem.eql(u8, "str", str) or
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
    return mem.eql(u8, "imp", str) or mem.eql(u8, "fun", str) or
        mem.eql(u8, "enum", str) or
        mem.eql(u8, "compound", str) or mem.eql(u8, "quirk", str) or mem.eql(u8, "impl", str) or
        mem.eql(u8, "defer", str) or
        mem.eql(u8, "void", str) or
        mem.eql(u8, "raw", str) or
        mem.eql(u8, "num", str) or mem.eql(u8, "dec", str) or mem.eql(u8, "str", str) or
        mem.eql(u8, "if", str) or mem.eql(u8, "elif", str) or
        mem.eql(u8, "else", str) or mem.eql(u8, "bin", str) or
        mem.eql(u8, "true", str) or mem.eql(u8, "false", str) or
        mem.eql(u8, "fit", str) or mem.eql(u8, "ret", str) or
        mem.eql(u8, "chr", str) or
        mem.eql(u8, "for", str) or
        mem.eql(u8, "break", str) or
        mem.eql(u8, "continue", str);
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
    return op == '(' or op == '[' or op == ',' or op == '*';
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
        op == ',' or op == '.' or op == ':';
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
        mem.eql(u8, ",", op) or mem.eql(u8, ".", op) or mem.eql(u8, "..", op) or mem.eql(u8, "...", op) or
        mem.eql(u8, ":", op) or mem.eql(u8, "::", op) or mem.eql(u8, "~", op) or
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
    if (mem.eql(u8, "void", dt)) return .Void;
    if (mem.eql(u8, "raw", dt)) return .Raw;
    if (mem.eql(u8, "chr", dt)) return .Chr;
    if (mem.eql(u8, "str", dt)) return .Str;
    if (mem.eql(u8, "dec", dt)) return .Dec;
    if (mem.eql(u8, "num", dt)) return .Num;
    if (mem.eql(u8, "bin", dt)) return .Bin;
    return .Unknown;
}

/// Best-effort semantic typing for common C typedef names.
///
/// These identifiers are emitted verbatim in C (`type_str`), but we tag them with a
/// Fun base type so the typechecker can treat them as numeric where appropriate.
///
/// Returns null when the name is not recognized.
pub fn get_c_typedef_alias_datatype_type(dt: []const u8) ?dtype.DataTypeType {
    // `stddef.h`
    if (mem.eql(u8, "size_t", dt)) return .Num;
    if (mem.eql(u8, "ptrdiff_t", dt)) return .Num;
    if (mem.eql(u8, "wchar_t", dt)) return .Num;
    // Optional (C11 Annex K), if provided by the platform headers.
    if (mem.eql(u8, "rsize_t", dt)) return .Num;
    // Common POSIX/C extensions
    if (mem.eql(u8, "ssize_t", dt)) return .Num;
    // `stdint.h`
    if (mem.eql(u8, "intptr_t", dt)) return .Num;
    if (mem.eql(u8, "uintptr_t", dt)) return .Num;
    if (mem.eql(u8, "int8_t", dt)) return .Num;
    if (mem.eql(u8, "uint8_t", dt)) return .Num;
    if (mem.eql(u8, "int16_t", dt)) return .Num;
    if (mem.eql(u8, "uint16_t", dt)) return .Num;
    if (mem.eql(u8, "int32_t", dt)) return .Num;
    if (mem.eql(u8, "uint32_t", dt)) return .Num;
    if (mem.eql(u8, "int64_t", dt)) return .Num;
    if (mem.eql(u8, "uint64_t", dt)) return .Num;
    // `time.h`
    if (mem.eql(u8, "time_t", dt)) return .Num;
    if (mem.eql(u8, "clock_t", dt)) return .Num;
    return null;
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

/// Prints indentation based on the specified depth.
///
/// This function prints a specified number of indentation levels to the provided writer.
/// Each indentation level consists of two spaces.
///
/// Parameters:
/// - `writer (anytype)`: The writer to which the indentation will be printed.
/// - `depth (usize)`: The number of indentation levels to print.
///
/// Errors:
/// - Returns an error if the writer fails to print the indentation.
fn print_indent(writer: anytype, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        try writer.print("  ", .{});
    }
}

// Prints the details of an AST node.
///
/// This function recursively prints the details of the provided AST node to the specified writer,
/// with indentation based on the specified depth. It handles various node types such as expressions,
/// functions, variables, numbers, strings, identifiers, bodies, imports, unary operations, booleans,
/// and different statement types.
///
/// Parameters:
/// - `node (ast.Node)`: The AST node to print.
/// - `writer (anytype)`: The writer to which the node details will be printed.
/// - `depth (usize)`: The current indentation depth.
///
/// Errors:
/// - Returns an error if the writer fails to print the node details.
pub fn print_node(node: ast.Node, writer: anytype, depth: usize) !void {
    try print_indent(writer, depth);
    try writer.print("Node Type: {s}\n", .{@tagName(node.type)});

    switch (node.type) {
        .Expression => {
            if (node.node_variant != null and node.node_variant.?.exp.op.len > 0) {
                try print_indent(writer, depth + 1);
                try writer.print("Operator: {s}\n", .{node.node_variant.?.exp.op});
                if (node.node_variant.?.exp.left) |left| {
                    try print_indent(writer, depth + 1);
                    try writer.print("Left:\n", .{});
                    try print_node(left.*, writer, depth + 2);
                }
                if (node.node_variant.?.exp.right) |right| {
                    try print_indent(writer, depth + 1);
                    try writer.print("Right:\n", .{});
                    try print_node(right.*, writer, depth + 2);
                }
            }
        },
        .Function => {
            if (node.node_variant.?.function.name) |name| {
                try print_indent(writer, depth + 1);
                try writer.print("Name: {s}\n", .{name.items});
            }
            if (node.node_variant.?.function.args) |args| {
                try print_indent(writer, depth + 1);
                try writer.print("Arguments count: {d}\n", .{args.count});
                for (args.items(), 0..) |arg, i| {
                    try print_indent(writer, depth + 1);
                    try writer.print("Arg {d}:\n", .{i});
                    try print_node(arg.*, writer, depth + 2);
                }
            }
            if (node.node_variant.?.function.body) |body| {
                try print_indent(writer, depth + 1);
                try writer.print("Body:\n", .{});
                try print_node(body.*, writer, depth + 2);
            }
        },
        .Variable => {
            if (node.node_variant.?.variable.name.items.len > 0) {
                try print_indent(writer, depth + 1);
                try writer.print("Name: {s}\n", .{node.node_variant.?.variable.name.items});
            }
            if (node.node_variant.?.variable.type.type_str.items.len > 0) {
                try print_indent(writer, depth + 1);
                try writer.print("Type: {s}", .{node.node_variant.?.variable.type.type_str.items});
                if (node.node_variant.?.variable.type.flags.?.is_pointer) {
                    try writer.print(" (pointer depth: {d})", .{node.node_variant.?.variable.type.pointer_depth});
                }
                try writer.print("\n", .{});
            }
            if (node.node_variant.?.variable.val) |val| {
                try print_indent(writer, depth + 1);
                try writer.print("Value:\n", .{});
                try print_node(val.*, writer, depth + 2);
            }
        },
        .Number => {
            if (node.data) |data| {
                try print_indent(writer, depth + 1);
                try writer.print("Value: {d}\n", .{data.llnum});
            }
        },
        .String => {
            if (node.data) |data| {
                try print_indent(writer, depth + 1);
                try writer.print("Value: \"{s}\"\n", .{data.sval.items});
            }
        },
        .Identifier => {
            if (node.data) |data| {
                try print_indent(writer, depth + 1);
                try writer.print("Name: {s}\n", .{data.sval.items});
            }
        },
        .Body => {
            if (node.node_variant != null and node.node_variant.?.body.statements.count > 0) {
                try print_indent(writer, depth + 1);
                try writer.print("Statements count: {d}\n", .{node.node_variant.?.body.statements.count});
                for (node.node_variant.?.body.statements.items(), 0..) |stmt, i| {
                    try print_indent(writer, depth + 1);
                    try writer.print("Statement {d}:\n", .{i});
                    try print_node(stmt.*, writer, depth + 2);
                }
            }
        },
        .Import => {
            if (node.node_variant != null and node.node_variant.?.import.path.len > 0) {
                try print_indent(writer, depth + 1);
                try writer.print("Path: {s}\n", .{node.node_variant.?.import.path});
            }
        },
        .Unary => {
            if (node.node_variant != null) {
                try print_indent(writer, depth + 1);
                try writer.print("Operator: {s}\n", .{node.node_variant.?.unary.op});
                if (node.node_variant.?.unary.indirection) |ind| {
                    try print_indent(writer, depth + 1);
                    try writer.print("Indirection depth: {d}\n", .{ind.depth});
                }
                try print_indent(writer, depth + 1);
                try writer.print("Operand:\n", .{});
                try print_node(node.node_variant.?.unary.operand.*, writer, depth + 2);
            }
        },
        .Boolean => {
            if (node.node_variant != null) {
                try print_indent(writer, depth + 1);
                try writer.print("Value: {s}\n", .{if (node.node_variant.?.boolean.val) "true" else "false"});
            }
        },
        .StatementIf => {
            if (node.node_variant != null) {
                try print_indent(writer, depth + 1);
                try writer.print("Condition:\n", .{});
                try print_node(node.node_variant.?.statement.if_stmt.condition.*, writer, depth + 2);
                try print_indent(writer, depth + 1);
                try writer.print("Body:\n", .{});
                try print_node(node.node_variant.?.statement.if_stmt.body.*, writer, depth + 2);
            }
        },
        .StatementElseIf => {
            if (node.node_variant != null) {
                try print_indent(writer, depth + 1);
                try writer.print("Condition:\n", .{});
                try print_node(node.node_variant.?.statement.elif_stmt.condition.*, writer, depth + 2);
                try print_indent(writer, depth + 1);
                try writer.print("Body:\n", .{});
                try print_node(node.node_variant.?.statement.elif_stmt.body.*, writer, depth + 2);
            }
        },
        .StatementElse => {
            if (node.node_variant != null) {
                try print_indent(writer, depth + 1);
                try writer.print("Body:\n", .{});
                try print_node(node.node_variant.?.statement.else_stmt.body.*, writer, depth + 2);
            }
        },
        .StatementFit => {
            if (node.node_variant != null) {
                try print_indent(writer, depth + 1);
                try writer.print("Expression:\n", .{});
                try print_node(node.node_variant.?.statement.fit_stmt.exp.*, writer, depth + 2);
                if (node.node_variant.?.statement.fit_stmt.branches.count > 0) {
                    try print_indent(writer, depth + 1);
                    try writer.print("Branches ({d}):\n", .{node.node_variant.?.statement.fit_stmt.branches.count});
                    for (node.node_variant.?.statement.fit_stmt.branches.items(), 0..) |branch, i| {
                        try print_indent(writer, depth + 2);
                        try writer.print("Branch {d}:\n", .{i});
                        if (branch.condition) |condition| {
                            try print_indent(writer, depth + 3);
                            try writer.print("Condition:\n", .{});
                            try print_node(condition.*, writer, depth + 4);
                        } else {
                            try print_indent(writer, depth + 3);
                            try writer.print("Default branch\n", .{});
                        }
                        try print_indent(writer, depth + 3);
                        try writer.print("Body:\n", .{});
                        try print_node(branch.body.*, writer, depth + 4);
                    }
                }
            }
        },
        .Bracket => {
            if (node.node_variant != null) {
                try print_indent(writer, depth + 1);
                try writer.print("Index:\n", .{});
                try print_node(node.node_variant.?.bracket.inner.*, writer, depth + 2);
            }
        },
        .ExpressionParenthesis => {
            if (node.node_variant != null) {
                try print_indent(writer, depth + 1);
                try writer.print("Inner:\n", .{});
                try print_node(node.node_variant.?.paren.exp.*, writer, depth + 2);
            }
        },
        .StatementReturn => {
            if (node.node_variant != null) {
                try print_indent(writer, depth + 1);
                try writer.print("Value:\n", .{});
                try print_node(node.node_variant.?.statement.return_stmt.*, writer, depth + 2);
            }
        },
        else => {
            // Print the node type for unhandled node types
            try print_indent(writer, depth + 1);
            try writer.print("(Unhandled node type details)\n", .{});
        },
    }
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
        /// A packed struct containing flags for various operations.
        flags: packed struct {
            /// A boolean flag initialized to `false`. This flag can be used to indicate
            /// whether a peek operation should decrement a counter or not.
            peek_decrement: bool = false,
        },
        /// The internal ArrayList for storing elements.
        data: std.ArrayList(T),
        /// The peek index for accessing elements without removing them.
        pindex: isize = 0,
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
                .flags = .{ .peek_decrement = false },
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
            if (self.pindex < 0 or self.pindex >= self.count) {
                return null;
            }
            return self.at(@intCast(self.pindex));
        }

        /// Peeks at the element at the peek index and increments the peek index.
        ///
        /// Returns:
        /// - `?T`: The element at the peek index, or `null` if the index is out of bounds.
        pub fn peek(self: *Self) ?T {
            const res = self.peek_no_increment();
            if (res != null) {
                if (self.flags.peek_decrement) {
                    self.pindex -= 1;
                } else {
                    self.pindex += 1;
                }
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
            self.pindex = @intCast(index);
        }

        /// Sets the peek pointer to the end of the Vector.
        pub fn set_peek_pointer_end(self: *Self) void {
            if (self.data.items.len > 0)
                self.pindex = @intCast(self.data.items.len - 1);
        }

        /// Pushes an element onto the Vector.
        ///
        /// Parameters:
        /// - `elem (T)`: The element to push onto the Vector.
        ///
        /// Errors:
        /// - Returns an error if the element could not be appended.
        pub fn push(self: *Self, elem: T) mem.Allocator.Error!void {
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
        pub fn back(self: Self) ?T {
            if (self.data.items.len == 0) {
                return null;
            }
            return self.data.items[self.data.items.len - 1];
        }

        /// Checks if the Vector is empty.
        ///
        /// Returns:
        /// - `bool`: `true` if the Vector is empty, otherwise `false`.
        pub fn is_empty(self: Self) bool {
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
