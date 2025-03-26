const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const assert = std.debug.assert;
const token = @import("./token.zig");
const ast = @import("./ast.zig");
const misc = @import("./misc.zig");
const scope = @import("./scope.zig");

/// TranspileProcessFlags is an enumeration that defines flags for the transpile process.
pub const TranspileProcessFlags = packed struct {
    /// Flag to indicate execution process. When true, the output will be compiled and executed.
    exec: bool = true,
    /// Flag to indicate output file process. When true, the .c file will be generated.
    outf: bool = false,
    /// Flag to print AST nodes. When true, prints the Abstract Syntax Tree nodes.
    ast: bool = false,
};

/// `TranspileProcess` represents the state and configuration of a transpilation process.
pub const TranspileProcess = struct {
    /// `flags` is a set of flags that control the behavior of the transpilation process.
    flags: TranspileProcessFlags,
    /// `pos` is the current position in the token stream.
    pos: token.Pos,
    /// `ifile` is the input file being read for transpilation.
    ifile: fs.File,
    /// `ofile` is the output file where the transpiled code will be written.
    /// Only used when outf flag is true.
    ofile: ?fs.File,
    /// Buffer to store generated C code when outf is false
    outbuf: ?std.ArrayList(u8),
    /// `tokens` is a vector of tokens generated from the input file.
    tokens: misc.Vector(token.Token),
    /// `nodes` is a list of AST (Abstract Syntax Tree) nodes.
    /// This vector holds the nodes that are part of the AST being processed by the transpiler.
    nodes: misc.Vector(ast.Node),
    /// Represents a scope structure used in the transpiler.
    scope: ?struct {
        /// A pointer to the root scope.
        root: ?*scope.Scope,
        /// A pointer to the current scope.
        current: ?*scope.Scope,
    } = null,
    /// The allocator to be used for memory allocation operations.
    allocator: mem.Allocator,

    const Self = @This();

    /// Initializes a new instance of `TranspileProcess`.
    ///
    /// This function opens the input file in read-only mode and creates the output file
    /// with read permissions. It also initializes the token list with the provided allocator.
    ///
    /// Parameters:
    /// - `allocator`: The memory allocator to use for memory allocation operations.
    /// - `ifilepath`: The file path of the input file.
    /// - `ofilepath`: The file path of the output file.
    /// - `flags`: The flags to set for the transpiler.
    ///
    /// Returns:
    /// - `Self`: A new instance of `TranspileProcess`.
    ///
    /// Errors:
    /// - Returns an error if opening the input file or creating the output file fails.
    pub fn init(allocator: mem.Allocator, ifilepath: []const u8, ofilepath: []const u8, flags: TranspileProcessFlags) !Self {
        const ifile = try fs.cwd().openFile(ifilepath, .{ .mode = .read_write });
        var ofile: ?fs.File = null;
        var outbuf: ?std.ArrayList(u8) = null;

        if (flags.outf) {
            ofile = try fs.cwd().createFile(ofilepath, .{ .read = true });
        } else {
            outbuf = std.ArrayList(u8).init(allocator);
        }

        return Self{
            .flags = flags,
            .pos = .{ .col = 1, .line = 1, .filename = ifilepath },
            .ifile = ifile,
            .ofile = ofile,
            .outbuf = outbuf,
            .tokens = misc.Vector(token.Token).init(allocator),
            .nodes = misc.Vector(ast.Node).init(allocator),
            .allocator = allocator,
        };
    }

    /// Logs an error message with the current position in the token stream.
    ///
    /// This function logs an error message along with the line number, column number,
    /// and filename where the error occurred, then panics.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `fmt`: The format string for the error message.
    /// - `args`: The arguments for the format string.
    pub fn err(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.deinit();
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        std.debug.panic("Error: {s} in {s}:{d}:{d}\n", .{
            msg,
            self.pos.filename,
            self.pos.line,
            self.pos.col,
        });
    }

    /// Logs a warning message with the current position in the token stream.
    ///
    /// This function logs a warning message along with the line number, column number,
    /// and filename where the warning occurred.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `fmt`: The format string for the warning message.
    /// - `args`: The arguments for the format string.
    pub fn warn(self: *Self, fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        std.debug.print("Warning: {s} in {s}:{d}:{d}\n", .{
            msg,
            self.pos.filename,
            self.pos.line,
            self.pos.col,
        });
    }

    /// Initializes the root scope for the transpiler.
    ///
    /// This function initializes the root scope and sets it as the current scope.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    ///
    /// Returns:
    /// - `scope.Scope`: The initialized root scope.
    pub fn init_root_scope(self: *Self) !scope.Scope {
        assert(self.scope == null);
        const root_scope = try self.allocator.create(scope.Scope);
        root_scope.* = scope.Scope.init(self.allocator);
        self.scope = .{
            .root = root_scope,
            .current = root_scope,
        };
        return root_scope.*;
    }

    /// Deinitializes a scope and its parent scopes recursively.
    ///
    /// This function deinitializes the given scope and its parent scopes recursively.
    /// It destroys the memory allocated for each scope using the provided allocator.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `s`: The scope to deinitialize.
    fn deinit_scope(self: *Self, s: *scope.Scope) void {
        if (s.parent) |parent| {
            self.deinit_scope(parent);
            self.allocator.destroy(parent);
        }
        s.deinit();
    }

    /// Deinitializes the root scope for the transpiler.
    ///
    /// This function deinitializes the root scope and sets the current scope to null.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    pub fn deinit_root_scope(self: *Self) void {
        assert(self.scope != null);
        if (self.scope.?.current) |current_scope| {
            self.deinit_scope(current_scope);
            self.allocator.destroy(current_scope);
        }
        self.scope.?.root = null;
        self.scope.?.current = null;
    }

    /// Creates a new scope for the transpiler.
    ///
    /// This function initializes a new scope and sets its parent to the current scope.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    ///
    /// Returns:
    /// - `scope.Scope`: The initialized new scope.
    pub fn new_scope(self: *Self) !scope.Scope {
        assert(self.scope != null);
        const nc = try self.allocator.create(scope.Scope);
        nc.* = scope.Scope.init(self.allocator);
        nc.parent = self.scope.?.current;
        self.scope.?.current = nc;
        return nc.*;
    }

    /// Retrieves the last entity from the current scope, stopping at a specified scope.
    ///
    /// This function retrieves the last entity from the current scope, stopping at the specified stop scope.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `stop_scope`: The scope to stop at when retrieving the last entity.
    ///
    /// Returns:
    /// - `?*ScopeEntity`: The last entity from the current scope, or `null` if not found.
    pub fn last_scope_entity_stop_at(self: *Self, stop_scope: ?*scope.Scope) ?*scope.ScopeEntity {
        return scope.Scope.last_entity_from_scope_stop_at(self.scope.?.current, stop_scope);
    }

    /// Retrieves the last entity from the current scope.
    ///
    /// This function retrieves the last entity from the current scope.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    ///
    /// Returns:
    /// - `?*ScopeEntity`: The last entity from the current scope, or `null` if not found.
    pub fn last_scope_entity(self: *Self) ?*scope.ScopeEntity {
        return self.last_scope_entity_stop_at(null);
    }

    /// Pushes an entity to the current scope.
    ///
    /// This function adds the specified entity pointer to the entities of the current scope.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `entity`: The scope entity to be added.
    ///
    /// Errors:
    /// - Returns an error if the entity could not be added.
    pub fn push_scope_entity(self: *Self, entity: *scope.ScopeEntity) !void {
        try self.scope.?.current.?.entities.push(entity);
    }

    /// Finishes the current scope and sets the parent scope as the current scope.
    ///
    /// This function deinitializes the current scope and sets its parent scope as the new current scope.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    pub fn finish_scope(self: *Self) void {
        const new_current_scope = self.scope.?.current.?.parent;
        self.scope.?.current.?.deinit();
        self.allocator.destroy(self.scope.?.current.?);
        self.scope.?.current = new_current_scope;
        if (self.scope.?.root != null and self.scope.?.current == null) {
            self.scope.?.root = null;
        }
    }

    /// Deinitializes the node and all its resources.
    /// Recursively frees memory allocated for child nodes and their resources.
    ///
    /// Parameters:
    ///   - `self`: The instance of the transpiler to deinitialize.
    ///   - `node`: The node to deinitialize
    fn deinit_node(self: *Self, node: ast.Node) void {
        const allocator = self.allocator;
        if (node.binded) |b| {
            if (b.owner) |owner| {
                self.deinit_node(owner.*);
                allocator.destroy(owner);
            }
            if (b.function) |function| {
                self.deinit_node(function.*);
                allocator.destroy(function);
            }
            allocator.destroy(b);
        }
        if (node.data) |data| {
            switch (data) {
                .sval => |list| if (list.items.len > 0) list.deinit(),
                else => {},
            }
        }
        if (node.node_variant) |variant| {
            switch (variant) {
                .exp => |exp| {
                    if (exp.left) |left| {
                        self.deinit_node(left.*);
                        allocator.destroy(left);
                    }
                    if (exp.right) |right| {
                        self.deinit_node(right.*);
                        allocator.destroy(right);
                    }
                },
                .paren => |paren| {
                    self.deinit_node(paren.exp.*);
                    allocator.destroy(paren.exp);
                },
                .variable => |variable| {
                    if (variable.val) |val| {
                        self.deinit_node(val.*);
                        allocator.destroy(val);
                    }
                    variable.type.type_str.deinit();
                    if (variable.type.array) |array| {
                        if (!array.brackets.is_empty()) {
                            for (array.brackets.items()) |bracket| {
                                self.deinit_node(bracket);
                            }
                        }
                        array.brackets.deinit();
                    }
                    allocator.destroy(variable.type);
                    variable.name.deinit();
                },
                .unary => |unary| {
                    self.deinit_node(unary.operand.*);
                    allocator.destroy(unary.operand);
                },
                .tenary => |tenary| {
                    self.deinit_node(tenary.condition.*);
                    allocator.destroy(tenary.condition);
                    self.deinit_node(tenary.true.*);
                    allocator.destroy(tenary.true);
                    self.deinit_node(tenary.false.*);
                    allocator.destroy(tenary.false);
                },
                .bracket => |bracket| {
                    self.deinit_node(bracket.inner.*);
                    allocator.destroy(bracket.inner);
                },
                .body => |body| {
                    for (body.statements.items()) |statement| {
                        self.deinit_node(statement.*);
                        allocator.destroy(statement);
                    }
                    body.statements.deinit();
                },
                .function => |function| {
                    if (function.args) |args| {
                        for (args.items()) |arg| {
                            self.deinit_node(arg.*);
                            allocator.destroy(arg);
                        }
                        args.deinit();
                    }
                    if (function.body) |body| {
                        self.deinit_node(body.*);
                        allocator.destroy(body);
                    }
                    if (function.rtype) |rtype| {
                        rtype.type_str.deinit();
                    }
                },
                .statement => |statement| {
                    switch (statement) {
                        .return_stmt => |ret| {
                            self.deinit_node(ret.*);
                            allocator.destroy(ret);
                        },
                        .if_stmt => |if_s| {
                            self.deinit_node(if_s.condition.*);
                            allocator.destroy(if_s.condition);
                            self.deinit_node(if_s.body.*);
                            allocator.destroy(if_s.body);
                        },
                        .elif_stmt => |elif| {
                            self.deinit_node(elif.condition.*);
                            allocator.destroy(elif.condition);
                            self.deinit_node(elif.body.*);
                            allocator.destroy(elif.body);
                        },
                        .else_stmt => |else_s| {
                            self.deinit_node(else_s.body.*);
                            allocator.destroy(else_s.body);
                        },
                        .fit_stmt => |fit| {
                            self.deinit_node(fit.exp.*);
                            allocator.destroy(fit.exp);
                            for (fit.branches.items()) |branch| {
                                if (branch.condition) |condition| {
                                    self.deinit_node(condition.*);
                                    allocator.destroy(condition);
                                }
                                self.deinit_node(branch.body.*);
                                allocator.destroy(branch.body);
                            }
                            fit.branches.deinit();
                        },
                    }
                },
                else => {},
            }
        }
    }

    /// Deinitializes the transpiler by closing input and output files and deinitializing tokens.
    ///
    /// This function performs the following actions:
    /// - Closes the input file associated with the transpiler.
    /// - Closes the output file associated with the transpiler.
    /// - Deinitializes the tokens used by the transpiler.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler to deinitialize.
    ///
    /// Returns:
    /// - This function does not return any value.
    pub fn deinit(self: *Self) void {
        self.ifile.close();
        if (self.ofile) |f| {
            f.close();
        }
        if (self.outbuf) |*buf| {
            buf.deinit();
        }
        for (self.tokens.items()) |t| {
            switch (t.data) {
                .sval => t.data.sval.deinit(),
                else => {},
            }
        }
        self.tokens.deinit();
        for (self.nodes.items()) |node| {
            self.deinit_node(node);
        }
        self.nodes.deinit();
    }

    /// Gets the output as a string. Only valid when outf is false.
    pub fn get_output(self: *Self) ?[]const u8 {
        if (self.outbuf) |*buf| {
            return buf.items;
        }
        return null;
    }

    /// Write to output (either file or buffer)
    pub fn write(self: *Self, bytes: []const u8) !void {
        if (self.flags.outf) {
            if (self.ofile) |f| {
                try f.writeAll(bytes);
            }
        } else if (self.outbuf) |*buf| {
            try buf.appendSlice(bytes);
        }
    }
};

test "TranspileProcess init and deinit" {
    const allocator = std.testing.allocator;
    const ifilepath = "TranspileProcess_init_and_deinit.fn";
    const ofilepath = "TranspileProcess_init_and_deinit.c";

    // Create dummy input file
    {
        const file = try fs.cwd().createFile(ifilepath, .{ .read = true });
        defer file.close();
        try file.writeAll("dummy input");
    }

    // Initialize TranspileProcess
    var process = try TranspileProcess.init(allocator, ifilepath, ofilepath, .{ .outf = true });
    defer process.deinit();

    // Check initial state
    try std.testing.expect(process.flags.outf);
    try std.testing.expect(process.pos.line == 1);
    try std.testing.expect(process.pos.col == 1);
    try std.testing.expect(mem.eql(u8, process.pos.filename, ifilepath));
    try std.testing.expect(process.tokens.items().len == 0);

    // Delete test files
    try fs.cwd().deleteFile(ifilepath);
    try fs.cwd().deleteFile(ofilepath);
}
