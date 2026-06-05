const std = @import("std");
const mem = std.mem;
const token = @import("lexer").token;
const semantics = @import("semantics");
const dtype = semantics.dtype;
const utils = @import("utils");
pub const expressionable = @import("expressionable.zig");

/// Compatibility shim: ArrayList with embedded allocator (old-style managed API).
fn ArrayList(comptime T: type) type {
    return std.array_list.Managed(T);
}

/// Flags representing characteristics of a node.
pub const NodeFlags = packed struct {
    /// Indicates if the node is inside an expression.
    inside_expression: bool = false,
    /// Indicates if the node has a combined variable.
    has_variable_combined: bool = false,
    /// Indicates if the node is publicly visible outside its module.
    is_public: bool = false,
    /// Indicates if the declaration node was referenced by semantic analysis.
    is_used: bool = false,
};

/// Stable warning identifiers used by diagnostics and warning controls.
pub const WarningId = enum {
    return_local_ptr,
    fit_non_exhaustive,
    fit_unreachable_branch,
    unreachable_code,
    assert_constant,
    unused_variable,
    unused_import,
    unused_function,
    unused_compound,
};

/// Intent controls for warning diagnostics.
pub const WarningControlAction = enum {
    allow,
    expect,
};

pub fn warning_id_from_string(name: []const u8) ?WarningId {
    if (mem.eql(u8, name, "return_local_ptr")) return .return_local_ptr;
    if (mem.eql(u8, name, "fit_non_exhaustive")) return .fit_non_exhaustive;
    if (mem.eql(u8, name, "fit_unreachable_branch")) return .fit_unreachable_branch;
    if (mem.eql(u8, name, "unreachable_code")) return .unreachable_code;
    if (mem.eql(u8, name, "assert_constant")) return .assert_constant;
    if (mem.eql(u8, name, "unused_variable")) return .unused_variable;
    if (mem.eql(u8, name, "unused_import")) return .unused_import;
    if (mem.eql(u8, name, "unused_function")) return .unused_function;
    if (mem.eql(u8, name, "unused_compound")) return .unused_compound;
    return null;
}

pub fn warning_id_to_string(id: WarningId) []const u8 {
    return switch (id) {
        .return_local_ptr => "return_local_ptr",
        .fit_non_exhaustive => "fit_non_exhaustive",
        .fit_unreachable_branch => "fit_unreachable_branch",
        .unreachable_code => "unreachable_code",
        .assert_constant => "assert_constant",
        .unused_variable => "unused_variable",
        .unused_import => "unused_import",
        .unused_function => "unused_function",
        .unused_compound => "unused_compound",
    };
}

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
    /// Represents a character node.
    Character,
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
    /// Represents a defer statement node.
    StatementDefer,
    /// Represents an inline assembly statement node.
    StatementAsm,
    /// Represents an if statement node.
    StatementIf,
    /// Represents a boolean node.
    Boolean,
    /// Represents the `nil` literal (a null pointer/string sentinel; emits C `NULL`).
    Nil,
    /// Represents a `fork` statement node (fire-and-forget virtual-thread spawn).
    StatementFork,
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
    /// Represents an assert statement node.
    StatementAssert,
    /// Represents warning control statements (`allow` / `expect`).
    StatementWarningControl,
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
    /// Represents a compound initializer (e.g. `Type{...}` or `.{...}`).
    CompoundInit,
    /// Represents an import node.
    Import,
    /// Represents a user-defined compound type declaration.
    Compound,
    /// Represents a quirk (structural interface) declaration.
    Quirk,
    /// Represents an enum declaration.
    Enum,
    /// Represents an implementation block binding a compound type to a quirk.
    Impl,
    /// Represents a blank node.
    Blank,
};

/// Represents a binded node.
pub const BindedNode = struct {
    /// The owner of the node.
    owner: ?*Node,
    /// The function associated with the node.
    function: ?*Node,
};

/// Represents a node in the abstract syntax tree (AST).
pub const Node = struct {
    /// Flags representing characteristics of the node.
    flags: ?NodeFlags = null,
    /// The specific type of the node.
    type: NodeType,
    /// The position of the node in the source code.
    pos: ?token.Pos = null,
    /// The binded node associated with the node.
    binded: ?*BindedNode = null,
    /// The token data associated with the node.
    data: ?token.TokenData = null,
    /// The variant data associated with the node.
    node_variant: ?union(enum) {
        /// The import node.
        import: struct {
            /// The path of the import.
            path: []const u8,
            /// Optional namespace alias (`imp foo.bar as baz;`).
            alias: ?[]const u8 = null,
        },
        /// The boolean node.
        boolean: struct {
            /// The boolean value of the node.
            val: bool,
        },
        /// The expression node.
        exp: struct {
            /// The left-hand side of the expression.
            left: ?*Node = null,
            /// The right-hand side of the expression.
            right: ?*Node = null,
            /// The operator used in the expression.
            op: []const u8,
        },
        /// The expression in parentheses node.
        paren: struct {
            /// The expression inside the parentheses.
            exp: *Node,
        },
        /// The variable node.
        variable: struct {
            /// The data type of the variable.
            type: *dtype.DataType,
            /// The name of the variable.
            name: ArrayList(u8),
            /// The value of the variable.
            val: ?*Node = null,
        },
        /// The unary node.
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
        /// The tenary node.
        tenary: struct {
            /// The condition of the tenary expression.
            condition: *Node,
            /// The expression for the true condition.
            true: *Node,
            /// The expression for the false condition.
            false: *Node,
        },
        /// The bracket node.
        bracket: struct {
            /// The inner expression of the bracket.
            inner: *Node,
        },
        /// The compound initializer node.
        compound_init: struct {
            /// Optional type (present for `Type{...}`, inferred for `.{...}`).
            dtype: ?*dtype.DataType = null,
            fields: utils.Vector(CompoundInitField),
        },
        /// The body node.
        body: struct {
            /// The statements inside the body.
            statements: utils.Vector(*Node),
        },
        /// The function node.
        function: struct {
            /// The return type of the function.
            rtype: ?dtype.DataType = null,
            /// The name of the function.
            name: ?ArrayList(u8) = null,
            /// Optional generic type parameters.
            type_params: ?utils.Vector(ArrayList(u8)) = null,
            /// The arguments of the function.
            args: ?utils.Vector(*Node) = null,
            /// Whether the function was declared with the `async` keyword.
            is_async: bool = false,
            /// Whether the function is variadic (C-style varargs).
            is_variadic: bool = false,
            /// The body of the function.
            body: ?*Node = null,
        },

        compound: struct {
            name: ArrayList(u8),
            fields: utils.Vector(CompoundField),
            /// Optional generic type parameters (e.g. Vec<T> -> ["T"]).
            type_params: ?utils.Vector(ArrayList(u8)) = null,
        },

        quirk: struct {
            name: ArrayList(u8),
            methods: utils.Vector(QuirkMethodSig),
        },

        enum_decl: struct {
            name: ArrayList(u8),
            variants: utils.Vector(EnumVariant),
        },

        impl: struct {
            type_name: ArrayList(u8),
            /// Optional generic type parameters for impl blocks.
            type_params: ?utils.Vector(ArrayList(u8)) = null,
            /// Forced concrete type combinations derived from constrained type parameters.
            /// E.g. `impl Vec<T: num | dec>` yields [["num"], ["dec"]].
            /// Each inner vector maps one concrete type name per param (parallel to type_params).
            type_param_forced_insts: ?utils.Vector(utils.Vector(ArrayList(u8))) = null,
            /// Optional quirk name. When null, this is a plain impl block: `impl Type { ... }`.
            quirk_name: ?ArrayList(u8) = null,
            methods: utils.Vector(*Node),
        },
        /// The statement node.
        statement: union(enum) {
            /// The return statement node.
            return_stmt: *Node,
            /// The defer statement node.
            defer_stmt: struct {
                body: *Node,
            },
            /// The inline assembly statement node.
            asm_stmt: struct {
                /// Assembly template text.
                template: ArrayList(u8),
                /// Whether the asm is volatile.
                is_volatile: bool = false,
                /// Optional target architecture name.
                arch: ?ArrayList(u8) = null,
                /// Output operands.
                outputs: utils.Vector(AsmOperand),
                /// Input operands.
                inputs: utils.Vector(AsmOperand),
                /// Clobber list (string literals).
                clobbers: utils.Vector(ArrayList(u8)),
                /// Whether the template was provided as a string literal.
                is_string_literal: bool = false,
            },
            /// The for statement node.
            for_stmt: union(enum) {
                /// Condition/infinite loop: `for { ... }` or `for cond { ... }`
                ///
                /// When `condition` is null, the loop is infinite.
                cond: struct {
                    condition: ?*Node = null,
                    body: *Node,
                },
                /// For range: `for i : start..end { ... }`
                range: struct {
                    index_name: []const u8,
                    range: *Node,
                    body: *Node,
                },
                /// For iterable array: `for item : arr { ... }` or `for i, item :: arr { ... }`
                iter: struct {
                    index_name: ?[]const u8 = null,
                    item_name: []const u8,
                    iterable: *Node,
                    body: *Node,
                },
            },
            /// The if statement node.
            if_stmt: struct {
                /// The condition of the if statement.
                condition: *Node,
                /// The body of the if statement.
                body: *Node,
            },
            /// The elif statement node.
            elif_stmt: struct {
                /// The condition of the elif statement.
                condition: *Node,
                /// The body of the elif statement.
                body: *Node,
            },
            /// The else statement node.
            else_stmt: struct {
                /// The body of the else statement.
                body: *Node,
            },
            /// The fit statement node.
            fit_stmt: struct {
                /// The expression for the fit statement.
                exp: *Node,
                /// The branches of the fit statement.
                branches: utils.Vector(FitBranch),
                /// Indicates if the fit statement has a default branch.
                has_default_branch: bool,
            },
            /// The assert statement node.
            assert_stmt: struct {
                /// The condition to assert.
                condition: *Node,
                /// Optional message expression (should be str).
                message: ?*Node = null,
            },
            /// Warning control statement.
            warning_ctrl: struct {
                action: WarningControlAction,
                id: WarningId,
                /// Intent rationale from source string literal.
                reason: []const u8,
            },
            /// The `fork` (fire-and-forget virtual-thread spawn) statement node.
            fork_stmt: struct {
                /// The expression to spawn; must resolve to a function call at codegen.
                expr: *Node,
            },
        },
    } = null,
};

pub const CompoundField = struct {
    name: ArrayList(u8),
    dtype: *dtype.DataType,
};

pub const CompoundInitField = struct {
    name: ArrayList(u8),
    value: *Node,
};

pub const QuirkMethodSig = struct {
    name: ArrayList(u8),
    rtype: dtype.DataType,
    args: utils.Vector(QuirkArg),
    is_async: bool = false,
};

pub const QuirkArg = struct {
    name: ArrayList(u8),
    dtype: *dtype.DataType,
};

pub const EnumVariant = struct {
    name: ArrayList(u8),
    /// Optional explicit integer value (`Variant = 3;`).
    /// When null, values auto-increment from 0 following C enum rules.
    value: ?i64 = null,
    /// Optional positional payload types for a data-carrying variant, e.g.
    /// `Circle(num)` -> [num], `Rect(num, num)` -> [num, num]. When null the
    /// variant carries no data (a plain C-style enumerator). An enum is a tagged
    /// union (sum type) iff ANY of its variants has a payload.
    payload: ?utils.Vector(*dtype.DataType) = null,
};

/// Represents the branches in a fit statement.
pub const FitBranch = struct {
    /// The condition of the branch statement.
    condition: ?*Node = null,
    /// The body of the branch statement.
    body: *Node,
    /// For a data-carrying enum arm (`Shape.Circle(r)` / `.Rect(w, h)`), the
    /// positional binding names that destructure the matched variant's payload
    /// into locals visible in `body`. Null/empty for plain (non-destructuring)
    /// arms. The condition node holds the variant path (`Shape.Circle`); the
    /// payload arg list is captured here so codegen can emit the bindings.
    bindings: ?utils.Vector(ArrayList(u8)) = null,
};

pub const AsmOperand = struct {
    name: ArrayList(u8),
    constraint: ArrayList(u8),
    expr: *Node,
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
        n.type == .String or n.type == .Character or n.type == .CompoundInit;
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
        n.type == .Number or n.type == .String or n.type == .Character or n.type == .Boolean or
        n.type == .CompoundInit;
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
    return n.type == .Expression and utils.is_array_operator(n.node_variant.?.exp.op);
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
