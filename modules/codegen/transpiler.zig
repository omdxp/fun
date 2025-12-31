const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const assert = std.debug.assert;
const parser = @import("parser");
const ParseError = parser.ParseError;
const lexer = @import("lexer");
const LexError = lexer.LexError;
const token = lexer.token;
const ast = @import("ast");
const utils = @import("utils");
const semantics = @import("semantics");
const scope = semantics.scope;
const symbol = semantics.symbol;
const dtype = semantics.dtype;

/// Errors that can occur during the transpilation process.
pub const TranspileError = error{
    /// Error indicating that a file is not found.
    FileNotFound,
    /// Error indicating that a file cannot be opened.
    FileOpenError,
    /// Error indicating that a file cannot be read.
    FileReadError,
    /// Error indicating that a file cannot be written.
    FileWriteError,
    /// Error indicating a file seek operation failed.
    FileSeekError,
    /// Error indicating a failure when writing to the output buffer.
    BufferWriteError,
    /// Error indicating memory allocation failure.
    MemoryAllocationFailed,
    /// Error indicating that a symbol is not defined.
    SymbolNotDefined,
    /// Error indicating that a symbol is already defined.
    DuplicateSymbol,
    /// Error indicating that a variable is already declared.
    VariableAlreadyDeclared,
    /// Error indicating unsupported import.
    UnsupportedImport,
    /// Error indicating circular import.
    CircularImport,
    /// Error indicating that the import path is invalid.
    InvalidImportPath,
    /// Error indicating unsupported AST node type.
    UnsupportedNodeType,
};

/// General errors that can occur during the transpilation process.
pub const GeneralError = TranspileError || LexError || ParseError;

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
    tokens: utils.Vector(token.Token),
    /// `nodes` is a list of AST (Abstract Syntax Tree) nodes.
    nodes: utils.Vector(ast.Node),

    /// Accumulates warning text emitted during transpilation (useful for tests/tooling).
    warnings: std.ArrayList(u8),

    /// Heap-allocated node containers that are referenced by other structures (e.g. scope entities)
    /// but whose contents are owned/deinitialized via `nodes`.
    owned_nodes: std.ArrayList(*ast.Node),

    /// Heap-allocated scope entities created by the parser.
    owned_scope_entities: std.ArrayList(*scope.ScopeEntity),
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
        tables: utils.Vector(*symbol.SymbolTable),
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

    /// The current token being processed
    current_token: ?token.Token = null,

    const Self = @This();

    fn build_full_import_path(self: *Self, import_path: []const u8) TranspileError![]const u8 {
        var file_path = std.ArrayList(u8).init(self.allocator);
        defer file_path.deinit();

        const dir_path = std.fs.path.dirname(self.input_file_path) orelse ".";
        file_path.appendSlice(dir_path) catch |e| {
            std.debug.print("Failed to allocate memory for file path: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
        file_path.append('/') catch |e| {
            std.debug.print("Failed to allocate memory for file path: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };

        for (import_path) |ch| {
            if (ch == '.') {
                file_path.append('/') catch |e| {
                    std.debug.print("Failed to allocate memory for file path: {s}\\n", .{@errorName(e)});
                    return TranspileError.MemoryAllocationFailed;
                };
            } else {
                file_path.append(ch) catch |e| {
                    std.debug.print("Failed to allocate memory for file path: {s}\\n", .{@errorName(e)});
                    return TranspileError.MemoryAllocationFailed;
                };
            }
        }

        file_path.appendSlice(".fn") catch |e| {
            std.debug.print("Failed to allocate memory for file path: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };

        return file_path.toOwnedSlice() catch |e| {
            std.debug.print("Failed to allocate memory for file path: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
    }

    /// Preload global symbol names from an import path before parsing the rest of the file.
    ///
    /// This enables identifier validation in the parser to recognize functions defined in
    /// locally imported modules.
    pub fn preload_import_global_symbols(self: *Self, import_path: []const u8) GeneralError!void {
        if (std.mem.indexOf(u8, import_path, "std.") != null) return;

        const full_path = try self.build_full_import_path(import_path);
        defer self.allocator.free(full_path);

        std.fs.cwd().access(full_path, .{}) catch {
            return TranspileError.FileNotFound;
        };

        // Early direct circular import detection (A imports B, and B imports A).
        // This is intentionally lightweight and mirrors the check in process_local_import.
        {
            const file_contents = fs.cwd().readFileAlloc(self.allocator, full_path, 1024 * 1024) catch |read_err| {
                self.err("Failed to read import file: {any}", .{read_err});
                return TranspileError.FileReadError;
            };
            defer self.allocator.free(file_contents);

            const our_name = std.fs.path.stem(self.input_file_path);
            var import_line = std.ArrayList(u8).init(self.allocator);
            defer import_line.deinit();
            import_line.appendSlice("imp ") catch |e| {
                std.debug.print("Failed to allocate memory for import line: {s}\\n", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
            import_line.appendSlice(our_name) catch |e| {
                std.debug.print("Failed to allocate memory for import line: {s}\\n", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
            import_line.appendSlice(";") catch |e| {
                std.debug.print("Failed to allocate memory for import line: {s}\\n", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };

            if (std.mem.indexOf(u8, file_contents, import_line.items)) |_| {
                const basename1 = std.fs.path.basename(self.input_file_path);
                const basename2 = std.fs.path.basename(full_path);
                self.err("CIRCULAR IMPORT DETECTED: '{s}' imports '{s}', but '{s}' also imports '{s}', creating a circular dependency", .{ basename1, basename2, basename2, basename1 });
                return TranspileError.CircularImport;
            }
        }

        var import_proc = try TranspileProcess.init(self.allocator, full_path, "temp.c", .{ .exec = false, .outf = false, .ast = false });
        defer import_proc.deinit();

        var lex_proc = lexer.LexProcess.init(&import_proc);
        defer lex_proc.deinit();
        try lex_proc.lex();

        const tokens = import_proc.tokens.items();
        var i: usize = 0;
        while (i < tokens.len) : (i += 1) {
            const t = tokens[i];
            if (t.type != .Keyword) continue;
            if (!mem.eql(u8, t.data.sval.items, "fun")) continue;

            var j: usize = i + 1;
            while (j < tokens.len and token.is_nl_or_comment_or_newline_separator(tokens[j])) : (j += 1) {}
            if (j >= tokens.len) continue;

            const name_tok = tokens[j];
            if (name_tok.type != .Identifier) continue;

            const name = name_tok.data.sval.items;
            if (mem.eql(u8, name, "main")) continue;

            if (self.global_symbols.get(name)) |existing| {
                if (!mem.eql(u8, existing.file_path, full_path) and !mem.eql(u8, existing.file_path, self.input_file_path)) {
                    self.err("Symbol '{s}' already defined in module '{s}'", .{ name, existing.file_path });
                    return TranspileError.DuplicateSymbol;
                }
            }

            const name_copy = self.allocator.dupe(u8, name) catch |e| {
                std.debug.print("Error duplicating symbol name '{any}': {s}\\n", .{ name, @errorName(e) });
                return TranspileError.MemoryAllocationFailed;
            };
            errdefer self.allocator.free(name_copy);

            const path_copy = self.allocator.dupe(u8, full_path) catch |e| {
                std.debug.print("Error duplicating file path '{any}': {s}\\n", .{ full_path, @errorName(e) });
                return TranspileError.MemoryAllocationFailed;
            };
            errdefer self.allocator.free(path_copy);

            self.global_symbols.put(name_copy, .{
                .symbol_name = name_copy,
                .file_path = path_copy,
                .is_function = true,
            }) catch |e| {
                std.debug.print("Error registering imported symbol '{any}': {s}\\n", .{ name_copy, @errorName(e) });
                return TranspileError.MemoryAllocationFailed;
            };
        }
    }

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
    pub fn init(allocator: mem.Allocator, ifilepath: []const u8, ofilepath: []const u8, flags: TranspileProcessFlags) TranspileError!Self {
        const ifile = fs.cwd().openFile(ifilepath, .{ .mode = .read_write }) catch |e| {
            std.debug.print("Error opening input file '{s}': {s}\\n", .{ ifilepath, @errorName(e) });
            return TranspileError.FileOpenError;
        };
        errdefer ifile.close();

        var ofile: ?fs.File = null;
        var outbuf: ?std.ArrayList(u8) = null;

        if (flags.outf) {
            ofile = fs.cwd().createFile(ofilepath, .{ .read = true }) catch |e| {
                std.debug.print("Error creating output file '{s}': {s}\\n", .{ ofilepath, @errorName(e) });
                return TranspileError.FileOpenError;
            };
            errdefer if (ofile) |f| f.close();
        } else {
            outbuf = std.ArrayList(u8).init(allocator);
        }

        // Create initial symbol table
        const initial_table = allocator.create(symbol.SymbolTable) catch |e| {
            std.debug.print("Error creating initial symbol table: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
        errdefer allocator.destroy(initial_table);
        initial_table.* = .{
            .symbols = utils.Vector(symbol.Symbol).init(allocator),
            .name = "",
        };
        errdefer initial_table.symbols.deinit();

        // Initialize import-related structures
        var imported_files = std.StringHashMap(bool).init(allocator);
        errdefer imported_files.deinit();
        imported_files.put(ifilepath, true) catch |e| {
            std.debug.print("Error adding file '{s}' to imported files: {s}\\n", .{ ifilepath, @errorName(e) });
            return TranspileError.MemoryAllocationFailed;
        }; // Mark current file as imported

        var import_chain = std.ArrayList([]const u8).init(allocator);
        errdefer import_chain.deinit();

        const initial_path = allocator.dupe(u8, ifilepath) catch |e| {
            std.debug.print("Error duplicating initial path '{s}': {s}\\n", .{ ifilepath, @errorName(e) });
            return TranspileError.MemoryAllocationFailed;
        };
        errdefer allocator.free(initial_path);
        import_chain.append(initial_path) catch |e| {
            std.debug.print("Error adding initial path '{s}' to import chain: {s}\\n", .{ initial_path, @errorName(e) });
            return TranspileError.MemoryAllocationFailed;
        };

        const input_file_path = allocator.dupe(u8, ifilepath) catch |e| {
            std.debug.print("Error duplicating input file path '{s}': {s}\\n", .{ ifilepath, @errorName(e) });
            return TranspileError.MemoryAllocationFailed;
        };
        errdefer allocator.free(input_file_path);

        return Self{
            .flags = flags,
            .pos = .{ .col = 1, .line = 1, .start_col = 1, .end_col = 1, .filename = ifilepath },
            .ifile = ifile,
            .ofile = ofile,
            .outbuf = outbuf,
            .tokens = utils.Vector(token.Token).init(allocator),
            .nodes = utils.Vector(ast.Node).init(allocator),
            .warnings = std.ArrayList(u8).init(allocator),
            .owned_nodes = std.ArrayList(*ast.Node).init(allocator),
            .owned_scope_entities = std.ArrayList(*scope.ScopeEntity).init(allocator),
            .scope = null,
            .symbols = .{
                .active_table = initial_table,
                .tables = utils.Vector(*symbol.SymbolTable).init(allocator),
            },
            .allocator = allocator,
            .imported_files = imported_files,
            .import_chain = import_chain,
            .global_symbols = std.StringHashMap(GlobalSymbolInfo).init(allocator),
            .children = std.ArrayList(*TranspileProcess).init(allocator),
            .std_imports = std.ArrayList([]const u8).init(allocator),
            .input_file_path = input_file_path,
        };
    }

    pub fn get_warnings(self: *Self) ?[]const u8 {
        if (self.warnings.items.len == 0) return null;
        return self.warnings.items;
    }

    /// Logs an error message with the current position in the token stream.
    ///
    /// This function logs an error message along with the line number, column span.,
    /// and filename where the error occurred, then panics.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `fmt`: The format string for the error message.
    /// - `args`: The arguments for the format string.
    pub fn err(self: *Self, comptime fmt: []const u8, args: anytype) void {
        const stderr = std.io.getStdErr().writer();
        stderr.print("\n[Error]\n", .{}) catch unreachable;
        stderr.print(fmt, args) catch unreachable;

        if (self.current_token) |ct| {
            const end_line = if (ct.pos.end_line == 0) ct.pos.line else ct.pos.end_line;
            if (end_line == ct.pos.line) {
                stderr.print("\nLocation: {s}:{d}:{d}-{d}\n", .{ ct.pos.filename, ct.pos.line, ct.pos.start_col, ct.pos.end_col }) catch unreachable;
            } else {
                stderr.print("\nLocation: {s}:{d}:{d}-{d}:{d}\n", .{ ct.pos.filename, ct.pos.line, ct.pos.start_col, end_line, ct.pos.end_col }) catch unreachable;
            }
        } else {
            stderr.print("\nLocation: {s}:{d}:{d}\n", .{ self.pos.filename, self.pos.line, self.pos.col }) catch unreachable;
        }
        self.deinit();
    }

    /// Logs a warning message with the current position in the token stream.
    ///
    /// This function logs a warning message along with the line number, column span,
    /// and filename where the warning occurred.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `fmt`: The format string for the warning message.
    /// - `args`: The arguments for the format string.
    pub fn warn(self: *Self, comptime fmt: []const u8, args: anytype) void {
        const stderr = std.io.getStdErr().writer();
        stderr.print("\n[Warning]\n", .{}) catch unreachable;
        stderr.print(fmt, args) catch unreachable;

        self.warnings.writer().print("\n[Warning]\n", .{}) catch unreachable;
        self.warnings.writer().print(fmt, args) catch unreachable;

        if (self.current_token) |ct| {
            const end_line = if (ct.pos.end_line == 0) ct.pos.line else ct.pos.end_line;
            if (end_line == ct.pos.line) {
                stderr.print("\nLocation: {s}:{d}:{d}-{d}\n", .{ ct.pos.filename, ct.pos.line, ct.pos.start_col, ct.pos.end_col }) catch unreachable;
                self.warnings.writer().print("\nLocation: {s}:{d}:{d}-{d}\n", .{ ct.pos.filename, ct.pos.line, ct.pos.start_col, ct.pos.end_col }) catch unreachable;
            } else {
                stderr.print("\nLocation: {s}:{d}:{d}-{d}:{d}\n", .{ ct.pos.filename, ct.pos.line, ct.pos.start_col, end_line, ct.pos.end_col }) catch unreachable;
                self.warnings.writer().print("\nLocation: {s}:{d}:{d}-{d}:{d}\n", .{ ct.pos.filename, ct.pos.line, ct.pos.start_col, end_line, ct.pos.end_col }) catch unreachable;
            }
        } else {
            stderr.print("\nLocation: {s}:{d}:{d}\n", .{ self.pos.filename, self.pos.line, self.pos.col }) catch unreachable;
            self.warnings.writer().print("\nLocation: {s}:{d}:{d}\n", .{ self.pos.filename, self.pos.line, self.pos.col }) catch unreachable;
        }
    }

    fn infer_simple_dtype(self: *Self, node: ast.Node) ?dtype.DataTypeType {
        return switch (node.type) {
            .Boolean => .Bin,
            .Number => .Num,
            .String => .Str,
            .Identifier => blk: {
                if (node.data == null) break :blk null;
                const name = node.data.?.sval.items;
                const ent = self.get_scope_entity(name) orelse break :blk null;
                const ent_node = ent.node orelse break :blk null;
                if (ent_node.type != .Variable) break :blk null;
                break :blk ent_node.node_variant.?.variable.type.type;
            },
            else => null,
        };
    }

    fn warn_if_fit_not_exhausted(self: *Self, condition: *ast.Node, branches: []const ast.FitBranch) void {
        // If there is any default branch, treat it as exhausted.
        for (branches) |branch| {
            if (branch.condition == null) return;
        }

        const cond_type = self.infer_simple_dtype(condition.*) orelse return;
        if (cond_type != .Bin) return;

        var has_true = false;
        var has_false = false;
        for (branches) |branch| {
            const cond = branch.condition orelse continue;
            if (cond.type == .Boolean) {
                if (cond.data != null and cond.data.?.bval) {
                    has_true = true;
                } else {
                    has_false = true;
                }
            }
        }

        if (!(has_true and has_false)) {
            if (!has_true and !has_false) {
                self.warn("fit statement is not exhausted for bin condition (missing true and false branches)", .{});
            } else if (!has_true) {
                self.warn("fit statement is not exhausted for bin condition (missing true branch)", .{});
            } else {
                self.warn("fit statement is not exhausted for bin condition (missing false branch)", .{});
            }
        }
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
    pub fn new_table(self: *Self) TranspileError!void {
        if (self.symbols.active_table) |table| {
            self.symbols.tables.push(table) catch |e| {
                std.debug.print("Error pushing symbol table: {s}\\n", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        }
        const table = self.allocator.create(symbol.SymbolTable) catch |e| {
            std.debug.print("Error creating new symbol table: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
        table.*.symbols = utils.Vector(symbol.Symbol).init(self.allocator);
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
    pub fn push_symbol(self: *Self, s: symbol.Symbol) TranspileError!void {
        self.symbols.active_table.?.symbols.push(s) catch |e| {
            std.debug.print("Error pushing symbol '{s}': {s}\\n", .{ s.name, @errorName(e) });
            return TranspileError.MemoryAllocationFailed;
        };
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

    /// Retrieves a symbol by name from a specific symbol table.
    ///
    /// This function searches for a symbol with the specified name in the given symbol table.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `table`: The symbol table to search in.
    /// - `name ( []const u8 )`: The name of the symbol to search for.
    ///
    /// Returns:
    /// - `?symbol.Symbol`: The symbol if found, otherwise `null`.
    pub fn get_symbol_from_table(_: *Self, table: *symbol.SymbolTable, name: []const u8) ?symbol.Symbol {
        for (table.symbols.items()) |s| {
            if (mem.eql(u8, s.name, name)) {
                return s;
            }
        }
        return null;
    }

    /// Retrieves a symbol table by its name.
    ///
    /// This function searches for a symbol table with the specified name in the list of symbol tables.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `name ( []const u8 )`: The name of the symbol table to search for.
    ///
    /// Returns:
    /// - `?*symbol.SymbolTable`: The symbol table if found, otherwise `null`.
    pub fn get_symbol_table(self: *Self, name: []const u8) ?*symbol.SymbolTable {
        for (self.symbols.tables.items()) |table| {
            if (mem.eql(u8, table.name, name)) {
                return table;
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
    pub fn register_symbol(self: *Self, s: symbol.Symbol) TranspileError!void {
        // Check if symbol is already defined in the current module
        if (self.get_symbol(s.name) != null) {
            self.err("Symbol '{s}' already defined in the current module", .{s.name});
            return TranspileError.DuplicateSymbol;
        }

        // Skip duplicate checks for main function - each module can have its own main
        if (!mem.eql(u8, s.name, "main")) {
            // Check if symbol is defined in any imported modules by checking global_symbols
            if (self.global_symbols.get(s.name)) |existing| {
                // Only report error if it's from a different file, not the same file
                if (!mem.eql(u8, existing.file_path, self.input_file_path)) {
                    self.err("Symbol '{s}' already defined in module '{s}'", .{ s.name, existing.file_path });
                    return TranspileError.DuplicateSymbol;
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
        self.global_symbols.put(s.name, .{
            .symbol_name = s.name,
            .file_path = self.input_file_path,
            .is_function = is_function,
        }) catch |e| {
            std.debug.print("Error registering symbol '{s}': {s}\\n", .{ s.name, @errorName(e) });
            return TranspileError.MemoryAllocationFailed;
        };

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
    pub fn register_global_node_symbol(self: *Self, node: ast.Node) TranspileError!void {
        switch (node.node_variant.?) {
            .variable => |variable| {
                const s = symbol.Symbol{
                    .type = symbol.SymbolType.Node,
                    .name = variable.name.items,
                    .data = .{ .node = node },
                    .symbol_table = null,
                };

                // Check if this symbol exists in any imported module
                if (self.global_symbols.get(variable.name.items)) |existing| {
                    self.err("Variable '{s}' already defined in module '{s}'", .{ variable.name.items, existing.file_path });
                    return TranspileError.DuplicateSymbol;
                }

                // Register the symbol in global registry
                self.global_symbols.put(variable.name.items, .{
                    .symbol_name = variable.name.items,
                    .file_path = self.input_file_path,
                    .is_function = false,
                }) catch |e| {
                    std.debug.print("Error registering symbol '{s}': {s}\\n", .{ variable.name.items, @errorName(e) });
                    return TranspileError.MemoryAllocationFailed;
                };

                try self.register_symbol(s);
            },
            .function => |function| {
                if (function.name == null) return;

                const s = symbol.Symbol{
                    .type = symbol.SymbolType.Node,
                    .name = function.name.?.items,
                    .data = .{ .node = node },
                    .symbol_table = null,
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
                        return TranspileError.DuplicateSymbol;
                    }
                }

                // Register the symbol in global registry
                self.global_symbols.put(function.name.?.items, .{
                    .symbol_name = function.name.?.items,
                    .file_path = self.input_file_path,
                    .is_function = true,
                }) catch |e| {
                    std.debug.print("Error registering symbol '{s}': {s}\\n", .{ function.name.?.items, @errorName(e) });
                    return TranspileError.MemoryAllocationFailed;
                };

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
    pub fn init_root_scope(self: *Self) TranspileError!scope.Scope {
        assert(self.scope == null);
        const root_scope = self.allocator.create(scope.Scope) catch |e| {
            std.debug.print("Error creating root scope: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
        errdefer self.allocator.destroy(root_scope);
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
        self.scope = null;
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
    pub fn new_scope(self: *Self) TranspileError!scope.Scope {
        assert(self.scope != null);
        const nc = self.allocator.create(scope.Scope) catch |e| {
            std.debug.print("Error creating new scope: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
        errdefer self.allocator.destroy(nc);
        nc.* = scope.Scope.init(self.allocator);
        nc.parent = self.scope.?.current;
        self.scope.?.current = nc;
        return nc.*;
    }

    /// Retrieves a scope entity by name from the current scope.
    ///
    /// This function searches for a scope entity with the specified name in the current scope.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `name`: The name of the scope entity to search for.
    ///
    /// Returns:
    /// - `?*ScopeEntity`: The scope entity if found, otherwise `null`.
    pub fn get_current_scope_entity(self: *Self, name: []const u8) ?*scope.ScopeEntity {
        if (self.scope.?.current == null) {
            return null;
        }
        return self.scope.?.current.?.get_entity_by_name(name);
    }

    /// Retrieves a scope entity by name from a specific scope.
    ///
    /// This function searches for a scope entity with the specified name in the given scope.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `name`: The name of the scope entity to search for.
    /// - `scope`: The scope to search in.
    ///
    /// Returns:
    /// - `?*ScopeEntity`: The scope entity if found, otherwise `null`.
    pub fn get_scope_entity_from_scope(_: *Self, name: []const u8, s: ?*scope.Scope) ?*scope.ScopeEntity {
        if (s == null) {
            return null;
        }
        return s.?.get_entity_by_name(name);
    }

    /// Retrieves a scope entity by name recursively from the current scope.
    ///
    /// This function searches for a scope entity with the specified name in the current scope
    /// and its parent scopes.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `name`: The name of the scope entity to search for.
    ///
    /// Returns:
    /// - `?*ScopeEntity`: The scope entity if found, otherwise `null`.
    pub fn get_scope_entity(self: *Self, name: []const u8) ?*scope.ScopeEntity {
        if (self.scope == null or self.scope.?.current == null) {
            return null;
        }
        var entity = self.get_current_scope_entity(name);
        if (entity) |e| {
            return e;
        }
        var current = self.scope.?.current;
        while (current.?.parent) |parent| {
            current = parent;
            entity = self.get_scope_entity_from_scope(name, current);
            if (entity) |e| {
                return e;
            }
        }
        current = self.scope.?.root;
        return null;
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
    pub fn push_scope_entity(self: *Self, entity: *scope.ScopeEntity) TranspileError!void {
        self.scope.?.current.?.entities.push(entity) catch |e| {
            std.debug.print("Error pushing scope entity: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
    }

    /// Finishes the current scope and sets the parent scope as the current scope.
    ///
    /// This function deinitializes the current scope and sets its parent scope as the new current scope.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    pub fn finish_scope(self: *Self) void {
        const new_current_scope = self.scope.?.current.?.parent;
        // Free the current scope's allocations (entities vector, etc.).
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
    pub fn deinit_node(self: *Self, node: ast.Node) void {
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
        // NOTE: `ast.Node.data.sval` is borrowed from the token stream.
        // Tokens own and free their string buffers in `TranspileProcess.deinit()`.
        // Deinitializing `.sval` here would double-free.
        if (node.node_variant) |variant| {
            switch (variant) {
                .import => |imp| {
                    // Import paths are allocated by the parser (toOwnedSlice).
                    self.allocator.free(imp.path);
                },
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
                        .for_stmt => |for_s| {
                            switch (for_s) {
                                .range => |fr| {
                                    self.deinit_node(fr.range.*);
                                    allocator.destroy(fr.range);
                                    self.deinit_node(fr.body.*);
                                    allocator.destroy(fr.body);
                                },
                                .iter => |fi| {
                                    self.deinit_node(fi.iterable.*);
                                    allocator.destroy(fi.iterable);
                                    self.deinit_node(fi.body.*);
                                    allocator.destroy(fi.body);
                                },
                            }
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

        self.warnings.deinit();

        // Free heap allocations that are not part of the `nodes` vector itself.
        for (self.owned_scope_entities.items) |entity| {
            self.allocator.destroy(entity);
        }
        self.owned_scope_entities.deinit();

        for (self.owned_nodes.items) |node_ptr| {
            self.allocator.destroy(node_ptr);
        }
        self.owned_nodes.deinit();
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
        while (global_it.next()) |entry| {
            // Many entries point at memory owned by:
            // - this process (e.g. `self.input_file_path`),
            // - or a still-live child process (during parent deinit, children are
            //   deinitialized after the parent's global_symbols map).
            //
            // Some entries (e.g. preloaded import symbols) may be backed by fresh
            // allocations and must be freed here.
            const fp = entry.value_ptr.file_path;

            var borrowed = mem.eql(u8, fp, self.input_file_path);
            if (!borrowed) {
                for (self.children.items) |child| {
                    if (mem.eql(u8, fp, child.input_file_path)) {
                        borrowed = true;
                        break;
                    }
                }
            }

            if (!borrowed) {
                self.allocator.free(entry.value_ptr.file_path);
                self.allocator.free(entry.key_ptr.*);
            }
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
    fn print(self: *Self, comptime fmt: []const u8, args: anytype) TranspileError!void {
        if (self.flags.outf) {
            std.fmt.format(self.ofile.?.writer(), fmt, args) catch |e| {
                std.debug.print("Error writing to output file: {s}\\n", .{@errorName(e)});
                return TranspileError.FileWriteError;
            };
        } else {
            std.fmt.format(self.outbuf.?.writer(), fmt, args) catch |e| {
                std.debug.print("Error writing to output buffer: {s}\\n", .{@errorName(e)});
                return TranspileError.BufferWriteError;
            };
        }
    }

    /// Write to output (either file or buffer)
    pub fn write(self: *Self, bytes: []const u8) TranspileError!void {
        if (self.flags.outf) {
            self.ofile.?.writeAll(bytes) catch |e| {
                std.debug.print("Error writing to output file: {s}\\n", .{@errorName(e)});
                return TranspileError.FileWriteError;
            };
        } else {
            self.outbuf.?.appendSlice(bytes) catch |e| {
                std.debug.print("Error writing to output buffer: {s}\\n", .{@errorName(e)});
                return TranspileError.BufferWriteError;
            };
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
    fn write_type(self: *Self, data_type: dtype.DataType) TranspileError!void {
        const c_type = map_type_to_c(data_type.type_str.items);
        try self.write(c_type);
        // TODO: Handle array types
        // if (data_type.array) |array| {
        //     for (array.brackets.items()) |bracket| {
        //         try self.write("[");
        //         try self.transpile_node(bracket);
        //         try self.write("]");
        //     }
        // }
    }

    /// Transpiles all nodes in the AST to C code
    pub fn transpile(self: *Self) GeneralError!void {
        // The parser uses scopes only for parse-time identifier validation.
        // Transpilation needs its own scope for type-driven features (e.g. warnings).
        var did_init_scope = false;
        if (self.scope == null or self.scope.?.current == null) {
            _ = try self.init_root_scope();
            did_init_scope = true;
        }
        defer if (did_init_scope) self.deinit_root_scope();

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
                import_nodes.append(i) catch |e| {
                    std.debug.print("Error adding import node index '{d}': {s}\\n", .{ i, @errorName(e) });
                    return TranspileError.MemoryAllocationFailed;
                };
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
    fn transpile_children_recursive(self: *Self, parent_proc: *TranspileProcess) TranspileError!void {
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
    fn transpile_prelude(self: *Self) TranspileError!void {
        try self.write_std_imports();
        try self.write("#include <stdbool.h>\n");
        try self.write("#include <stdlib.h>\n");
        try self.write("#include <string.h>\n\n");
    }

    /// Transpiles a node to C code
    fn transpile_node(self: *Self, node: ast.Node) TranspileError!void {
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
                } else if (mem.eql(u8, exp.op, "[]")) {
                    if (exp.left) |left| {
                        try self.transpile_node(left.*);
                    }
                    try self.write("[");
                    if (exp.right) |right| {
                        if (right.type == .Bracket) {
                            try self.transpile_node(right.node_variant.?.bracket.inner.*);
                        } else {
                            try self.transpile_node(right.*);
                        }
                    }
                    try self.write("]");
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
                // if (self.get_symbol(str) == null) {
                //     self.err("Symbol '{s}' not found", .{str});
                //     return TranspileError.SymbolNotDefined;
                // }
                try self.write(str);
            },
            .Variable => {
                const variable = node.node_variant.?.variable;
                try self.write_type(variable.type.*);
                try self.write(" ");
                try self.write(variable.name.items);

                // Array declarators come after the variable name in C.
                if (variable.type.flags != null and variable.type.flags.?.is_array) {
                    if (variable.type.array) |array| {
                        if (!array.brackets.is_empty()) {
                            for (array.brackets.items()) |bracket_node| {
                                try self.write("[");
                                if (bracket_node.type == .Bracket) {
                                    try self.transpile_node(bracket_node.node_variant.?.bracket.inner.*);
                                } else {
                                    try self.transpile_node(bracket_node);
                                }
                                try self.write("]");
                            }
                        } else {
                            try self.write("[]");
                        }
                    } else {
                        try self.write("[]");
                    }
                }

                if (variable.val) |val| {
                    try self.write(" = ");
                    if (val.type == .String) {
                        try self.write("\"");
                        try self.write(val.data.?.sval.items);
                        try self.write("\"");
                    } else if (val.type == .Boolean) {
                        const bval = val.data.?.bval;
                        try self.write(if (bval) "true" else "false");
                    } else if (val.type == .Bracket) {
                        // Array literal: `[1, 2, 3]` becomes `{1, 2, 3}` in C.
                        try self.write("{");
                        try self.transpile_node(val.node_variant.?.bracket.inner.*);
                        try self.write("}");
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

                // Function scope (arguments live here; body gets its own nested scope).
                _ = try self.new_scope();
                defer self.finish_scope();

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
                            // Make args visible for later type queries.
                            if (arg.type == .Variable) {
                                try self.register_scope_variable(arg);
                            }
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

                // Each body introduces a new scope.
                _ = try self.new_scope();
                defer self.finish_scope();

                try self.write("{");
                self.indent();
                for (body.statements.items()) |statement| {
                    if (statement.type == .Variable) {
                        try self.register_scope_variable(statement);
                    }
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
            .StatementReturn, .StatementIf, .StatementElseIf, .StatementElse, .StatementFit, .StatementFor => {
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
                    .for_stmt => |for_s| {
                        switch (for_s) {
                            .range => |fr| {
                                if (fr.range.type != .Expression or !mem.eql(u8, fr.range.node_variant.?.exp.op, "..")) {
                                    return TranspileError.UnsupportedNodeType;
                                }
                                const range_exp = fr.range.node_variant.?.exp;
                                const start = range_exp.left orelse return TranspileError.UnsupportedNodeType;
                                const end = range_exp.right orelse return TranspileError.UnsupportedNodeType;

                                try self.write("for (int ");
                                try self.write(fr.index_name);
                                try self.write(" = ");
                                try self.transpile_node(start.*);
                                try self.write("; ");
                                try self.write(fr.index_name);
                                try self.write(" < ");
                                try self.transpile_node(end.*);
                                try self.write("; ");
                                try self.write(fr.index_name);
                                try self.write("++) {");
                                self.indent();

                                if (fr.body.type == .Body) {
                                    const body = fr.body.node_variant.?.body;
                                    for (body.statements.items()) |body_stmt| {
                                        try self.write_indent();
                                        try self.transpile_node(body_stmt.*);
                                        if (body_stmt.type == .Expression) {
                                            try self.write(";");
                                        }
                                    }
                                } else {
                                    try self.write_indent();
                                    try self.transpile_node(fr.body.*);
                                    if (fr.body.type == .Expression) {
                                        try self.write(";");
                                    }
                                }

                                self.dedent();
                                try self.write_indent();
                                try self.write("}");
                            },
                            .iter => |fi| {
                                // We only support iterating array identifiers for now.
                                if (fi.iterable.type != .Identifier) {
                                    self.err("for-each loops currently require an array identifier", .{});
                                    return TranspileError.UnsupportedNodeType;
                                }
                                const arr_name = fi.iterable.data.?.sval.items;

                                const idx_name = fi.index_name orelse "__fun_i";

                                try self.write("for (int ");
                                try self.write(idx_name);
                                try self.write(" = 0; ");
                                try self.write(idx_name);
                                try self.write(" < (int)(sizeof(");
                                try self.write(arr_name);
                                try self.write(")/sizeof(");
                                try self.write(arr_name);
                                try self.write("[0])); ");
                                try self.write(idx_name);
                                try self.write("++) {");
                                self.indent();

                                // Declare the item binding each iteration.
                                // If we can find the array type in scope, use it.
                                var item_c_type: []const u8 = "int";
                                if (self.get_scope_entity(arr_name)) |ent| {
                                    if (ent.node) |arr_node| {
                                        if (arr_node.type == .Variable) {
                                            const dt = arr_node.node_variant.?.variable.type.*;
                                            item_c_type = map_type_to_c(dt.type_str.items);
                                        }
                                    }
                                }
                                try self.write_indent();
                                try self.write(item_c_type);
                                try self.write(" ");
                                try self.write(fi.item_name);
                                try self.write(" = ");
                                try self.write(arr_name);
                                try self.write("[");
                                try self.write(idx_name);
                                try self.write("];");

                                if (fi.body.type == .Body) {
                                    const body = fi.body.node_variant.?.body;
                                    for (body.statements.items()) |body_stmt| {
                                        try self.write_indent();
                                        try self.transpile_node(body_stmt.*);
                                        if (body_stmt.type == .Expression) {
                                            try self.write(";");
                                        }
                                    }
                                } else {
                                    try self.write_indent();
                                    try self.transpile_node(fi.body.*);
                                    if (fi.body.type == .Expression) {
                                        try self.write(";");
                                    }
                                }

                                self.dedent();
                                try self.write_indent();
                                try self.write("}");
                            },
                        }
                    },
                    .fit_stmt => |fit| {
                        self.warn_if_fit_not_exhausted(fit.exp, fit.branches.items());
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
            .StatementBreak => {
                try self.write("break;");
            },
            .StatementContinue => {
                try self.write("continue;");
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

    fn register_scope_variable(self: *Self, var_node: *ast.Node) TranspileError!void {
        if (self.scope == null or self.scope.?.current == null) return;
        if (var_node.type != .Variable) return;

        const ent = self.allocator.create(scope.ScopeEntity) catch |e| {
            std.debug.print("Error creating scope entity: {s}\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
        errdefer self.allocator.destroy(ent);

        ent.* = .{
            .flags = .{ .on_stack = false },
            .node = var_node,
            .name = var_node.node_variant.?.variable.name.items,
        };

        try self.push_scope_entity(ent);
        self.owned_scope_entities.append(ent) catch |e| {
            std.debug.print("Error tracking scope entity: {s}\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
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
    pub fn write_indent(self: *Self) TranspileError!void {
        try self.write("\n");
        try self.write_spaces(self.indent_level * 4); // 4 spaces per level
    }

    /// Write a specific number of spaces
    pub fn write_spaces(self: *Self, spaces: u32) TranspileError!void {
        var i: u32 = 0;
        while (i < spaces) : (i += 1) {
            try self.write(" ");
        }
    }

    /// Write formatted with indentation prefix
    pub fn write_indented(self: *Self, text: []const u8) TranspileError!void {
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
    fn process_import(self: *Self, node: ast.Node) GeneralError!void {
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
    fn process_std_import(self: *Self, import_path: []const u8) TranspileError!void {
        var header_name: []const u8 = undefined;

        if (mem.eql(u8, import_path, "std.io")) {
            header_name = self.allocator.dupe(u8, "stdio.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else if (mem.eql(u8, import_path, "std.mem")) {
            header_name = self.allocator.dupe(u8, "stdlib.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else if (mem.eql(u8, import_path, "std.string")) {
            header_name = self.allocator.dupe(u8, "string.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else if (mem.eql(u8, import_path, "std.math")) {
            header_name = self.allocator.dupe(u8, "math.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else {
            self.err("Unsupported standard library import: {s}", .{import_path});
            return TranspileError.UnsupportedImport;
        }

        for (self.std_imports.items) |existing| {
            if (mem.eql(u8, existing, header_name)) {
                self.allocator.free(header_name);
                return;
            }
        }
        self.std_imports.append(header_name) catch |e| {
            self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
    }

    /// Process a local file import (e.g., "custom" or "folder.file")
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `import_path`: The import path as a string.
    ///
    /// Errors:
    /// - Returns an error if processing the import fails.
    fn process_local_import(self: *Self, import_path: []const u8) GeneralError!void {
        // Get full path of the file to import
        var file_path = std.ArrayList(u8).init(self.allocator);
        defer file_path.deinit();

        const dir_path = std.fs.path.dirname(self.input_file_path) orelse ".";
        file_path.appendSlice(dir_path) catch |e| {
            std.debug.print("Failed to allocate memory for file path: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
        file_path.append('/') catch |e| {
            std.debug.print("Failed to allocate memory for file path: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };

        var i: usize = 0;
        while (i < import_path.len) : (i += 1) {
            if (import_path[i] == '.') {
                file_path.append('/') catch |e| {
                    std.debug.print("Failed to allocate memory for file path: {s}\\n", .{@errorName(e)});
                    return TranspileError.MemoryAllocationFailed;
                };
            } else {
                file_path.append(import_path[i]) catch |e| {
                    std.debug.print("Failed to allocate memory for file path: {s}\\n", .{@errorName(e)});
                    return TranspileError.MemoryAllocationFailed;
                };
            }
        }

        file_path.appendSlice(".fn") catch |e| {
            std.debug.print("Failed to allocate memory for file path: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
        const full_path = file_path.toOwnedSlice() catch |e| {
            std.debug.print("Failed to allocate memory for file path: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
        errdefer self.allocator.free(full_path);
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
            return TranspileError.FileNotFound;
        };

        // Robust direct circular dependency detection
        // First, check if the file being imported already has us in its import chain
        const file_contents = fs.cwd().readFileAlloc(self.allocator, full_path, 1024 * 1024) catch |read_err| {
            self.err("Failed to read import file: {any}", .{read_err});
            return TranspileError.FileReadError;
        };
        defer self.allocator.free(file_contents);

        // Check if the file imports us directly (crude but effective)
        const our_name = std.fs.path.stem(self.input_file_path);
        var import_line = std.ArrayList(u8).init(self.allocator);
        defer import_line.deinit();
        import_line.appendSlice("imp ") catch |e| {
            std.debug.print("Failed to allocate memory for import line: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
        import_line.appendSlice(our_name) catch |e| {
            std.debug.print("Failed to allocate memory for import line: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
        import_line.appendSlice(";") catch |e| {
            std.debug.print("Failed to allocate memory for import line: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };

        // Check if the target file imports us
        if (std.mem.indexOf(u8, file_contents, import_line.items)) |_| {
            const basename1 = std.fs.path.basename(self.input_file_path);
            const basename2 = std.fs.path.basename(full_path);

            self.err("CIRCULAR IMPORT DETECTED: '{s}' imports '{s}', but '{s}' also imports '{s}', creating a circular dependency", .{ basename1, basename2, basename2, basename1 });
            return TranspileError.CircularImport;
        }

        // Mark this file as imported
        const full_path_copy = self.allocator.dupe(u8, full_path) catch |e| {
            std.debug.print("Failed to allocate memory for full path copy: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
        errdefer self.allocator.free(full_path_copy);

        self.imported_files.put(full_path_copy, true) catch |e| {
            std.debug.print("Failed to allocate memory for imported file: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };

        // Create and initialize child transpile process
        var import_proc = self.allocator.create(TranspileProcess) catch |e| {
            std.debug.print("Failed to allocate memory for import process: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
        errdefer self.allocator.destroy(import_proc);

        import_proc.* = try TranspileProcess.init(self.allocator, full_path, "temp.c", .{ .outf = false });

        import_proc.parent = self;
        import_proc.is_importing = true;

        // Copy the import chain and add the current import for tracking
        for (self.import_chain.items) |chain_path| {
            const chain_path_copy = self.allocator.dupe(u8, chain_path) catch |e| {
                std.debug.print("Failed to allocate memory for import chain copy: {s}\\n", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
            errdefer self.allocator.free(chain_path_copy);

            import_proc.import_chain.append(chain_path_copy) catch |e| {
                std.debug.print("Failed to allocate memory for import chain: {s}\\n", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        }
        const import_path_copy = self.allocator.dupe(u8, full_path) catch |e| {
            std.debug.print("Failed to allocate memory for import path copy: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
        errdefer self.allocator.free(import_path_copy);

        import_proc.import_chain.append(import_path_copy) catch |e| {
            std.debug.print("Failed to allocate memory for import chain: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };

        // Copy imported files to child
        var it = self.imported_files.iterator();
        while (it.next()) |entry| {
            const imported_file_copy = self.allocator.dupe(u8, entry.key_ptr.*) catch |e| {
                std.debug.print("Failed to allocate memory for imported file copy: {s}\\n", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
            errdefer self.allocator.free(imported_file_copy);

            import_proc.imported_files.put(imported_file_copy, true) catch |e| {
                std.debug.print("Failed to allocate memory for imported file: {s}\\n", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        }

        // Process the imported file
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
        self.children.append(import_proc) catch |e| {
            std.debug.print("Failed to allocate memory for child process: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
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
    fn sync_global_symbols_to_parent(self: *Self) TranspileError!void {
        if (self.parent == null) return; // Not a child process

        var it = self.global_symbols.iterator();
        while (it.next()) |entry| {
            const symbol_name = entry.key_ptr.*;
            const symbol_info = entry.value_ptr.*;

            // Skip main functions entirely
            if (mem.eql(u8, symbol_name, "main")) continue;

            // Check if this symbol is already defined in the parent
            if (self.parent.?.global_symbols.get(symbol_name)) |existing| {
                // If we find a conflict from a different file, report it.
                // Allow duplicates from the same file path (e.g. when symbols were
                // preloaded earlier for parsing).
                if (!mem.eql(u8, existing.file_path, symbol_info.file_path)) {
                    self.err("Symbol '{s}' in module '{s}' conflicts with same symbol defined in module '{s}'", .{ symbol_name, symbol_info.file_path, existing.file_path });
                    return TranspileError.DuplicateSymbol;
                }

                continue;
            }

            // Add this symbol to the parent's global registry
            self.parent.?.global_symbols.put(symbol_name, .{
                .symbol_name = symbol_name,
                .file_path = symbol_info.file_path,
                .is_function = symbol_info.is_function,
            }) catch |e| {
                std.debug.print("Failed to allocate memory for global symbol: {s}\\n", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        }
    }

    /// Write standard library imports to the output
    fn write_std_imports(self: *Self) TranspileError!void {
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
