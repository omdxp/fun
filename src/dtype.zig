const std = @import("std");
const ast = @import("./ast.zig");

/// Flags representing characteristics of a data type.
pub const DataTypeFlags = packed struct {
    /// Indicates if the data type is a pointer.
    is_pointer: bool = false,
    /// Indicates if the data type is a literal.
    is_literal: bool = false,
};

/// Types of data types.
///
/// This enum defines the various types of data that can be represented.
pub const DataTypeType = enum {
    /// Represents a void type.
    Void,
    /// Represents a character type.
    Chr,
    /// Represents a string type.
    Str,
    /// Represents a number type.
    Num,
    /// Represents a boolean type.
    Bin,
    /// Represents an unknown type.
    Unknown,
};

/// Represents a data type in the context of the transpiler.
///
/// This struct defines a data type, including its flags, type, string representation,
/// pointer depth, and array information.
pub const DataType = struct {
    /// Flags representing characteristics of the data type.
    flags: DataTypeFlags,
    /// The specific type of data.
    type: DataTypeType,
    /// A string representation of the data type.
    type_str: std.ArrayList(u8),
    /// The depth of pointers if the data type is a pointer.
    pointer_depth: usize,
    /// Information about the array dimensions and brackets.
    array: struct {
        brackets: std.ArrayList(ast.Node),
    },
};
