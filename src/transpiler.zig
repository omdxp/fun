const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const assert = std.debug.assert;
const token = @import("./token.zig");
const ast = @import("./ast.zig");
const misc = @import("./misc.zig");
const scope = @import("./scope.zig");
const symbol = @import("./symbol.zig");
const dtype = @import("./dtype.zig");

/// TranspileProcessFlags is an enumeration that defines flags for the transpile process.
pub const TranspileProcessFlags = packed struct {
    /// Flag to indicate execution process. When true, the output will be compiled and executed.
    exec: bool = true,
    /// Flag to indicate output file process. When true, the .c file will be generated.
    outf: bool = false,
    /// Flag to print AST nodes. When true, prints the Abstract Syntax Tree nodes.
    ast: bool = false,
};

/// GlobalSymbolInfo tracks information about symbols across modules
pub const GlobalSymbolInfo = struct {
    symbol_name: []const u8,
    file_path: []const u8,
    is_function: bool,
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
    nodes: misc.Vector(ast.Node),
    /// Track if we're currently transpiling function parameters
    in_function_params: bool = false,
    /// Current indentation level for code formatting
    indent_level: u32 = 0,
    /// Represents a scope structure used in the transpiler.
    scope: ?struct {
        /// A pointer to the root scope.
        root: ?*scope.Scope,
        /// A pointer to the current scope.
        current: ?*scope.Scope,
    } = null,
    /// Represents a struct containing the active symbol table and a list of symbol tables.
    symbols: struct {
        /// The active symbol table.
        active_table: ?*symbol.SymbolTable = null,
        /// A list of symbol tables.
        tables: misc.Vector(*symbol.SymbolTable),
    },
    /// The allocator to be used for memory allocation operations.
    allocator: mem.Allocator,

    /// Initialize a new indentation field to track active statement type
    current_statement_type: enum {
        None,
        If,
        ElseIf,
        Else,
        Other,
    } = .None,

    /// Track the next statement for proper formatting
    next_statement_type: enum {
        None,
        ElseIf,
        Else,
        Other,
    } = .None,

    /// Track imported files to avoid circular imports
    imported_files: std.StringHashMap(bool),

    /// Import chain to detect circular dependencies
    import_chain: std.ArrayList([]const u8),

    /// Track global symbols across all modules to detect duplicates
    global_symbols: std.StringHashMap(GlobalSymbolInfo),

    /// Parent TranspileProcess if this is a child import process
    parent: ?*TranspileProcess = null,

    /// Child import processes
    children: std.ArrayList(*TranspileProcess),

    /// Standard library imports to be added at the beginning of the output
    std_imports: std.ArrayList([]const u8),

    /// The input file path (used for relative path resolution)
    input_file_path: []const u8,

    /// Whether the current file is importing other files
    is_importing: bool = false,

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

        // Create initial symbol table
        const initial_table = try allocator.create(symbol.SymbolTable);
        initial_table.* = .{
            .symbols = misc.Vector(symbol.Symbol).init(allocator),
        };

        // Initialize import-related structures
        var imported_files = std.StringHashMap(bool).init(allocator);
        try imported_files.put(ifilepath, true); // Mark current file as imported

        var import_chain = std.ArrayList([]const u8).init(allocator);
        try import_chain.append(try allocator.dupe(u8, ifilepath));

        return Self{
            .flags = flags,
            .pos = .{ .col = 1, .line = 1, .filename = ifilepath },
            .ifile = ifile,
            .ofile = ofile,
            .outbuf = outbuf,
            .tokens = misc.Vector(token.Token).init(allocator),
            .nodes = misc.Vector(ast.Node).init(allocator),
            .scope = null,
            .symbols = .{
                .active_table = initial_table,
                .tables = misc.Vector(*symbol.SymbolTable).init(allocator),
            },
            .allocator = allocator,
            .imported_files = imported_files,
            .import_chain = import_chain,
            .global_symbols = std.StringHashMap(GlobalSymbolInfo).init(allocator),
            .children = std.ArrayList(*TranspileProcess).init(allocator),
            .std_imports = std.ArrayList([]const u8).init(allocator),
            .input_file_path = try allocator.dupe(u8, ifilepath),
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
        std.debug.print("Error: ", .{});
        std.debug.print(fmt, args);
        std.debug.print(" in {s}:{d}:{d}\n", .{
            self.pos.filename,
            self.pos.line,
            self.pos.col,
        });
        self.deinit();
        std.process.exit(1);
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
    pub fn warn(self: *Self, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("Warning: ", .{});
        std.debug.print(fmt, args);
        std.debug.print(" in {s}:{d}:{d}\n", .{
            self.pos.filename,
            self.pos.line,
            self.pos.col,
        });
    }

    /// Creates a new symbol table and sets it as the active table.
    ///
    /// This function creates a new symbol table and initializes its symbols vector.
    /// If there is an existing active table, it is pushed to the list of tables before
    /// the new table is created and set as the active table.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    ///
    /// Errors:
    /// - Returns an error if creating the new symbol table or initializing its symbols fails.
    pub fn new_table(self: *Self) !void {
        if (self.symbols.active_table) |table| {
            try self.symbols.tables.push(table);
        }
        const table = try self.allocator.create(symbol.SymbolTable);
        table.*.symbols = misc.Vector(symbol.Symbol).init(self.allocator);
        self.symbols.active_table = table;
    }

    /// Ends the current active symbol table and restores the previous one.
    ///
    /// This function removes the current active symbol table from the list of tables
    /// and sets the last table in the list as the new active table.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    pub fn end_table(self: *Self) void {
        const last_table = self.symbols.tables.back();
        self.symbols.active_table = last_table;
        self.symbols.tables.pop();
    }

    /// Pushes a symbol to the active symbol table.
    ///
    /// This function adds the specified symbol to the active symbol table.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `s (symbol.Symbol)`: The symbol to be added.
    ///
    /// Errors:
    /// - Returns an error if the symbol cannot be added to the active symbol table.
    pub fn push_symbol(self: *Self, s: symbol.Symbol) !void {
        try self.symbols.active_table.?.symbols.push(s);
    }

    /// Retrieves a symbol by name from the active symbol table.
    ///
    /// This function searches for a symbol with the specified name in the active symbol table.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `name ( []const u8 )`: The name of the symbol to search for.
    ///
    /// Returns:
    /// - `?symbol.Symbol`: The symbol if found, otherwise `null`.
    pub fn get_symbol(self: *Self, name: []const u8) ?symbol.Symbol {
        for (self.symbols.active_table.?.symbols.items()) |s| {
            if (mem.eql(u8, s.name, name)) {
                return s;
            }
        }
        return null;
    }

    /// Retrieves a native function symbol by name from all symbol tables.
    ///
    /// This function searches for a symbol with the specified name and type `NativeFunction`
    /// in all symbol tables.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `name ( []const u8 )`: The name of the native function to search for.
    ///
    /// Returns:
    /// - `?symbol.Symbol`: The native function symbol if found, otherwise `null`.
    pub fn get_symbol_for_native_function(self: *Self, name: []const u8) ?symbol.Symbol {
        for (self.symbols.tables.items()) |table| {
            for (table.symbols.items()) |s| {
                if (s.type == symbol.SymbolType.NativeFunction and mem.eql(u8, s.name, name)) {
                    return s;
                }
            }
        }
        return null;
    }

    /// Registers a new symbol in the active symbol table.
    ///
    /// This function checks if a symbol with the same name already exists in the active symbol table
    /// or in any imported module. If a duplicate is found, an error is logged.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `s (symbol.Symbol)`: The symbol to register.
    ///
    /// Errors:
    /// - Logs an error if a symbol with the same name already exists.
    /// - Returns an error if the symbol cannot be added to the active symbol table.
    pub fn register_symbol(self: *Self, s: symbol.Symbol) !void {
        // Check if symbol is already defined in the current module
        if (self.get_symbol(s.name) != null) {
            self.err("Symbol '{s}' already defined in the current module", .{s.name});
        }

        // Skip duplicate checks for main function - each module can have its own main
        if (!mem.eql(u8, s.name, "main")) {
            // Check if symbol is defined in any imported modules by checking global_symbols
            if (self.global_symbols.get(s.name)) |existing| {
                // Only report error if it's from a different file, not the same file
                if (!mem.eql(u8, existing.file_path, self.input_file_path)) {
                    self.err("Symbol '{s}' already defined in module '{s}'", .{ s.name, existing.file_path });
                }
            }
        }

        // Determine if this is a function symbol
        var is_function = false;
        if (s.type == symbol.SymbolType.Node) {
            // For Node symbols, we need to check if the node is a Function
            if (s.data) |data| {
                // We can't directly check the union tag, instead check based on the symbol type
                is_function = s.type == symbol.SymbolType.Node and data.node.type == .Function;
            }
        }

        // Register the symbol in global registry to detect conflicts in other modules
        try self.global_symbols.put(s.name, .{
            .symbol_name = s.name,
            .file_path = self.input_file_path,
            .is_function = is_function,
        });

        // Add the symbol to the active symbol table
        try self.push_symbol(s);
    }

    /// Registers a symbol for a given AST node.
    ///
    /// This function creates a symbol for the provided AST node and registers it in the active symbol table.
    /// The symbol type is set to `Node`, and the symbol name is derived from the node's variant (e.g., variable or function).
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `node (*ast.Node)`: The AST node for which the symbol will be registered.
    ///
    /// Errors:
    /// - Returns an error if registering the symbol fails.
    pub fn register_node_symbol(self: *Self, node: ast.Node) !void {
        switch (node.node_variant.?) {
            .variable => |variable| {
                const s = symbol.Symbol{
                    .type = symbol.SymbolType.Node,
                    .name = variable.name.items,
                    .data = .{ .node = node },
                };

                // Check if this symbol exists in any imported module
                if (self.global_symbols.get(variable.name.items)) |existing| {
                    self.err("Variable '{s}' already defined in module '{s}'", .{ variable.name.items, existing.file_path });
                }

                // Register the symbol in global registry
                try self.global_symbols.put(variable.name.items, .{
                    .symbol_name = variable.name.items,
                    .file_path = self.input_file_path,
                    .is_function = false,
                });

                try self.register_symbol(s);
            },
            .function => |function| {
                if (function.name == null) return;

                const s = symbol.Symbol{
                    .type = symbol.SymbolType.Node,
                    .name = function.name.?.items,
                    .data = .{ .node = node },
                };

                // Skip main functions in imported modules
                if (function.name != null and mem.eql(u8, function.name.?.items, "main")) {
                    // Only include main function from the main module (not from imported modules)
                    if (self.is_importing) {
                        return; // Skip this main function from an imported module
                    }

                    // Check if this function exists in any imported module
                    if (self.global_symbols.get(function.name.?.items)) |existing| {
                        self.err("Function '{s}' already defined in module '{s}'", .{ function.name.?.items, existing.file_path });
                    }
                }

                // Register the symbol in global registry
                try self.global_symbols.put(function.name.?.items, .{
                    .symbol_name = function.name.?.items,
                    .file_path = self.input_file_path,
                    .is_function = true,
                });

                try self.register_symbol(s);
            },
            else => {},
        }
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
        if (self.symbols.active_table) |table| {
            table.symbols.deinit();
            self.allocator.destroy(table);
        }
        for (self.symbols.tables.items()) |table| {
            table.symbols.deinit();
            self.allocator.destroy(table);
        }
        self.symbols.tables.deinit();

        // Free the imported files map
        var it = self.imported_files.keyIterator();
        while (it.next()) |key| {
            if (!mem.eql(u8, key.*, self.input_file_path)) {
                self.allocator.free(key.*);
            }
        }
        self.imported_files.deinit();

        // Free the import chain
        for (self.import_chain.items) |path| {
            self.allocator.free(path);
        }
        self.import_chain.deinit();

        // Properly clean up global_symbols hash map
        var global_it = self.global_symbols.iterator();
        while (global_it.next()) |_| {
            // We don't need to free file_path and symbol_name in GlobalSymbolInfo
            // as they are slices pointing to already managed memory
        }
        self.global_symbols.deinit();

        // Deinit children TranspileProcesses
        for (self.children.items) |child| {
            child.deinit();
            self.allocator.destroy(child);
        }
        self.children.deinit();

        // Free std imports
        for (self.std_imports.items) |import_path| {
            self.allocator.free(import_path);
        }
        self.std_imports.deinit();

        // Free input file path
        self.allocator.free(self.input_file_path);
    }

    /// Gets the output as a string. Only valid when outf is false.
    pub fn get_output(self: *Self) ?[]const u8 {
        if (self.outbuf) |*buf| {
            return buf.items;
        }
        return null;
    }

    /// Helper function to format and write values
    fn print(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        if (self.flags.outf) {
            try std.fmt.format(self.ofile.?.writer(), fmt, args);
        } else {
            try std.fmt.format(self.outbuf.?.writer(), fmt, args);
        }
    }

    /// Write to output (either file or buffer)
    pub fn write(self: *Self, bytes: []const u8) !void {
        if (self.flags.outf) {
            try self.ofile.?.writeAll(bytes);
        } else {
            try self.outbuf.?.appendSlice(bytes);
        }
    }

    /// Maps fun language types to C types
    fn map_type_to_c(type_str: []const u8) []const u8 {
        if (mem.eql(u8, type_str, "num")) return "int";
        if (mem.eql(u8, type_str, "str")) return "char*";
        if (mem.eql(u8, type_str, "bin")) return "bool";
        return type_str;
    }

    /// Helper function to write data type to output
    fn write_type(self: *Self, data_type: dtype.DataType) anyerror!void {
        const c_type = map_type_to_c(data_type.type_str.items);
        try self.write(c_type);
        // if (data_type.array) |array| {
        //     for (array.brackets.items()) |bracket| {
        //         try self.write("[");
        //         try self.transpile_node(bracket);
        //         try self.write("]");
        //     }
        // }
    }

    /// Transpiles all nodes in the AST to C code
    pub fn transpile(self: *Self) !void {
        // Add source file name at the top of the output
        const source_file = std.fs.path.basename(self.input_file_path);
        try self.write("// Source file: ");
        try self.write(source_file);
        try self.write("\n");

        // Process import nodes first
        var import_nodes = std.ArrayList(usize).init(self.allocator);
        defer import_nodes.deinit();

        // Identify import nodes
        for (self.nodes.items(), 0..) |node, i| {
            if (node.type == .Import) {
                try import_nodes.append(i);
            }
        }

        // Process the identified import nodes
        for (import_nodes.items) |i| {
            try self.process_import(self.nodes.items()[i]);
        }

        // Write standard library includes and prelude
        try self.transpile_prelude();

        // Output content from child imports recursively
        if (!self.is_importing) {
            try self.transpile_children_recursive(self);
        }

        // Now output the main file content
        for (self.nodes.items()) |node| {
            if (node.type != .Import) { // Skip import nodes as they've been processed
                try self.transpile_node(node);
                try self.write("\n\n");
            }
        }
    }

    // Helper function to recursively transpile children
    fn transpile_children_recursive(self: *Self, parent_proc: *TranspileProcess) !void {
        for (parent_proc.children.items) |child| {
            // Recursively transpile the child's children first
            try self.transpile_children_recursive(child);

            // Then, transpile the child's own nodes (excluding imports and main functions)
            for (child.nodes.items()) |node| {
                if (node.type != .Import) {
                    // Skip main functions in imported modules
                    if (node.type == .Function and node.node_variant != null) {
                        const function = node.node_variant.?.function;
                        if (function.name != null and mem.eql(u8, function.name.?.items, "main")) {
                            continue; // Skip this main function from an imported module
                        }
                    }

                    try self.transpile_node(node);
                    try self.write("\n\n");
                }
            }
        }
    }

    /// Transpiles the prelude code to C
    fn transpile_prelude(self: *Self) !void {
        try self.write_std_imports();
        try self.write("#include <stdbool.h>\n");
        try self.write("#include <stdlib.h>\n");
        try self.write("#include <string.h>\n\n");
    }

    /// Transpiles a node to C code
    fn transpile_node(self: *Self, node: ast.Node) !void {
        switch (node.type) {
            .Expression => {
                const exp = node.node_variant.?.exp;
                if (mem.eql(u8, exp.op, "()")) {
                    if (exp.left) |left| {
                        try self.transpile_node(left.*);
                        try self.write("(");
                        if (exp.right) |right| {
                            try self.transpile_node(right.*);
                        }
                        try self.write(")");
                    }
                } else if (mem.eql(u8, exp.op, ",")) {
                    if (exp.left) |left| {
                        try self.transpile_node(left.*);
                    }
                    if (exp.right) |right| {
                        try self.write(", ");
                        try self.transpile_node(right.*);
                    }
                } else if (exp.op.len > 0) {
                    if (exp.left) |left| {
                        try self.transpile_node(left.*);
                    }
                    try self.write(" ");
                    try self.write(exp.op);
                    try self.write(" ");
                    if (exp.right) |right| {
                        try self.transpile_node(right.*);
                    }
                } else if (exp.left) |left| {
                    try self.transpile_node(left.*);
                }
            },
            .ExpressionParenthesis => {
                const exp = node.node_variant.?.paren.exp;
                try self.transpile_node(exp.*);
            },
            .Number => {
                const num = node.data.?.llnum;
                try self.print("{d}", .{num});
            },
            .String => {
                const str = node.data.?.sval.items;
                try self.write("\"");
                try self.write(str);
                try self.write("\"");
            },
            .Identifier => {
                const str = node.data.?.sval.items;
                try self.write(str);
            },
            .Variable => {
                const variable = node.node_variant.?.variable;
                try self.write_type(variable.type.*);
                try self.write(" ");
                try self.write(variable.name.items);
                if (variable.val) |val| {
                    try self.write(" = ");
                    if (val.type == .String) {
                        try self.write("\"");
                        try self.write(val.data.?.sval.items);
                        try self.write("\"");
                    } else if (val.type == .Boolean) {
                        const bval = val.data.?.bval;
                        try self.write(if (bval) "true" else "false");
                    } else {
                        try self.transpile_node(val.*);
                    }
                }
                if (!self.in_function_params) {
                    try self.write(";");
                }
            },
            .Function => {
                const function = node.node_variant.?.function;

                // Skip main functions in imported modules
                if (function.name != null and mem.eql(u8, function.name.?.items, "main")) {
                    // Only include main function from the main module (not from imported modules)
                    if (self.is_importing) {
                        return; // Skip this main function from an imported module
                    }

                    try self.write("int");
                    try self.write(" ");
                    try self.write("main");
                    try self.write("(int argc, char** argv) ");
                    if (function.body) |body| {
                        try self.transpile_node(body.*);
                    }
                } else {
                    if (function.rtype) |rtype| {
                        try self.write_type(rtype);
                    } else {
                        try self.write("void");
                    }
                    try self.write(" ");
                    if (function.name) |name| {
                        try self.write(name.items);
                    }
                    try self.write("(");
                    self.in_function_params = true;
                    if (function.args) |args| {
                        for (args.items(), 0..) |arg, i| {
                            if (i > 0) try self.write(", ");
                            try self.transpile_node(arg.*);
                        }
                    }
                    self.in_function_params = false;
                    try self.write(") ");

                    if (function.body) |body| {
                        try self.transpile_node(body.*);
                    }
                }
            },
            .Body => {
                const body = node.node_variant.?.body;
                try self.write("{");
                self.indent();
                for (body.statements.items()) |statement| {
                    try self.write_indent();
                    try self.transpile_node(statement.*);
                    if (statement.type == .Expression) {
                        try self.write(";");
                    }
                }
                self.dedent();
                try self.write_indent();
                try self.write("}");
            },
            .StatementReturn, .StatementIf, .StatementElseIf, .StatementElse, .StatementFit => {
                const statement = node.node_variant.?.statement;
                switch (statement) {
                    .if_stmt => |if_s| {
                        try self.write("if (");
                        try self.transpile_node(if_s.condition.*);
                        try self.write(") {");
                        self.indent();
                        if (if_s.body.type == .Body) {
                            const body = if_s.body.node_variant.?.body;
                            for (body.statements.items()) |body_stmt| {
                                try self.write_indent();
                                try self.transpile_node(body_stmt.*);
                                if (body_stmt.type == .Expression) {
                                    try self.write(";");
                                }
                            }
                        } else {
                            try self.write_indent();
                            try self.transpile_node(if_s.body.*);
                            if (if_s.body.type == .Expression) {
                                try self.write(";");
                            }
                        }
                        self.dedent();
                        try self.write_indent();
                        try self.write("}");
                    },
                    .elif_stmt => |elif| {
                        try self.write("else if (");
                        try self.transpile_node(elif.condition.*);
                        try self.write(") {");
                        self.indent();
                        if (elif.body.type == .Body) {
                            const body = elif.body.node_variant.?.body;
                            for (body.statements.items()) |body_stmt| {
                                try self.write_indent();
                                try self.transpile_node(body_stmt.*);
                                if (body_stmt.type == .Expression) {
                                    try self.write(";");
                                }
                            }
                        } else {
                            try self.write_indent();
                            try self.transpile_node(elif.body.*);
                            if (elif.body.type == .Expression) {
                                try self.write(";");
                            }
                        }

                        self.dedent();
                        try self.write_indent();
                        try self.write("}");
                    },
                    .else_stmt => |else_s| {
                        try self.write("else {");
                        self.indent();
                        if (else_s.body.type == .Body) {
                            const body = else_s.body.node_variant.?.body;
                            for (body.statements.items()) |body_stmt| {
                                try self.write_indent();
                                try self.transpile_node(body_stmt.*);
                                if (body_stmt.type == .Expression) {
                                    try self.write(";");
                                }
                            }
                        } else {
                            try self.write_indent();
                            try self.transpile_node(else_s.body.*);
                            if (else_s.body.type == .Expression) {
                                try self.write(";");
                            }
                        }

                        self.dedent();
                        try self.write_indent();
                        try self.write("}");
                    },
                    .fit_stmt => |fit| {
                        try self.write("switch (");
                        try self.transpile_node(fit.exp.*);
                        try self.write(") {");
                        self.indent();
                        for (fit.branches.items()) |branch| {
                            if (branch.condition) |condition| {
                                try self.write_indent();
                                try self.write("case ");
                                try self.transpile_node(condition.*);
                                try self.write(":");
                                self.indent();
                                if (branch.body.type == .Expression or branch.body.type == .ExpressionParenthesis) {
                                    try self.write_indent();
                                    try self.transpile_node(branch.body.*);
                                    try self.write(";");
                                } else {
                                    try self.write_indent();
                                    try self.transpile_node(branch.body.*);
                                }
                                try self.write_indent();
                                try self.write("break;");
                                self.dedent();
                            } else {
                                try self.write_indent();
                                try self.write("default:");

                                self.indent();
                                if (branch.body.type == .Expression or branch.body.type == .ExpressionParenthesis) {
                                    try self.write_indent();
                                    try self.transpile_node(branch.body.*);
                                    try self.write(";");
                                } else {
                                    try self.write_indent();
                                    try self.transpile_node(branch.body.*);
                                }
                                try self.write_indent();
                                try self.write("break;");
                                self.dedent();
                            }
                        }
                        self.dedent();
                        try self.write_indent();
                        try self.write("}");
                    },
                    .return_stmt => |ret| {
                        try self.write("return ");
                        try self.transpile_node(ret.*);
                        try self.write(";");
                    },
                }
            },
            .Unary => {
                const unary = node.node_variant.?.unary;
                if (unary.is_left_operanded_unary) {
                    try self.transpile_node(unary.operand.*);
                    try self.write(unary.op);
                } else {
                    try self.write(unary.op);
                    try self.transpile_node(unary.operand.*);
                }
            },
            .Tenary => {
                const tenary = node.node_variant.?.tenary;
                try self.transpile_node(tenary.condition.*);
                try self.write(" ? ");
                try self.transpile_node(tenary.true.*);
                try self.write(" : ");
                try self.transpile_node(tenary.false.*);
            },
            .Boolean => {
                const val = node.data.?.bval;
                try self.write(if (val) "true" else "false");
            },
            else => {},
        }
    }

    /// Increase the indentation level
    pub fn indent(self: *Self) void {
        self.indent_level += 1;
    }

    /// Decrease the indentation level
    pub fn dedent(self: *Self) void {
        if (self.indent_level > 0) {
            self.indent_level -= 1;
        }
    }

    /// Write a newline followed by the current indentation
    pub fn write_indent(self: *Self) !void {
        try self.write("\n");
        try self.write_spaces(self.indent_level * 4); // 4 spaces per level
    }

    /// Write a specific number of spaces
    pub fn write_spaces(self: *Self, spaces: u32) !void {
        var i: u32 = 0;
        while (i < spaces) : (i += 1) {
            try self.write(" ");
        }
    }

    /// Write formatted with indentation prefix
    pub fn write_indented(self: *Self, text: []const u8) !void {
        try self.write_spaces(self.indent_level * 4);
        try self.write(text);
    }

    /// Process an import node to include standard library or local file
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `node`: The import node to process.
    ///
    /// Errors:
    /// - Returns an error if processing the import fails.
    fn process_import(self: *Self, node: ast.Node) !void {
        const import_path = node.node_variant.?.import.path;
        if (std.mem.indexOf(u8, import_path, "std.") != null) {
            try self.process_std_import(import_path);
        } else {
            try self.process_local_import(import_path);
        }
    }

    /// Process a standard library import (e.g., "std.io")
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `import_path`: The import path as a string.
    ///
    /// Errors:
    /// - Returns an error if processing the import fails.
    fn process_std_import(self: *Self, import_path: []const u8) !void {
        var header_name: []const u8 = undefined;

        if (mem.eql(u8, import_path, "std.io")) {
            header_name = try self.allocator.dupe(u8, "stdio.h");
        } else if (mem.eql(u8, import_path, "std.mem")) {
            header_name = try self.allocator.dupe(u8, "stdlib.h");
        } else if (mem.eql(u8, import_path, "std.string")) {
            header_name = try self.allocator.dupe(u8, "string.h");
        } else if (mem.eql(u8, import_path, "std.math")) {
            header_name = try self.allocator.dupe(u8, "math.h");
        } else {
            self.err("Unsupported standard library import: {s}", .{import_path});
            return;
        }

        for (self.std_imports.items) |existing| {
            if (mem.eql(u8, existing, header_name)) {
                self.allocator.free(header_name);
                return;
            }
        }
        try self.std_imports.append(header_name);
    }

    /// Process a local file import (e.g., "custom" or "folder.file")
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `import_path`: The import path as a string.
    ///
    /// Errors:
    /// - Returns an error if processing the import fails.
    fn process_local_import(self: *Self, import_path: []const u8) anyerror!void {
        // Get full path of the file to import
        var file_path = std.ArrayList(u8).init(self.allocator);
        defer file_path.deinit();

        const dir_path = std.fs.path.dirname(self.input_file_path) orelse ".";
        try file_path.appendSlice(dir_path);
        try file_path.append('/');

        var i: usize = 0;
        while (i < import_path.len) : (i += 1) {
            if (import_path[i] == '.') {
                try file_path.append('/');
            } else {
                try file_path.append(import_path[i]);
            }
        }

        try file_path.appendSlice(".fn");
        const full_path = try file_path.toOwnedSlice();
        defer self.allocator.free(full_path);

        // Add a comment showing the import attempt
        try self.write("\n/* Attempting to import: ");
        try self.write(full_path);
        try self.write(" */\n");

        // Check if the file exists
        std.fs.cwd().access(full_path, .{}) catch {
            try self.write("\n/* ERROR: Import file not found: ");
            try self.write(full_path);
            try self.write(" */\n");
            return error.FileNotFound;
        };

        // Robust direct circular dependency detection
        // First, check if the file being imported already has us in its import chain
        const file_contents = fs.cwd().readFileAlloc(self.allocator, full_path, 1024 * 1024) catch |read_err| {
            self.err("Failed to read import file: {any}", .{read_err});
            return;
        };
        defer self.allocator.free(file_contents);

        // Check if the file imports us directly (crude but effective)
        const our_name = std.fs.path.stem(self.input_file_path);
        var import_line = std.ArrayList(u8).init(self.allocator);
        defer import_line.deinit();
        try import_line.appendSlice("imp ");
        try import_line.appendSlice(our_name);
        try import_line.appendSlice(";");

        // Check if the target file imports us
        if (std.mem.indexOf(u8, file_contents, import_line.items)) |_| {
            const basename1 = std.fs.path.basename(self.input_file_path);
            const basename2 = std.fs.path.basename(full_path);

            self.err("CIRCULAR IMPORT DETECTED: '{s}' imports '{s}', but '{s}' also imports '{s}', creating a circular dependency", .{ basename1, basename2, basename2, basename1 });
            return;
        }

        // Mark this file as imported
        try self.imported_files.put(try self.allocator.dupe(u8, full_path), true);

        // Create and initialize child transpile process
        var import_proc = try self.allocator.create(TranspileProcess);
        errdefer self.allocator.destroy(import_proc);

        import_proc.* = try TranspileProcess.init(self.allocator, full_path, "temp.c", .{ .outf = false });

        import_proc.parent = self;
        import_proc.is_importing = true;

        // Copy the import chain and add the current import for tracking
        for (self.import_chain.items) |chain_path| {
            try import_proc.import_chain.append(try self.allocator.dupe(u8, chain_path));
        }
        try import_proc.import_chain.append(try self.allocator.dupe(u8, full_path));

        // Copy imported files to child
        var it = self.imported_files.iterator();
        while (it.next()) |entry| {
            try import_proc.imported_files.put(try self.allocator.dupe(u8, entry.key_ptr.*), true);
        }

        // Process the imported file
        const parser = @import("./parser.zig");
        const lexer = @import("./lexer.zig");

        var lex_proc = lexer.LexProcess.init(import_proc);
        var parse_proc = parser.ParseProcess.init(import_proc);

        try lex_proc.lex();
        try parse_proc.parse();

        // Process imports within the imported file
        for (import_proc.nodes.items()) |node| {
            if (node.type == .Import) {
                try import_proc.process_import(node);
            }
        }

        // After processing is complete, sync all symbols back to parent
        try import_proc.sync_global_symbols_to_parent();

        // Add to children list
        try self.children.append(import_proc);
    }

    /// Synchronize global symbols from a child process to the parent process
    ///
    /// This ensures that symbols defined in imported files are visible to the parent process
    /// for duplicate detection across modules.
    ///
    /// Parameters:
    /// - `self`: The child process whose symbols will be synced to its parent
    ///
    /// Errors:
    /// - Returns an error if the synchronization fails.
    fn sync_global_symbols_to_parent(self: *Self) !void {
        if (self.parent == null) return; // Not a child process

        var it = self.global_symbols.iterator();
        while (it.next()) |entry| {
            const symbol_name = entry.key_ptr.*;
            const symbol_info = entry.value_ptr.*;

            // Skip main functions entirely
            if (mem.eql(u8, symbol_name, "main")) continue;

            // Check if this symbol is already defined in the parent
            if (self.parent.?.global_symbols.get(symbol_name)) |existing| {
                // If we find a conflict, report it
                self.err("Symbol '{s}' in module '{s}' conflicts with same symbol defined in module '{s}'", .{ symbol_name, symbol_info.file_path, existing.file_path });
            }

            // Add this symbol to the parent's global registry
            try self.parent.?.global_symbols.put(symbol_name, .{
                .symbol_name = symbol_name,
                .file_path = symbol_info.file_path,
                .is_function = symbol_info.is_function,
            });
        }
    }

    /// Write standard library imports to the output
    fn write_std_imports(self: *Self) !void {
        for (self.std_imports.items) |header| {
            try self.write("#include <");
            try self.write(header);
            try self.write(">\n");
        }
        // Add imports from child processes as well
        for (self.children.items) |child| {
            for (child.std_imports.items) |header| {
                // Check if we've already added this header
                var already_added = false;
                for (self.std_imports.items) |existing| {
                    if (mem.eql(u8, header, existing)) {
                        already_added = true;
                        break;
                    }
                }
                if (!already_added) {
                    try self.write("#include <");
                    try self.write(header);
                    try self.write(">\n");
                }
            }
        }
    }
};
