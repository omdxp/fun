const std = @import("std");
const token = @import("./token.zig");
const dtype = @import("./dtype.zig");
const misc = @import("./misc.zig");

/// Flags representing characteristics of a node.
pub const NodeFlags = packed struct {
    /// Indicates if the node is inside an expression.
    inside_expression: bool = false,
    /// Indicates if the node has a combined variable.
    has_variable_combined: bool = false,
};

/// Types of nodes.
pub const NodeType = enum {
    /// Represents an expression node.
    Expression,
    /// Represents a parenthesis expression node.
    ExpressionParenthesis,
    /// Represents a number node.
    Number,
    /// Represents an identifier node.
    Identifier,
    /// Represents a string node.
    String,
    /// Represents a variable node.
    Variable,
    /// Represents a variable list node.
    VariableList,
    /// Represents a function node.
    Function,
    /// Represents a body node.
    Body,
    /// Represents a return statement node.
    StatementReturn,
    /// Represents an if statement node.
    StatementIf,
    /// Represents an elif statement node.
    StatementElseIf,
    /// Represents an else statement node.
    StatementElse,
    /// Represents a for statement node.
    StatementFor,
    /// Represents a break statement node.
    StatementBreak,
    /// Represents a continue statement node.
    StatementContinue,
    /// Represents a fit statement node.
    StatementFit,
    /// Represents a case statement node.
    StatementCase,
    /// Represents a default statement node.
    StatementDefault,
    /// Represents a unary node.
    Unary,
    /// Represents a tenary node.
    Tenary,
    /// Represents a blank node.
    Blank,
};

/// Represents a node in the abstract syntax tree (AST).
pub const Node = struct {
    /// Flags representing characteristics of the node.
    flags: NodeFlags,
    /// The specific type of the node.
    type: NodeType,
    /// The position of the node in the source code.
    pos: token.Pos,
    binded: struct {
        /// The owner of the node.
        owner: *Node,
        /// The function associated with the node.
        function: *Node,
    },
    /// The token data associated with the node.
    data: token.TokenData,
    node_variant: union(enum) {
        exp: struct {
            /// The left-hand side of the expression.
            left: *Node,
            /// The right-hand side of the expression.
            right: *Node,
            /// The operator used in the expression.
            op: std.ArrayList(u8),
        },
        paren: struct {
            /// The expression inside the parentheses.
            exp: *Node,
        },
        variable: struct {
            /// The data type of the variable.
            type: dtype.DataType,
            /// The name of the variable.
            name: std.ArrayList(u8),
            /// The value of the variable.
            val: *Node,
        },
        tenary: struct {
            /// The expression for the true condition.
            true: *Node,
            /// The expression for the false condition.
            false: *Node,
        },
        bracket: struct {
            /// The inner expression of the bracket.
            inner: *Node,
        },
        body: struct {
            /// The statements inside the body.
            statements: misc.Vector(*Node),
        },
        function: struct {
            /// The return type of the function.
            rtype: dtype.DataType,
            /// The name of the function.
            name: std.ArrayList(u8),
            /// The arguments of the function.
            args: misc.Vector(*Node),
        },
        statement: struct {
            return_stmt: struct {
                /// The return statement node.
                return_stmt: *Node,
            },
            if_stmt: struct {
                /// The condition of the if statement.
                condition: *Node,
                /// The body of the if statement.
                body: *Node,
                /// The next node (else or else-if).
                next: *Node,
            },
            else_stmt: struct {
                /// The body of the else statement.
                body: *Node,
            },
            fit_stmt: struct {
                /// The expression for the fit statement.
                exp: *Node,
                /// The body of the fit statement.
                body: *Node,
                /// The branches of the fit statement.
                branches: misc.Vector(u8), // index of parsed branch
                /// Indicates if the fit statement has a default branch.
                has_default_branch: bool,
            },
            branch_stmt: struct {
                /// The expression for the branch statement.
                exp: *Node,
            },
        },
    },
};
