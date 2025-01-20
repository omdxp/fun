const std = @import("std");

/// Enum representing operator associativity directions.
pub const Associativity = enum { LeftToRight, RightToLeft };

/// Maximum number of operators in a precedence group.
pub const MAX_OPERATORS_IN_GROUP = 12;
/// Total number of operator precedence groups.
pub const TOTAL_OPERATOR_GROUPS = 13;

/// Structure representing an operator precedence group.
pub const OpPrecedenceGroup = struct {
    /// Array of operators in the precedence group.
    operators: [MAX_OPERATORS_IN_GROUP]?[]const u8,
    /// Associativity direction of the operators in the group.
    associativity: ?Associativity = null,
};

/// Array of operator precedence groups.
pub const op_precedence = [_]OpPrecedenceGroup{
    OpPrecedenceGroup{
        .operators = [_]?[]const u8{ "++", "--", "()", "[]", "(", "[", ".", null, null, null, null, null },
        .associativity = .LeftToRight,
    },
    OpPrecedenceGroup{
        .operators = [_]?[]const u8{ "*", "/", "%", null, null, null, null, null, null, null, null, null },
        .associativity = .LeftToRight,
    },
    OpPrecedenceGroup{
        .operators = [_]?[]const u8{ "+", "-", null, null, null, null, null, null, null, null, null, null },
        .associativity = .LeftToRight,
    },
    OpPrecedenceGroup{
        .operators = [_]?[]const u8{ "<<", ">>", null, null, null, null, null, null, null, null, null, null },
        .associativity = .LeftToRight,
    },
    OpPrecedenceGroup{
        .operators = [_]?[]const u8{ "<", "<=", ">", ">=", null, null, null, null, null, null, null, null },
        .associativity = .LeftToRight,
    },
    OpPrecedenceGroup{
        .operators = [_]?[]const u8{ "==", "!=", null, null, null, null, null, null, null, null, null, null },
        .associativity = .LeftToRight,
    },
    OpPrecedenceGroup{
        .operators = [_]?[]const u8{ "&", null, null, null, null, null, null, null, null, null, null, null },
        .associativity = .LeftToRight,
    },
    OpPrecedenceGroup{
        .operators = [_]?[]const u8{ "^", null, null, null, null, null, null, null, null, null, null, null },
        .associativity = .LeftToRight,
    },
    OpPrecedenceGroup{
        .operators = [_]?[]const u8{ "|", null, null, null, null, null, null, null, null, null, null, null },
        .associativity = .LeftToRight,
    },
    OpPrecedenceGroup{
        .operators = [_]?[]const u8{ "&&", null, null, null, null, null, null, null, null, null, null, null },
        .associativity = .LeftToRight,
    },
    OpPrecedenceGroup{
        .operators = [_]?[]const u8{ "||", null, null, null, null, null, null, null, null, null, null, null },
        .associativity = .LeftToRight,
    },
    OpPrecedenceGroup{
        .operators = [_]?[]const u8{ "=", "+=", "-=", "*=", "/=", "%=", "<<=", ">>=", "&=", "^=", "|=", null },
        .associativity = .RightToLeft,
    },
    OpPrecedenceGroup{
        .operators = [_]?[]const u8{ ",", null, null, null, null, null, null, null, null, null, null, null },
        .associativity = .LeftToRight,
    },
};
