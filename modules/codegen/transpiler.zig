const std = @import("std");
const builtin = @import("builtin");
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
    /// Error indicating an imported module file is not found.
    ImportFileNotFound,
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

    /// Error indicating a type mismatch.
    TypeMismatch,
    /// Error indicating a function call has the wrong number of arguments.
    WrongArgCount,
    /// Error indicating a return statement does not match the function return type.
    ReturnTypeMismatch,
    /// Error indicating a condition expression has an invalid type.
    InvalidConditionType,
    /// Error indicating an expression is not callable.
    NotCallable,

    /// Error indicating compounds have cyclic by-value dependencies.
    CyclicCompoundDependency,
    /// Error indicating an index operation is applied to a non-array.
    IndexNonArray,
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

    /// Flag to preload imported module symbols during parsing.
    ///
    /// This is primarily for parser identifier validation. Tooling (like `fls`) may disable
    /// it when indexing from in-memory text to avoid filesystem churn and noisy diagnostics
    /// when relative imports are resolved from a temp path.
    preload_imports: bool = true,

    /// Flag to preload stdlib signature modules during parsing.
    ///
    /// This is best-effort and non-fatal, but still touches the filesystem.
    preload_std_imports: bool = true,

    /// When false, suppress writing diagnostics to stderr.
    ///
    /// Tooling (like `fls`) may parse/lex temporary/incomplete snapshots while typing.
    /// Emitting those transient errors to stderr creates noisy logs without improving UX.
    emit_stderr: bool = true,
};

/// GlobalSymbolInfo tracks information about symbols across modules
pub const GlobalSymbolInfo = struct {
    symbol_name: []const u8,
    file_path: []const u8,
    is_function: bool,
};

const ImplKey = struct {
    type_name: []const u8,
    quirk_sig: []const u8,
};

const ImplKeyContext = struct {
    pub fn hash(_: @This(), key: ImplKey) u64 {
        const a = std.hash.Wyhash.hash(0, key.type_name);
        return std.hash.Wyhash.hash(a, key.quirk_sig);
    }

    pub fn eql(_: @This(), a: ImplKey, b: ImplKey) bool {
        return mem.eql(u8, a.type_name, b.type_name) and mem.eql(u8, a.quirk_sig, b.quirk_sig);
    }
};

pub const TypeRegistry = struct {
    allocator: mem.Allocator,

    /// Maps `compound` names to their defining heap node.
    compounds_by_name: std.StringHashMap(*ast.Node),

    /// Maps quirk names to a canonical signature key.
    quirk_sig_by_name: std.StringHashMap([]const u8),

    /// Maps canonical signature key to the (first-seen) quirk definition node.
    quirks_by_sig: std.StringHashMap(*ast.Node),

    /// Caches hash(sig) for canonical quirk signature keys.
    quirk_hash_by_sig: std.StringHashMap(u64),

    /// Maps `<Type> + <QuirkSig>` to the impl definition node.
    impls_by_key: std.HashMap(ImplKey, *ast.Node, ImplKeyContext, 80),

    /// Owned allocations for quirk signature keys.
    owned_keys: std.ArrayList([]const u8),

    pub fn init(allocator: mem.Allocator) TypeRegistry {
        return .{
            .allocator = allocator,
            .compounds_by_name = std.StringHashMap(*ast.Node).init(allocator),
            .quirk_sig_by_name = std.StringHashMap([]const u8).init(allocator),
            .quirks_by_sig = std.StringHashMap(*ast.Node).init(allocator),
            .quirk_hash_by_sig = std.StringHashMap(u64).init(allocator),
            .impls_by_key = std.HashMap(ImplKey, *ast.Node, ImplKeyContext, 80).init(allocator),
            .owned_keys = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *TypeRegistry) void {
        // compound/quirk name keys are borrowed from AST node allocations.
        self.compounds_by_name.deinit();
        self.quirk_sig_by_name.deinit();
        self.quirks_by_sig.deinit();
        self.quirk_hash_by_sig.deinit();
        self.impls_by_key.deinit();

        for (self.owned_keys.items) |k| {
            self.allocator.free(k);
        }
        self.owned_keys.deinit();
    }
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

    /// Guard to avoid emitting type/vtable prelude more than once.
    did_emit_user_types: bool = false,
    /// Guard to avoid emitting impl bodies/vtables more than once.
    did_emit_impls: bool = false,
    /// Track if we're currently transpiling function parameters
    in_function_params: bool = false,

    /// True while generating the C `main` body.
    in_main: bool = false,
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

    /// Backing allocator used by this process's arena.
    backing_allocator: mem.Allocator,

    /// Arena used for AST/scopes/registries (simplifies ownership and cleanup).
    arena: *std.heap.ArenaAllocator,

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

    /// Registry for user-defined types (`compound`/`quirk`/`impl`).
    /// Stored only on the root process; children access it through `get_root()`.
    type_registry: ?TypeRegistry = null,

    /// Parent TranspileProcess if this is a child import process
    parent: ?*TranspileProcess = null,

    /// Child import processes
    children: std.ArrayList(*TranspileProcess),

    /// Standard library imports to be added at the beginning of the output
    std_imports: std.ArrayList([]const u8),

    /// The input file path (used for relative path resolution)
    input_file_path: []const u8,

    /// Standard library root directory (expected to contain `std/`), if discovered.
    /// Typical installed layout is: `<prefix>/share/fun/std/*.fn`.
    stdlib_dir: ?[]const u8 = null,

    /// Whether the current file is importing other files
    is_importing: bool = false,

    /// The current token being processed
    current_token: ?token.Token = null,

    const Self = @This();

    fn is_abs_path(path: []const u8) bool {
        return std.fs.path.isAbsolute(path);
    }

    fn dir_exists(path: []const u8) bool {
        if (is_abs_path(path)) {
            var d = std.fs.openDirAbsolute(path, .{}) catch return false;
            d.close();
            return true;
        }
        var d = std.fs.cwd().openDir(path, .{}) catch return false;
        d.close();
        return true;
    }

    fn dupe_arena(a: mem.Allocator, s: []const u8) TranspileError![]const u8 {
        return a.dupe(u8, s) catch TranspileError.MemoryAllocationFailed;
    }

    fn join_alloc(allocator: mem.Allocator, parts: []const []const u8) TranspileError![]const u8 {
        return std.fs.path.join(allocator, parts) catch TranspileError.MemoryAllocationFailed;
    }

    fn discover_stdlib_dir(backing: mem.Allocator, a: mem.Allocator) TranspileError!?[]const u8 {
        // 1) Explicit override (best for installers and CI)
        const env = std.process.getEnvVarOwned(backing, "FUN_STDLIB_DIR") catch |e| switch (e) {
            error.EnvironmentVariableNotFound => null,
            else => return TranspileError.MemoryAllocationFailed,
        };
        if (env) |p| {
            defer backing.free(p);
            // Even if it doesn't exist, keep the value for downstream tooling.
            return try dupe_arena(a, p);
        }

        // 2) Relative to executable: `<exe_dir>/../share/fun`
        const exe_path = std.fs.selfExePathAlloc(backing) catch null;
        if (exe_path) |exe| {
            defer backing.free(exe);
            const exe_dir = std.fs.path.dirname(exe) orelse null;
            if (exe_dir) |d| {
                const prefix_dir = std.fs.path.dirname(d) orelse d;
                const cand = try join_alloc(backing, &[_][]const u8{ prefix_dir, "share", "fun" });
                defer backing.free(cand);
                if (dir_exists(cand)) return try dupe_arena(a, cand);
            }
        }

        // 3) Dev-tree fallbacks (when running from repo root)
        {
            const cand1 = "zig-out/share/fun";
            if (dir_exists(cand1)) return try dupe_arena(a, cand1);
            const cand2 = "stdlib";
            if (dir_exists(cand2)) return try dupe_arena(a, cand2);
        }

        // 4) Common system locations
        if (builtin.target.os.tag == .windows) {
            const local_app = std.process.getEnvVarOwned(backing, "LOCALAPPDATA") catch null;
            if (local_app) |base| {
                defer backing.free(base);
                const cand = try join_alloc(backing, &[_][]const u8{ base, "fun", "share", "fun" });
                defer backing.free(cand);
                if (dir_exists(cand)) return try dupe_arena(a, cand);
            }
            const program_files = std.process.getEnvVarOwned(backing, "ProgramFiles") catch null;
            if (program_files) |base| {
                defer backing.free(base);
                const cand = try join_alloc(backing, &[_][]const u8{ base, "fun", "share", "fun" });
                defer backing.free(cand);
                if (dir_exists(cand)) return try dupe_arena(a, cand);
            }
        } else {
            const cand1 = "/usr/local/share/fun";
            if (dir_exists(cand1)) return try dupe_arena(a, cand1);
            const cand2 = "/usr/share/fun";
            if (dir_exists(cand2)) return try dupe_arena(a, cand2);

            const home = std.process.getEnvVarOwned(backing, "HOME") catch null;
            if (home) |h| {
                defer backing.free(h);
                const cand = try join_alloc(backing, &[_][]const u8{ h, ".local", "share", "fun" });
                defer backing.free(cand);
                if (dir_exists(cand)) return try dupe_arena(a, cand);
            }
        }

        return null;
    }

    fn get_root(self: *Self) *Self {
        var cur: *Self = self;
        while (cur.parent) |p| {
            cur = p;
        }
        return cur;
    }

    fn ensure_type_registry(self: *Self) *TypeRegistry {
        const root = self.get_root();
        if (root.type_registry == null) {
            root.type_registry = TypeRegistry.init(root.allocator);
        }
        return &root.type_registry.?;
    }

    fn append_dtype_sig(self: *Self, buf: *std.ArrayList(u8), dt: *const dtype.DataType) TranspileError!void {
        _ = self;
        buf.appendSlice(dt.type_str.items) catch {
            return TranspileError.MemoryAllocationFailed;
        };
        if (dt.pointer_depth > 0) {
            var i: usize = 0;
            while (i < dt.pointer_depth) : (i += 1) {
                buf.append('*') catch {
                    return TranspileError.MemoryAllocationFailed;
                };
            }
        }
        if (dt.array) |arr| {
            var i: usize = 0;
            while (i < arr.brackets.count) : (i += 1) {
                buf.appendSlice("[]") catch {
                    return TranspileError.MemoryAllocationFailed;
                };
            }
        }
    }

    fn quirk_signature_key(self: *Self, qnode: *ast.Node) TranspileError![]const u8 {
        if (qnode.node_variant == null) return TranspileError.UnsupportedNodeType;
        const q = qnode.node_variant.?.quirk;

        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        const methods = q.methods.items();
        var idxs = self.allocator.alloc(usize, methods.len) catch {
            return TranspileError.MemoryAllocationFailed;
        };
        defer self.allocator.free(idxs);
        for (methods, 0..) |_, i| idxs[i] = i;

        // Structural equivalence should not depend on declaration order.
        std.sort.pdq(usize, idxs, methods, struct {
            fn lessThan(ctx: []const ast.QuirkMethodSig, a: usize, b: usize) bool {
                return mem.lessThan(u8, ctx[a].name.items, ctx[b].name.items);
            }
        }.lessThan);

        for (idxs) |mi| {
            const m = methods[mi];

            buf.appendSlice(m.name.items) catch {
                return TranspileError.MemoryAllocationFailed;
            };
            buf.append('(') catch {
                return TranspileError.MemoryAllocationFailed;
            };

            const args = m.args.items();
            for (args, 0..) |a, ai| {
                if (ai != 0) {
                    buf.appendSlice(",") catch {
                        return TranspileError.MemoryAllocationFailed;
                    };
                }
                try self.append_dtype_sig(&buf, a.dtype);
            }

            buf.appendSlice(")->") catch {
                return TranspileError.MemoryAllocationFailed;
            };
            try self.append_dtype_sig(&buf, &m.rtype);
            buf.append(';') catch {
                return TranspileError.MemoryAllocationFailed;
            };
        }

        const owned = buf.toOwnedSlice() catch {
            return TranspileError.MemoryAllocationFailed;
        };
        return owned;
    }

    fn collect_type_registry_module(self: *Self, proc: *Self, reg: *TypeRegistry) TranspileError!void {
        for (proc.owned_nodes.items) |n| {
            switch (n.type) {
                .Compound => {
                    if (n.node_variant == null) continue;
                    const name = n.node_variant.?.compound.name.items;
                    if (reg.compounds_by_name.contains(name)) {
                        return TranspileError.DuplicateSymbol;
                    }
                    reg.compounds_by_name.put(name, n) catch {
                        return TranspileError.MemoryAllocationFailed;
                    };
                },
                .Quirk => {
                    if (n.node_variant == null) continue;
                    const name = n.node_variant.?.quirk.name.items;

                    // Compute signature, but only keep one allocated key per unique signature.
                    const sig_key_tmp = try self.quirk_signature_key(n);
                    const sig_hash = std.hash.Wyhash.hash(0, sig_key_tmp);

                    const gop = reg.quirks_by_sig.getOrPut(sig_key_tmp) catch {
                        reg.allocator.free(sig_key_tmp);
                        return TranspileError.MemoryAllocationFailed;
                    };

                    const sig_key = gop.key_ptr.*;
                    if (gop.found_existing) {
                        // Not inserted; free the temporary signature string.
                        reg.allocator.free(sig_key_tmp);
                    } else {
                        // Inserted; keep and free at registry teardown.
                        reg.owned_keys.append(sig_key) catch {
                            reg.allocator.free(sig_key);
                            return TranspileError.MemoryAllocationFailed;
                        };
                        gop.value_ptr.* = n;
                    }

                    // Cache hash(sig) for fast codegen naming.
                    if (!reg.quirk_hash_by_sig.contains(sig_key)) {
                        reg.quirk_hash_by_sig.put(sig_key, sig_hash) catch {
                            return TranspileError.MemoryAllocationFailed;
                        };
                    }

                    // Map name -> canonical signature.
                    if (reg.quirk_sig_by_name.contains(name)) {
                        return TranspileError.DuplicateSymbol;
                    }
                    reg.quirk_sig_by_name.put(name, sig_key) catch {
                        return TranspileError.MemoryAllocationFailed;
                    };
                },
                .Impl => {
                    // Collected in a second pass after all quirks are known.
                },
                else => {},
            }
        }
    }

    fn collect_impls_module(self: *Self, proc: *Self, reg: *TypeRegistry) TranspileError!void {
        _ = self;
        for (proc.owned_nodes.items) |n| {
            if (n.type != .Impl or n.node_variant == null) continue;
            const imp = n.node_variant.?.impl;
            const type_name = imp.type_name.items;

            // Plain impl blocks (`impl Type { ... }`) are not part of the quirk registry.
            const quirk_name = if (imp.quirk_name) |qn| qn.items else continue;

            const sig = reg.quirk_sig_by_name.get(quirk_name) orelse quirk_name;

            // Validate: quirk impl must implement all quirk methods.
            // This is a compiler-time error so users get a clear missing-method list.
            try proc.validate_quirk_impl_complete(n, type_name, quirk_name, sig, reg);

            const key: ImplKey = .{ .type_name = type_name, .quirk_sig = sig };
            if (reg.impls_by_key.contains(key)) {
                return TranspileError.DuplicateSymbol;
            }

            reg.impls_by_key.put(key, n) catch {
                return TranspileError.MemoryAllocationFailed;
            };
        }
    }

    fn validate_quirk_impl_complete(
        self: *Self,
        impl_node: *ast.Node,
        type_name: []const u8,
        quirk_name: []const u8,
        quirk_sig: []const u8,
        reg: *TypeRegistry,
    ) TranspileError!void {
        const qnode = reg.quirks_by_sig.get(quirk_sig) orelse {
            self.report_type_error(impl_node.*, "unknown quirk '{s}'", .{quirk_name});
            return TranspileError.SymbolNotDefined;
        };
        if (qnode.node_variant == null) return TranspileError.UnsupportedNodeType;
        const q = qnode.node_variant.?.quirk;

        if (impl_node.node_variant == null) return TranspileError.UnsupportedNodeType;
        const im = impl_node.node_variant.?.impl;

        // Build a lookup from base method name -> function node.
        // Impl methods are parsed as Function nodes with generated names:
        // `<Type>__<Quirk>__<method>`.
        var methods_by_name = std.StringHashMap(*ast.Node).init(self.backing_allocator);
        defer methods_by_name.deinit();

        for (im.methods.items()) |m_ptr| {
            const m = m_ptr.*;
            if (m.type != .Function or m.node_variant == null) continue;
            const fnv = m.node_variant.?.function;
            const gen = if (fnv.name) |nm| nm.items else continue;
            const base = base_method_name_from_generated(gen);
            if (base.len == 0) continue;
            // Keep the first occurrence; duplicates are already handled elsewhere.
            if (!methods_by_name.contains(base)) {
                methods_by_name.put(base, m_ptr) catch return TranspileError.MemoryAllocationFailed;
            }
        }

        // Collect missing methods.
        var missing = std.ArrayList(ast.QuirkMethodSig).init(self.backing_allocator);
        defer missing.deinit();

        for (q.methods.items()) |qm| {
            const name = qm.name.items;
            const m_ptr = methods_by_name.get(name) orelse {
                missing.append(qm) catch return TranspileError.MemoryAllocationFailed;
                continue;
            };
            const m = m_ptr.*;
            const fnv = m.node_variant.?.function;

            // Must have a body to count as implemented.
            if (fnv.body == null) {
                missing.append(qm) catch return TranspileError.MemoryAllocationFailed;
                continue;
            }

            // Signature must match the quirk declaration.
            try self.validate_quirk_method_signature(impl_node, name, m, qm);
        }

        if (missing.items.len != 0) {
            var buf = std.ArrayList(u8).init(self.backing_allocator);
            defer buf.deinit();

            buf.writer().print(
                "impl '{s}' for quirk '{s}' is missing {d} method(s):\n",
                .{ type_name, quirk_name, missing.items.len },
            ) catch return TranspileError.MemoryAllocationFailed;

            for (missing.items) |qm| {
                buf.appendSlice("- ") catch return TranspileError.MemoryAllocationFailed;
                try self.append_quirk_method_stub_sig(&buf, qm);
                buf.append('\n') catch return TranspileError.MemoryAllocationFailed;
            }

            self.report_type_error(impl_node.*, "{s}", .{buf.items});
            return TranspileError.TypeMismatch;
        }
    }

    fn validate_quirk_method_signature(
        self: *Self,
        impl_node: *ast.Node,
        method_name: []const u8,
        impl_method_node: ast.Node,
        quirk_sig: ast.QuirkMethodSig,
    ) TranspileError!void {
        if (impl_method_node.node_variant == null or impl_method_node.type != .Function) {
            self.report_type_error(impl_node.*, "invalid impl method '{s}'", .{method_name});
            return TranspileError.UnsupportedNodeType;
        }
        const impl_fn = impl_method_node.node_variant.?.function;

        // Impl args include implicit `self` as arg0; quirk sig args do not.
        const impl_args = if (impl_fn.args) |a| a.items() else &[_]*ast.Node{};
        const quirk_args = quirk_sig.args.items();
        const impl_user_args = if (impl_args.len > 0) impl_args[1..] else impl_args;

        if (impl_user_args.len != quirk_args.len) {
            self.report_type_error(
                impl_node.*,
                "impl method '{s}' arg count mismatch for quirk method '{s}'",
                .{ method_name, method_name },
            );
            return TranspileError.WrongArgCount;
        }

        // Return type: missing means void.
        var impl_rtype: dtype.DataType = .{ .type_str = std.ArrayList(u8).init(self.backing_allocator) };
        defer impl_rtype.type_str.deinit();
        if (impl_fn.rtype) |rt| {
            impl_rtype.type_str.appendSlice(rt.type_str.items) catch return TranspileError.MemoryAllocationFailed;
            impl_rtype.pointer_depth = rt.pointer_depth;
            impl_rtype.array = rt.array;
            impl_rtype.type = rt.type;
        } else {
            impl_rtype.type = .Void;
            impl_rtype.type_str.appendSlice("void") catch return TranspileError.MemoryAllocationFailed;
        }

        if (!dtype_sig_equal(&impl_rtype, &quirk_sig.rtype)) {
            var want = std.ArrayList(u8).init(self.backing_allocator);
            defer want.deinit();
            var got = std.ArrayList(u8).init(self.backing_allocator);
            defer got.deinit();
            try self.append_dtype_sig(&want, &quirk_sig.rtype);
            try self.append_dtype_sig(&got, &impl_rtype);
            self.report_type_error(
                impl_node.*,
                "impl method '{s}' return type mismatch: expected {s}, got {s}",
                .{ method_name, want.items, got.items },
            );
            return TranspileError.ReturnTypeMismatch;
        }

        for (quirk_args, 0..) |qa, i| {
            const impl_arg_node = impl_user_args[i];
            if (impl_arg_node.node_variant == null or impl_arg_node.type != .Variable) {
                self.report_type_error(impl_node.*, "invalid impl method '{s}' arg", .{method_name});
                return TranspileError.UnsupportedNodeType;
            }
            const impl_dt = impl_arg_node.node_variant.?.variable.type;
            if (!dtype_sig_equal(impl_dt, qa.dtype)) {
                var want = std.ArrayList(u8).init(self.backing_allocator);
                defer want.deinit();
                var got = std.ArrayList(u8).init(self.backing_allocator);
                defer got.deinit();
                try self.append_dtype_sig(&want, qa.dtype);
                try self.append_dtype_sig(&got, impl_dt);
                self.report_type_error(
                    impl_node.*,
                    "impl method '{s}' arg {d} type mismatch: expected {s}, got {s}",
                    .{ method_name, i + 1, want.items, got.items },
                );
                return TranspileError.TypeMismatch;
            }
        }
    }

    fn dtype_sig_equal(a: *const dtype.DataType, b: *const dtype.DataType) bool {
        if (!mem.eql(u8, a.type_str.items, b.type_str.items)) return false;
        if (a.pointer_depth != b.pointer_depth) return false;
        const a_arr = a.array;
        const b_arr = b.array;
        if ((a_arr == null) != (b_arr == null)) return false;
        if (a_arr) |aa| {
            if (b_arr) |bb| {
                if (aa.brackets.count != bb.brackets.count) return false;
            } else return false;
        }
        return true;
    }

    fn base_method_name_from_generated(gen: []const u8) []const u8 {
        // Split on "__" and return the last segment.
        var i: usize = gen.len;
        while (i >= 2) : (i -= 1) {
            if (gen[i - 1] == '_' and gen[i - 2] == '_') {
                return gen[i..];
            }
        }
        return "";
    }

    fn append_quirk_method_stub_sig(self: *Self, buf: *std.ArrayList(u8), m: ast.QuirkMethodSig) TranspileError!void {
        buf.appendSlice(m.name.items) catch return TranspileError.MemoryAllocationFailed;
        buf.append('(') catch return TranspileError.MemoryAllocationFailed;

        const args = m.args.items();
        for (args, 0..) |a, i| {
            if (i != 0) buf.appendSlice(", ") catch return TranspileError.MemoryAllocationFailed;
            try self.append_dtype_sig(buf, a.dtype);
            buf.append(' ') catch return TranspileError.MemoryAllocationFailed;
            buf.appendSlice(a.name.items) catch return TranspileError.MemoryAllocationFailed;
        }
        buf.append(')') catch return TranspileError.MemoryAllocationFailed;

        if (m.rtype.type != .Void) {
            buf.append(' ') catch return TranspileError.MemoryAllocationFailed;
            try self.append_dtype_sig(buf, &m.rtype);
        }
    }

    fn collect_type_registry_all(self: *Self) TranspileError!void {
        const reg = self.ensure_type_registry();

        // Rebuild from scratch each transpile run.
        reg.deinit();
        self.get_root().type_registry = TypeRegistry.init(self.get_root().allocator);
        const new_reg = &self.get_root().type_registry.?;

        try self.collect_type_registry_module(self, new_reg);
        for (self.children.items) |child| {
            try self.collect_type_registry_module(child, new_reg);
        }

        // Second pass: impls need quirk name->signature resolution.
        try self.collect_impls_module(self, new_reg);
        for (self.children.items) |child| {
            try self.collect_impls_module(child, new_reg);
        }
    }

    fn build_full_import_path(self: *Self, import_path: []const u8) TranspileError![]const u8 {
        // This path is a temporary helper string; keep it off the arena.
        var file_path = std.ArrayList(u8).init(self.backing_allocator);
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

        // Convert dotted imports to a path. Additionally, support parent traversal via dot runs:
        // - `.`  => path separator
        // - `..` => `../` (one parent)
        // - `....` => `../../` (two parents)
        var i: usize = 0;
        while (i < import_path.len) {
            if (import_path[i] != '.') {
                file_path.append(import_path[i]) catch |e| {
                    std.debug.print("Failed to allocate memory for file path: {s}\\n", .{@errorName(e)});
                    return TranspileError.MemoryAllocationFailed;
                };
                i += 1;
                continue;
            }

            var j = i;
            while (j < import_path.len and import_path[j] == '.') : (j += 1) {}
            const run_len = j - i;
            const parents = run_len / 2;
            const sep = (run_len % 2) == 1;

            var p: usize = 0;
            while (p < parents) : (p += 1) {
                file_path.appendSlice("..") catch |e| {
                    std.debug.print("Failed to allocate memory for file path: {s}\\n", .{@errorName(e)});
                    return TranspileError.MemoryAllocationFailed;
                };
                file_path.append('/') catch |e| {
                    std.debug.print("Failed to allocate memory for file path: {s}\\n", .{@errorName(e)});
                    return TranspileError.MemoryAllocationFailed;
                };
            }
            if (sep) {
                file_path.append('/') catch |e| {
                    std.debug.print("Failed to allocate memory for file path: {s}\\n", .{@errorName(e)});
                    return TranspileError.MemoryAllocationFailed;
                };
            }

            i = j;
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
    pub fn preload_import_global_symbols(self: *Self, import_node: ast.Node, import_path: []const u8) GeneralError!void {
        if (!self.flags.preload_imports) return;
        if (std.mem.indexOf(u8, import_path, "std.") != null) return;

        const full_path = try self.build_full_import_path(import_path);
        defer self.backing_allocator.free(full_path);

        std.fs.cwd().access(full_path, .{}) catch {
            self.report_error(import_node, "Import file not found: {s}", .{full_path});
            return TranspileError.ImportFileNotFound;
        };

        // Early direct circular import detection (A imports B, and B imports A).
        // This is intentionally lightweight and mirrors the check in process_local_import.
        {
            const file_contents = fs.cwd().readFileAlloc(self.backing_allocator, full_path, 1024 * 1024) catch |read_err| {
                self.report_error(import_node, "Failed to read import file '{s}': {any}", .{ full_path, read_err });
                return TranspileError.FileReadError;
            };
            defer self.backing_allocator.free(file_contents);

            const our_name = std.fs.path.stem(self.input_file_path);
            var import_line = std.ArrayList(u8).init(self.backing_allocator);
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
                self.report_error(import_node, "CIRCULAR IMPORT DETECTED: '{s}' imports '{s}', but '{s}' also imports '{s}', creating a circular dependency", .{ basename1, basename2, basename2, basename1 });
                return TranspileError.CircularImport;
            }
        }

        var import_proc = try TranspileProcess.init(self.backing_allocator, full_path, "temp.c", .{ .exec = false, .outf = false, .ast = false });
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
        return init_with_stdlib_dir(allocator, ifilepath, ofilepath, flags, null);
    }

    /// Same as `init`, but opens the input file read-write.
    ///
    /// This is required for operations that modify the input file in-place (e.g. the formatter).
    pub fn init_rw(allocator: mem.Allocator, ifilepath: []const u8, ofilepath: []const u8, flags: TranspileProcessFlags) TranspileError!Self {
        return init_with_stdlib_dir_mode(allocator, ifilepath, ofilepath, flags, null, .read_write);
    }

    pub fn init_with_stdlib_dir(
        allocator: mem.Allocator,
        ifilepath: []const u8,
        ofilepath: []const u8,
        flags: TranspileProcessFlags,
        stdlib_dir_override: ?[]const u8,
    ) TranspileError!Self {
        return init_with_stdlib_dir_mode(allocator, ifilepath, ofilepath, flags, stdlib_dir_override, .read_only);
    }

    fn init_with_stdlib_dir_mode(
        allocator: mem.Allocator,
        ifilepath: []const u8,
        ofilepath: []const u8,
        flags: TranspileProcessFlags,
        stdlib_dir_override: ?[]const u8,
        input_mode: fs.File.OpenMode,
    ) TranspileError!Self {
        const ifile = fs.cwd().openFile(ifilepath, .{ .mode = input_mode }) catch |e| {
            std.debug.print("Error opening input file '{s}': {s}\\n", .{ ifilepath, @errorName(e) });
            return TranspileError.FileOpenError;
        };
        errdefer ifile.close();

        const arena_ptr = allocator.create(std.heap.ArenaAllocator) catch {
            return TranspileError.MemoryAllocationFailed;
        };
        errdefer allocator.destroy(arena_ptr);
        arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena_ptr.deinit();
        const a = arena_ptr.allocator();

        var ofile: ?fs.File = null;
        var outbuf: ?std.ArrayList(u8) = null;

        if (flags.outf) {
            ofile = fs.cwd().createFile(ofilepath, .{ .read = true }) catch |e| {
                std.debug.print("Error creating output file '{s}': {s}\\n", .{ ofilepath, @errorName(e) });
                return TranspileError.FileOpenError;
            };
            errdefer if (ofile) |f| f.close();
        } else {
            outbuf = std.ArrayList(u8).init(a);
        }

        // Create initial symbol table
        const initial_table = a.create(symbol.SymbolTable) catch |e| {
            std.debug.print("Error creating initial symbol table: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
        errdefer a.destroy(initial_table);
        initial_table.* = .{
            .symbols = utils.Vector(symbol.Symbol).init(a),
            .name = "",
        };
        errdefer initial_table.symbols.deinit();

        // Initialize import-related structures
        var imported_files = std.StringHashMap(bool).init(a);
        errdefer imported_files.deinit();

        var import_chain = std.ArrayList([]const u8).init(a);
        errdefer import_chain.deinit();

        const input_file_path = a.dupe(u8, ifilepath) catch |e| {
            std.debug.print("Error duplicating input file path '{s}': {s}\\n", .{ ifilepath, @errorName(e) });
            return TranspileError.MemoryAllocationFailed;
        };
        errdefer a.free(input_file_path);

        imported_files.put(input_file_path, true) catch |e| {
            std.debug.print("Error adding file '{s}' to imported files: {s}\\n", .{ input_file_path, @errorName(e) });
            return TranspileError.MemoryAllocationFailed;
        }; // Mark current file as imported

        import_chain.append(input_file_path) catch |e| {
            std.debug.print("Error adding initial path '{s}' to import chain: {s}\\n", .{ input_file_path, @errorName(e) });
            return TranspileError.MemoryAllocationFailed;
        };

        const discovered_stdlib_dir: ?[]const u8 = if (stdlib_dir_override) |p|
            (try dupe_arena(a, p))
        else
            (try discover_stdlib_dir(allocator, a));

        return Self{
            .flags = flags,
            .pos = .{ .col = 1, .line = 1, .start_col = 1, .end_col = 1, .filename = input_file_path },
            .ifile = ifile,
            .ofile = ofile,
            .outbuf = outbuf,
            .tokens = utils.Vector(token.Token).init(a),
            .nodes = utils.Vector(ast.Node).init(a),
            .warnings = std.ArrayList(u8).init(a),
            .owned_nodes = std.ArrayList(*ast.Node).init(a),
            .owned_scope_entities = std.ArrayList(*scope.ScopeEntity).init(a),
            .scope = null,
            .symbols = .{
                .active_table = initial_table,
                .tables = utils.Vector(*symbol.SymbolTable).init(a),
            },
            .allocator = a,
            .backing_allocator = allocator,
            .arena = arena_ptr,
            .imported_files = imported_files,
            .import_chain = import_chain,
            .global_symbols = std.StringHashMap(GlobalSymbolInfo).init(a),
            .children = std.ArrayList(*TranspileProcess).init(a),
            .std_imports = std.ArrayList([]const u8).init(a),
            .input_file_path = input_file_path,
            .stdlib_dir = discovered_stdlib_dir,
        };
    }

    fn build_stdlib_module_path(self: *Self, import_path: []const u8) TranspileError!?[]const u8 {
        if (!std.mem.startsWith(u8, import_path, "std.")) return null;
        if (self.stdlib_dir == null) return null;

        // Canonical layout:
        // - `std.c.io` => <stdlib>/std/c/io.fn
        // Compatibility alias:
        // - `std.io`   => <stdlib>/std/c/io.fn (fallback to <stdlib>/std/io.fn if present)
        const rel_after_std = import_path["std.".len..];
        const has_c_prefix = std.mem.startsWith(u8, rel_after_std, "c.");
        const rel = if (has_c_prefix) rel_after_std["c.".len..] else rel_after_std;

        const StdPathLayout = enum { canonical, legacy };

        const Builder = struct {
            fn build(self2: *Self, rel2: []const u8, layout: StdPathLayout) TranspileError![]const u8 {
                var tmp = std.ArrayList(u8).init(self2.backing_allocator);
                defer tmp.deinit();

                tmp.appendSlice(self2.stdlib_dir.?) catch return TranspileError.MemoryAllocationFailed;
                tmp.append('/') catch return TranspileError.MemoryAllocationFailed;
                tmp.appendSlice("std") catch return TranspileError.MemoryAllocationFailed;
                tmp.append('/') catch return TranspileError.MemoryAllocationFailed;
                if (layout == .canonical) {
                    tmp.appendSlice("c") catch return TranspileError.MemoryAllocationFailed;
                    tmp.append('/') catch return TranspileError.MemoryAllocationFailed;
                }
                for (rel2) |ch| {
                    if (ch == '.') {
                        tmp.append('/') catch return TranspileError.MemoryAllocationFailed;
                    } else {
                        tmp.append(ch) catch return TranspileError.MemoryAllocationFailed;
                    }
                }
                tmp.appendSlice(".fn") catch return TranspileError.MemoryAllocationFailed;
                return tmp.toOwnedSlice() catch TranspileError.MemoryAllocationFailed;
            }
        };

        // Try canonical path first.
        const canonical = try Builder.build(self, rel, .canonical);
        std.fs.cwd().access(canonical, .{}) catch {
            self.backing_allocator.free(canonical);
            if (has_c_prefix) return null;

            // Fallback for older installs that still ship <stdlib>/std/<mod>.fn
            const legacy = try Builder.build(self, rel, .legacy);
            std.fs.cwd().access(legacy, .{}) catch {
                self.backing_allocator.free(legacy);
                return null;
            };
            return legacy;
        };
        return canonical;
    }

    /// Best-effort preload of stdlib signature modules (non-fatal).
    ///
    /// This is for tooling/identifier validation: it allows `imp std.c.*;` (and the `std.*` alias)
    /// source of truth when installed, without changing codegen behavior.
    pub fn preload_std_import_global_symbols(self: *Self, import_node: ast.Node, import_path: []const u8) void {
        if (!self.flags.preload_std_imports) return;
        const full_path_opt = self.build_stdlib_module_path(import_path) catch return;
        if (full_path_opt == null) return;
        const full_path = full_path_opt.?;
        defer self.backing_allocator.free(full_path);

        std.fs.cwd().access(full_path, .{}) catch return;

        var import_proc = TranspileProcess.init_with_stdlib_dir(
            self.backing_allocator,
            full_path,
            "temp.c",
            .{ .exec = false, .outf = false, .ast = false },
            self.stdlib_dir,
        ) catch return;
        defer import_proc.deinit();

        var lex_proc = lexer.LexProcess.init(&import_proc);
        defer lex_proc.deinit();
        lex_proc.lex() catch return;

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
                    // Keep behavior consistent with local preloading.
                    self.report_error(import_node, "Symbol '{s}' already defined in module '{s}'", .{ name, existing.file_path });
                    return;
                }
            }

            const name_copy = self.allocator.dupe(u8, name) catch return;
            errdefer self.allocator.free(name_copy);

            const path_copy = self.allocator.dupe(u8, full_path) catch return;
            errdefer self.allocator.free(path_copy);

            self.global_symbols.put(name_copy, .{
                .symbol_name = name_copy,
                .file_path = path_copy,
                .is_function = true,
            }) catch return;
        }
    }

    pub fn get_warnings(self: *Self) ?[]const u8 {
        if (self.warnings.items.len == 0) return null;
        return self.warnings.items;
    }

    /// Logs an error message with the current position in the token stream.
    ///
    /// This function logs an error message along with the line number, column span.,
    /// and filename where the error occurred.
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `fmt`: The format string for the error message.
    /// - `args`: The arguments for the format string.
    pub fn err(self: *Self, comptime fmt: []const u8, args: anytype) void {
        if (!self.flags.emit_stderr) return;
        const stderr = std.io.getStdErr().writer();
        stderr.print("\n[Error]\n", .{}) catch unreachable;
        // Defensive: if format string expects args but none provided, print fallback
        if (args.len == 0 and std.mem.indexOf(u8, fmt, "{") != null) {
            stderr.print("[INTERNAL ERROR: format string '{s}' called with no arguments]", .{fmt}) catch unreachable;
        } else {
            stderr.print(fmt, args) catch unreachable;
        }

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
        // Do not deinit here. Callers typically `defer tp.deinit()`; implicitly
        // deinitializing inside `err()` causes double-close crashes (especially on Windows).
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
            .Number => blk: {
                if (node.data == null) break :blk .Num;
                break :blk switch (node.data.?) {
                    .dnum => .Dec,
                    else => .Num,
                };
            },
            .String => .Str,
            .Character => .Chr,
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

    const CheckedType = struct {
        base: dtype.DataTypeType,
        is_array: bool = false,
        pointer_depth: usize = 0,
        /// True when this value is the integer literal 0 (C null pointer constant).
        is_null_literal: bool = false,
        /// For user-defined types, `base` is `.Unknown` and `name` holds the identifier.
        name: ?[]const u8 = null,

        fn eql(a: CheckedType, b: CheckedType) bool {
            if (a.base != b.base) return false;
            if (a.is_array != b.is_array) return false;
            if (a.pointer_depth != b.pointer_depth) return false;
            if (a.name == null and b.name == null) return true;
            if (a.name == null or b.name == null) return false;
            return mem.eql(u8, a.name.?, b.name.?);
        }
    };

    const FnSig = struct {
        rtype: CheckedType,
        args: []CheckedType,
        is_variadic: bool = false,
    };

    const TypeEnv = struct {
        allocator: mem.Allocator,
        scopes: std.ArrayList(std.StringHashMap(CheckedType)),

        fn init(allocator: mem.Allocator) TypeEnv {
            return .{
                .allocator = allocator,
                .scopes = std.ArrayList(std.StringHashMap(CheckedType)).init(allocator),
            };
        }

        fn deinit(self: *TypeEnv) void {
            for (self.scopes.items) |*scope_map| {
                scope_map.deinit();
            }
            self.scopes.deinit();
        }

        fn push(self: *TypeEnv) TranspileError!void {
            self.scopes.append(std.StringHashMap(CheckedType).init(self.allocator)) catch {
                return TranspileError.MemoryAllocationFailed;
            };
        }

        fn pop(self: *TypeEnv) void {
            if (self.scopes.pop()) |popped| {
                var last = popped;
                last.deinit();
            }
        }

        fn put_current(self: *TypeEnv, name: []const u8, ty: CheckedType) TranspileError!void {
            if (self.scopes.items.len == 0) return TranspileError.MemoryAllocationFailed;
            var scope_map = &self.scopes.items[self.scopes.items.len - 1];
            scope_map.put(name, ty) catch {
                return TranspileError.MemoryAllocationFailed;
            };
        }

        fn get(self: *TypeEnv, name: []const u8) ?CheckedType {
            var i: usize = self.scopes.items.len;
            while (i > 0) : (i -= 1) {
                if (self.scopes.items[i - 1].get(name)) |t| return t;
            }
            return null;
        }
    };

    fn report_type_error(self: *Self, node: ?ast.Node, comptime fmt: []const u8, args: anytype) void {
        const stderr = std.io.getStdErr().writer();
        stderr.print("\n[TypeError]\n", .{}) catch unreachable;
        if (args.len == 0 and std.mem.indexOf(u8, fmt, "{") != null) {
            stderr.print("[INTERNAL ERROR: format string '{s}' called with no arguments]", .{fmt}) catch unreachable;
        } else {
            stderr.print(fmt, args) catch unreachable;
        }

        if (node) |n| {
            if (n.pos) |p| {
                const end_line = if (p.end_line == 0) p.line else p.end_line;
                if (end_line == p.line) {
                    stderr.print("\nLocation: {s}:{d}:{d}-{d}\n", .{ p.filename, p.line, p.start_col, p.end_col }) catch unreachable;
                } else {
                    stderr.print("\nLocation: {s}:{d}:{d}-{d}:{d}\n", .{ p.filename, p.line, p.start_col, end_line, p.end_col }) catch unreachable;
                }
                return;
            }
        }
        stderr.print("\nLocation: {s}:{d}:{d}\n", .{ self.pos.filename, self.pos.line, self.pos.col }) catch unreachable;
    }

    fn report_warning(self: *Self, node: ?ast.Node, comptime fmt: []const u8, args: anytype) void {
        const stderr = std.io.getStdErr().writer();
        if (self.flags.emit_stderr) {
            stderr.print("\n[Warning]\n", .{}) catch unreachable;
            stderr.print(fmt, args) catch unreachable;
        }

        self.warnings.writer().print("\n[Warning]\n", .{}) catch unreachable;
        self.warnings.writer().print(fmt, args) catch unreachable;

        if (node) |n| {
            if (n.pos) |p| {
                const end_line = if (p.end_line == 0) p.line else p.end_line;
                if (end_line == p.line) {
                    if (self.flags.emit_stderr) stderr.print("\nLocation: {s}:{d}:{d}-{d}\n", .{ p.filename, p.line, p.start_col, p.end_col }) catch unreachable;
                    self.warnings.writer().print("\nLocation: {s}:{d}:{d}-{d}\n", .{ p.filename, p.line, p.start_col, p.end_col }) catch unreachable;
                } else {
                    if (self.flags.emit_stderr) stderr.print("\nLocation: {s}:{d}:{d}-{d}:{d}\n", .{ p.filename, p.line, p.start_col, end_line, p.end_col }) catch unreachable;
                    self.warnings.writer().print("\nLocation: {s}:{d}:{d}-{d}:{d}\n", .{ p.filename, p.line, p.start_col, end_line, p.end_col }) catch unreachable;
                }
                return;
            }
        }

        if (self.flags.emit_stderr) stderr.print("\nLocation: {s}:{d}:{d}\n", .{ self.pos.filename, self.pos.line, self.pos.col }) catch unreachable;
        self.warnings.writer().print("\nLocation: {s}:{d}:{d}\n", .{ self.pos.filename, self.pos.line, self.pos.col }) catch unreachable;
    }

    fn report_error(self: *Self, node: ?ast.Node, comptime fmt: []const u8, args: anytype) void {
        if (!self.flags.emit_stderr) return;
        const stderr = std.io.getStdErr().writer();
        stderr.print("\n[Error]\n", .{}) catch unreachable;
        if (args.len == 0 and std.mem.indexOf(u8, fmt, "{") != null) {
            stderr.print("[INTERNAL ERROR: format string '{s}' called with no arguments]", .{fmt}) catch unreachable;
        } else {
            stderr.print(fmt, args) catch unreachable;
        }

        if (node) |n| {
            if (n.pos) |p| {
                const end_line = if (p.end_line == 0) p.line else p.end_line;
                if (end_line == p.line) {
                    stderr.print("\nLocation: {s}:{d}:{d}-{d}\n", .{ p.filename, p.line, p.start_col, p.end_col }) catch unreachable;
                } else {
                    stderr.print("\nLocation: {s}:{d}:{d}-{d}:{d}\n", .{ p.filename, p.line, p.start_col, end_line, p.end_col }) catch unreachable;
                }
                return;
            }
        }

        stderr.print("\nLocation: {s}:{d}:{d}\n", .{ self.pos.filename, self.pos.line, self.pos.col }) catch unreachable;
    }

    fn type_from_dtype(dt: *const dtype.DataType) CheckedType {
        const base = dt.type orelse .Unknown;
        return .{
            .base = base,
            .is_array = (dt.flags != null and dt.flags.?.is_array),
            .pointer_depth = dt.pointer_depth,
            .name = if (base == .Unknown and dt.type_str.items.len > 0) dt.type_str.items else null,
        };
    }

    fn is_known_type(t: CheckedType) bool {
        return t.base != .Unknown or t.name != null;
    }

    fn is_user_named_type(t: CheckedType) bool {
        return t.base == .Unknown and t.name != null;
    }

    fn lookup_compound_field(self: *Self, compound_name: []const u8, field_name: []const u8) ?*const dtype.DataType {
        const root = self.get_root();
        if (root.type_registry == null) return null;
        const reg = &root.type_registry.?;
        const cnode = reg.compounds_by_name.get(compound_name) orelse return null;
        if (cnode.node_variant == null) return null;
        const fields = cnode.node_variant.?.compound.fields.items();
        for (fields) |f| {
            if (mem.eql(u8, f.name.items, field_name)) return f.dtype;
        }
        return null;
    }

    fn lookup_quirk_method(self: *Self, quirk_name: []const u8, method_name: []const u8) ?ast.QuirkMethodSig {
        const root = self.get_root();
        if (root.type_registry == null) return null;
        const reg = &root.type_registry.?;

        const sig = reg.quirk_sig_by_name.get(quirk_name) orelse return null;
        const qnode = reg.quirks_by_sig.get(sig) orelse return null;
        if (qnode.node_variant == null) return null;
        const methods = qnode.node_variant.?.quirk.methods.items();
        for (methods) |m| {
            if (mem.eql(u8, m.name.items, method_name)) return m;
        }
        return null;
    }

    fn infer_compound_field_access_type(self: *Self, node: ast.Node, base: CheckedType, field_name: []const u8) TranspileError!CheckedType {
        if (!is_user_named_type(base)) {
            self.report_type_error(node, "field access requires a compound-typed value", .{});
            return TranspileError.TypeMismatch;
        }

        if (base.pointer_depth > 1) {
            self.report_type_error(node, "field access supports at most one pointer indirection", .{});
            return TranspileError.TypeMismatch;
        }

        const fdt = self.lookup_compound_field(base.name.?, field_name) orelse {
            self.report_type_error(node, "type '{s}' has no field '{s}'", .{ base.name.?, field_name });
            return TranspileError.TypeMismatch;
        };
        return type_from_dtype(fdt);
    }

    fn lookup_plain_impl_method_fn_proc(self: *Self, proc: *Self, type_name: []const u8, method_name: []const u8) ?[]const u8 {
        for (proc.owned_nodes.items) |n| {
            if (n.type != .Impl or n.node_variant == null) continue;
            const im = n.node_variant.?.impl;
            if (im.quirk_name != null) continue; // only plain impl
            if (!mem.eql(u8, im.type_name.items, type_name)) continue;

            for (im.methods.items()) |m| {
                if (m.type != .Function or m.node_variant == null) continue;
                const fnv = m.node_variant.?.function;
                if (fnv.name == null) continue;
                const full = fnv.name.?.items;
                // Expected: `<Type>__<method>`
                if (!mem.startsWith(u8, full, type_name)) continue;
                const need_len = type_name.len + 2 + method_name.len;
                if (full.len != need_len) continue;
                if (!mem.eql(u8, full[type_name.len .. type_name.len + 2], "__")) continue;
                if (!mem.eql(u8, full[type_name.len + 2 ..], method_name)) continue;
                return full;
            }
        }

        for (proc.children.items) |child| {
            if (self.lookup_plain_impl_method_fn_proc(child, type_name, method_name)) |n| return n;
        }
        return null;
    }

    fn lookup_plain_impl_method_fn(self: *Self, type_name: []const u8, method_name: []const u8) ?[]const u8 {
        const root = self.get_root();
        return self.lookup_plain_impl_method_fn_proc(root, type_name, method_name);
    }

    fn lookup_quirk_impl_method_fn_for_self(self: *Self, type_name: []const u8, method_name: []const u8) ?[]const u8 {
        const root = self.get_root();
        if (root.type_registry == null) return null;
        const reg = &root.type_registry.?;

        var it = reg.impls_by_key.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (!mem.eql(u8, key.type_name, type_name)) continue;

            // Only consider quirk impls.
            const impl_node = entry.value_ptr.*;
            if (impl_node.node_variant == null) continue;
            const im = impl_node.node_variant.?.impl;
            if (im.quirk_name == null) continue;

            // Ensure the quirk signature actually contains this method name.
            const qnode = reg.quirks_by_sig.get(key.quirk_sig) orelse continue;
            if (qnode.node_variant == null) continue;
            const q = qnode.node_variant.?.quirk;
            var has_method = false;
            for (q.methods.items()) |qm| {
                if (mem.eql(u8, qm.name.items, method_name)) {
                    has_method = true;
                    break;
                }
            }
            if (!has_method) continue;

            // Find the generated method function name by suffix match.
            var suf_buf: [128]u8 = undefined;
            const suf = (std.fmt.bufPrint(&suf_buf, "__{s}", .{method_name}) catch unreachable);
            for (im.methods.items()) |m| {
                if (m.type != .Function or m.node_variant == null) continue;
                const fnv = m.node_variant.?.function;
                if (fnv.name == null) continue;
                const full = fnv.name.?.items;
                if (mem.endsWith(u8, full, suf)) return full;
            }
        }
        return null;
    }

    const QuirkImplMethodResolution = struct {
        fn_name: ?[]const u8 = null,
        quirk_name: ?[]const u8 = null,
        ambiguous: bool = false,
        other_quirk_name: ?[]const u8 = null,
    };

    fn resolve_quirk_impl_method_for_concrete(self: *Self, type_name: []const u8, method_name: []const u8) QuirkImplMethodResolution {
        const root = self.get_root();
        if (root.type_registry == null) return .{};
        const reg = &root.type_registry.?;

        var res: QuirkImplMethodResolution = .{};
        var it = reg.impls_by_key.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (!mem.eql(u8, key.type_name, type_name)) continue;

            const impl_node = entry.value_ptr.*;
            if (impl_node.node_variant == null) continue;
            const im = impl_node.node_variant.?.impl;
            if (im.quirk_name == null) continue;

            const qnode = reg.quirks_by_sig.get(key.quirk_sig) orelse continue;
            if (qnode.node_variant == null) continue;
            const q = qnode.node_variant.?.quirk;
            const qname = q.name.items;

            var has_method = false;
            for (q.methods.items()) |qm| {
                if (mem.eql(u8, qm.name.items, method_name)) {
                    has_method = true;
                    break;
                }
            }
            if (!has_method) continue;

            var suf_buf: [128]u8 = undefined;
            const suf = (std.fmt.bufPrint(&suf_buf, "__{s}", .{method_name}) catch unreachable);

            var fn_name: ?[]const u8 = null;
            for (im.methods.items()) |m| {
                if (m.type != .Function or m.node_variant == null) continue;
                const fnv = m.node_variant.?.function;
                if (fnv.name == null) continue;
                const full = fnv.name.?.items;
                if (mem.endsWith(u8, full, suf)) {
                    fn_name = full;
                    break;
                }
            }
            if (fn_name == null) continue;

            if (res.fn_name == null) {
                res.fn_name = fn_name;
                res.quirk_name = qname;
            } else {
                // Multiple quirks implemented by this type share the same method name.
                res.ambiguous = true;
                res.other_quirk_name = qname;
                return res;
            }
        }
        return res;
    }

    fn is_numeric_type(t: CheckedType) bool {
        return !t.is_array and t.pointer_depth == 0 and (t.base == .Num or t.base == .Dec);
    }

    fn is_pointer_type(t: CheckedType) bool {
        return !t.is_array and t.pointer_depth > 0;
    }

    fn promote_numeric_type(a: CheckedType, b: CheckedType) dtype.DataTypeType {
        // Assumes `is_numeric_type(a)` and `is_numeric_type(b)`.
        if (a.base == .Dec or b.base == .Dec) return .Dec;
        return .Num;
    }

    fn is_quirk_named_type(self: *Self, t: CheckedType) bool {
        if (!is_user_named_type(t)) return false;
        const root = self.get_root();
        if (root.type_registry == null) return false;
        return root.type_registry.?.quirk_sig_by_name.contains(t.name.?);
    }

    fn can_implicit_coerce(self: *Self, expected: CheckedType, actual: CheckedType) TranspileError!bool {
        if (CheckedType.eql(expected, actual)) return true;

        // Quirk coercion: allow `T*` -> `Quirk` if an `impl T Quirk { ... }` exists.
        if (self.is_quirk_named_type(expected) and is_user_named_type(actual) and actual.pointer_depth == 1 and !actual.is_array) {
            const root = self.get_root();
            if (root.type_registry == null) return false;
            const reg = &root.type_registry.?;
            const sig = reg.quirk_sig_by_name.get(expected.name.?) orelse return false;
            if (reg.impls_by_key.contains(.{ .type_name = actual.name.?, .quirk_sig = sig })) return true;
        }

        // C-style null pointer constant: allow `0` to convert to any pointer type.
        if (!expected.is_array and expected.pointer_depth > 0 and !actual.is_array and actual.pointer_depth == 0 and actual.is_null_literal) {
            return true;
        }

        // Treat `str` as a nullable reference type: allow `0` to convert to `str`.
        if (!expected.is_array and expected.pointer_depth == 0 and expected.base == .Str and !actual.is_array and actual.pointer_depth == 0 and actual.is_null_literal) {
            return true;
        }

        if (expected.is_array != actual.is_array or expected.pointer_depth != actual.pointer_depth) return false;

        // `raw*` behaves like C `void*`: allow implicit conversion to/from any object pointer.
        if (!expected.is_array and expected.pointer_depth > 0 and actual.pointer_depth > 0) {
            if (expected.base == .Raw or actual.base == .Raw) return true;
        }

        // Allow widening conversions.
        if (expected.base == .Dec and actual.base == .Num and !expected.is_array and expected.pointer_depth == 0) return true;
        return false;
    }

    fn can_compare_or_match(a: CheckedType, b: CheckedType) bool {
        if (CheckedType.eql(a, b)) return true;

        // Numeric comparisons/coercion.
        if (is_numeric_type(a) and is_numeric_type(b)) return true;

        // C-style null pointer constant comparisons: allow `ptr == 0` / `ptr != 0`.
        if (is_pointer_type(a) and !b.is_array and b.pointer_depth == 0 and b.is_null_literal) return true;
        if (is_pointer_type(b) and !a.is_array and a.pointer_depth == 0 and a.is_null_literal) return true;

        // Also allow `str` to compare against null constant: `s == 0` / `s != 0`.
        if (!a.is_array and a.pointer_depth == 0 and a.base == .Str and !b.is_array and b.pointer_depth == 0 and b.is_null_literal) return true;
        if (!b.is_array and b.pointer_depth == 0 and b.base == .Str and !a.is_array and a.pointer_depth == 0 and a.is_null_literal) return true;

        // `raw*` behaves like `void*`: allow equality comparisons to other pointers.
        if (is_pointer_type(a) and is_pointer_type(b) and (a.base == .Raw or b.base == .Raw)) return true;

        return false;
    }

    fn flatten_call_args(self: *Self, node: ast.Node, out: *std.ArrayList(ast.Node)) TranspileError!void {
        // Function call arguments are parsed as a parenthesis node that wraps an expression.
        // For zero-arg calls this inner expression is `.Blank`.
        if (node.type == .ExpressionParenthesis and node.node_variant != null) {
            const inner = node.node_variant.?.paren.exp.*;
            if (inner.type == .Blank) return;
            return try self.flatten_call_args(inner, out);
        }

        // A `.Blank` node represents an empty argument list.
        if (node.type == .Blank) return;

        if (node.type == .Expression and node.node_variant != null and mem.eql(u8, node.node_variant.?.exp.op, ",")) {
            const exp = node.node_variant.?.exp;
            if (exp.left) |left| try self.flatten_call_args(left.*, out);
            if (exp.right) |right| try self.flatten_call_args(right.*, out);
            return;
        }
        out.append(node) catch {
            return TranspileError.MemoryAllocationFailed;
        };
    }

    fn infer_expr_type(self: *Self, node: ast.Node, env: *TypeEnv, fns: *const std.StringHashMap(FnSig)) TranspileError!CheckedType {
        switch (node.type) {
            .Bracket => {
                // Array literal: `[a, b, c]`. The parser stores elements under `bracket.inner`.
                const inner = node.node_variant.?.bracket.inner.*;

                var elems = std.ArrayList(ast.Node).init(self.allocator);
                defer elems.deinit();
                try self.flatten_call_args(inner, &elems);

                var elem_type: ?CheckedType = null;
                for (elems.items) |elem_node| {
                    const t = try self.infer_expr_type(elem_node, env, fns);
                    if (elem_type == null) {
                        elem_type = t;
                        continue;
                    }
                    if (!CheckedType.eql(t, elem_type.?)) {
                        self.report_type_error(node, "array literal elements must share a type", .{});
                        return TranspileError.TypeMismatch;
                    }
                }

                return .{
                    .base = if (elem_type) |et| et.base else .Unknown,
                    .is_array = true,
                    .pointer_depth = 0,
                };
            },
            .Number => {
                if (node.data) |d| {
                    return switch (d) {
                        .dnum => .{ .base = .Dec },
                        .llnum => |n| .{ .base = .Num, .is_null_literal = (n == 0) },
                        else => .{ .base = .Num },
                    };
                }
                return .{ .base = .Num };
            },
            .String => return .{ .base = .Str },
            .Boolean => return .{ .base = .Bin },
            .Character => return .{ .base = .Chr },
            .Identifier => {
                if (node.data == null) return .{ .base = .Unknown };
                const name = node.data.?.sval.items;
                if (env.get(name)) |t| return t;
                // If it's a known function name used as a value, it's not a first-class function.
                if (fns.get(name) != null) {
                    self.report_type_error(node, "function '{s}' is not a value", .{name});
                    return TranspileError.NotCallable;
                }

                // Best-effort typing for common C macro constants.
                // - `NULL` behaves like a C null pointer constant.
                // - Common numeric macros (limits/stdio/stdlib/time) behave like integers.
                if (mem.eql(u8, name, "NULL")) {
                    return .{ .base = .Num, .is_null_literal = true };
                }
                if (mem.eql(u8, name, "EOF") or
                    mem.eql(u8, name, "EXIT_SUCCESS") or mem.eql(u8, name, "EXIT_FAILURE") or
                    mem.eql(u8, name, "SEEK_SET") or mem.eql(u8, name, "SEEK_CUR") or mem.eql(u8, name, "SEEK_END") or
                    mem.eql(u8, name, "INT_MAX") or mem.eql(u8, name, "INT_MIN") or
                    mem.eql(u8, name, "UINT_MAX") or
                    mem.eql(u8, name, "LONG_MAX") or mem.eql(u8, name, "LONG_MIN") or
                    mem.eql(u8, name, "ULONG_MAX") or
                    mem.eql(u8, name, "LLONG_MAX") or mem.eql(u8, name, "LLONG_MIN") or
                    mem.eql(u8, name, "ULLONG_MAX") or
                    mem.eql(u8, name, "CLOCKS_PER_SEC"))
                {
                    return .{ .base = .Num };
                }

                return .{ .base = .Unknown };
            },
            .ExpressionParenthesis => {
                return try self.infer_expr_type(node.node_variant.?.paren.exp.*, env, fns);
            },
            .Unary => {
                const u = node.node_variant.?.unary;
                const operand_t = try self.infer_expr_type(u.operand.*, env, fns);

                // Indirection unary: `*x`, `**x`, ...
                if (u.indirection) |ind| {
                    if (operand_t.pointer_depth < ind.depth) {
                        self.report_type_error(node, "cannot dereference a non-pointer", .{});
                        return TranspileError.TypeMismatch;
                    }
                    var out = operand_t;
                    out.pointer_depth -= ind.depth;
                    return out;
                }

                // Address-of: `&x`
                if (mem.eql(u8, u.op, "&")) {
                    var out = operand_t;
                    out.pointer_depth += 1;
                    return out;
                }

                if (mem.eql(u8, u.op, "!")) {
                    if (operand_t.base != .Bin) {
                        self.report_type_error(node, "unary '!' expects bin operand", .{});
                        return TranspileError.TypeMismatch;
                    }
                    return .{ .base = .Bin };
                }
                if (mem.eql(u8, u.op, "-") or mem.eql(u8, u.op, "+")) {
                    if (operand_t.base != .Num and operand_t.base != .Dec) {
                        self.report_type_error(node, "unary '{s}' expects num/dec operand", .{u.op});
                        return TranspileError.TypeMismatch;
                    }
                    return .{ .base = operand_t.base };
                }
                if (mem.eql(u8, u.op, "++") or mem.eql(u8, u.op, "--")) {
                    if (operand_t.base != .Num and operand_t.base != .Dec) {
                        self.report_type_error(node, "unary '{s}' expects num/dec operand", .{u.op});
                        return TranspileError.TypeMismatch;
                    }
                    return .{ .base = operand_t.base };
                }
                return operand_t;
            },
            .Tenary => {
                const t = node.node_variant.?.tenary;
                const cond_t = try self.infer_expr_type(t.condition.*, env, fns);
                if (cond_t.base != .Bin) {
                    self.report_type_error(node, "tenary condition must be bin", .{});
                    return TranspileError.InvalidConditionType;
                }
                const a = try self.infer_expr_type(t.true.*, env, fns);
                const b = try self.infer_expr_type(t.false.*, env, fns);
                if (CheckedType.eql(a, b)) return a;
                if (is_numeric_type(a) and is_numeric_type(b)) {
                    return .{ .base = promote_numeric_type(a, b) };
                }
                self.report_type_error(node, "tenary branches must have the same type", .{});
                return TranspileError.TypeMismatch;
            },
            .Expression => {
                const exp = node.node_variant.?.exp;
                const op = exp.op;

                if (mem.eql(u8, op, "()")) {
                    const callee = exp.left orelse {
                        self.report_type_error(node, "invalid call expression", .{});
                        return TranspileError.NotCallable;
                    };

                    // Standard function call: `foo(...)`.
                    var maybe_sig: ?FnSig = null;
                    var call_rtype: CheckedType = .{ .base = .Unknown };
                    var method_sig: ?ast.QuirkMethodSig = null;
                    var plain_method_sig: ?FnSig = null;
                    var plain_method_name: ?[]const u8 = null;

                    if (callee.type == .Identifier and callee.data != null) {
                        const fname = callee.data.?.sval.items;
                        if (fns.get(fname)) |sig| {
                            maybe_sig = sig;
                            call_rtype = sig.rtype;
                        } else {
                            // If the name is known from preloaded imports/stdlib signatures, treat it
                            // as an external function and skip type checking.
                            // Otherwise, this is a real semantic error (we don't want to defer to C).
                            if (self.global_symbols.get(fname) != null or is_known_extern_function_name(fname)) {
                                return .{ .base = .Unknown };
                            }

                            self.report_type_error(node, "unknown function '{s}'", .{fname});
                            return TranspileError.SymbolNotDefined;
                        }
                    } else if (callee.type == .Expression and callee.node_variant != null and mem.eql(u8, callee.node_variant.?.exp.op, ".")) {
                        // Method call: `x.method(...)`.
                        const dot = callee.node_variant.?.exp;
                        const recv = dot.left orelse {
                            self.report_type_error(node, "invalid method call", .{});
                            return TranspileError.NotCallable;
                        };
                        const member = dot.right orelse {
                            self.report_type_error(node, "invalid method call", .{});
                            return TranspileError.NotCallable;
                        };
                        if (member.type != .Identifier or member.data == null) {
                            self.report_type_error(node, "invalid method call", .{});
                            return TranspileError.NotCallable;
                        }

                        const recv_t = try self.infer_expr_type(recv.*, env, fns);
                        const mname = member.data.?.sval.items;
                        if (!is_user_named_type(recv_t)) {
                            self.report_type_error(node, "method calls require a named receiver", .{});
                            return TranspileError.NotCallable;
                        }

                        // If the receiver is a quirk type, typecheck against the quirk signature.
                        // Otherwise, treat as a plain impl method call and typecheck against the
                        // generated `Type__method` function signature.
                        const reg = self.root_registry();
                        const recv_is_quirk = if (reg) |r| r.quirk_sig_by_name.contains(recv_t.name.?) else false;

                        if (recv_is_quirk) {
                            method_sig = self.lookup_quirk_method(recv_t.name.?, mname) orelse {
                                self.report_type_error(node, "quirk '{s}' has no method '{s}'", .{ recv_t.name.?, mname });
                                return TranspileError.NotCallable;
                            };
                            call_rtype = type_from_dtype(&method_sig.?.rtype);
                        } else {
                            if (recv_t.pointer_depth > 1) {
                                self.report_type_error(node, "method calls support at most one pointer indirection", .{});
                                return TranspileError.NotCallable;
                            }

                            var buf: [256]u8 = undefined;
                            const gen_name = std.fmt.bufPrint(&buf, "{s}__{s}", .{ recv_t.name.?, mname }) catch unreachable;

                            if (fns.get(gen_name)) |sig| {
                                plain_method_sig = sig;
                                plain_method_name = mname;
                                call_rtype = sig.rtype;
                            } else {
                                // Also allow calling quirk-impl methods directly on concrete types.
                                // If the type implements exactly one quirk that defines this method name,
                                // lower/typecheck as a direct call to the generated impl function.
                                const qres = self.resolve_quirk_impl_method_for_concrete(recv_t.name.?, mname);
                                if (qres.ambiguous) {
                                    self.report_type_error(node, "type '{s}' method '{s}' is ambiguous (quirks: '{s}', '{s}')", .{ recv_t.name.?, mname, qres.quirk_name orelse "<unknown>", qres.other_quirk_name orelse "<unknown>" });
                                    return TranspileError.NotCallable;
                                }
                                if (qres.fn_name) |qfn| {
                                    plain_method_sig = fns.get(qfn) orelse {
                                        self.report_type_error(node, "type '{s}' has no method '{s}'", .{ recv_t.name.?, mname });
                                        return TranspileError.NotCallable;
                                    };
                                    plain_method_name = mname;
                                    call_rtype = plain_method_sig.?.rtype;
                                } else {
                                    self.report_type_error(node, "type '{s}' has no method '{s}'", .{ recv_t.name.?, mname });
                                    return TranspileError.NotCallable;
                                }
                            }
                        }
                    } else {
                        self.report_type_error(node, "only calling named functions or quirk methods is supported", .{});
                        return TranspileError.NotCallable;
                    }

                    var args_nodes = std.ArrayList(ast.Node).init(self.allocator);
                    defer args_nodes.deinit();
                    if (exp.right) |right| {
                        try self.flatten_call_args(right.*, &args_nodes);
                    }

                    if (maybe_sig) |sig| {
                        // Function call.
                        if (!sig.is_variadic and args_nodes.items.len != sig.args.len) {
                            const fname = callee.data.?.sval.items;
                            self.report_type_error(node, "function '{s}' expects {d} args, got {d}", .{ fname, sig.args.len, args_nodes.items.len });
                            return TranspileError.WrongArgCount;
                        }
                        if (sig.is_variadic and args_nodes.items.len < sig.args.len) {
                            const fname = callee.data.?.sval.items;
                            self.report_type_error(node, "function '{s}' expects at least {d} args, got {d}", .{ fname, sig.args.len, args_nodes.items.len });
                            return TranspileError.WrongArgCount;
                        }
                        for (args_nodes.items, 0..) |arg_node, idx| {
                            if (idx >= sig.args.len) break; // variadic extras are not typechecked
                            const actual = try self.infer_expr_type(arg_node, env, fns);
                            const expected = sig.args[idx];
                            if (is_known_type(expected) and is_known_type(actual) and !(try self.can_implicit_coerce(expected, actual))) {
                                const fname = callee.data.?.sval.items;
                                self.report_type_error(node, "type mismatch in call to '{s}' argument {d}", .{ fname, idx + 1 });
                                return TranspileError.TypeMismatch;
                            }
                        }
                    } else if (method_sig) |msig| {
                        // Quirk method call.
                        const expected_args = msig.args.items();
                        if (args_nodes.items.len != expected_args.len) {
                            self.report_type_error(node, "method '{s}' expects {d} args, got {d}", .{ msig.name.items, expected_args.len, args_nodes.items.len });
                            return TranspileError.WrongArgCount;
                        }
                        for (args_nodes.items, 0..) |arg_node, idx| {
                            const actual = try self.infer_expr_type(arg_node, env, fns);
                            const expected = type_from_dtype(expected_args[idx].dtype);
                            if (is_known_type(expected) and is_known_type(actual) and !(try self.can_implicit_coerce(expected, actual))) {
                                self.report_type_error(node, "type mismatch in call to method '{s}' argument {d}", .{ msig.name.items, idx + 1 });
                                return TranspileError.TypeMismatch;
                            }
                        }
                    } else if (plain_method_sig) |psig| {
                        // Plain impl method call. The generated function signature includes the
                        // implicit `self` parameter as the first argument.
                        if (!psig.is_variadic and psig.args.len == 0) {
                            self.report_type_error(node, "invalid method signature", .{});
                            return TranspileError.NotCallable;
                        }

                        const expected_user_args = if (psig.args.len > 0) psig.args.len - 1 else 0;
                        if (!psig.is_variadic and args_nodes.items.len != expected_user_args) {
                            self.report_type_error(node, "method '{s}' expects {d} args, got {d}", .{ plain_method_name orelse "<method>", expected_user_args, args_nodes.items.len });
                            return TranspileError.WrongArgCount;
                        }
                        if (psig.is_variadic and args_nodes.items.len < expected_user_args) {
                            self.report_type_error(node, "method '{s}' expects at least {d} args, got {d}", .{ plain_method_name orelse "<method>", expected_user_args, args_nodes.items.len });
                            return TranspileError.WrongArgCount;
                        }

                        for (args_nodes.items, 0..) |arg_node, idx| {
                            const sig_idx = idx + 1; // skip implicit self
                            if (sig_idx >= psig.args.len) break; // variadic extras are not typechecked
                            const actual = try self.infer_expr_type(arg_node, env, fns);
                            const expected = psig.args[sig_idx];
                            if (is_known_type(expected) and is_known_type(actual) and !(try self.can_implicit_coerce(expected, actual))) {
                                self.report_type_error(node, "type mismatch in call to method '{s}' argument {d}", .{ plain_method_name orelse "<method>", idx + 1 });
                                return TranspileError.TypeMismatch;
                            }
                        }
                    }

                    return call_rtype;
                }

                if (mem.eql(u8, op, ".")) {
                    const left = exp.left orelse return .{ .base = .Unknown };
                    const right = exp.right orelse return .{ .base = .Unknown };

                    var lt = try self.infer_expr_type(left.*, env, fns);

                    // The parser can encode chained field access right-associatively:
                    // `rect.a.x` -> `rect . (a . x)`.
                    // Support both `left . Identifier` and `left . (a . b . c)` forms.
                    if (right.type == .Identifier and right.data != null) {
                        return try self.infer_compound_field_access_type(node, lt, right.data.?.sval.items);
                    }

                    if (right.type == .Expression and right.node_variant != null and mem.eql(u8, right.node_variant.?.exp.op, ".")) {
                        var cursor: ast.Node = right.*;
                        while (true) {
                            if (cursor.type == .Expression and cursor.node_variant != null and mem.eql(u8, cursor.node_variant.?.exp.op, ".")) {
                                const dot = cursor.node_variant.?.exp;
                                const seg = dot.left orelse {
                                    self.report_type_error(node, "field access requires an identifier", .{});
                                    return TranspileError.TypeMismatch;
                                };
                                if (seg.type != .Identifier or seg.data == null) {
                                    self.report_type_error(node, "field access requires an identifier", .{});
                                    return TranspileError.TypeMismatch;
                                }
                                lt = try self.infer_compound_field_access_type(node, lt, seg.data.?.sval.items);

                                const next = dot.right orelse {
                                    self.report_type_error(node, "field access requires an identifier", .{});
                                    return TranspileError.TypeMismatch;
                                };
                                cursor = next.*;
                                continue;
                            }

                            if (cursor.type == .Identifier and cursor.data != null) {
                                lt = try self.infer_compound_field_access_type(node, lt, cursor.data.?.sval.items);
                                return lt;
                            }

                            self.report_type_error(node, "field access requires an identifier", .{});
                            return TranspileError.TypeMismatch;
                        }
                    }

                    self.report_type_error(node, "field access requires an identifier", .{});
                    return TranspileError.TypeMismatch;
                }

                if (mem.eql(u8, op, ",")) {
                    // Comma expression type is the RHS type.
                    if (exp.right) |right| return try self.infer_expr_type(right.*, env, fns);
                    if (exp.left) |left| return try self.infer_expr_type(left.*, env, fns);
                    return .{ .base = .Unknown };
                }

                if (mem.eql(u8, op, "[]")) {
                    const left = exp.left orelse return .{ .base = .Unknown };
                    const right = exp.right orelse return .{ .base = .Unknown };
                    const lt = try self.infer_expr_type(left.*, env, fns);
                    const rt = try self.infer_expr_type(right.*, env, fns);
                    if (!lt.is_array) {
                        self.report_type_error(node, "indexing requires an array", .{});
                        return TranspileError.IndexNonArray;
                    }
                    if (rt.base != .Num) {
                        self.report_type_error(node, "array index must be num", .{});
                        return TranspileError.TypeMismatch;
                    }
                    return .{ .base = lt.base, .is_array = false, .pointer_depth = lt.pointer_depth };
                }

                const is_assign = mem.eql(u8, op, "=") or
                    mem.eql(u8, op, "+=") or mem.eql(u8, op, "-=") or mem.eql(u8, op, "*=") or mem.eql(u8, op, "/=") or
                    mem.eql(u8, op, "<<=") or mem.eql(u8, op, ">>=");

                if (is_assign) {
                    const left = exp.left orelse return .{ .base = .Unknown };
                    const right = exp.right orelse return .{ .base = .Unknown };
                    const lt = try self.infer_expr_type(left.*, env, fns);
                    const rt = try self.infer_expr_type(right.*, env, fns);

                    // For compound assignments, require numeric types.
                    if (!mem.eql(u8, op, "=")) {
                        if (mem.eql(u8, op, "<<=") or mem.eql(u8, op, ">>=")) {
                            if (lt.base != .Num or rt.base != .Num) {
                                self.report_type_error(node, "compound assignment '{s}' expects num", .{op});
                                return TranspileError.TypeMismatch;
                            }
                            return .{ .base = .Num };
                        }

                        if (!is_numeric_type(lt) or !is_numeric_type(rt)) {
                            self.report_type_error(node, "compound assignment '{s}' expects num/dec", .{op});
                            return TranspileError.TypeMismatch;
                        }
                        const res_base = promote_numeric_type(lt, rt);
                        if (res_base != lt.base) {
                            self.report_type_error(node, "compound assignment '{s}' would change the variable type", .{op});
                            return TranspileError.TypeMismatch;
                        }
                        return lt;
                    }

                    if (is_known_type(lt) and is_known_type(rt) and !(try self.can_implicit_coerce(lt, rt))) {
                        self.report_type_error(node, "type mismatch in assignment", .{});
                        return TranspileError.TypeMismatch;
                    }
                    return lt;
                }

                const l: CheckedType = if (exp.left) |left| try self.infer_expr_type(left.*, env, fns) else CheckedType{ .base = .Unknown };
                const r: CheckedType = if (exp.right) |right| try self.infer_expr_type(right.*, env, fns) else CheckedType{ .base = .Unknown };

                if (mem.eql(u8, op, "+") or mem.eql(u8, op, "-") or mem.eql(u8, op, "*") or mem.eql(u8, op, "/") or mem.eql(u8, op, "%")) {
                    if (mem.eql(u8, op, "%")) {
                        if (l.base != .Num or r.base != .Num) {
                            self.report_type_error(node, "operator '{s}' expects num operands", .{op});
                            return TranspileError.TypeMismatch;
                        }
                        return .{ .base = .Num };
                    }

                    if (!is_numeric_type(l) or !is_numeric_type(r)) {
                        self.report_type_error(node, "operator '{s}' expects num/dec operands", .{op});
                        return TranspileError.TypeMismatch;
                    }
                    return .{ .base = promote_numeric_type(l, r) };
                }

                if (mem.eql(u8, op, "<") or mem.eql(u8, op, "<=") or mem.eql(u8, op, ">") or mem.eql(u8, op, ">=")) {
                    if (!is_numeric_type(l) or !is_numeric_type(r)) {
                        self.report_type_error(node, "comparison '{s}' expects num/dec operands", .{op});
                        return TranspileError.TypeMismatch;
                    }
                    return .{ .base = .Bin };
                }

                if (mem.eql(u8, op, "==") or mem.eql(u8, op, "!=")) {
                    if (is_known_type(l) and is_known_type(r) and !can_compare_or_match(l, r)) {
                        self.report_type_error(node, "equality '{s}' expects both sides to have the same type", .{op});
                        return TranspileError.TypeMismatch;
                    }
                    return .{ .base = .Bin };
                }

                if (mem.eql(u8, op, "&&") or mem.eql(u8, op, "||")) {
                    if (l.base != .Bin or r.base != .Bin) {
                        self.report_type_error(node, "logical '{s}' expects bin operands", .{op});
                        return TranspileError.TypeMismatch;
                    }
                    return .{ .base = .Bin };
                }

                if (mem.eql(u8, op, "..")) {
                    if (l.base != .Num or r.base != .Num) {
                        self.report_type_error(node, "range '..' expects num endpoints", .{});
                        return TranspileError.TypeMismatch;
                    }
                    return .{ .base = .Unknown };
                }

                return l;
            },
            else => return .{ .base = .Unknown },
        }
    }

    fn check_body(self: *Self, body: *ast.Node, env: *TypeEnv, fns: *const std.StringHashMap(FnSig), fn_rtype: CheckedType) TranspileError!void {
        if (body.type != .Body) return;

        try env.push();
        defer env.pop();

        const stmts = body.node_variant.?.body.statements;
        for (stmts.items()) |stmt_ptr| {
            const stmt = stmt_ptr.*;
            switch (stmt.type) {
                .Variable => {
                    const v = stmt.node_variant.?.variable;
                    const name = v.name.items;
                    const vtype = type_from_dtype(v.type);
                    try env.put_current(name, vtype);
                    if (v.val) |val| {
                        const init_t = try self.infer_expr_type(val.*, env, fns);
                        if (is_known_type(vtype) and is_known_type(init_t) and !(try self.can_implicit_coerce(vtype, init_t))) {
                            self.report_type_error(stmt, "type mismatch in initialization of '{s}'", .{name});
                            return TranspileError.TypeMismatch;
                        }
                    }
                },
                .StatementReturn => {
                    const has_expr = stmt.node_variant != null;
                    if (fn_rtype.base == .Void) {
                        if (has_expr) {
                            self.report_type_error(stmt, "void function cannot return a value", .{});
                            return TranspileError.ReturnTypeMismatch;
                        }
                    } else {
                        if (!has_expr) {
                            self.report_type_error(stmt, "non-void function must return a value", .{});
                            return TranspileError.ReturnTypeMismatch;
                        }
                        const rv = stmt.node_variant.?.statement.return_stmt;
                        const rt = try self.infer_expr_type(rv.*, env, fns);
                        if (is_known_type(fn_rtype) and is_known_type(rt) and !(try self.can_implicit_coerce(fn_rtype, rt))) {
                            self.report_type_error(stmt, "return type mismatch", .{});
                            return TranspileError.ReturnTypeMismatch;
                        }
                    }
                },
                .StatementIf => {
                    const ifs = stmt.node_variant.?.statement.if_stmt;
                    const ct = try self.infer_expr_type(ifs.condition.*, env, fns);
                    if (ct.base != .Bin) {
                        self.report_type_error(stmt, "if condition must be bin", .{});
                        return TranspileError.InvalidConditionType;
                    }
                    try self.check_body(ifs.body, env, fns, fn_rtype);
                },
                .StatementElseIf => {
                    const elif = stmt.node_variant.?.statement.elif_stmt;
                    const ct = try self.infer_expr_type(elif.condition.*, env, fns);
                    if (ct.base != .Bin) {
                        self.report_type_error(stmt, "elif condition must be bin", .{});
                        return TranspileError.InvalidConditionType;
                    }
                    try self.check_body(elif.body, env, fns, fn_rtype);
                },
                .StatementElse => {
                    const els = stmt.node_variant.?.statement.else_stmt;
                    try self.check_body(els.body, env, fns, fn_rtype);
                },
                .StatementFit => {
                    const fit = stmt.node_variant.?.statement.fit_stmt;
                    const target_t = try self.infer_expr_type(fit.exp.*, env, fns);
                    for (fit.branches.items()) |branch| {
                        if (branch.condition) |cond| {
                            const ct = try self.infer_expr_type(cond.*, env, fns);
                            if (is_known_type(target_t) and is_known_type(ct) and !can_compare_or_match(target_t, ct)) {
                                self.report_type_error(stmt, "fit branch condition type must match fit expression type", .{});
                                return TranspileError.TypeMismatch;
                            }
                        }
                        try self.check_body(branch.body, env, fns, fn_rtype);
                    }
                },
                .StatementFor => {
                    const f = stmt.node_variant.?.statement.for_stmt;
                    switch (f) {
                        .cond => |fc| {
                            if (fc.condition) |cond| {
                                const ct = try self.infer_expr_type(cond.*, env, fns);
                                if (ct.base != .Bin) {
                                    self.report_type_error(stmt, "for condition must be bin", .{});
                                    return TranspileError.InvalidConditionType;
                                }
                            }
                            try env.push();
                            defer env.pop();
                            try self.check_body(fc.body, env, fns, fn_rtype);
                        },
                        .range => |fr| {
                            // for i : start..end { ... }
                            const range_node = fr.range.*;
                            if (range_node.type != .Expression or !mem.eql(u8, range_node.node_variant.?.exp.op, "..")) {
                                self.report_type_error(stmt, "for-range expects '..'", .{});
                                return TranspileError.TypeMismatch;
                            }
                            _ = try self.infer_expr_type(range_node, env, fns);
                            try env.push();
                            defer env.pop();
                            try env.put_current(fr.index_name, .{ .base = .Num });
                            try self.check_body(fr.body, env, fns, fn_rtype);
                        },
                        .iter => |fi| {
                            const it_t = try self.infer_expr_type(fi.iterable.*, env, fns);
                            if (!it_t.is_array) {
                                self.report_type_error(stmt, "for-iter expects array iterable", .{});
                                return TranspileError.TypeMismatch;
                            }
                            try env.push();
                            defer env.pop();
                            if (fi.index_name) |iname| try env.put_current(iname, .{ .base = .Num });
                            try env.put_current(fi.item_name, .{ .base = it_t.base });
                            try self.check_body(fi.body, env, fns, fn_rtype);
                        },
                    }
                },
                .Body => {
                    try self.check_body(stmt_ptr, env, fns, fn_rtype);
                },
                else => {
                    // Expression statements, break/continue, etc.
                    _ = try self.infer_expr_type(stmt, env, fns);
                },
            }
        }
    }

    fn collect_fn_sigs(self: *Self, proc: *Self, fns: *std.StringHashMap(FnSig), owned_args: *std.ArrayList([]CheckedType)) TranspileError!void {
        for (proc.nodes.items()) |node| {
            if (node.type != .Function or node.node_variant == null) continue;
            const fnv = node.node_variant.?.function;
            if (fnv.name == null) continue;
            const name = fnv.name.?.items;

            if (fns.contains(name)) continue;

            const args_vec = fnv.args orelse utils.Vector(*ast.Node).init(proc.allocator);
            const args_len = args_vec.count;
            var args_slice = proc.allocator.alloc(CheckedType, args_len) catch {
                return TranspileError.MemoryAllocationFailed;
            };
            errdefer proc.allocator.free(args_slice);

            var i: usize = 0;
            for (args_vec.items()) |arg_ptr| {
                const arg = arg_ptr.*;
                if (arg.type == .Variable and arg.node_variant != null) {
                    args_slice[i] = type_from_dtype(arg.node_variant.?.variable.type);
                } else {
                    args_slice[i] = .{ .base = .Unknown };
                }
                i += 1;
            }

            owned_args.append(args_slice) catch {
                return TranspileError.MemoryAllocationFailed;
            };
            fns.put(name, .{
                .rtype = if (fnv.rtype) |rt| type_from_dtype(&rt) else .{ .base = .Void },
                .args = args_slice,
                .is_variadic = fnv.is_variadic,
            }) catch {
                return TranspileError.MemoryAllocationFailed;
            };
        }

        // Impl methods are nested under `.Impl` nodes, not in `proc.nodes`.
        // Collect their generated function signatures too so method calls can be typechecked.
        for (proc.owned_nodes.items) |n| {
            if (n.type != .Impl or n.node_variant == null) continue;
            const im = n.node_variant.?.impl;
            for (im.methods.items()) |m| {
                if (m.type != .Function or m.node_variant == null) continue;
                const fnv = m.node_variant.?.function;
                if (fnv.name == null) continue;
                const name = fnv.name.?.items;

                if (fns.contains(name)) continue;

                const args_vec = fnv.args orelse utils.Vector(*ast.Node).init(proc.allocator);
                const args_len = args_vec.count;
                var args_slice = proc.allocator.alloc(CheckedType, args_len) catch {
                    return TranspileError.MemoryAllocationFailed;
                };
                errdefer proc.allocator.free(args_slice);

                var i: usize = 0;
                for (args_vec.items()) |arg_ptr| {
                    const arg = arg_ptr.*;
                    if (arg.type == .Variable and arg.node_variant != null) {
                        args_slice[i] = type_from_dtype(arg.node_variant.?.variable.type);
                    } else {
                        args_slice[i] = .{ .base = .Unknown };
                    }
                    i += 1;
                }

                owned_args.append(args_slice) catch {
                    return TranspileError.MemoryAllocationFailed;
                };
                fns.put(name, .{
                    .rtype = if (fnv.rtype) |rt| type_from_dtype(&rt) else .{ .base = .Void },
                    .args = args_slice,
                    .is_variadic = fnv.is_variadic,
                }) catch {
                    return TranspileError.MemoryAllocationFailed;
                };
            }
        }

        for (proc.children.items) |child| {
            try self.collect_fn_sigs(child, fns, owned_args);
        }
    }

    fn typecheck_all(self: *Self) TranspileError!void {
        var fns = std.StringHashMap(FnSig).init(self.allocator);
        defer fns.deinit();
        var owned_args = std.ArrayList([]CheckedType).init(self.allocator);
        defer {
            for (owned_args.items) |slice| self.allocator.free(slice);
            owned_args.deinit();
        }

        try self.collect_fn_sigs(self, &fns, &owned_args);

        // Check this module and all imported modules.
        try typecheck_module(self, &fns);
        for (self.children.items) |child| {
            try typecheck_module(child, &fns);
        }
    }

    fn typecheck_module(proc: *Self, fns: *const std.StringHashMap(FnSig)) TranspileError!void {
        for (proc.nodes.items()) |node| {
            if (node.type != .Function or node.node_variant == null) continue;
            const fnv = node.node_variant.?.function;
            const fn_rtype: CheckedType = if (fnv.rtype) |rt| type_from_dtype(&rt) else CheckedType{ .base = .Void };

            var fn_env = TypeEnv.init(proc.allocator);
            defer fn_env.deinit();
            try fn_env.push();

            // Add module-level globals (nodes without binded context).
            for (proc.nodes.items()) |gn| {
                if (gn.type == .Variable and gn.node_variant != null and gn.binded == null) {
                    const v = gn.node_variant.?.variable;
                    try fn_env.put_current(v.name.items, type_from_dtype(v.type));
                }
            }

            // Add args.
            if (fnv.args) |args| {
                for (args.items()) |arg_ptr| {
                    const arg = arg_ptr.*;
                    if (arg.type != .Variable or arg.node_variant == null) continue;
                    const v = arg.node_variant.?.variable;
                    try fn_env.put_current(v.name.items, type_from_dtype(v.type));
                }
            }

            if (fnv.body) |body| {
                try proc.check_body(body, &fn_env, fns, fn_rtype);
            }
        }
    }

    fn warn_if_fit_not_exhausted(self: *Self, fit_stmt: ast.Node, condition: *ast.Node, branches: []const ast.FitBranch) void {
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
                self.report_warning(fit_stmt, "fit statement is not exhausted for bin condition (missing true and false branches)", .{});
            } else if (!has_true) {
                self.report_warning(fit_stmt, "fit statement is not exhausted for bin condition (missing true branch)", .{});
            } else {
                self.report_warning(fit_stmt, "fit statement is not exhausted for bin condition (missing false branch)", .{});
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
                    if (function.name) |name| {
                        name.deinit();
                    }
                },
                .compound => |c| {
                    c.name.deinit();
                    for (c.fields.items()) |f| {
                        f.name.deinit();
                        f.dtype.type_str.deinit();
                        if (f.dtype.array) |array| {
                            if (!array.brackets.is_empty()) {
                                for (array.brackets.items()) |bracket| {
                                    self.deinit_node(bracket);
                                }
                            }
                            array.brackets.deinit();
                        }
                        allocator.destroy(f.dtype);
                    }
                    c.fields.deinit();
                },
                .quirk => |q| {
                    q.name.deinit();
                    for (q.methods.items()) |m| {
                        m.name.deinit();
                        m.rtype.type_str.deinit();
                        for (m.args.items()) |a| {
                            a.name.deinit();
                            a.dtype.type_str.deinit();
                            if (a.dtype.array) |array| {
                                if (!array.brackets.is_empty()) {
                                    for (array.brackets.items()) |bracket| {
                                        self.deinit_node(bracket);
                                    }
                                }
                                array.brackets.deinit();
                            }
                            allocator.destroy(a.dtype);
                        }
                        m.args.deinit();
                    }
                    q.methods.deinit();
                },
                .impl => |im| {
                    im.type_name.deinit();
                    if (im.quirk_name) |*qn| {
                        qn.deinit();
                    }
                    for (im.methods.items()) |m| {
                        self.deinit_node(m.*);
                        allocator.destroy(m);
                    }
                    im.methods.deinit();
                },
                .statement => |statement| {
                    switch (statement) {
                        .return_stmt => |ret| {
                            self.deinit_node(ret.*);
                            allocator.destroy(ret);
                        },
                        .for_stmt => |for_s| {
                            switch (for_s) {
                                .cond => |fc| {
                                    if (fc.condition) |cond| {
                                        self.deinit_node(cond.*);
                                        allocator.destroy(cond);
                                    }
                                    self.deinit_node(fc.body.*);
                                    allocator.destroy(fc.body);
                                },
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
        if (self.type_registry) |*reg| {
            reg.deinit();
            self.type_registry = null;
        }
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

        // Most allocations in a `TranspileProcess` are arena-backed; deinit the
        // containers, then release the arena at the end.
        self.owned_scope_entities.deinit();
        self.owned_nodes.deinit();
        if (self.symbols.active_table) |table| {
            table.symbols.deinit();
        }
        for (self.symbols.tables.items()) |table| {
            table.symbols.deinit();
        }
        self.symbols.tables.deinit();

        self.imported_files.deinit();
        self.import_chain.deinit();
        self.global_symbols.deinit();

        // Deinit children TranspileProcesses
        for (self.children.items) |child| {
            child.deinit();
            self.backing_allocator.destroy(child);
        }
        self.children.deinit();

        self.std_imports.deinit();

        // Release all arena allocations back to the backing allocator.
        self.arena.deinit();
        self.backing_allocator.destroy(self.arena);
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
        if (mem.eql(u8, type_str, "dec")) return "double";
        if (mem.eql(u8, type_str, "str")) return "char*";
        if (mem.eql(u8, type_str, "bin")) return "bool";
        if (mem.eql(u8, type_str, "chr")) return "char";
        if (mem.eql(u8, type_str, "raw")) return "void";
        return type_str;
    }

    /// Helper function to write data type to output
    fn write_type(self: *Self, data_type: dtype.DataType) TranspileError!void {
        const c_type = map_type_to_c(data_type.type_str.items);
        try self.write(c_type);

        const ptr_depth: usize = if (data_type.pointer_depth > 0) data_type.pointer_depth else blk: {
            if (data_type.flags != null and data_type.flags.?.is_pointer) break :blk 1;
            break :blk 0;
        };
        if (ptr_depth > 0) {
            var i: usize = 0;
            while (i < ptr_depth) : (i += 1) {
                try self.write("*");
            }
        }
        // TODO: Handle array types
        // if (data_type.array) |array| {
        //     for (array.brackets.items()) |bracket| {
        //         try self.write("[");
        //         try self.transpile_node(bracket);
        //         try self.write("]");
        //     }
        // }
    }

    fn c_ident_sanitize(self: *Self, raw: []const u8) TranspileError![]const u8 {
        var out = std.ArrayList(u8).init(self.allocator);
        errdefer out.deinit();
        for (raw) |c| {
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_') {
                out.append(c) catch return TranspileError.MemoryAllocationFailed;
            } else {
                out.append('_') catch return TranspileError.MemoryAllocationFailed;
            }
        }
        return out.toOwnedSlice() catch return TranspileError.MemoryAllocationFailed;
    }

    const SanitizedIdent = struct {
        slice: []const u8,
        owned: bool,
    };

    fn c_ident_sanitize_temp(self: *Self, raw: []const u8, stack_buf: []u8) TranspileError!SanitizedIdent {
        if (raw.len <= stack_buf.len) {
            var i: usize = 0;
            while (i < raw.len) : (i += 1) {
                const c = raw[i];
                stack_buf[i] = if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_') c else '_';
            }
            return .{ .slice = stack_buf[0..raw.len], .owned = false };
        }

        // Fallback for unusually long identifiers: allocate from the backing allocator
        // so the memory is promptly freed and doesn't bloat the arena.
        const heap_buf = self.backing_allocator.alloc(u8, raw.len) catch return TranspileError.MemoryAllocationFailed;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            const c = raw[i];
            heap_buf[i] = if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_') c else '_';
        }
        return .{ .slice = heap_buf, .owned = true };
    }

    fn quirk_sig_hash(sig: []const u8) u64 {
        return std.hash.Wyhash.hash(0, sig);
    }

    fn quirk_sig_hash_cached(self: *Self, sig: []const u8) u64 {
        const reg = self.root_registry() orelse return quirk_sig_hash(sig);
        return reg.quirk_hash_by_sig.get(sig) orelse quirk_sig_hash(sig);
    }

    const QuirkCNames = struct {
        quirk: [64]u8,
        quirk_len: usize,
        vtable: [72]u8,
        vtable_len: usize,
    };

    fn write_quirk_c_names_hash(h: u64) TranspileError!QuirkCNames {
        var out: QuirkCNames = undefined;
        out.quirk_len = (std.fmt.bufPrint(&out.quirk, "__fun_quirk_{x}", .{h}) catch unreachable).len;
        out.vtable_len = (std.fmt.bufPrint(&out.vtable, "__fun_quirk_{x}_vtable", .{h}) catch unreachable).len;
        return out;
    }

    fn write_quirk_c_names(sig: []const u8) TranspileError!QuirkCNames {
        return write_quirk_c_names_hash(quirk_sig_hash(sig));
    }

    fn root_registry(self: *Self) ?*TypeRegistry {
        const root = self.get_root();
        if (root.type_registry) |*reg| return reg;
        return null;
    }

    fn is_quirk_name(self: *Self, name: []const u8) bool {
        const reg = self.root_registry() orelse return false;
        return reg.quirk_sig_by_name.contains(name);
    }

    fn identifier_declared_dtype(self: *Self, ident: []const u8) ?*const dtype.DataType {
        const ent = self.get_scope_entity(ident) orelse return null;
        const ent_node = ent.node orelse return null;
        if (ent_node.type != .Variable or ent_node.node_variant == null) return null;
        return ent_node.node_variant.?.variable.type;
    }

    fn identifier_is_quirk_typed(self: *Self, ident: []const u8) bool {
        const dt = self.identifier_declared_dtype(ident) orelse return false;
        if (dt.type != .Unknown) return false;
        return self.is_quirk_name(dt.type_str.items);
    }

    fn expr_pointer_depth_from_scope(self: *Self, node: ast.Node) usize {
        switch (node.type) {
            .Identifier => {
                if (node.data == null) return 0;
                const name = node.data.?.sval.items;
                const ent = self.get_scope_entity(name) orelse return 0;
                const ent_node = ent.node orelse return 0;
                if (ent_node.type != .Variable or ent_node.node_variant == null) return 0;
                return ent_node.node_variant.?.variable.type.pointer_depth;
            },
            .ExpressionParenthesis => {
                if (node.node_variant == null) return 0;
                return self.expr_pointer_depth_from_scope(node.node_variant.?.paren.exp.*);
            },
            .Unary => {
                const u = node.node_variant.?.unary;
                const base = self.expr_pointer_depth_from_scope(u.operand.*);
                if (u.indirection) |ind| {
                    if (base < ind.depth) return 0;
                    return base - ind.depth;
                }
                if (mem.eql(u8, u.op, "&")) return base + 1;
                return base;
            },
            .Expression => {
                if (node.node_variant == null) return 0;
                const exp = node.node_variant.?.exp;
                if (!mem.eql(u8, exp.op, ".")) return 0;
                const left = exp.left orelse return 0;
                const right = exp.right orelse return 0;
                if (right.type != .Identifier or right.data == null) return 0;

                // Determine the named (compound) type of the left expression.
                const lt_name: []const u8 = blk: {
                    if (left.type == .Identifier and left.data != null) {
                        const dt = self.identifier_declared_dtype(left.data.?.sval.items) orelse break :blk "";
                        if (dt.type != .Unknown) break :blk "";
                        break :blk dt.type_str.items;
                    }

                    if (left.type == .Expression and left.node_variant != null and mem.eql(u8, left.node_variant.?.exp.op, ".")) {
                        // For chained field access, we only support resolving compound types.
                        // If we can't resolve, fall back to '.' (pointer depth 0).
                        // NOTE: pointer depth of the left doesn't matter for field type lookup here.
                        var cur: ast.Node = left.*;
                        var base_name: []const u8 = "";

                        // Walk to the left-most identifier to find the base variable's declared type.
                        while (cur.type == .Expression and cur.node_variant != null and mem.eql(u8, cur.node_variant.?.exp.op, ".")) {
                            const cur_left = cur.node_variant.?.exp.left orelse break;
                            cur = cur_left.*;
                        }
                        if (cur.type == .Identifier and cur.data != null) {
                            const dt0 = self.identifier_declared_dtype(cur.data.?.sval.items) orelse break :blk "";
                            if (dt0.type != .Unknown) break :blk "";
                            base_name = dt0.type_str.items;
                        } else {
                            break :blk "";
                        }

                        // Now replay the chain from the original left expression to compute the final named type.
                        // We only care about the named type (base Unknown + name).
                        var t: CheckedType = .{ .base = .Unknown, .name = base_name, .pointer_depth = 0 };
                        cur = left.*;
                        while (cur.type == .Expression and cur.node_variant != null and mem.eql(u8, cur.node_variant.?.exp.op, ".")) {
                            const dot = cur.node_variant.?.exp;
                            const seg = dot.right orelse break;
                            if (seg.type != .Identifier or seg.data == null) break;
                            const fdt = self.lookup_compound_field(t.name.?, seg.data.?.sval.items) orelse break;
                            t = type_from_dtype(fdt);
                            const nl = dot.left orelse break;
                            cur = nl.*;
                        }
                        if (t.base != .Unknown or t.name == null) break :blk "";
                        break :blk t.name.?;
                    }

                    break :blk "";
                };
                if (lt_name.len == 0) return 0;

                const fdt = self.lookup_compound_field(lt_name, right.data.?.sval.items) orelse return 0;
                return fdt.pointer_depth;
            },
            else => return 0,
        }
    }

    fn expr_named_pointee_from_scope(self: *Self, node: ast.Node) ?[]const u8 {
        // Returns type name `T` if expression is a `T*` (pointer_depth == 1).
        switch (node.type) {
            .Identifier => {
                if (node.data == null) return null;
                const name = node.data.?.sval.items;
                const ent = self.get_scope_entity(name) orelse return null;
                const ent_node = ent.node orelse return null;
                if (ent_node.type != .Variable or ent_node.node_variant == null) return null;
                const dt = ent_node.node_variant.?.variable.type;
                if (dt.pointer_depth != 1 or dt.type != .Unknown) return null;
                return dt.type_str.items;
            },
            .Unary => {
                const u = node.node_variant.?.unary;
                if (mem.eql(u8, u.op, "&")) {
                    // &x => pointer to x's declared type
                    const op = u.operand.*;
                    if (op.type != .Identifier or op.data == null) return null;
                    const name = op.data.?.sval.items;
                    const ent = self.get_scope_entity(name) orelse return null;
                    const ent_node = ent.node orelse return null;
                    if (ent_node.type != .Variable or ent_node.node_variant == null) return null;
                    const dt = ent_node.node_variant.?.variable.type;
                    if (dt.type != .Unknown) return null;
                    return dt.type_str.items;
                }
                return null;
            },
            else => return null,
        }
    }

    fn emit_user_types(self: *Self) TranspileError!void {
        if (self.did_emit_user_types) return;
        self.did_emit_user_types = true;

        const reg = self.root_registry() orelse return;

        try self.write("// --- User types ---\n\n");

        // Compounds
        // NOTE: `std.StringHashMap` iteration order is not stable and can place
        // dependent compounds before their dependencies (e.g. Rectangle before Point).
        // Emit compounds in a stable order that respects by-value dependencies.
        const root = self.get_root();

        var compound_nodes = std.ArrayList(*ast.Node).init(self.allocator);
        defer compound_nodes.deinit();

        var seen_compounds = std.StringHashMap(bool).init(self.allocator);
        defer seen_compounds.deinit();

        for (root.nodes.items()) |n| {
            if (n.type != .Compound or n.node_variant == null) continue;
            const cname = n.node_variant.?.compound.name.items;
            if (!reg.compounds_by_name.contains(cname)) continue;
            if (seen_compounds.contains(cname)) continue;
            seen_compounds.put(cname, true) catch {
                return TranspileError.MemoryAllocationFailed;
            };
            compound_nodes.append(reg.compounds_by_name.get(cname).?) catch {
                return TranspileError.MemoryAllocationFailed;
            };
        }

        var emitted_compounds = std.StringHashMap(bool).init(self.allocator);
        defer emitted_compounds.deinit();

        var remaining = std.ArrayList(*ast.Node).init(self.allocator);
        defer remaining.deinit();
        remaining.appendSlice(compound_nodes.items) catch {
            return TranspileError.MemoryAllocationFailed;
        };

        var ordered = std.ArrayList(*ast.Node).init(self.allocator);
        defer ordered.deinit();

        // Forward typedefs allow pointer fields (including self-pointers) to refer to
        // types declared later.
        for (compound_nodes.items) |cnode| {
            if (cnode.node_variant == null) continue;
            const c = cnode.node_variant.?.compound;
            try self.write("typedef struct ");
            try self.write(c.name.items);
            try self.write(" ");
            try self.write(c.name.items);
            try self.write(";\n");
        }
        if (compound_nodes.items.len > 0) try self.write("\n");

        while (remaining.items.len > 0) {
            var progress = false;
            var i: usize = 0;
            while (i < remaining.items.len) {
                const cnode = remaining.items[i];
                if (cnode.node_variant == null) {
                    _ = remaining.swapRemove(i);
                    continue;
                }
                const c = cnode.node_variant.?.compound;

                var deps_satisfied = true;
                for (c.fields.items()) |f| {
                    // Only enforce ordering for by-value named compound dependencies.
                    // Pointer-typed fields can refer to incomplete types.
                    if (f.dtype.pointer_depth != 0) continue;
                    if (f.dtype.type != .Unknown) continue;
                    if (f.dtype.type_str.items.len == 0) continue;
                    const dep = f.dtype.type_str.items;
                    if (!reg.compounds_by_name.contains(dep)) continue;
                    if (!emitted_compounds.contains(dep)) {
                        deps_satisfied = false;
                        break;
                    }
                }

                if (deps_satisfied) {
                    ordered.append(cnode) catch {
                        return TranspileError.MemoryAllocationFailed;
                    };
                    emitted_compounds.put(c.name.items, true) catch {
                        return TranspileError.MemoryAllocationFailed;
                    };
                    _ = remaining.swapRemove(i);
                    progress = true;
                    continue;
                }

                i += 1;
            }

            if (!progress) {
                self.report_error(null, "cyclic by-value compound dependency (use pointers to break the cycle)", .{});
                return TranspileError.CyclicCompoundDependency;
            }
        }

        for (ordered.items) |cnode| {
            if (cnode.node_variant == null) continue;
            const c = cnode.node_variant.?.compound;

            try self.write("typedef struct ");
            try self.write(c.name.items);
            try self.write(" {\n");

            for (c.fields.items()) |f| {
                try self.write("  ");
                try self.write_type(f.dtype.*);
                try self.write(" ");
                try self.write(f.name.items);

                if (f.dtype.flags != null and f.dtype.flags.?.is_array) {
                    if (f.dtype.array) |array| {
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
                try self.write(";\n");
            }
            try self.write("} ");
            try self.write(c.name.items);
            try self.write(";\n\n");
        }

        // Quirk canonical structs per signature
        var q_it = reg.quirks_by_sig.iterator();
        while (q_it.next()) |entry| {
            const sig = entry.key_ptr.*;
            const qnode = entry.value_ptr.*;
            if (qnode.node_variant == null) continue;
            const q = qnode.node_variant.?.quirk;

            const h = self.quirk_sig_hash_cached(sig);
            const names = try write_quirk_c_names_hash(h);
            const quirk_c = names.quirk[0..names.quirk_len];
            const vtable_c = names.vtable[0..names.vtable_len];

            // Vtable type
            try self.write("typedef struct ");
            try self.write(vtable_c);
            try self.write(" {\n");
            for (q.methods.items()) |m| {
                try self.write("  ");
                try self.write_type(m.rtype);
                try self.write(" (*");
                try self.write(m.name.items);
                try self.write(")(void* self");
                for (m.args.items(), 0..) |a, i| {
                    _ = i;
                    try self.write(", ");
                    try self.write_type(a.dtype.*);
                }
                try self.write(");\n");
            }
            try self.write("} ");
            try self.write(vtable_c);
            try self.write(";\n\n");

            // Quirk object type
            try self.write("typedef struct ");
            try self.write(quirk_c);
            try self.write(" {\n");
            try self.write("  void* self;\n");
            try self.write("  const ");
            try self.write(vtable_c);
            try self.write("* vtable;\n");
            try self.write("} ");
            try self.write(quirk_c);
            try self.write(";\n\n");
        }

        // Quirk name aliases
        var qn_it = reg.quirk_sig_by_name.iterator();
        while (qn_it.next()) |entry| {
            const qname = entry.key_ptr.*;
            const sig = entry.value_ptr.*;
            const h = self.quirk_sig_hash_cached(sig);
            const names = try write_quirk_c_names_hash(h);
            const quirk_c = names.quirk[0..names.quirk_len];
            try self.write("typedef ");
            try self.write(quirk_c);
            try self.write(" ");
            try self.write(qname);
            try self.write(";\n");
        }
        try self.write("\n");
    }

    fn emit_impls_and_vtables(self: *Self) TranspileError!void {
        if (self.did_emit_impls) return;
        self.did_emit_impls = true;

        const reg = self.root_registry() orelse return;

        // Plain impl methods (`impl Type { ... }`) can be called from within quirk impl
        // method bodies. Emit their forward declarations up-front so C compilation
        // never relies on implicit declarations.
        // NOTE: Prototypes will also be emitted again in the "Plain impl methods" block;
        // duplicate identical prototypes are OK in C.
        var plain_emitted = std.StringHashMap(bool).init(self.backing_allocator);
        defer plain_emitted.deinit();
        try self.emit_plain_impl_method_prototypes_module(self, &plain_emitted);
        try self.write("\n");

        // Impl wrappers/vtables/coercions
        try self.write("// --- Quirk impl vtables ---\n\n");
        var impl_it = reg.impls_by_key.iterator();
        while (impl_it.next()) |entry| {
            const impl_node = entry.value_ptr.*;
            if (impl_node.node_variant == null) continue;
            const im = impl_node.node_variant.?.impl;
            const type_name = im.type_name.items;
            const quirk_name = if (im.quirk_name) |qn| qn.items else continue;
            const sig = reg.quirk_sig_by_name.get(quirk_name) orelse continue;
            const sig_h = self.quirk_sig_hash_cached(sig);
            const qnode = reg.quirks_by_sig.get(sig) orelse continue;
            if (qnode.node_variant == null) continue;
            const q = qnode.node_variant.?.quirk;

            const names = try write_quirk_c_names_hash(sig_h);
            const quirk_c = names.quirk[0..names.quirk_len];
            const vtable_c = names.vtable[0..names.vtable_len];

            var type_stack: [128]u8 = undefined;
            const type_s = try self.c_ident_sanitize_temp(type_name, &type_stack);
            defer if (type_s.owned) self.backing_allocator.free(type_s.slice);

            var vtbl_buf: [96]u8 = undefined;
            const vtbl_name = (std.fmt.bufPrint(&vtbl_buf, "__fun_impl_{s}_{x}_vtable", .{ type_s.slice, sig_h }) catch unreachable);

            var coerce_buf: [96]u8 = undefined;
            const coerce_name = (std.fmt.bufPrint(&coerce_buf, "__fun_coerce_{s}_{x}", .{ type_s.slice, sig_h }) catch unreachable);

            // Forward declare generated impl methods so wrappers can call them.
            for (im.methods.items()) |m| {
                if (m.type != .Function or m.node_variant == null) continue;
                const fnv = m.node_variant.?.function;
                if (fnv.name == null) continue;
                if (fnv.rtype) |rt| {
                    try self.write_type(rt);
                } else {
                    try self.write("void");
                }
                try self.write(" ");
                try self.write(fnv.name.?.items);
                try self.write("(");
                self.in_function_params = true;
                if (fnv.args) |args| {
                    for (args.items(), 0..) |arg, i| {
                        if (i > 0) try self.write(", ");
                        try self.transpile_node(arg.*);
                    }
                }
                self.in_function_params = false;
                try self.write(");\n");
            }
            try self.write("\n");

            // Emit method bodies.
            for (im.methods.items()) |m| {
                if (m.type != .Function or m.node_variant == null) continue;
                const fnv = m.node_variant.?.function;
                if (fnv.body == null) continue;
                try self.transpile_node(m.*);
                try self.write("\n\n");
            }

            // Wrappers with `void* self` to match vtable signature.
            for (q.methods.items()) |m| {
                // Find the generated method function name by suffix match.
                var impl_fn_name: ?[]const u8 = null;
                for (im.methods.items()) |fm| {
                    if (fm.type != .Function or fm.node_variant == null) continue;
                    const fnv = fm.node_variant.?.function;
                    if (fnv.name == null) continue;
                    const n = fnv.name.?.items;
                    var suf_buf: [128]u8 = undefined;
                    const suf = (std.fmt.bufPrint(&suf_buf, "__{s}", .{m.name.items}) catch unreachable);
                    if (mem.endsWith(u8, n, suf)) {
                        impl_fn_name = n;
                        break;
                    }
                }
                if (impl_fn_name == null) continue;

                var m_stack: [128]u8 = undefined;
                const m_s = try self.c_ident_sanitize_temp(m.name.items, &m_stack);
                defer if (m_s.owned) self.backing_allocator.free(m_s.slice);
                var wrap_buf: [128]u8 = undefined;
                const wrap_name = (std.fmt.bufPrint(&wrap_buf, "__fun_wrap_{s}_{x}_{s}", .{ type_s.slice, sig_h, m_s.slice }) catch unreachable);

                try self.write("static ");
                try self.write_type(m.rtype);
                try self.write(" ");
                try self.write(wrap_name);
                try self.write("(void* self");
                for (m.args.items(), 0..) |a, i| {
                    try self.write(", ");
                    try self.write_type(a.dtype.*);
                    var an: [16]u8 = undefined;
                    const aname = (std.fmt.bufPrint(&an, " a{d}", .{i}) catch unreachable);
                    try self.write(aname);
                }
                try self.write(") {\n");

                try self.write("  ");
                if (m.rtype.type != .Void) {
                    try self.write("return ");
                }
                try self.write(impl_fn_name.?);
                try self.write("((");
                try self.write(type_name);
                try self.write("*)self");
                for (m.args.items(), 0..) |_, i| {
                    var an2: [16]u8 = undefined;
                    const aname2 = (std.fmt.bufPrint(&an2, ", a{d}", .{i}) catch unreachable);
                    try self.write(aname2);
                }
                try self.write(");\n");
                try self.write("}\n\n");
            }

            // Vtable instance
            try self.write("static const ");
            try self.write(vtable_c);
            try self.write(" ");
            try self.write(vtbl_name);
            try self.write(" = {\n");
            for (q.methods.items()) |m| {
                var m_stack2: [128]u8 = undefined;
                const m_s = try self.c_ident_sanitize_temp(m.name.items, &m_stack2);
                defer if (m_s.owned) self.backing_allocator.free(m_s.slice);
                var wrap_buf2: [128]u8 = undefined;
                const wrap_name2 = (std.fmt.bufPrint(&wrap_buf2, "__fun_wrap_{s}_{x}_{s}", .{ type_s.slice, sig_h, m_s.slice }) catch unreachable);
                try self.write("  .");
                try self.write(m.name.items);
                try self.write(" = ");
                try self.write(wrap_name2);
                try self.write(",\n");
            }
            try self.write("};\n\n");

            // Coercion helper
            try self.write("static inline ");
            try self.write(quirk_c);
            try self.write(" ");
            try self.write(coerce_name);
            try self.write("(");
            try self.write(type_name);
            try self.write("* self) {\n");
            try self.write("  return (");
            try self.write(quirk_c);
            try self.write("){ .self = self, .vtable = &");
            try self.write(vtbl_name);
            try self.write(" };\n");
            try self.write("}\n\n");
        }

        // Plain impl method bodies (non-quirk): `impl Type { ... }`
        try self.write("// --- Plain impl methods ---\n\n");
        var emitted = std.StringHashMap(bool).init(self.backing_allocator);
        defer emitted.deinit();
        try self.emit_plain_impl_methods_module(self, &emitted);
    }

    fn emit_plain_impl_method_prototypes_module(self: *Self, proc: *Self, emitted: *std.StringHashMap(bool)) TranspileError!void {
        for (proc.owned_nodes.items) |n| {
            if (n.type != .Impl or n.node_variant == null) continue;
            const im = n.node_variant.?.impl;
            if (im.quirk_name != null) continue;

            for (im.methods.items()) |m| {
                if (m.type != .Function or m.node_variant == null) continue;
                const fnv = m.node_variant.?.function;
                if (fnv.name == null) continue;
                const fname = fnv.name.?.items;
                if (emitted.contains(fname)) continue;
                emitted.put(fname, true) catch return TranspileError.MemoryAllocationFailed;

                if (fnv.rtype) |rt| {
                    try proc.write_type(rt);
                } else {
                    try proc.write("void");
                }
                try proc.write(" ");
                try proc.write(fname);
                try proc.write("(");
                proc.in_function_params = true;
                if (fnv.args) |args| {
                    for (args.items(), 0..) |arg, i| {
                        if (i > 0) try proc.write(", ");
                        try proc.transpile_node(arg.*);
                    }
                }
                proc.in_function_params = false;
                try proc.write(");\n");
            }
        }

        for (proc.children.items) |child| {
            try self.emit_plain_impl_method_prototypes_module(child, emitted);
        }
    }

    fn emit_plain_impl_methods_module(self: *Self, proc: *Self, emitted: *std.StringHashMap(bool)) TranspileError!void {
        for (proc.owned_nodes.items) |n| {
            if (n.type != .Impl or n.node_variant == null) continue;
            const im = n.node_variant.?.impl;
            if (im.quirk_name != null) continue;

            // Forward declare first, so bodies can call each other.
            for (im.methods.items()) |m| {
                if (m.type != .Function or m.node_variant == null) continue;
                const fnv = m.node_variant.?.function;
                if (fnv.name == null) continue;
                const fname = fnv.name.?.items;
                if (emitted.contains(fname)) continue;
                emitted.put(fname, true) catch return TranspileError.MemoryAllocationFailed;

                if (fnv.rtype) |rt| {
                    try proc.write_type(rt);
                } else {
                    try proc.write("void");
                }
                try proc.write(" ");
                try proc.write(fname);
                try proc.write("(");
                proc.in_function_params = true;
                if (fnv.args) |args| {
                    for (args.items(), 0..) |arg, i| {
                        if (i > 0) try proc.write(", ");
                        try proc.transpile_node(arg.*);
                    }
                }
                proc.in_function_params = false;
                try proc.write(");\n");
            }
            try proc.write("\n");

            for (im.methods.items()) |m| {
                if (m.type != .Function or m.node_variant == null) continue;
                const fnv = m.node_variant.?.function;
                if (fnv.body == null) continue;
                try proc.transpile_node(m.*);
                try proc.write("\n\n");
            }
        }

        for (proc.children.items) |child| {
            try self.emit_plain_impl_methods_module(child, emitted);
        }
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

        // Collect user-defined type declarations across imports before typechecking.
        try self.collect_type_registry_all();

        // Type check after imports are parsed (so imported signatures are available).
        try self.typecheck_all();

        // Write standard library includes and prelude
        try self.transpile_prelude();

        // Emit user-defined types (compounds/quirks) once at the root.
        // NOTE: Impl method bodies/vtables are emitted later so the global function
        // prototype block can appear before any function bodies that might call
        // imported functions.
        if (!self.is_importing) {
            try self.emit_user_types();
        }

        // Emit forward declarations for all functions so calls work even when
        // function bodies are declared later in the file.
        if (!self.is_importing) {
            try self.emit_function_prototypes_all();
        }

        // Emit impl method bodies/vtables/coercions after the prototype block.
        if (!self.is_importing) {
            try self.emit_impls_and_vtables();
        }

        // Output content from child imports recursively
        if (!self.is_importing) {
            try self.transpile_children_recursive(self);
        }

        // Now output the main file content
        for (self.nodes.items()) |node| {
            if (node.type != .Import) { // Skip import nodes as they've been processed
                if (node.type == .Compound or node.type == .Quirk) continue;
                try self.transpile_node(node);
                try self.write("\n\n");
            }
        }
    }

    fn emit_function_prototypes_all(self: *Self) TranspileError!void {
        // Only the root module emits this block.
        if (self.is_importing) return;
        try self.write("\n// Function prototypes (allow out-of-order definitions)\n");
        try self.emit_function_prototypes_module(self);
        try self.write("\n");
    }

    fn emit_function_prototypes_module(self: *Self, proc: *Self) TranspileError!void {
        for (proc.nodes.items()) |node| {
            if (node.type != .Function or node.node_variant == null) continue;
            const function = node.node_variant.?.function;
            if (function.body == null) continue;
            if (function.name != null and mem.eql(u8, function.name.?.items, "main")) continue;

            try self.write_function_prototype(node);
        }

        for (proc.children.items) |child| {
            try self.emit_function_prototypes_module(child);
        }
    }

    fn write_function_prototype(self: *Self, node: ast.Node) TranspileError!void {
        if (node.type != .Function or node.node_variant == null) return;
        const function = node.node_variant.?.function;
        if (function.body == null) return;

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
        var wrote_any_param = false;
        if (function.args) |args| {
            for (args.items(), 0..) |arg, i| {
                if (i > 0) try self.write(", ");
                try self.transpile_node(arg.*);
                wrote_any_param = true;
            }
        }
        if (function.is_variadic) {
            if (wrote_any_param) try self.write(", ");
            try self.write("...");
        }
        self.in_function_params = false;
        try self.write(");\n");
    }

    // Helper function to recursively transpile children
    fn transpile_children_recursive(self: *Self, parent_proc: *TranspileProcess) TranspileError!void {
        for (parent_proc.children.items) |child| {
            // Recursively transpile the child's children first
            try self.transpile_children_recursive(child);

            // Then, transpile the child's own nodes (excluding imports and main functions)
            for (child.nodes.items()) |node| {
                if (node.type != .Import) {
                    if (node.type == .Compound or node.type == .Quirk) continue;
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
                    // Quirk method call: `q.method(...)` emits `q.vtable->method(q.self, ...)`.
                    if (exp.left) |left| {
                        if (left.type == .Expression and left.node_variant != null and mem.eql(u8, left.node_variant.?.exp.op, ".")) {
                            const dot = left.node_variant.?.exp;
                            const recv = dot.left orelse null;
                            const member = dot.right orelse null;
                            if (recv != null and member != null and member.?.type == .Identifier and member.?.data != null) {
                                // Only special-case when receiver is a quirk-typed identifier.
                                if (recv.?.type == .Identifier and recv.?.data != null and self.identifier_is_quirk_typed(recv.?.data.?.sval.items)) {
                                    const mname = member.?.data.?.sval.items;
                                    try self.write("(");
                                    try self.transpile_node(recv.?.*);
                                    try self.write(".vtable->");
                                    try self.write(mname);
                                    try self.write("(");
                                    try self.transpile_node(recv.?.*);
                                    try self.write(".self");

                                    // Append call args.
                                    if (exp.right) |right| {
                                        // Right is an ExpressionParenthesis node.
                                        const inner = if (right.type == .ExpressionParenthesis and right.node_variant != null)
                                            right.node_variant.?.paren.exp.*
                                        else
                                            right.*;
                                        if (inner.type != .Blank) {
                                            // Render arg expression(s) as a comma list.
                                            try self.write(", ");
                                            try self.transpile_node(inner);
                                        }
                                    }

                                    try self.write(")");
                                    try self.write(")");
                                    return;
                                }

                                // Plain impl method call on compounds: `x.method(...)`.
                                if (recv.?.type == .Identifier and recv.?.data != null and !self.identifier_is_quirk_typed(recv.?.data.?.sval.items)) {
                                    const rname = recv.?.data.?.sval.items;
                                    const dt = self.identifier_declared_dtype(rname) orelse null;
                                    if (dt != null and dt.?.type == .Unknown and !self.is_quirk_name(dt.?.type_str.items) and (dt.?.pointer_depth == 0 or dt.?.pointer_depth == 1)) {
                                        const type_name = dt.?.type_str.items;
                                        const mname = member.?.data.?.sval.items;
                                        if (self.lookup_plain_impl_method_fn(type_name, mname)) |fn_name| {
                                            try self.write("(");
                                            try self.write(fn_name);
                                            try self.write("(");

                                            if (dt.?.pointer_depth == 0) {
                                                try self.write("&");
                                                try self.transpile_node(recv.?.*);
                                            } else {
                                                try self.transpile_node(recv.?.*);
                                            }

                                            if (exp.right) |right| {
                                                const inner = if (right.type == .ExpressionParenthesis and right.node_variant != null)
                                                    right.node_variant.?.paren.exp.*
                                                else
                                                    right.*;
                                                if (inner.type != .Blank) {
                                                    try self.write(", ");
                                                    try self.transpile_node(inner);
                                                }
                                            }

                                            try self.write(")");
                                            try self.write(")");
                                            return;
                                        }

                                        // Also allow calling quirk-impl methods directly on concrete types.
                                        const qres = self.resolve_quirk_impl_method_for_concrete(type_name, mname);
                                        if (!qres.ambiguous) {
                                            if (qres.fn_name) |qfn_name| {
                                                try self.write("(");
                                                try self.write(qfn_name);
                                                try self.write("(");

                                                if (dt.?.pointer_depth == 0) {
                                                    try self.write("&");
                                                    try self.transpile_node(recv.?.*);
                                                } else {
                                                    try self.transpile_node(recv.?.*);
                                                }

                                                if (exp.right) |right| {
                                                    const inner = if (right.type == .ExpressionParenthesis and right.node_variant != null)
                                                        right.node_variant.?.paren.exp.*
                                                    else
                                                        right.*;
                                                    if (inner.type != .Blank) {
                                                        try self.write(", ");
                                                        try self.transpile_node(inner);
                                                    }
                                                }

                                                try self.write(")");
                                                try self.write(")");
                                                return;
                                            }
                                        }

                                        // Quirk impl method call on `self` inside `impl Type Quirk { ... }`.
                                        // `self.method()` is not a struct member call in C; emit a direct call to
                                        // the generated impl function when we can resolve it.
                                        if (mem.eql(u8, rname, "self")) {
                                            if (self.lookup_quirk_impl_method_fn_for_self(type_name, mname)) |qfn_name| {
                                                try self.write("(");
                                                try self.write(qfn_name);
                                                try self.write("(");

                                                if (dt.?.pointer_depth == 0) {
                                                    try self.write("&");
                                                    try self.transpile_node(recv.?.*);
                                                } else {
                                                    try self.transpile_node(recv.?.*);
                                                }

                                                if (exp.right) |right| {
                                                    const inner = if (right.type == .ExpressionParenthesis and right.node_variant != null)
                                                        right.node_variant.?.paren.exp.*
                                                    else
                                                        right.*;
                                                    if (inner.type != .Blank) {
                                                        try self.write(", ");
                                                        try self.transpile_node(inner);
                                                    }
                                                }

                                                try self.write(")");
                                                try self.write(")");
                                                return;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
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
                } else if (mem.eql(u8, exp.op, ".")) {
                    const left = exp.left orelse return;
                    const right = exp.right orelse return;
                    try self.transpile_node(left.*);
                    const pd = self.expr_pointer_depth_from_scope(left.*);
                    try self.write(if (pd > 0) "->" else ".");
                    try self.transpile_node(right.*);
                } else if (mem.eql(u8, exp.op, "=")) {
                    // If assigning into a quirk-typed variable, coerce `T*` -> quirk when possible.
                    const left = exp.left orelse return;
                    const right = exp.right orelse return;
                    if (left.type == .Identifier and left.data != null) {
                        const lname = left.data.?.sval.items;
                        if (self.identifier_is_quirk_typed(lname)) {
                            const reg = self.root_registry() orelse {
                                try self.transpile_node(left.*);
                                try self.write(" = ");
                                try self.transpile_node(right.*);
                                return;
                            };
                            const ldt = self.identifier_declared_dtype(lname) orelse null;
                            const expected_sig = if (ldt != null) reg.quirk_sig_by_name.get(ldt.?.type_str.items) else null;
                            if (expected_sig != null) {
                                const actual = self.expr_named_pointee_from_scope(right.*);
                                if (actual != null) {
                                    if (reg.impls_by_key.contains(.{ .type_name = actual.?, .quirk_sig = expected_sig.? })) {
                                        var type_stack2: [128]u8 = undefined;
                                        const type_s = try self.c_ident_sanitize_temp(actual.?, &type_stack2);
                                        defer if (type_s.owned) self.backing_allocator.free(type_s.slice);
                                        var coerce_buf: [96]u8 = undefined;
                                        const coerce_name = (std.fmt.bufPrint(&coerce_buf, "__fun_coerce_{s}_{x}", .{ type_s.slice, self.quirk_sig_hash_cached(expected_sig.?) }) catch unreachable);
                                        try self.transpile_node(left.*);
                                        try self.write(" = ");
                                        try self.write(coerce_name);
                                        try self.write("(");
                                        try self.transpile_node(right.*);
                                        try self.write(")");
                                        return;
                                    }
                                }
                            }
                        }
                    }
                    try self.transpile_node(left.*);
                    try self.write(" = ");
                    try self.transpile_node(right.*);
                } else if (exp.op.len > 0) {
                    if (exp.left) |left| {
                        try self.transpile_node(left.*);
                    }
                    // Special case: no space after reference operator '&' or '^' (address-of/reference)
                    if (mem.eql(u8, exp.op, "&") or mem.eql(u8, exp.op, "^")) {
                        try self.write(exp.op);
                        if (exp.right) |right| {
                            try self.transpile_node(right.*);
                        }
                    } else {
                        // Default: space before and after all other operators
                        try self.write(" ");
                        try self.write(exp.op);
                        try self.write(" ");
                        if (exp.right) |right| {
                            try self.transpile_node(right.*);
                        }
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
                const d = node.data orelse {
                    try self.write("0");
                    return;
                };
                switch (d) {
                    .llnum => |v| try self.print("{d}", .{v}),
                    .lnum => |v| try self.print("{d}", .{v}),
                    .inum => |v| try self.print("{d}", .{v}),
                    .dnum => |v| try self.print("{e}", .{v}),
                    .cval => |v| try self.print("{d}", .{v}),
                    else => try self.write("0"),
                }
            },
            .Character => {
                const d = node.data orelse {
                    try self.write("'\\0'");
                    return;
                };
                const c: u8 = switch (d) {
                    .cval => |v| v,
                    else => 0,
                };
                try self.write("'");
                switch (c) {
                    '\\' => try self.write("\\\\"),
                    '\'' => try self.write("\\\'"),
                    '\n' => try self.write("\\n"),
                    '\r' => try self.write("\\r"),
                    '\t' => try self.write("\\t"),
                    0 => try self.write("\\0"),
                    else => {
                        if (c < 0x20 or c >= 0x7f) {
                            try self.print("\\x{x:0>2}", .{c});
                        } else {
                            var buf: [1]u8 = .{c};
                            try self.write(buf[0..]);
                        }
                    },
                }
                try self.write("'");
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

                    // Implicit quirk coercion in initializers: `Quirk q = &t;`.
                    if (variable.type.type == .Unknown and self.is_quirk_name(variable.type.type_str.items)) {
                        const reg = self.root_registry() orelse {
                            try self.transpile_node(val.*);
                            if (!self.in_function_params) try self.write(";");
                            return;
                        };
                        const sig = reg.quirk_sig_by_name.get(variable.type.type_str.items) orelse null;
                        if (sig != null) {
                            const actual = self.expr_named_pointee_from_scope(val.*);
                            if (actual != null) {
                                if (reg.impls_by_key.contains(.{ .type_name = actual.?, .quirk_sig = sig.? })) {
                                    var type_stack3: [128]u8 = undefined;
                                    const type_s = try self.c_ident_sanitize_temp(actual.?, &type_stack3);
                                    defer if (type_s.owned) self.backing_allocator.free(type_s.slice);
                                    var coerce_buf: [96]u8 = undefined;
                                    const coerce_name = (std.fmt.bufPrint(&coerce_buf, "__fun_coerce_{s}_{x}", .{ type_s.slice, self.quirk_sig_hash_cached(sig.?) }) catch unreachable);
                                    try self.write(coerce_name);
                                    try self.write("(");
                                    try self.transpile_node(val.*);
                                    try self.write(")");
                                    if (!self.in_function_params) try self.write(";");
                                    return;
                                }
                            }
                        }
                    }

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

                    // Main parameter rules:
                    // - No params: emit standard `(int argc, char** argv)`.
                    // - Exactly one param of type `str[] name`: emit `(int argc, char** name)`.
                    //   This keeps the Fun surface as `main(str[] args)` (README style) while
                    //   still receiving OS argv.
                    // - Otherwise: emit user-declared params verbatim.
                    try self.write("(");

                    const args_vec_opt = function.args;
                    const argcnt: usize = if (args_vec_opt) |a| a.count else 0;

                    const is_single_str_array = blk: {
                        if (argcnt != 1) break :blk false;
                        const arg0 = args_vec_opt.?.items()[0];
                        if (arg0.type != .Variable or arg0.node_variant == null) break :blk false;
                        const dt = arg0.node_variant.?.variable.type.*;
                        if (!mem.eql(u8, dt.type_str.items, "str")) break :blk false;
                        if (dt.flags == null or !dt.flags.?.is_array) break :blk false;
                        break :blk true;
                    };

                    if (argcnt == 0) {
                        try self.write("int argc, char** argv");
                    } else if (is_single_str_array) {
                        // Register the Fun-visible param for later type queries.
                        const arg0 = args_vec_opt.?.items()[0];
                        try self.register_scope_variable(arg0);
                        self.in_function_params = true;
                        try self.write("int argc, ");
                        // `str[] args` prints as `char* args[]`, which is OK for argv.
                        try self.transpile_node(arg0.*);
                        self.in_function_params = false;
                    } else {
                        self.in_function_params = true;
                        if (function.args) |args| {
                            for (args.items(), 0..) |arg, i| {
                                if (i > 0) try self.write(", ");
                                if (arg.type == .Variable) {
                                    try self.register_scope_variable(arg);
                                }
                                try self.transpile_node(arg.*);
                            }
                        }
                        self.in_function_params = false;
                    }

                    try self.write(") ");
                    if (function.body) |body| {
                        const prev_in_main = self.in_main;
                        self.in_main = true;
                        defer self.in_main = prev_in_main;
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
                    var wrote_any_param = false;
                    if (function.args) |args| {
                        for (args.items(), 0..) |arg, i| {
                            if (i > 0) try self.write(", ");
                            // Make args visible for later type queries.
                            if (arg.type == .Variable) {
                                try self.register_scope_variable(arg);
                            }
                            try self.transpile_node(arg.*);
                            wrote_any_param = true;
                        }
                    }
                    if (function.is_variadic) {
                        if (wrote_any_param) try self.write(", ");
                        try self.write("...");
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
                // `ret;` is represented as StatementReturn with no node_variant.
                if (node.type == .StatementReturn and node.node_variant == null) {
                    if (self.in_main) {
                        try self.write("return 0;");
                    } else {
                        try self.write("return;");
                    }
                    return;
                }

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
                            .cond => |fc| {
                                if (fc.condition) |cond| {
                                    try self.write("while (");
                                    try self.transpile_node(cond.*);
                                    try self.write(") {");
                                } else {
                                    try self.write("while (1) {");
                                }
                                self.indent();

                                if (fc.body.type == .Body) {
                                    const body = fc.body.node_variant.?.body;
                                    for (body.statements.items()) |body_stmt| {
                                        try self.write_indent();
                                        try self.transpile_node(body_stmt.*);
                                        if (body_stmt.type == .Expression) {
                                            try self.write(";");
                                        }
                                    }
                                } else {
                                    try self.write_indent();
                                    try self.transpile_node(fc.body.*);
                                    if (fc.body.type == .Expression) {
                                        try self.write(";");
                                    }
                                }

                                self.dedent();
                                try self.write_indent();
                                try self.write("}");
                            },
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
                        self.warn_if_fit_not_exhausted(node, fit.exp, fit.branches.items());
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
        if (std.mem.startsWith(u8, import_path, "std.")) {
            try self.process_std_import(node, import_path);
        } else {
            try self.process_local_import(node, import_path);
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
    fn process_std_import(self: *Self, import_node: ast.Node, import_path: []const u8) TranspileError!void {
        var header_name: []const u8 = undefined;

        if (mem.eql(u8, import_path, "std.io") or mem.eql(u8, import_path, "std.c.io")) {
            header_name = self.allocator.dupe(u8, "stdio.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else if (mem.eql(u8, import_path, "std.mem") or mem.eql(u8, import_path, "std.c.mem")) {
            header_name = self.allocator.dupe(u8, "stdlib.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else if (mem.eql(u8, import_path, "std.string") or mem.eql(u8, import_path, "std.c.string")) {
            header_name = self.allocator.dupe(u8, "string.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else if (mem.eql(u8, import_path, "std.math") or mem.eql(u8, import_path, "std.c.math")) {
            header_name = self.allocator.dupe(u8, "math.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else if (mem.eql(u8, import_path, "std.ctype") or mem.eql(u8, import_path, "std.c.ctype")) {
            header_name = self.allocator.dupe(u8, "ctype.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else if (mem.eql(u8, import_path, "std.time") or mem.eql(u8, import_path, "std.c.time")) {
            header_name = self.allocator.dupe(u8, "time.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else if (mem.eql(u8, import_path, "std.limits") or mem.eql(u8, import_path, "std.c.limits")) {
            header_name = self.allocator.dupe(u8, "limits.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else if (mem.eql(u8, import_path, "std.stdint") or mem.eql(u8, import_path, "std.c.stdint")) {
            header_name = self.allocator.dupe(u8, "stdint.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else if (mem.eql(u8, import_path, "std.stddef") or mem.eql(u8, import_path, "std.c.stddef")) {
            header_name = self.allocator.dupe(u8, "stddef.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else if (mem.eql(u8, import_path, "std.errno") or mem.eql(u8, import_path, "std.c.errno")) {
            header_name = self.allocator.dupe(u8, "errno.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else {
            self.report_error(import_node, "Unsupported standard library import: {s}", .{import_path});
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
    fn process_local_import(self: *Self, import_node: ast.Node, import_path: []const u8) GeneralError!void {
        // Get full path of the file to import
        // This is a temporary helper string; keep it off the arena.
        var file_path = std.ArrayList(u8).init(self.backing_allocator);
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

        // Convert dotted imports to a path. Additionally, support parent traversal via dot runs:
        // - `.`  => path separator
        // - `..` => `../` (one parent)
        // - `....` => `../../` (two parents)
        var i: usize = 0;
        while (i < import_path.len) {
            if (import_path[i] != '.') {
                file_path.append(import_path[i]) catch |e| {
                    std.debug.print("Failed to allocate memory for file path: {s}\\n", .{@errorName(e)});
                    return TranspileError.MemoryAllocationFailed;
                };
                i += 1;
                continue;
            }

            var j = i;
            while (j < import_path.len and import_path[j] == '.') : (j += 1) {}
            const run_len = j - i;
            const parents = run_len / 2;
            const sep = (run_len % 2) == 1;

            var p: usize = 0;
            while (p < parents) : (p += 1) {
                file_path.appendSlice("..") catch |e| {
                    std.debug.print("Failed to allocate memory for file path: {s}\\n", .{@errorName(e)});
                    return TranspileError.MemoryAllocationFailed;
                };
                file_path.append('/') catch |e| {
                    std.debug.print("Failed to allocate memory for file path: {s}\\n", .{@errorName(e)});
                    return TranspileError.MemoryAllocationFailed;
                };
            }
            if (sep) {
                file_path.append('/') catch |e| {
                    std.debug.print("Failed to allocate memory for file path: {s}\\n", .{@errorName(e)});
                    return TranspileError.MemoryAllocationFailed;
                };
            }

            i = j;
        }

        file_path.appendSlice(".fn") catch |e| {
            std.debug.print("Failed to allocate memory for file path: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
        const full_path = file_path.toOwnedSlice() catch |e| {
            std.debug.print("Failed to allocate memory for file path: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
        errdefer self.backing_allocator.free(full_path);
        defer self.backing_allocator.free(full_path);

        // Add a comment showing the import attempt
        try self.write("\n/* Attempting to import: ");
        try self.write(full_path);
        try self.write(" */\n");

        // Check if the file exists
        std.fs.cwd().access(full_path, .{}) catch {
            // Keep the output comment (useful when dumping partial output), but also
            // emit a real diagnostic tied to the import statement.
            try self.write("\n/* ERROR: Import file not found: ");
            try self.write(full_path);
            try self.write(" */\n");

            self.report_error(import_node, "Import file not found: {s}", .{full_path});
            return TranspileError.ImportFileNotFound;
        };

        // Robust direct circular dependency detection
        // First, check if the file being imported already has us in its import chain
        const file_contents = fs.cwd().readFileAlloc(self.backing_allocator, full_path, 1024 * 1024) catch |read_err| {
            self.report_error(import_node, "Failed to read import file '{s}': {any}", .{ full_path, read_err });
            return TranspileError.FileReadError;
        };
        defer self.backing_allocator.free(file_contents);

        // Check if the file imports us directly (crude but effective)
        const our_name = std.fs.path.stem(self.input_file_path);
        var import_line = std.ArrayList(u8).init(self.backing_allocator);
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

            self.report_error(import_node, "CIRCULAR IMPORT DETECTED: '{s}' imports '{s}', but '{s}' also imports '{s}', creating a circular dependency", .{ basename1, basename2, basename2, basename1 });
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

        // Create and initialize child transpile process.
        // The child process struct itself must be backing-allocated so the parent
        // can safely destroy it after `child.deinit()`.
        var import_proc = self.backing_allocator.create(TranspileProcess) catch |e| {
            std.debug.print("Failed to allocate memory for import process: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
        errdefer self.backing_allocator.destroy(import_proc);

        import_proc.* = try TranspileProcess.init(self.backing_allocator, full_path, "temp.c", .{ .outf = false });

        import_proc.parent = self;
        import_proc.is_importing = true;

        // Copy the import chain and add the current import for tracking
        for (self.import_chain.items) |chain_path| {
            const chain_path_copy = import_proc.allocator.dupe(u8, chain_path) catch |e| {
                std.debug.print("Failed to allocate memory for import chain copy: {s}\\n", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
            errdefer import_proc.allocator.free(chain_path_copy);

            import_proc.import_chain.append(chain_path_copy) catch |e| {
                std.debug.print("Failed to allocate memory for import chain: {s}\\n", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        }
        const import_path_copy = import_proc.allocator.dupe(u8, full_path) catch |e| {
            std.debug.print("Failed to allocate memory for import path copy: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
        errdefer import_proc.allocator.free(import_path_copy);

        import_proc.import_chain.append(import_path_copy) catch |e| {
            std.debug.print("Failed to allocate memory for import chain: {s}\\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };

        // Copy imported files to child
        var it = self.imported_files.iterator();
        while (it.next()) |entry| {
            const imported_file_copy = import_proc.allocator.dupe(u8, entry.key_ptr.*) catch |e| {
                std.debug.print("Failed to allocate memory for imported file copy: {s}\\n", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
            errdefer import_proc.allocator.free(imported_file_copy);

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

fn is_known_extern_function_name(name: []const u8) bool {
    return mem.eql(u8, name, "printf") or
        mem.eql(u8, name, "fprintf") or
        mem.eql(u8, name, "sprintf") or
        mem.eql(u8, name, "snprintf") or
        mem.eql(u8, name, "scanf") or
        mem.eql(u8, name, "sscanf") or
        mem.eql(u8, name, "puts") or
        mem.eql(u8, name, "putchar") or
        mem.eql(u8, name, "getchar") or
        mem.eql(u8, name, "fopen") or
        mem.eql(u8, name, "freopen") or
        mem.eql(u8, name, "fclose") or
        mem.eql(u8, name, "fflush") or
        mem.eql(u8, name, "fgetc") or
        mem.eql(u8, name, "fputc") or
        mem.eql(u8, name, "fgets") or
        mem.eql(u8, name, "fputs") or
        mem.eql(u8, name, "fread") or
        mem.eql(u8, name, "fwrite") or
        mem.eql(u8, name, "fseek") or
        mem.eql(u8, name, "ftell") or
        mem.eql(u8, name, "rewind") or
        mem.eql(u8, name, "feof") or
        mem.eql(u8, name, "ferror") or
        mem.eql(u8, name, "perror") or
        mem.eql(u8, name, "remove") or
        mem.eql(u8, name, "rename") or
        mem.eql(u8, name, "tmpfile") or
        mem.eql(u8, name, "tmpnam");
}

fn typeRegistryRoot(proc: *TranspileProcess) ?*TypeRegistry {
    const root = proc.get_root() orelse proc;
    if (root.type_registry) |*reg| return reg;
    return null;
}
