const std = @import("std");
const ast = @import("ast");
const utils = @import("utils");

/// Flags representing characteristics of a data type.
pub const DataTypeFlags = packed struct {
    /// Indicates if the data type is a pointer.
    is_pointer: bool = false,
    /// Indicates if the data type is a literal.
    is_literal: bool = false,
    /// Indicates if the data type is an array.
    is_array: bool = false,
};

/// Types of data types.
///
/// This enum defines the various types of data that can be represented.
pub const DataTypeType = enum {
    /// Represents a void type.
    Void,
    /// Represents a raw/opaque type (C `void`).
    Raw,
    /// Represents a character type.
    Chr,
    /// Represents a string type.
    Str,
    /// Represents a decimal (floating-point) number type.
    Dec,
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
    flags: ?DataTypeFlags = null,
    /// The specific type of data.
    type: ?DataTypeType = null,
    /// A string representation of the data type.
    type_str: std.ArrayList(u8),
    /// The depth of pointers if the data type is a pointer.
    pointer_depth: usize = 0,
    /// Information about the array dimensions and brackets.
    array: ?struct {
        /// The dimensions of the array.
        brackets: utils.Vector(ast.Node),
    } = null,

    /// The depth of array dimensions (e.g. 1 for num[], 2 for num[][], etc.).
    array_depth: usize = 0,

    /// Optional generic arguments (e.g. Vec<num> -> [num]).
    generic_args: ?utils.Vector(*DataType) = null,
};
