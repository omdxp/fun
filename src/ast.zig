const std = @import("std");
const mem = std.mem;
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
    /// Represents a bracket node.
    Bracket,
    /// Represents a blank node.
    Blank,
};

/// Represents a node in the abstract syntax tree (AST).
pub const Node = struct {
    /// Flags representing characteristics of the node.
    flags: ?NodeFlags = null,
    /// The specific type of the node.
    type: NodeType,
    /// The position of the node in the source code.
    pos: ?token.Pos = null,
    binded: ?struct {
        /// The owner of the node.
        owner: ?*Node,
        /// The function associated with the node.
        function: ?*Node,
    } = null,
    /// The token data associated with the node.
    data: ?token.TokenData = null,
    node_variant: ?union(enum) {
        exp: struct {
            /// The left-hand side of the expression.
            left: *Node,
            /// The right-hand side of the expression.
            right: ?*Node = null,
            /// The operator used in the expression.
            op: []const u8,
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
        unary: struct {
            /// Indicates if the unary operator is left-operanded.
            is_left_operanded_unary: bool = false,
            /// The unary operator.
            op: []const u8,
            /// The operand of the unary operation.
            operand: *Node,
            /// Optional indirection information.
            indirection: ?struct {
                /// The depth of indirection.
                depth: usize,
            } = null,
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
    } = null,
};

/// Checks if the node is an expression or a parenthesis.
///
/// This function determines if the given node (`n`) is of type `.Expression`
/// or `.ExpressionParenthesis`.
///
/// Returns:
/// - `bool`: `true` if the node is an expression or a parenthesis, otherwise `false`.
///
/// Parameters:
/// - `n (Node)`: The node to check.
pub fn node_is_expression_or_parenthesis(n: Node) bool {
    return n.type == .Expression or n.type == .ExpressionParenthesis;
}

/// Checks if the node is a value type.
///
/// This function determines if the given node (`n`) is of a value type, which includes:
/// - Expression or ExpressionParenthesis
/// - Identifier
/// - Number
/// - Unary
/// - Tenary
/// - String
///
/// Returns:
/// - `bool`: `true` if the node is a value type, otherwise `false`.
///
/// Parameters:
/// - `n (Node)`: The node to check.
pub fn node_is_value_type(n: Node) bool {
    return node_is_expression_or_parenthesis(n) or
        n.type == .Identifier or n.type == .Number or
        n.type == .Unary or n.type == .Tenary or
        n.type == .String;
}

/// Checks if the node is expressionable.
///
/// This function determines if the given node (`n`) is of a type that can be part of an expression.
/// The types considered expressionable are:
/// - Expression
/// - ExpressionParenthesis
/// - Unary
/// - Identifier
/// - Number
/// - String
///
/// Returns:
/// - `bool`: `true` if the node is expressionable, otherwise `false`.
///
/// Parameters:
/// - `n (Node)`: The node to check.
pub fn node_is_expressionable(n: Node) bool {
    return n.type == .Expression or n.type == .ExpressionParenthesis or
        n.type == .Unary or n.type == .Identifier or
        n.type == .Number or n.type == .String;
}

/// Checks if the node is an array expression.
///
/// This function determines if the given node (`n`) is of type `.Expression`
/// and if its operation is an array operator.
///
/// Returns:
/// - `bool`: `true` if the node is an array expression, otherwise `false`.
///
/// Parameters:
/// - `n (Node)`: The node to check.
pub fn node_is_array(n: Node) bool {
    return n.type == .Expression and misc.is_array_operator(n.node_variant.?.exp.op);
}

/// Checks if the node is an assignment expression.
///
/// This function determines if the given node (`n`) is of type `.Expression`
/// and if its operation is an assignment operator. The assignment operators checked are:
/// `"="`, `"+="`, `"-="`, `"*="`, `"/="`, `"%="`, `"&="`, `"|="`, `"^="`, `"<<="`, `">>="`.
///
/// Returns:
/// - `bool`: `true` if the node is an assignment expression, otherwise `false`.
///
/// Parameters:
/// - `n (Node)`: The node to check.
pub fn node_is_assignment(n: Node) bool {
    if (n.type != .Expression) {
        return false;
    }
    const op = n.node_variant.?.exp.op;
    return mem.eql(u8, "=", op) or mem.eql(u8, "+=", op) or
        mem.eql(u8, "-=", op) or mem.eql(u8, "*=", op) or
        mem.eql(u8, "/=", op) or mem.eql(u8, "%=", op) or
        mem.eql(u8, "&=", op) or mem.eql(u8, "|=", op) or
        mem.eql(u8, "^=", op) or mem.eql(u8, "<<=", op) or
        mem.eql(u8, ">>=", op);
}

/// Checks if the node is an expression with a specific operator.
///
/// This function determines if the given node (`n`) is of type `.Expression`
/// and if its operation matches the specified operator (`op`).
///
/// Returns:
/// - `bool`: `true` if the node is an expression with the specified operator, otherwise `false`.
///
/// Parameters:
/// - `n (Node)`: The node to check.
/// - `op ( []const u8 )`: The operator to check against.
pub fn node_is_expression(n: Node, op: []const u8) bool {
    return n.type == .Expression and mem.eql(u8, n.node_variant.?.exp.op, op);
}
