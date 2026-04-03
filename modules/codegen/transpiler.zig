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

    /// Error indicating a field/member access is syntactically/semantically invalid.
    InvalidFieldAccess,
    /// Error indicating a named type does not have a requested field.
    UnknownField,

    /// Error indicating invalid inline assembly usage.
    InvalidAsm,

    /// Error indicating an invalid `sizeof(...)` usage.
    InvalidSizeof,
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

    /// Error indicating an expected warning annotation was not fulfilled.
    UnmetWarningExpectation,
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
    is_public: bool,
};

const ImplKey = struct {
    type_name: []const u8,
    quirk_sig: []const u8,
};

const GenericSpec = struct {
    cnode: *ast.Node,
    dt: *const dtype.DataType,
    mangled: []const u8,
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

    /// Maps `enum` names to their defining heap node.
    enums_by_name: std.StringHashMap(*ast.Node),

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

    /// Owned allocations for registry-internal keys (quirk signatures, alias-qualified names).
    owned_keys: std.ArrayList([]const u8),

    pub fn init(allocator: mem.Allocator) TypeRegistry {
        return .{
            .allocator = allocator,
            .enums_by_name = std.StringHashMap(*ast.Node).init(allocator),
            .compounds_by_name = std.StringHashMap(*ast.Node).init(allocator),
            .quirk_sig_by_name = std.StringHashMap([]const u8).init(allocator),
            .quirks_by_sig = std.StringHashMap(*ast.Node).init(allocator),
            .quirk_hash_by_sig = std.StringHashMap(u64).init(allocator),
            .impls_by_key = std.HashMap(ImplKey, *ast.Node, ImplKeyContext, 80).init(allocator),
            .owned_keys = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *TypeRegistry) void {
        self.enums_by_name.deinit();
        self.compounds_by_name.deinit();
        self.quirk_sig_by_name.deinit();
        self.quirks_by_sig.deinit();
        self.quirk_hash_by_sig.deinit();
        self.impls_by_key.deinit();
        for (self.owned_keys.items) |key| {
            self.allocator.free(key);
        }
        self.owned_keys.deinit();
    }
};

pub const TranspileProcess = struct {
    /// Transpilation flags for this process.
    flags: TranspileProcessFlags,

    /// Current token position for diagnostics.
    pos: token.Pos,

    /// Input/output file handles.
    ifile: fs.File,
    ofile: ?fs.File,
    outbuf: ?std.ArrayList(u8),

    /// Token and node storage.
    tokens: utils.Vector(token.Token),
    nodes: utils.Vector(ast.Node),
    warnings: std.ArrayList(u8),
    pending_warning_allows: std.ArrayList(PendingWarningControl),
    pending_warning_expects: std.ArrayList(PendingWarningControl),
    owned_nodes: std.ArrayList(*ast.Node),
    owned_scope_entities: std.ArrayList(*scope.ScopeEntity),
    defer_stack: std.ArrayList(*ast.Node),

    /// Scope tracking.
    scope: ?struct {
        root: ?*scope.Scope,
        current: ?*scope.Scope,
    } = null,

    /// Active symbol tables.
    symbols: struct {
        active_table: ?*symbol.SymbolTable,
        tables: utils.Vector(*symbol.SymbolTable),
    },

    /// Arena allocator used for most allocations.
    allocator: mem.Allocator,

    /// Current indentation level (4 spaces per level).
    indent_level: u32 = 0,

    /// Generic type substitution during emission.
    type_subst_params: ?*const utils.Vector(std.ArrayList(u8)) = null,
    type_subst_args: ?[]*dtype.DataType = null,

    /// Optional override for specialized function names during emission.
    override_fn_name: ?[]const u8 = null,

    /// Track if we're emitting function params/body.
    in_function_params: bool = false,
    in_function_body: bool = false,
    function_body_depth: usize = 0,
    in_main: bool = false,

    /// Track return type of current function (for warnings).
    current_fn_return: ?CheckedType = null,

    /// Track whether current function is variadic.
    current_fn_is_variadic: bool = false,

    /// Track whether current function is async (for await semantics in typecheck).
    current_fn_is_async: bool = false,

    /// True while inferring the operand of an `await` unary expression.
    in_await_operand_inference: bool = false,

    /// Temp name counter for codegen.
    tmp_counter: usize = 0,

    /// One-time emission guards.
    did_emit_user_types: bool = false,
    did_emit_impls: bool = false,

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

    /// Forced generic instantiations discovered during typecheck.
    forced_generic_instantiations: std.ArrayList(*const dtype.DataType),
    forced_generic_instantiation_keys: std.StringHashMap(bool),

    /// Mangled names of emitted generic compound specializations.
    emitted_generic_spec_keys: std.StringHashMap(bool),

    /// Forced generic function instantiations discovered during typecheck.
    generic_fn_instantiations: std.ArrayList(GenericFnInstantiation),
    generic_fn_instantiation_keys: std.StringHashMap(bool),

    /// Call-site overrides for generic function names (keyed by position).
    generic_call_overrides: std.StringHashMap([]const u8),

    /// Call-site overrides for await lowering (resolved callee + receiver strategy).
    await_call_overrides: std.StringHashMap(AwaitCallOverride),

    /// Import chain to detect circular dependencies
    import_chain: std.ArrayList([]const u8),

    /// Track global symbols across all modules to detect duplicates
    global_symbols: std.StringHashMap(GlobalSymbolInfo),

    /// Import aliases declared in this module (`alias` -> import path).
    import_aliases: std.StringHashMap([]const u8),

    /// Optional override for import alias resolution (used while emitting child modules).
    import_aliases_override: ?*std.StringHashMap([]const u8) = null,

    /// If this process came from an aliased import, the alias namespace.
    import_alias: ?[]const u8 = null,

    /// While emitting child modules, this tracks which module's file path
    /// is currently being emitted (used for symbol qualification).
    emit_input_file_path: ?[]const u8 = null,

    /// While emitting child modules, this tracks the current module process
    /// so identifier emission can resolve local function names.
    emit_module_proc: ?*TranspileProcess = null,

    /// Registry for user-defined types (`compound`/`quirk`/`impl`).
    /// Stored only on the root process; children access it through `get_root()`.
    type_registry: ?TypeRegistry = null,

    /// Parent TranspileProcess if this is a child import process
    parent: ?*TranspileProcess = null,

    /// Child import processes
    children: std.ArrayList(*TranspileProcess),

    /// Standard library imports to be added at the beginning of the output
    std_imports: std.ArrayList([]const u8),

    /// True when `std.c.thread` or `std.c.thread_windows` is imported
    /// anywhere in this module tree.
    /// When set, codegen emits a small Windows compatibility layer that maps
    /// pthread-shaped symbols onto Win32 synchronization/thread primitives.
    requires_thread_compat_layer: bool = false,

    /// The input file path (used for relative path resolution)
    input_file_path: []const u8,

    /// Full source contents of the input file.
    /// Used for exact span-preserving features (e.g. raw asm blocks).
    input_source: []const u8,

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
            const cand_workspace = "stdlib";
            if (dir_exists(cand_workspace)) {
                const abs = std.fs.cwd().realpathAlloc(backing, cand_workspace) catch null;
                if (abs) |p| {
                    defer backing.free(p);
                    return try dupe_arena(a, p);
                }
                return try dupe_arena(a, cand_workspace);
            }

            const cand_install = "zig-out/share/fun";
            if (dir_exists(cand_install)) {
                const abs = std.fs.cwd().realpathAlloc(backing, cand_install) catch null;
                if (abs) |p| {
                    defer backing.free(p);
                    return try dupe_arena(a, p);
                }
                return try dupe_arena(a, cand_install);
            }
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

    fn is_await_dynamic_quirk_dispatch(self: *Self, call_node: ast.Node) bool {
        if (call_node.type != .Expression or call_node.node_variant == null or !mem.eql(u8, call_node.node_variant.?.exp.op, "()")) {
            return false;
        }
        const call = call_node.node_variant.?.exp;
        const callee = call.left orelse return false;
        if (callee.*.type != .Expression or callee.*.node_variant == null or !mem.eql(u8, callee.*.node_variant.?.exp.op, ".")) {
            return false;
        }
        const dot = callee.*.node_variant.?.exp;
        const recv = dot.left orelse return false;
        return self.expr_is_quirk_typed_from_scope(recv.*);
    }

    fn discover_stdlib_dir_near_input(backing: mem.Allocator, a: mem.Allocator, ifilepath: []const u8) TranspileError!?[]const u8 {
        const abs = if (std.fs.path.isAbsolute(ifilepath))
            (backing.dupe(u8, ifilepath) catch return TranspileError.MemoryAllocationFailed)
        else blk: {
            const rp = std.fs.cwd().realpathAlloc(backing, ifilepath) catch return null;
            break :blk rp;
        };
        defer backing.free(abs);

        var cur_dir = std.fs.path.dirname(abs) orelse return null;
        var depth: usize = 0;
        while (depth < 12) : (depth += 1) {
            const cand = try join_alloc(backing, &[_][]const u8{ cur_dir, "stdlib" });
            defer backing.free(cand);
            if (dir_exists(cand)) {
                const resolved = std.fs.cwd().realpathAlloc(backing, cand) catch null;
                if (resolved) |r| {
                    defer backing.free(r);
                    return try dupe_arena(a, r);
                }
                return try dupe_arena(a, cand);
            }

            const parent_opt = std.fs.path.dirname(cur_dir);
            if (parent_opt == null) break;
            const parent = parent_opt.?;
            if (parent.len == cur_dir.len) break;
            cur_dir = parent;
        }

        return null;
    }

    fn normalize_stdlib_dir(backing: mem.Allocator, a: mem.Allocator, candidate: []const u8) TranspileError![]const u8 {
        const candidate_std = try join_alloc(backing, &[_][]const u8{ candidate, "std" });
        defer backing.free(candidate_std);
        if (dir_exists(candidate_std)) {
            return try dupe_arena(a, candidate);
        }

        const base = std.fs.path.basename(candidate);
        if (std.mem.eql(u8, base, "std")) {
            const parent = std.fs.path.dirname(candidate) orelse candidate;
            const parent_std = try join_alloc(backing, &[_][]const u8{ parent, "std" });
            defer backing.free(parent_std);
            if (dir_exists(parent_std)) {
                return try dupe_arena(a, parent);
            }
        }

        return try dupe_arena(a, candidate);
    }

    fn get_root(self: *Self) *Self {
        var cur: *Self = self;
        while (cur.parent) |p| {
            cur = p;
        }
        return cur;
    }

    fn find_process_for_file(self: *Self, filename: []const u8) ?*TranspileProcess {
        if (std.mem.eql(u8, self.input_file_path, filename)) return self;
        const fname_base = std.fs.path.basename(filename);
        if (std.mem.eql(u8, std.fs.path.basename(self.input_file_path), fname_base)) return self;
        for (self.children.items) |child| {
            if (child.find_process_for_file(filename)) |found| return found;
        }
        return null;
    }

    fn find_import_alias_path(self: *Self, alias: []const u8) ?[]const u8 {
        if (self.import_aliases.get(alias)) |p| return p;
        for (self.children.items) |child| {
            if (child.find_import_alias_path(alias)) |p| return p;
        }
        return null;
    }

    fn make_alias_qualified_symbol_name(self: *Self, alias: []const u8, name: []const u8) TranspileError![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        buf.appendSlice(alias) catch return TranspileError.MemoryAllocationFailed;
        buf.appendSlice("__") catch return TranspileError.MemoryAllocationFailed;
        buf.appendSlice(name) catch return TranspileError.MemoryAllocationFailed;
        return buf.toOwnedSlice() catch TranspileError.MemoryAllocationFailed;
    }

    fn register_import_alias(self: *Self, alias: []const u8, import_path: []const u8) TranspileError!void {
        if (self.import_aliases.get(alias)) |existing| {
            if (!mem.eql(u8, existing, import_path)) {
                self.err("Import alias '{s}' already used for '{s}'", .{ alias, existing });
                return TranspileError.DuplicateSymbol;
            }
            return;
        }
        const alias_copy = self.allocator.dupe(u8, alias) catch return TranspileError.MemoryAllocationFailed;
        errdefer self.allocator.free(alias_copy);
        const path_copy = self.allocator.dupe(u8, import_path) catch return TranspileError.MemoryAllocationFailed;
        errdefer self.allocator.free(path_copy);
        self.import_aliases.put(alias_copy, path_copy) catch return TranspileError.MemoryAllocationFailed;
    }

    fn alias_map_for_node(self: *Self, ref_node: ?*const ast.Node) *const std.StringHashMap([]const u8) {
        if (self.import_aliases_override) |m| return m;
        if (ref_node) |n| {
            if (n.pos) |p| {
                const root = self.get_root();
                if (root.find_process_for_file(p.filename)) |proc| {
                    return &proc.import_aliases;
                }
            }
        }
        return &self.import_aliases;
    }

    fn resolve_alias_qualified_symbol_name(self: *Self, ref_node: ?*const ast.Node, alias: []const u8, name: []const u8) TranspileError!?[]const u8 {
        const alias_map = self.alias_map_for_node(ref_node);
        const import_path = alias_map.get(alias);
        if (import_path == null) return null;
        const import_path_unwrapped = import_path.?;
        if (std.mem.startsWith(u8, import_path_unwrapped, "std.c.")) {
            return self.allocator.dupe(u8, name) catch TranspileError.MemoryAllocationFailed;
        }
        return try self.make_alias_qualified_symbol_name(alias, name);
    }

    fn ensure_type_registry(self: *Self) *TypeRegistry {
        const root = self.get_root();
        if (root.type_registry == null) {
            root.type_registry = TypeRegistry.init(root.allocator);
        }
        return &root.type_registry.?;
    }

    fn append_dtype_sig(self: *Self, buf: *std.ArrayList(u8), dt: *const dtype.DataType) TranspileError!void {
        buf.appendSlice(dt.type_str.items) catch {
            return TranspileError.MemoryAllocationFailed;
        };
        if (dt.generic_args) |gargs| {
            buf.append('<') catch return TranspileError.MemoryAllocationFailed;
            for (gargs.items(), 0..) |ga, i| {
                if (i != 0) buf.appendSlice(",") catch return TranspileError.MemoryAllocationFailed;
                try self.append_dtype_sig(buf, ga);
            }
            buf.append('>') catch return TranspileError.MemoryAllocationFailed;
        }
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

            if (m.is_async) {
                buf.appendSlice("async ") catch {
                    return TranspileError.MemoryAllocationFailed;
                };
            }

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
            if (self.is_std_c_signature_node(n)) continue;
            switch (n.type) {
                .Enum => {
                    if (n.node_variant == null) continue;
                    const name = n.node_variant.?.enum_decl.name.items;
                    if (reg.enums_by_name.get(name)) |existing| {
                        if (!self.same_node_file(n, existing)) return TranspileError.DuplicateSymbol;
                        continue;
                    }
                    if (reg.compounds_by_name.contains(name) or reg.quirk_sig_by_name.contains(name)) {
                        return TranspileError.DuplicateSymbol;
                    }
                    reg.enums_by_name.put(name, n) catch {
                        return TranspileError.MemoryAllocationFailed;
                    };

                    if (proc.import_alias) |alias| {
                        const alias_name = try self.make_alias_qualified_symbol_name(alias, name);
                        if (reg.enums_by_name.get(alias_name)) |existing| {
                            if (!self.same_node_file(n, existing)) {
                                self.allocator.free(alias_name);
                                return TranspileError.DuplicateSymbol;
                            }
                            self.allocator.free(alias_name);
                        } else {
                            reg.enums_by_name.put(alias_name, n) catch {
                                self.allocator.free(alias_name);
                                return TranspileError.MemoryAllocationFailed;
                            };
                            reg.owned_keys.append(alias_name) catch {
                                self.allocator.free(alias_name);
                                return TranspileError.MemoryAllocationFailed;
                            };
                        }
                    }
                },
                .Compound => {
                    if (n.node_variant == null) continue;
                    const name = n.node_variant.?.compound.name.items;
                    if (reg.compounds_by_name.get(name)) |existing| {
                        if (!self.same_node_file(n, existing)) return TranspileError.DuplicateSymbol;
                        continue;
                    }
                    reg.compounds_by_name.put(name, n) catch {
                        return TranspileError.MemoryAllocationFailed;
                    };

                    if (proc.import_alias) |alias| {
                        const alias_name = try self.make_alias_qualified_symbol_name(alias, name);
                        if (reg.compounds_by_name.get(alias_name)) |existing| {
                            if (!self.same_node_file(n, existing)) {
                                self.allocator.free(alias_name);
                                return TranspileError.DuplicateSymbol;
                            }
                            self.allocator.free(alias_name);
                        } else {
                            reg.compounds_by_name.put(alias_name, n) catch {
                                self.allocator.free(alias_name);
                                return TranspileError.MemoryAllocationFailed;
                            };
                            reg.owned_keys.append(alias_name) catch {
                                self.allocator.free(alias_name);
                                return TranspileError.MemoryAllocationFailed;
                            };
                        }
                    }
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
                        const existing = gop.value_ptr.*;
                        if (!self.same_node_file(n, existing)) {
                            reg.allocator.free(sig_key_tmp);
                            return TranspileError.DuplicateSymbol;
                        }
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
                    if (reg.quirk_sig_by_name.get(name)) |existing_sig| {
                        const existing_node = reg.quirks_by_sig.get(existing_sig) orelse null;
                        if (existing_node == null or !self.same_node_file(n, existing_node.?)) {
                            return TranspileError.DuplicateSymbol;
                        }
                    } else {
                        reg.quirk_sig_by_name.put(name, sig_key) catch {
                            return TranspileError.MemoryAllocationFailed;
                        };
                    }

                    if (proc.import_alias) |alias| {
                        const alias_name = try self.make_alias_qualified_symbol_name(alias, name);
                        if (reg.quirk_sig_by_name.get(alias_name)) |existing_sig| {
                            const existing_node = reg.quirks_by_sig.get(existing_sig) orelse null;
                            if (existing_node == null or !self.same_node_file(n, existing_node.?)) {
                                self.allocator.free(alias_name);
                                return TranspileError.DuplicateSymbol;
                            }
                            self.allocator.free(alias_name);
                        } else {
                            reg.quirk_sig_by_name.put(alias_name, sig_key) catch {
                                self.allocator.free(alias_name);
                                return TranspileError.MemoryAllocationFailed;
                            };
                            reg.owned_keys.append(alias_name) catch {
                                self.allocator.free(alias_name);
                                return TranspileError.MemoryAllocationFailed;
                            };
                        }
                    }
                },
                .Impl => {
                    // Collected in a second pass after all quirks are known.
                },
                else => {},
            }
        }
    }

    fn collect_type_registry_recursive(self: *Self, proc: *Self, reg: *TypeRegistry) TranspileError!void {
        try self.collect_type_registry_module(proc, reg);
        for (proc.children.items) |child| {
            try self.collect_type_registry_recursive(child, reg);
        }
    }

    fn collect_impls_module(self: *Self, proc: *Self, reg: *TypeRegistry) TranspileError!void {
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
            if (reg.impls_by_key.get(key)) |existing| {
                if (!self.same_node_file(n, existing)) return TranspileError.DuplicateSymbol;
                continue;
            }

            reg.impls_by_key.put(key, n) catch {
                return TranspileError.MemoryAllocationFailed;
            };
        }
    }

    fn collect_impls_recursive(self: *Self, proc: *Self, reg: *TypeRegistry) TranspileError!void {
        try self.collect_impls_module(proc, reg);
        for (proc.children.items) |child| {
            try self.collect_impls_recursive(child, reg);
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
            const base = base_method_name_from_generated(gen) orelse continue;
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

        if (impl_fn.is_async != quirk_sig.is_async) {
            self.report_type_error(
                impl_node.*,
                "impl method '{s}' async modifier mismatch: expected {s}",
                .{ method_name, if (quirk_sig.is_async) "async" else "non-async" },
            );
            return TranspileError.TypeMismatch;
        }

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
        if ((a.generic_args == null) != (b.generic_args == null)) return false;
        if (a.generic_args) |ga| {
            const gb = b.generic_args.?.items();
            const ai = ga.items();
            if (ai.len != gb.len) return false;
            for (ai, 0..) |a_dt, i| {
                if (!dtype_sig_equal(a_dt, gb[i])) return false;
            }
        }
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

    fn base_method_name_from_generated(gen: []const u8) ?[]const u8 {
        // Split on "__" and return the last segment.
        var i: usize = gen.len;
        while (i >= 2) : (i -= 1) {
            if (gen[i - 1] == '_' and gen[i - 2] == '_') {
                return gen[i..];
            }
        }
        return null;
    }

    fn impl_type_params(self: *Self, impl_node: *const ast.Node) ?*const utils.Vector(std.ArrayList(u8)) {
        if (impl_node.node_variant == null) return null;
        const im = &impl_node.node_variant.?.impl;
        if (im.type_params) |*params| return params;
        if (mem.indexOf(u8, im.type_name.items, "__") != null) return null;
        const base = if (mem.indexOf(u8, im.type_name.items, "__")) |idx| im.type_name.items[0..idx] else im.type_name.items;
        const reg = self.root_registry() orelse return null;
        const cnode = reg.compounds_by_name.get(base) orelse return null;
        if (cnode.node_variant == null) return null;
        const c = &cnode.node_variant.?.compound;
        if (c.type_params) |*params| return params;
        return null;
    }

    fn register_generic_instantiation(self: *Self, dt: *const dtype.DataType) TranspileError!void {
        if (dt.generic_args == null) return;
        if (dt.type_str.items.len == 0) return;
        if (@intFromPtr(dt.type_str.items.ptr) == 0) return;
        if (self.dtype_has_unresolved_placeholder(dt)) return;
        const root = self.get_root();
        const key = try self.type_name_mangled(dt);
        if (root.forced_generic_instantiation_keys.contains(key)) {
            self.allocator.free(key);
            return;
        }
        const clone = try self.clone_dtype(dt);
        root.forced_generic_instantiation_keys.put(key, true) catch return TranspileError.MemoryAllocationFailed;
        root.forced_generic_instantiations.append(clone) catch return TranspileError.MemoryAllocationFailed;
    }

    fn register_generic_instantiations_from_dtype(self: *Self, dt: *const dtype.DataType) TranspileError!void {
        if (dt.generic_args == null) {
            if (dt.type_str.items.len > 0 and mem.indexOf(u8, dt.type_str.items, "__") != null) {
                if (try self.dtype_from_mangled_type(dt.type_str.items)) |synthetic| {
                    try self.register_generic_instantiations_from_dtype(synthetic);
                }
            }
            return;
        }
        if (dt.type_str.items.len > 0 and @intFromPtr(dt.type_str.items.ptr) != 0 and !self.dtype_has_unresolved_placeholder(dt)) {
            try self.register_generic_instantiation(dt);
        }
        if (dt.generic_args) |gargs| {
            for (gargs.items()) |ga| {
                try self.register_generic_instantiations_from_dtype(ga);
            }
        }
    }

    fn register_generic_instantiation_from_checked_type(self: *Self, ct: CheckedType) TranspileError!void {
        const name = ct.mangled_name orelse ct.name orelse return;
        if (mem.indexOf(u8, name, "__") == null) return;
        if (try self.dtype_from_mangled_type(name)) |synthetic| {
            try self.register_generic_instantiations_from_dtype(synthetic);
        }
    }

    fn dtype_from_mangled_type(self: *Self, type_name: []const u8) TranspileError!?*dtype.DataType {
        if (mem.indexOf(u8, type_name, "__") == null) return null;
        const reg = self.root_registry() orelse return null;

        var segments = std.ArrayList([]const u8).init(self.allocator);
        defer segments.deinit();
        var it = mem.splitSequence(u8, type_name, "__");
        while (it.next()) |seg| {
            if (seg.len == 0) continue;
            segments.append(seg) catch return TranspileError.MemoryAllocationFailed;
        }
        if (segments.items.len == 0) return null;

        var idx: usize = 0;
        return self.dtype_from_mangled_segments(reg, segments.items, &idx);
    }

    fn dtype_from_mangled_segments(self: *Self, reg: *TypeRegistry, segments: [][]const u8, idx: *usize) TranspileError!?*dtype.DataType {
        if (idx.* >= segments.len) return null;
        const name = segments[idx.*];
        idx.* += 1;

        const out = self.allocator.create(dtype.DataType) catch {
            return TranspileError.MemoryAllocationFailed;
        };
        out.* = .{
            .flags = null,
            .type = .Unknown,
            .type_str = std.ArrayList(u8).init(self.allocator),
            .pointer_depth = 0,
            .array = null,
            .generic_args = null,
        };
        out.type_str.appendSlice(name) catch return TranspileError.MemoryAllocationFailed;

        if (reg.compounds_by_name.get(name)) |cnode| {
            if (cnode.node_variant != null) {
                const c = cnode.node_variant.?.compound;
                if (c.type_params) |params| {
                    if (params.count > 0) {
                        var args = utils.Vector(*dtype.DataType).init(self.allocator);
                        errdefer {
                            for (args.items()) |ga| {
                                ga.type_str.deinit();
                                self.allocator.destroy(ga);
                            }
                            args.deinit();
                        }
                        var i: usize = 0;
                        while (i < params.count) : (i += 1) {
                            const arg_dt = try self.dtype_from_mangled_segments(reg, segments, idx) orelse return null;
                            args.push(arg_dt) catch return TranspileError.MemoryAllocationFailed;
                        }
                        out.generic_args = args;
                    }
                }
            }
        }

        return out;
    }

    fn add_spec_from_dtype(self: *Self, registry: *TypeRegistry, dt: *const dtype.DataType, spec_keys: *std.StringHashMap(bool), specs: *std.ArrayList(GenericSpec)) TranspileError!void {
        var use_dt: *const dtype.DataType = dt;
        if (use_dt.generic_args == null and use_dt.type_str.items.len > 0 and mem.indexOf(u8, use_dt.type_str.items, "__") != null) {
            if (try self.dtype_from_mangled_type(use_dt.type_str.items)) |synthetic| {
                use_dt = synthetic;
            }
        }
        if (use_dt.generic_args == null) return;
        if (self.dtype_has_unresolved_placeholder(use_dt)) return;

        const dep_base = if (mem.indexOf(u8, use_dt.type_str.items, "__")) |idx| use_dt.type_str.items[0..idx] else use_dt.type_str.items;
        const dep_cnode = registry.compounds_by_name.get(dep_base) orelse return;
        if (dep_cnode.node_variant == null) return;
        const dep_params = dep_cnode.node_variant.?.compound.type_params orelse return;
        if (use_dt.generic_args == null) return;
        if (use_dt.generic_args.?.items().len != dep_params.count) return;

        const dep_mangled = try self.type_name_mangled(use_dt);
        if (self.mangled_contains_unresolved_placeholder(dep_mangled)) {
            self.allocator.free(dep_mangled);
            return;
        }
        const spec_dt = (try self.dtype_from_mangled_type(dep_mangled)) orelse use_dt;
        if (!spec_keys.contains(dep_mangled)) {
            spec_keys.put(dep_mangled, true) catch return TranspileError.MemoryAllocationFailed;
            specs.append(.{ .cnode = dep_cnode, .dt = spec_dt, .mangled = dep_mangled }) catch {
                return TranspileError.MemoryAllocationFailed;
            };
        } else {
            self.allocator.free(dep_mangled);
        }
    }

    fn add_specs_from_dtype(self: *Self, registry: *TypeRegistry, dt: *const dtype.DataType, spec_keys: *std.StringHashMap(bool), specs: *std.ArrayList(GenericSpec)) TranspileError!void {
        try self.add_spec_from_dtype(registry, dt, spec_keys, specs);
        if (dt.generic_args) |gargs| {
            for (gargs.items()) |ga| {
                try self.add_specs_from_dtype(registry, ga, spec_keys, specs);
            }
        }
    }

    fn add_specs_from_body(self: *Self, registry: *TypeRegistry, body: *const ast.Node, spec_keys: *std.StringHashMap(bool), specs: *std.ArrayList(GenericSpec)) TranspileError!void {
        if (body.type != .Body or body.node_variant == null) return;
        const stmts = body.node_variant.?.body.statements;
        for (stmts.items()) |stmt_ptr| {
            const stmt = stmt_ptr.*;
            switch (stmt.type) {
                .Variable => {
                    const v = stmt.node_variant.?.variable;
                    try self.add_specs_from_dtype(registry, v.type, spec_keys, specs);
                },
                .StatementIf => {
                    const ifs = stmt.node_variant.?.statement.if_stmt;
                    try self.add_specs_from_body(registry, ifs.body, spec_keys, specs);
                },
                .StatementElseIf => {
                    const elif = stmt.node_variant.?.statement.elif_stmt;
                    try self.add_specs_from_body(registry, elif.body, spec_keys, specs);
                },
                .StatementElse => {
                    const els = stmt.node_variant.?.statement.else_stmt;
                    try self.add_specs_from_body(registry, els.body, spec_keys, specs);
                },
                .StatementFit => {
                    const fit = stmt.node_variant.?.statement.fit_stmt;
                    for (fit.branches.items()) |br| {
                        try self.add_specs_from_body(registry, br.body, spec_keys, specs);
                    }
                },
                .StatementFor => {
                    const f = stmt.node_variant.?.statement.for_stmt;
                    switch (f) {
                        .cond => |fc| try self.add_specs_from_body(registry, fc.body, spec_keys, specs),
                        .iter => |fi| try self.add_specs_from_body(registry, fi.body, spec_keys, specs),
                        .range => |fr| try self.add_specs_from_body(registry, fr.body, spec_keys, specs),
                    }
                },
                else => {},
            }
        }
    }

    fn add_specs_from_node(self: *Self, registry: *TypeRegistry, node: *ast.Node, spec_keys: *std.StringHashMap(bool), specs: *std.ArrayList(GenericSpec)) TranspileError!void {
        switch (node.type) {
            .Function => if (node.node_variant) |f| {
                if (f.function.rtype) |*rt| try self.add_specs_from_dtype(registry, rt, spec_keys, specs);
                if (f.function.args) |args| {
                    for (args.items()) |a| {
                        if (a.node_variant) |av| {
                            try self.add_specs_from_dtype(registry, av.variable.type, spec_keys, specs);
                        }
                    }
                }
            },
            else => {},
        }
    }

    fn add_specs_from_nodes_recursive(self: *Self, proc: *Self, registry: *TypeRegistry, spec_keys: *std.StringHashMap(bool), specs: *std.ArrayList(GenericSpec)) TranspileError!void {
        for (proc.nodes.items()) |*node| {
            try self.add_specs_from_node(registry, node, spec_keys, specs);
        }
        for (proc.owned_nodes.items) |node_ptr| {
            try self.add_specs_from_node(registry, node_ptr, spec_keys, specs);
        }
        for (proc.children.items) |child| {
            try self.add_specs_from_nodes_recursive(child, registry, spec_keys, specs);
        }
    }

    fn register_generic_instantiations_in_body(self: *Self, body: *const ast.Node) TranspileError!void {
        if (body.type != .Body or body.node_variant == null) return;
        const stmts = body.node_variant.?.body.statements;
        for (stmts.items()) |stmt_ptr| {
            const stmt = stmt_ptr.*;
            switch (stmt.type) {
                .Variable => if (stmt.node_variant) |v| {
                    try self.register_generic_instantiations_from_dtype(v.variable.type);
                },
                .StatementIf => if (stmt.node_variant) |sv| {
                    try self.register_generic_instantiations_in_body(sv.statement.if_stmt.body);
                },
                .StatementElseIf => if (stmt.node_variant) |sv| {
                    try self.register_generic_instantiations_in_body(sv.statement.elif_stmt.body);
                },
                .StatementElse => if (stmt.node_variant) |sv| {
                    try self.register_generic_instantiations_in_body(sv.statement.else_stmt.body);
                },
                .StatementFit => if (stmt.node_variant) |sv| {
                    const fit = sv.statement.fit_stmt;
                    for (fit.branches.items()) |br| {
                        try self.register_generic_instantiations_in_body(br.body);
                    }
                },
                .StatementFor => if (stmt.node_variant) |sv| {
                    const f = sv.statement.for_stmt;
                    switch (f) {
                        .cond => |fc| try self.register_generic_instantiations_in_body(fc.body),
                        .iter => |fi| try self.register_generic_instantiations_in_body(fi.body),
                        .range => |fr| try self.register_generic_instantiations_in_body(fr.body),
                    }
                },
                else => {},
            }
        }
    }

    fn seed_forced_generic_instantiations_from_signatures_module(self: *Self, proc: *Self) TranspileError!void {
        for (proc.nodes.items()) |node| {
            switch (node.type) {
                .Variable => if (node.node_variant) |v| try self.register_generic_instantiations_from_dtype(v.variable.type),
                .Compound => if (node.node_variant) |c| {
                    for (c.compound.fields.items()) |f| {
                        try self.register_generic_instantiations_from_dtype(f.dtype);
                    }
                },
                .Function => if (node.node_variant) |f| {
                    if (f.function.rtype) |*rt| try self.register_generic_instantiations_from_dtype(rt);
                    if (f.function.args) |args| {
                        for (args.items()) |a| {
                            if (a.node_variant) |av| {
                                try self.register_generic_instantiations_from_dtype(av.variable.type);
                            }
                        }
                    }
                    if (f.function.body) |body| {
                        try self.register_generic_instantiations_in_body(body);
                    }
                },
                .Impl => if (node.node_variant) |iv| {
                    const im = iv.impl;
                    for (im.methods.items()) |m| {
                        if (m.type != .Function or m.node_variant == null) continue;
                        const fnv = m.node_variant.?.function;
                        if (fnv.rtype) |*rt| try self.register_generic_instantiations_from_dtype(rt);
                        if (fnv.args) |args| {
                            for (args.items()) |a| {
                                if (a.node_variant) |av| {
                                    try self.register_generic_instantiations_from_dtype(av.variable.type);
                                }
                            }
                        }
                        if (fnv.body) |body| {
                            try self.register_generic_instantiations_in_body(body);
                        }
                    }
                },
                else => {},
            }
        }

        for (proc.owned_nodes.items) |node_ptr| {
            const node = node_ptr.*;
            switch (node.type) {
                .Variable => if (node.node_variant) |v| try self.register_generic_instantiations_from_dtype(v.variable.type),
                .Compound => if (node.node_variant) |c| {
                    for (c.compound.fields.items()) |f| {
                        try self.register_generic_instantiations_from_dtype(f.dtype);
                    }
                },
                .Function => if (node.node_variant) |f| {
                    if (f.function.rtype) |*rt| try self.register_generic_instantiations_from_dtype(rt);
                    if (f.function.args) |args| {
                        for (args.items()) |a| {
                            if (a.node_variant) |av| {
                                try self.register_generic_instantiations_from_dtype(av.variable.type);
                            }
                        }
                    }
                    if (f.function.body) |body| {
                        try self.register_generic_instantiations_in_body(body);
                    }
                },
                .Impl => if (node.node_variant) |iv| {
                    const im = iv.impl;
                    for (im.methods.items()) |m| {
                        if (m.type != .Function or m.node_variant == null) continue;
                        const fnv = m.node_variant.?.function;
                        if (fnv.rtype) |*rt| try self.register_generic_instantiations_from_dtype(rt);
                        if (fnv.args) |args| {
                            for (args.items()) |a| {
                                if (a.node_variant) |av| {
                                    try self.register_generic_instantiations_from_dtype(av.variable.type);
                                }
                            }
                        }
                        if (fnv.body) |body| {
                            try self.register_generic_instantiations_in_body(body);
                        }
                    }
                },
                else => {},
            }
        }

        for (proc.children.items) |child| {
            try self.seed_forced_generic_instantiations_from_signatures_module(child);
        }
    }

    fn seed_forced_generic_instantiations_from_signatures(self: *Self) TranspileError!void {
        try self.seed_forced_generic_instantiations_from_signatures_module(self.get_root());
    }

    fn call_pos_key_alloc(self: *Self, p: token.Pos) TranspileError![]const u8 {
        const end_line = if (p.end_line == 0) p.line else p.end_line;
        return std.fmt.allocPrint(self.allocator, "{s}:{d}:{d}:{d}:{d}", .{ p.filename, p.line, p.start_col, end_line, p.end_col }) catch {
            return TranspileError.MemoryAllocationFailed;
        };
    }

    fn call_pos_key_buf(p: token.Pos, buf: []u8) ?[]const u8 {
        const end_line = if (p.end_line == 0) p.line else p.end_line;
        return std.fmt.bufPrint(buf, "{s}:{d}:{d}:{d}:{d}", .{ p.filename, p.line, p.start_col, end_line, p.end_col }) catch null;
    }

    fn lookup_generic_call_override(self: *Self, node: ast.Node) ?[]const u8 {
        const p = node.pos orelse return null;
        var buf: [512]u8 = undefined;
        const key = call_pos_key_buf(p, &buf) orelse return null;
        return self.generic_call_overrides.get(key);
    }

    fn record_await_call_override(
        self: *Self,
        node: ast.Node,
        callee_name: []const u8,
        has_receiver: bool,
        receiver_pass_by_ref: bool,
    ) TranspileError!void {
        const p = node.pos orelse return;
        const key = try self.call_pos_key_alloc(p);
        const gop = self.await_call_overrides.getOrPut(key) catch {
            self.allocator.free(key);
            return TranspileError.MemoryAllocationFailed;
        };
        if (gop.found_existing) {
            self.allocator.free(key);
        }
        gop.value_ptr.* = .{
            .callee_name = callee_name,
            .has_receiver = has_receiver,
            .receiver_pass_by_ref = receiver_pass_by_ref,
        };
    }

    fn lookup_await_call_override(self: *Self, node: ast.Node) ?AwaitCallOverride {
        const p = node.pos orelse return null;
        var buf: [512]u8 = undefined;
        const key = call_pos_key_buf(p, &buf) orelse return null;
        return self.await_call_overrides.get(key);
    }

    const PrintFmtArgKind = enum {
        any,
        str,
        num,
        dec,
        bin,
        chr,
        ptr,
        raw,
    };

    fn escape_printf_literal(buf: *std.ArrayList(u8), s: []const u8) TranspileError!void {
        for (s) |c| {
            switch (c) {
                '"' => buf.appendSlice("\\\"") catch return TranspileError.MemoryAllocationFailed,
                '\\' => buf.appendSlice("\\\\") catch return TranspileError.MemoryAllocationFailed,
                '\n' => buf.appendSlice("\\n") catch return TranspileError.MemoryAllocationFailed,
                '\r' => buf.appendSlice("\\r") catch return TranspileError.MemoryAllocationFailed,
                '\t' => buf.appendSlice("\\t") catch return TranspileError.MemoryAllocationFailed,
                0 => buf.appendSlice("\\0") catch return TranspileError.MemoryAllocationFailed,
                else => buf.append(c) catch return TranspileError.MemoryAllocationFailed,
            }
        }
    }

    fn next_tmp_name(self: *Self, prefix: []const u8) TranspileError![]const u8 {
        var buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "__fun_{s}_{d}", .{ prefix, self.tmp_counter }) catch {
            return TranspileError.MemoryAllocationFailed;
        };
        self.tmp_counter += 1;
        return self.allocator.dupe(u8, name) catch TranspileError.MemoryAllocationFailed;
    }

    fn build_printf_format(fmt: []const u8, out_fmt: *std.ArrayList(u8), kinds: *std.ArrayList(PrintFmtArgKind)) TranspileError!void {
        var i: usize = 0;
        while (i < fmt.len) {
            const c = fmt[i];
            if (c == '{') {
                if (i + 1 < fmt.len and fmt[i + 1] == '{') {
                    out_fmt.append('{') catch return TranspileError.MemoryAllocationFailed;
                    i += 2;
                    continue;
                }
                if (i + 1 < fmt.len and fmt[i + 1] == '}') {
                    out_fmt.appendSlice("%s") catch return TranspileError.MemoryAllocationFailed;
                    kinds.append(.any) catch return TranspileError.MemoryAllocationFailed;
                    i += 2;
                    continue;
                }
                if (i + 4 < fmt.len and fmt[i + 4] == '}') {
                    const a = fmt[i + 1];
                    const b = fmt[i + 2];
                    const d = fmt[i + 3];
                    if (a == 's' and b == 't' and d == 'r') {
                        out_fmt.appendSlice("%s") catch return TranspileError.MemoryAllocationFailed;
                        kinds.append(.str) catch return TranspileError.MemoryAllocationFailed;
                        i += 5;
                        continue;
                    }
                    if (a == 'n' and b == 'u' and d == 'm') {
                        out_fmt.appendSlice("%lld") catch return TranspileError.MemoryAllocationFailed;
                        kinds.append(.num) catch return TranspileError.MemoryAllocationFailed;
                        i += 5;
                        continue;
                    }
                    if (a == 'd' and b == 'e' and d == 'c') {
                        out_fmt.appendSlice("%g") catch return TranspileError.MemoryAllocationFailed;
                        kinds.append(.dec) catch return TranspileError.MemoryAllocationFailed;
                        i += 5;
                        continue;
                    }
                    if (a == 'b' and b == 'i' and d == 'n') {
                        out_fmt.appendSlice("%s") catch return TranspileError.MemoryAllocationFailed;
                        kinds.append(.bin) catch return TranspileError.MemoryAllocationFailed;
                        i += 5;
                        continue;
                    }
                    if (a == 'c' and b == 'h' and d == 'r') {
                        out_fmt.appendSlice("%c") catch return TranspileError.MemoryAllocationFailed;
                        kinds.append(.chr) catch return TranspileError.MemoryAllocationFailed;
                        i += 5;
                        continue;
                    }
                    if (a == 'p' and b == 't' and d == 'r') {
                        out_fmt.appendSlice("%p") catch return TranspileError.MemoryAllocationFailed;
                        kinds.append(.ptr) catch return TranspileError.MemoryAllocationFailed;
                        i += 5;
                        continue;
                    }
                    if (a == 'r' and b == 'a' and d == 'w') {
                        out_fmt.appendSlice("%p") catch return TranspileError.MemoryAllocationFailed;
                        kinds.append(.raw) catch return TranspileError.MemoryAllocationFailed;
                        i += 5;
                        continue;
                    }
                }
            }

            if (c == '}' and i + 1 < fmt.len and fmt[i + 1] == '}') {
                out_fmt.append('}') catch return TranspileError.MemoryAllocationFailed;
                i += 2;
                continue;
            }

            if (c == '%') {
                out_fmt.appendSlice("%%") catch return TranspileError.MemoryAllocationFailed;
            } else {
                out_fmt.append(c) catch return TranspileError.MemoryAllocationFailed;
            }
            i += 1;
        }
    }

    fn emit_print_fmt_literal(self: *Self, node: ast.Node, is_newline: bool, args_node: ?*ast.Node) TranspileError!bool {
        if (args_node == null) return false;

        var args_nodes = std.ArrayList(*ast.Node).init(self.allocator);
        defer args_nodes.deinit();
        try self.flatten_call_args_ptr(args_node.?, &args_nodes);
        if (args_nodes.items.len == 0) return false;

        const fmt_node = args_nodes.items[0].*;
        if (fmt_node.type != .String or fmt_node.data == null) return false;

        const fmt = fmt_node.data.?.sval.items;
        var fmt_out = std.ArrayList(u8).init(self.allocator);
        defer fmt_out.deinit();

        var kinds = std.ArrayList(PrintFmtArgKind).init(self.allocator);
        defer kinds.deinit();

        try build_printf_format(fmt, &fmt_out, &kinds);

        // Keep the optimization only for explicitly typed placeholders.
        // Bare `{}` should use the regular vararg path, which handles mixed argument kinds.
        for (kinds.items) |k| {
            if (k == .any) return false;
        }

        if (is_newline) {
            fmt_out.append('\n') catch return TranspileError.MemoryAllocationFailed;
        }

        const expected_args = kinds.items.len;
        const provided_args = if (args_nodes.items.len > 0) args_nodes.items.len - 1 else 0;
        if (provided_args != expected_args) {
            self.report_error(node, "print_fmt expects {d} arguments, got {d}", .{ expected_args, provided_args });
            return true;
        }

        var escaped = std.ArrayList(u8).init(self.allocator);
        defer escaped.deinit();
        try escape_printf_literal(&escaped, fmt);

        const vec_name = try self.next_tmp_name("fmt_args");
        const out_name = try self.next_tmp_name("fmt_out");

        try self.write("{ ");
        try self.write("Vec__str ");
        try self.write(vec_name);
        try self.write("; ");
        try self.write(vec_name);
        try self.write(".len = ");
        try self.print("{d}", .{expected_args});
        try self.write("; ");
        try self.write(vec_name);
        try self.write(".cap = ");
        try self.print("{d}", .{expected_args});
        try self.write("; ");

        if (expected_args > 0) {
            try self.write(vec_name);
            try self.write(".data = (char**)malloc(sizeof(char*) * ");
            try self.print("{d}", .{expected_args});
            try self.write("); ");

            var arg_i: usize = 0;
            while (arg_i < expected_args) : (arg_i += 1) {
                const kind = kinds.items[arg_i];
                const arg_node = args_nodes.items[arg_i + 1].*;
                try self.write(vec_name);
                try self.write(".data[");
                try self.print("{d}", .{arg_i});
                try self.write("] = ");
                switch (kind) {
                    .any => unreachable,
                    .str => try self.transpile_node(arg_node),
                    .num => {
                        try self.write("fmt_num((long long)(");
                        try self.transpile_node(arg_node);
                        try self.write("))");
                    },
                    .dec => {
                        try self.write("fmt_dec((double)(");
                        try self.transpile_node(arg_node);
                        try self.write("))");
                    },
                    .bin => {
                        try self.write("fmt_bin((bool)(");
                        try self.transpile_node(arg_node);
                        try self.write("))");
                    },
                    .chr => {
                        try self.write("fmt_chr((char)(");
                        try self.transpile_node(arg_node);
                        try self.write("))");
                    },
                    .ptr, .raw => {
                        try self.write("fmt_raw((void*)(");
                        try self.transpile_node(arg_node);
                        try self.write("))");
                    },
                }
                try self.write("; ");
            }
        } else {
            try self.write(vec_name);
            try self.write(".data = NULL; ");
        }

        try self.write("char* ");
        try self.write(out_name);
        try self.write(" = format_impl(\"");
        try self.write(escaped.items);
        try self.write("\", &");
        try self.write(vec_name);
        try self.write("); ");

        try self.write("if (");
        try self.write(out_name);
        try self.write(") { ");
        if (is_newline) {
            try self.write("puts(");
            try self.write(out_name);
            try self.write("); ");
        } else {
            try self.write("printf(\"%s\", ");
            try self.write(out_name);
            try self.write("); ");
        }
        try self.write("free(");
        try self.write(out_name);
        try self.write("); }");

        if (expected_args > 0) {
            var free_i: usize = 0;
            while (free_i < expected_args) : (free_i += 1) {
                const kind = kinds.items[free_i];
                if (kind == .str) continue;
                try self.write(" free(");
                try self.write(vec_name);
                try self.write(".data[");
                try self.print("{d}", .{free_i});
                try self.write("]); ");
            }
            try self.write(" free(");
            try self.write(vec_name);
            try self.write(".data);");
        }

        try self.write(" }");
        return true;
    }

    fn emit_format_literal(self: *Self, node: ast.Node, args_node: ?*ast.Node) TranspileError!bool {
        if (args_node == null) return false;

        var args_nodes = std.ArrayList(*ast.Node).init(self.allocator);
        defer args_nodes.deinit();
        try self.flatten_call_args_ptr(args_node.?, &args_nodes);
        if (args_nodes.items.len == 0) return false;

        const fmt_node = args_nodes.items[0].*;
        if (fmt_node.type != .String or fmt_node.data == null) return false;

        const fmt = fmt_node.data.?.sval.items;
        var fmt_out = std.ArrayList(u8).init(self.allocator);
        defer fmt_out.deinit();

        var kinds = std.ArrayList(PrintFmtArgKind).init(self.allocator);
        defer kinds.deinit();

        try build_printf_format(fmt, &fmt_out, &kinds);

        // Keep the optimization only for explicitly typed placeholders.
        // Bare `{}` should use the regular vararg path, which handles mixed argument kinds.
        for (kinds.items) |k| {
            if (k == .any) return false;
        }

        const expected_args = kinds.items.len;
        const provided_args = if (args_nodes.items.len > 0) args_nodes.items.len - 1 else 0;
        if (provided_args != expected_args) {
            self.report_error(node, "format expects {d} arguments, got {d}", .{ expected_args, provided_args });
            return true;
        }

        var escaped = std.ArrayList(u8).init(self.allocator);
        defer escaped.deinit();
        try escape_printf_literal(&escaped, fmt);

        const vec_name = try self.next_tmp_name("fmt_args");
        const out_name = try self.next_tmp_name("fmt_out");

        try self.write("({ ");
        try self.write("Vec__str ");
        try self.write(vec_name);
        try self.write("; ");
        try self.write(vec_name);
        try self.write(".len = ");
        try self.print("{d}", .{expected_args});
        try self.write("; ");
        try self.write(vec_name);
        try self.write(".cap = ");
        try self.print("{d}", .{expected_args});
        try self.write("; ");

        if (expected_args > 0) {
            try self.write(vec_name);
            try self.write(".data = (char**)malloc(sizeof(char*) * ");
            try self.print("{d}", .{expected_args});
            try self.write("); ");

            var arg_i: usize = 0;
            while (arg_i < expected_args) : (arg_i += 1) {
                const kind = kinds.items[arg_i];
                const arg_node = args_nodes.items[arg_i + 1].*;
                try self.write(vec_name);
                try self.write(".data[");
                try self.print("{d}", .{arg_i});
                try self.write("] = ");
                switch (kind) {
                    .any => unreachable,
                    .str => try self.transpile_node(arg_node),
                    .num => {
                        try self.write("fmt_num((long long)(");
                        try self.transpile_node(arg_node);
                        try self.write("))");
                    },
                    .dec => {
                        try self.write("fmt_dec((double)(");
                        try self.transpile_node(arg_node);
                        try self.write("))");
                    },
                    .bin => {
                        try self.write("fmt_bin((bool)(");
                        try self.transpile_node(arg_node);
                        try self.write("))");
                    },
                    .chr => {
                        try self.write("fmt_chr((char)(");
                        try self.transpile_node(arg_node);
                        try self.write("))");
                    },
                    .ptr, .raw => {
                        try self.write("fmt_raw((void*)(");
                        try self.transpile_node(arg_node);
                        try self.write("))");
                    },
                }
                try self.write("; ");
            }
        } else {
            try self.write(vec_name);
            try self.write(".data = NULL; ");
        }

        try self.write("char* ");
        try self.write(out_name);
        try self.write(" = format_impl(\"");
        try self.write(escaped.items);
        try self.write("\", &");
        try self.write(vec_name);
        try self.write("); ");

        if (expected_args > 0) {
            var free_i: usize = 0;
            while (free_i < expected_args) : (free_i += 1) {
                const kind = kinds.items[free_i];
                if (kind == .str) continue;
                try self.write(" free(");
                try self.write(vec_name);
                try self.write(".data[");
                try self.print("{d}", .{free_i});
                try self.write("]); ");
            }
            try self.write(" free(");
            try self.write(vec_name);
            try self.write(".data);");
        }

        try self.write(" ");
        try self.write(out_name);
        try self.write("; })");
        return true;
    }

    fn base_type_name(t: CheckedType) ?[]const u8 {
        if (t.base == .Unknown) return t.name;
        return switch (t.base) {
            .Void => "void",
            .Raw => "raw",
            .Chr => "chr",
            .Str => "str",
            .Dec => "dec",
            .Num => "num",
            .Bin => "bin",
            .Unknown => null,
        };
    }

    fn checked_type_to_dtype(self: *Self, t: CheckedType) TranspileError!?*dtype.DataType {
        const name = base_type_name(t) orelse return null;
        const out = self.allocator.create(dtype.DataType) catch {
            return TranspileError.MemoryAllocationFailed;
        };
        out.* = .{
            .flags = null,
            .type = t.base,
            .type_str = std.ArrayList(u8).init(self.allocator),
            .pointer_depth = t.pointer_depth,
            .array = null,
            .generic_args = null,
        };
        if (t.is_array) {
            var flags = out.flags orelse dtype.DataTypeFlags{};
            flags.is_array = true;
            out.flags = flags;
        }
        out.type_str.appendSlice(name) catch return TranspileError.MemoryAllocationFailed;
        return out;
    }

    fn alloc_simple_dtype(self: *Self, name: []const u8) TranspileError!*dtype.DataType {
        const out = self.allocator.create(dtype.DataType) catch {
            return TranspileError.MemoryAllocationFailed;
        };
        out.* = .{
            .flags = null,
            .type = .Unknown,
            .type_str = std.ArrayList(u8).init(self.allocator),
            .pointer_depth = 0,
            .array = null,
            .generic_args = null,
        };
        out.type_str.appendSlice(name) catch return TranspileError.MemoryAllocationFailed;
        return out;
    }

    fn clone_dtype(self: *Self, dt: *const dtype.DataType) TranspileError!*dtype.DataType {
        if (dt.array != null) return TranspileError.TypeMismatch;

        const out = self.allocator.create(dtype.DataType) catch {
            return TranspileError.MemoryAllocationFailed;
        };
        out.* = dt.*;
        out.type_str = std.ArrayList(u8).init(self.allocator);
        out.type_str.appendSlice(dt.type_str.items) catch return TranspileError.MemoryAllocationFailed;
        out.generic_args = null;

        if (dt.generic_args) |gargs| {
            var out_args = utils.Vector(*dtype.DataType).init(self.allocator);
            errdefer {
                for (out_args.items()) |ga| {
                    ga.type_str.deinit();
                    self.allocator.destroy(ga);
                }
                out_args.deinit();
            }
            for (gargs.items()) |ga| {
                const ga_copy = try self.clone_dtype(ga);
                out_args.push(ga_copy) catch return TranspileError.MemoryAllocationFailed;
            }
            out.generic_args = out_args;
        }

        return out;
    }

    fn validate_compound_init(self: *Self, init_node: ast.Node, dt: *dtype.DataType, env: *TypeEnv, fns: *const std.StringHashMap(FnSig)) TranspileError!void {
        if (dt.pointer_depth != 0 or (dt.flags != null and dt.flags.?.is_array)) {
            self.report_type_error(init_node, "compound initializer expects a non-pointer, non-array compound type", .{});
            return TranspileError.TypeMismatch;
        }

        try self.ensure_dtype_visible(init_node, dt, env.type_params);

        const root = self.root_registry() orelse {
            self.report_type_error(init_node, "unknown compound type", .{});
            return TranspileError.SymbolNotDefined;
        };
        const base_name = if (mem.indexOf(u8, dt.type_str.items, "__")) |idx| dt.type_str.items[0..idx] else dt.type_str.items;
        const cnode = root.compounds_by_name.get(base_name) orelse {
            self.report_type_error(init_node, "type '{s}' is not a compound", .{base_name});
            return TranspileError.TypeMismatch;
        };
        if (!self.can_access(&init_node, cnode)) {
            self.report_type_error(init_node, "type '{s}' is private", .{base_name});
            return TranspileError.SymbolNotDefined;
        }

        const cdef = cnode.node_variant.?.compound;
        const params = cdef.type_params;
        const gargs = if (dt.generic_args) |ga| ga.items() else null;
        if (params != null) {
            const pcount = params.?.count;
            const gcount = if (gargs) |ga| ga.len else 0;
            if (pcount != gcount) {
                self.report_type_error(init_node, "compound initializer generic arg count mismatch", .{});
                return TranspileError.TypeMismatch;
            }
        }
        if (dt.generic_args != null) {
            try self.register_generic_instantiation(dt);
        }

        var seen = std.StringHashMap(bool).init(self.allocator);
        defer seen.deinit();

        const ci = init_node.node_variant.?.compound_init;
        for (ci.fields.items()) |field| {
            if (seen.contains(field.name.items)) {
                self.report_type_error(init_node, "duplicate field '{s}' in compound initializer", .{field.name.items});
                return TranspileError.TypeMismatch;
            }
            seen.put(field.name.items, true) catch return TranspileError.MemoryAllocationFailed;

            var fdt: ?*dtype.DataType = null;
            for (cdef.fields.items()) |f| {
                if (mem.eql(u8, f.name.items, field.name.items)) {
                    fdt = f.dtype;
                    break;
                }
            }
            if (fdt == null) {
                self.report_type_error(init_node, "unknown field '{s}' in compound initializer", .{field.name.items});
                return TranspileError.UnknownField;
            }

            const expected = if (params != null and gargs != null)
                try self.type_from_dtype_with_subst(fdt.?, params.?, gargs.?)
            else
                try self.type_from_dtype_with_mangled(fdt.?);

            if (field.value.*.type == .CompoundInit) {
                try self.bind_compound_init_expected(field.value, expected, env, fns);
            }
            if (self.expected_enum_name(expected)) |enum_name| {
                if (dot_shorthand_variant_name(field.value)) |_| {
                    _ = try self.resolve_dot_shorthand_enum_variant(field.value, enum_name);
                }
            }

            const actual = try self.infer_expr_type(field.value.*, env, fns);
            if (is_known_type(expected) and is_known_type(actual) and !(try self.can_implicit_coerce(expected, actual))) {
                self.report_type_error(init_node, "type mismatch for field '{s}' in compound initializer", .{field.name.items});
                return TranspileError.TypeMismatch;
            }
        }
    }

    fn bind_compound_init_expected(self: *Self, init_node: *ast.Node, expected: CheckedType, env: *TypeEnv, fns: *const std.StringHashMap(FnSig)) TranspileError!void {
        if (init_node.type != .CompoundInit or init_node.node_variant == null) return;
        const ci = &init_node.node_variant.?.compound_init;
        if (ci.dtype == null) {
            if (expected.dtype_ref) |dt| {
                if (dt.pointer_depth != 0 or (dt.flags != null and dt.flags.?.is_array)) {
                    self.report_type_error(init_node.*, "compound initializer expects a non-pointer, non-array compound type", .{});
                    return TranspileError.TypeMismatch;
                }
                ci.dtype = try self.clone_dtype(dt);
            } else if (expected.name) |name| {
                const dt = self.allocator.create(dtype.DataType) catch {
                    return TranspileError.MemoryAllocationFailed;
                };
                dt.* = .{
                    .flags = null,
                    .type = .Unknown,
                    .type_str = std.ArrayList(u8).init(self.allocator),
                    .pointer_depth = 0,
                    .array = null,
                    .generic_args = null,
                };
                dt.type_str.appendSlice(name) catch return TranspileError.MemoryAllocationFailed;
                ci.dtype = dt;
            } else {
                return;
            }
        }

        if (ci.dtype) |dt| {
            try self.validate_compound_init(init_node.*, dt, env, fns);
        }
    }

    fn make_vec_str_dtype(self: *Self) TranspileError!*dtype.DataType {
        const dt_str = self.allocator.create(dtype.DataType) catch {
            return TranspileError.MemoryAllocationFailed;
        };
        dt_str.* = .{
            .flags = null,
            .type = .Str,
            .type_str = std.ArrayList(u8).init(self.allocator),
            .pointer_depth = 0,
            .array = null,
            .generic_args = null,
        };
        dt_str.type_str.appendSlice("str") catch return TranspileError.MemoryAllocationFailed;

        var gargs = utils.Vector(*dtype.DataType).init(self.allocator);
        gargs.push(dt_str) catch return TranspileError.MemoryAllocationFailed;

        const dt_vec = self.allocator.create(dtype.DataType) catch {
            return TranspileError.MemoryAllocationFailed;
        };
        dt_vec.* = .{
            .flags = null,
            .type = .Unknown,
            .type_str = std.ArrayList(u8).init(self.allocator),
            .pointer_depth = 0,
            .array = null,
            .generic_args = gargs,
        };
        dt_vec.type_str.appendSlice("Vec") catch return TranspileError.MemoryAllocationFailed;
        return dt_vec;
    }

    fn clone_dtype_with_ptr_adjust(self: *Self, dt: *const dtype.DataType, new_ptr_depth: usize) TranspileError!*dtype.DataType {
        const out = self.allocator.create(dtype.DataType) catch {
            return TranspileError.MemoryAllocationFailed;
        };
        out.* = dt.*;
        out.pointer_depth = new_ptr_depth;
        if (new_ptr_depth > 0) {
            var flags = out.flags orelse dtype.DataTypeFlags{};
            flags.is_pointer = true;
            out.flags = flags;
        }
        out.type_str = std.ArrayList(u8).init(self.allocator);
        out.type_str.appendSlice(dt.type_str.items) catch return TranspileError.MemoryAllocationFailed;
        return out;
    }

    fn dtype_equiv(a: *const dtype.DataType, b: *const dtype.DataType) bool {
        if (a.pointer_depth != b.pointer_depth) return false;
        if ((a.flags != null and a.flags.?.is_array) != (b.flags != null and b.flags.?.is_array)) return false;
        const a_name = a.type_str.items;
        const b_name = b.type_str.items;
        if (!mem.eql(u8, a_name, b_name)) return false;
        if ((a.generic_args == null) != (b.generic_args == null)) return false;
        if (a.generic_args) |ag| {
            const bg = b.generic_args.?.items();
            if (ag.items().len != bg.len) return false;
            for (ag.items(), 0..) |ga, i| {
                if (!dtype_equiv(ga, bg[i])) return false;
            }
        }
        return true;
    }

    fn bind_generic_param(self: *Self, expected: *const dtype.DataType, actual: *const dtype.DataType, params: *const utils.Vector(std.ArrayList(u8)), out: *std.StringHashMap(*dtype.DataType)) TranspileError!bool {
        // Type param match.
        if ((expected.type == null or expected.type == .Unknown) and expected.type_str.items.len > 0) {
            for (params.items()) |p| {
                if (mem.eql(u8, p.items, expected.type_str.items)) {
                    if (actual.pointer_depth < expected.pointer_depth) return false;
                    const adj_ptr = actual.pointer_depth - expected.pointer_depth;
                    const adj = if (expected.pointer_depth == 0) @constCast(actual) else try self.clone_dtype_with_ptr_adjust(actual, adj_ptr);
                    if (out.get(p.items)) |existing| {
                        if (!dtype_equiv(existing, adj)) return false;
                    } else {
                        out.put(p.items, adj) catch return TranspileError.MemoryAllocationFailed;
                    }
                    return true;
                }
            }
        }

        // Non-param: ensure base matches.
        if (expected.pointer_depth != actual.pointer_depth) return false;
        if ((expected.flags != null and expected.flags.?.is_array) != (actual.flags != null and actual.flags.?.is_array)) return false;
        if (expected.type != null and expected.type != .Unknown) {
            if (expected.type != actual.type) return false;
        } else {
            if (!mem.eql(u8, expected.type_str.items, actual.type_str.items)) return false;
        }

        if (expected.generic_args) |eg| {
            const ag = actual.generic_args orelse return false;
            if (eg.items().len != ag.items().len) return false;
            for (eg.items(), 0..) |egv, i| {
                if (!(try self.bind_generic_param(egv, ag.items()[i], params, out))) return false;
            }
        }
        return true;
    }

    fn mangle_generic_fn_name(self: *Self, fname: []const u8, gargs: []*dtype.DataType) TranspileError![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();
        buf.appendSlice(fname) catch return TranspileError.MemoryAllocationFailed;
        for (gargs) |ga| {
            buf.appendSlice("__") catch return TranspileError.MemoryAllocationFailed;
            try self.append_mangled_type(&buf, ga);
        }
        return buf.toOwnedSlice() catch return TranspileError.MemoryAllocationFailed;
    }

    fn register_generic_fn_instantiation(self: *Self, fn_node: *ast.Node, params: *const utils.Vector(std.ArrayList(u8)), gargs: []*dtype.DataType, name: []const u8) TranspileError!void {
        const root = self.get_root();
        var key_buf = std.ArrayList(u8).init(self.allocator);
        defer key_buf.deinit();
        key_buf.appendSlice(name) catch return TranspileError.MemoryAllocationFailed;
        const key = key_buf.toOwnedSlice() catch return TranspileError.MemoryAllocationFailed;
        if (root.generic_fn_instantiation_keys.contains(key)) {
            self.allocator.free(key);
            return;
        }
        root.generic_fn_instantiation_keys.put(key, true) catch return TranspileError.MemoryAllocationFailed;
        root.generic_fn_instantiations.append(.{
            .fn_node = fn_node,
            .params = params,
            .args = gargs,
            .name = name,
        }) catch return TranspileError.MemoryAllocationFailed;
    }

    fn append_quirk_method_stub_sig(self: *Self, buf: *std.ArrayList(u8), m: ast.QuirkMethodSig) TranspileError!void {
        if (m.is_async) {
            buf.appendSlice("async ") catch return TranspileError.MemoryAllocationFailed;
        }
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

        try self.collect_type_registry_recursive(self, new_reg);

        // Second pass: impls need quirk name->signature resolution.
        try self.collect_impls_recursive(self, new_reg);
    }

    fn has_compound_named(proc: *Self, name: []const u8) bool {
        for (proc.owned_nodes.items) |n| {
            if (n.type != .Compound or n.node_variant == null) continue;
            if (mem.eql(u8, n.node_variant.?.compound.name.items, name)) return true;
        }
        for (proc.children.items) |child| {
            if (has_compound_named(child, name)) return true;
        }
        return false;
    }

    fn has_quirk_named(proc: *Self, name: []const u8) bool {
        for (proc.owned_nodes.items) |n| {
            if (n.type != .Quirk or n.node_variant == null) continue;
            if (mem.eql(u8, n.node_variant.?.quirk.name.items, name)) return true;
        }
        for (proc.children.items) |child| {
            if (has_quirk_named(child, name)) return true;
        }
        return false;
    }

    fn find_fn_defining_decl(self: *Self, kind_kw: []const u8, name: []const u8) !?[]u8 {
        // Best-effort: scan workspace files for a `compound <Name>` or `quirk <Name>` declaration.
        // Returns a backing-allocator owned relative path like `parent/child/some.fn`.
        var matches = std.ArrayList([]u8).init(self.backing_allocator);
        defer {
            for (matches.items) |m| self.backing_allocator.free(m);
            matches.deinit();
        }

        var root_dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
        defer root_dir.close();
        var walker = try root_dir.walk(self.backing_allocator);
        defer walker.deinit();

        var pat_buf: [256]u8 = undefined;
        const pat = try std.fmt.bufPrint(&pat_buf, "{s} {s}", .{ kind_kw, name });

        while (try walker.next()) |entry| {
            // Skip generated/vendor trees.
            if (mem.startsWith(u8, entry.path, ".zig-cache") or mem.startsWith(u8, entry.path, "zig-out") or mem.startsWith(u8, entry.path, ".git") or mem.startsWith(u8, entry.path, "stdlib")) {
                continue;
            }
            if (entry.kind != .file) continue;
            if (!mem.endsWith(u8, entry.path, ".fn")) continue;

            var f = try root_dir.openFile(entry.path, .{});
            defer f.close();
            const contents = f.readToEndAlloc(self.backing_allocator, 512 * 1024) catch continue;
            defer self.backing_allocator.free(contents);

            if (mem.indexOf(u8, contents, pat) == null) continue;
            try matches.append(try self.backing_allocator.dupe(u8, entry.path));
            if (matches.items.len > 1) break;
        }

        if (matches.items.len != 1) return null;
        return try self.backing_allocator.dupe(u8, matches.items[0]);
    }

    fn process_local_import_full_path(self: *Self, full_path: []const u8, import_alias: ?[]const u8) GeneralError!void {
        // Minimal variant of `process_local_import()` that takes a resolved `.fn` path.
        // Used for auto-importing type definitions so entrypoint scripts can run unchanged.

        const canon_path = std.fs.cwd().realpathAlloc(self.allocator, full_path) catch null;
        const canon = canon_path orelse (self.allocator.dupe(u8, full_path) catch return TranspileError.MemoryAllocationFailed);
        errdefer self.allocator.free(canon);

        // Avoid duplicate imports.
        if (self.imported_files.contains(canon)) {
            self.allocator.free(canon);
            return;
        }

        std.fs.cwd().access(canon, .{}) catch {
            self.report_error(null, "Import file not found: {s}", .{full_path});
            return TranspileError.ImportFileNotFound;
        };

        self.imported_files.put(canon, true) catch |e| {
            std.debug.print("Failed to allocate memory for imported file: {s}\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };

        var import_proc = self.backing_allocator.create(TranspileProcess) catch |e| {
            std.debug.print("Failed to allocate memory for import process: {s}\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
        errdefer self.backing_allocator.destroy(import_proc);

        import_proc.* = try TranspileProcess.init_with_stdlib_dir(self.backing_allocator, canon, "temp.c", .{ .outf = false }, self.stdlib_dir);
        import_proc.parent = self;
        import_proc.is_importing = true;
        if (import_alias) |alias| {
            import_proc.import_alias = import_proc.allocator.dupe(u8, alias) catch return TranspileError.MemoryAllocationFailed;
        }

        // Copy imported files to child (prevents duplicate imports across branches).
        var it = self.imported_files.iterator();
        while (it.next()) |entry| {
            const imported_file_copy = import_proc.allocator.dupe(u8, entry.key_ptr.*) catch |e| {
                std.debug.print("Failed to allocate memory for imported file copy: {s}\n", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
            errdefer import_proc.allocator.free(imported_file_copy);
            import_proc.imported_files.put(imported_file_copy, true) catch |e| {
                std.debug.print("Failed to allocate memory for imported file: {s}\n", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        }

        for (self.import_chain.items) |chain_path| {
            const chain_path_copy = import_proc.allocator.dupe(u8, chain_path) catch |e| {
                std.debug.print("Failed to allocate memory for import chain copy: {s}\n", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
            errdefer import_proc.allocator.free(chain_path_copy);
            import_proc.import_chain.append(chain_path_copy) catch |e| {
                std.debug.print("Failed to allocate memory for import chain: {s}\n", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        }

        const import_path_copy = import_proc.allocator.dupe(u8, canon) catch |e| {
            std.debug.print("Failed to allocate memory for import path copy: {s}\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
        errdefer import_proc.allocator.free(import_path_copy);
        import_proc.import_chain.append(import_path_copy) catch |e| {
            std.debug.print("Failed to allocate memory for import chain: {s}\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };

        var lex_proc = lexer.LexProcess.init(import_proc);
        var parse_proc = parser.ParseProcess.init(import_proc);
        try lex_proc.lex();
        try parse_proc.parse();

        for (import_proc.nodes.items()) |node| {
            if (node.type == .Import) {
                try import_proc.process_import(node);
            }
        }

        try import_proc.sync_global_symbols_to_parent();

        self.children.append(import_proc) catch |e| {
            std.debug.print("Failed to allocate memory for child process: {s}\n", .{@errorName(e)});
            return TranspileError.MemoryAllocationFailed;
        };
    }

    fn collect_user_type_refs_in_body(self: *Self, body: *ast.Node, out: *std.StringHashMap(bool)) TranspileError!void {
        if (body.type != .Body or body.node_variant == null) return;
        const stmts = body.node_variant.?.body.statements;
        for (stmts.items()) |stmt_ptr| {
            const stmt = stmt_ptr.*;
            switch (stmt.type) {
                .Variable => {
                    const v = stmt.node_variant.?.variable;
                    const dt = v.type;
                    if (dt.type == .Unknown and dt.type_str.items.len != 0) {
                        out.put(dt.type_str.items, true) catch return TranspileError.MemoryAllocationFailed;
                    }
                },
                .StatementIf => {
                    const ifs = stmt.node_variant.?.statement.if_stmt;
                    try self.collect_user_type_refs_in_body(ifs.body, out);
                },
                .StatementElseIf => {
                    const elif = stmt.node_variant.?.statement.elif_stmt;
                    try self.collect_user_type_refs_in_body(elif.body, out);
                },
                .StatementElse => {
                    const els = stmt.node_variant.?.statement.else_stmt;
                    try self.collect_user_type_refs_in_body(els.body, out);
                },
                .StatementFit => {
                    const fit = stmt.node_variant.?.statement.fit_stmt;
                    for (fit.branches.items()) |br| {
                        try self.collect_user_type_refs_in_body(br.body, out);
                    }
                },
                .StatementFor => {
                    const f = stmt.node_variant.?.statement.for_stmt;
                    switch (f) {
                        .cond => |fc| try self.collect_user_type_refs_in_body(fc.body, out),
                        .iter => |fi| try self.collect_user_type_refs_in_body(fi.body, out),
                        .range => |fr| try self.collect_user_type_refs_in_body(fr.body, out),
                    }
                },
                else => {},
            }
        }
    }

    fn auto_import_missing_user_types(self: *Self) GeneralError!void {
        // Scan root file for referenced user-defined types (e.g. `Data data;`, `impl Data Display`).
        // If a referenced type isn't currently defined in the import graph, try to find a unique
        // declaration in the workspace and import that file automatically.

        var refs = std.StringHashMap(bool).init(self.backing_allocator);
        defer refs.deinit();

        // Root nodes
        for (self.nodes.items()) |n| {
            switch (n.type) {
                .Variable => {
                    if (n.node_variant == null) continue;
                    const v = n.node_variant.?.variable;
                    const dt = v.type;
                    if (dt.type == .Unknown and dt.type_str.items.len != 0) {
                        refs.put(dt.type_str.items, true) catch return TranspileError.MemoryAllocationFailed;
                    }
                },
                .Function => {
                    if (n.node_variant == null) continue;
                    const f = n.node_variant.?.function;
                    if (f.args) |args| {
                        for (args.items()) |arg| {
                            if (arg.type != .Variable or arg.node_variant == null) continue;
                            const dt = arg.node_variant.?.variable.type;
                            if (dt.type == .Unknown and dt.type_str.items.len != 0) {
                                refs.put(dt.type_str.items, true) catch return TranspileError.MemoryAllocationFailed;
                            }
                        }
                    }
                    if (f.rtype) |rt| {
                        if (rt.type == .Unknown and rt.type_str.items.len != 0) {
                            refs.put(rt.type_str.items, true) catch return TranspileError.MemoryAllocationFailed;
                        }
                    }
                    if (f.body) |b| {
                        try self.collect_user_type_refs_in_body(b, &refs);
                    }
                },
                .Impl => {
                    if (n.node_variant == null) continue;
                    const im = n.node_variant.?.impl;
                    if (im.type_name.items.len != 0) {
                        refs.put(im.type_name.items, true) catch return TranspileError.MemoryAllocationFailed;
                    }
                    if (im.quirk_name) |qn| {
                        if (qn.items.len != 0) refs.put(qn.items, true) catch return TranspileError.MemoryAllocationFailed;
                    }
                },
                else => {},
            }
        }

        var it = refs.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;

            // Skip builtins.
            if (mem.eql(u8, name, "num") or mem.eql(u8, name, "dec") or mem.eql(u8, name, "str") or mem.eql(u8, name, "chr") or mem.eql(u8, name, "bin") or mem.eql(u8, name, "raw") or mem.eql(u8, name, "void")) {
                continue;
            }

            // If the type already exists in the current import graph, nothing to do.
            if (has_compound_named(self, name) or has_quirk_named(self, name)) continue;

            // Prefer compounds; if not found, try quirks.
            if (self.find_fn_defining_decl("compound", name) catch null) |path| {
                defer self.backing_allocator.free(path);
                try self.process_local_import_full_path(path, null);
                continue;
            }
            if (self.find_fn_defining_decl("quirk", name) catch null) |path| {
                defer self.backing_allocator.free(path);
                try self.process_local_import_full_path(path, null);
                continue;
            }
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
    pub fn preload_import_global_symbols(self: *Self, import_node: ast.Node, import_path: []const u8, import_alias: ?[]const u8) GeneralError!void {
        if (!self.flags.preload_imports) return;
        if (std.mem.indexOf(u8, import_path, "std.") != null) return;

        const full_path = try self.build_full_import_path(import_path);
        defer self.backing_allocator.free(full_path);

        const canon_path = std.fs.cwd().realpathAlloc(self.allocator, full_path) catch null;
        const canon = canon_path orelse (self.allocator.dupe(u8, full_path) catch return TranspileError.MemoryAllocationFailed);
        defer self.allocator.free(canon);

        std.fs.cwd().access(canon, .{}) catch {
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

        var import_proc = try TranspileProcess.init_with_stdlib_dir(self.backing_allocator, canon, "temp.c", .{ .exec = false, .outf = false, .ast = false }, self.stdlib_dir);
        defer import_proc.deinit();

        var lex_proc = lexer.LexProcess.init(&import_proc);
        defer lex_proc.deinit();
        try lex_proc.lex();

        const tokens = import_proc.tokens.items();
        var i: usize = 0;
        while (i < tokens.len) : (i += 1) {
            const t = tokens[i];
            if (t.type != .Keyword) continue;

            var is_public = false;
            var decl_kind: ?[]const u8 = null;
            if (mem.eql(u8, t.data.sval.items, "pub")) {
                var j: usize = i + 1;
                while (j < tokens.len and token.is_nl_or_comment_or_newline_separator(tokens[j])) : (j += 1) {}
                if (j >= tokens.len) continue;
                if (tokens[j].type != .Keyword) continue;

                const kw = tokens[j].data.sval.items;
                if (!mem.eql(u8, kw, "fun") and !mem.eql(u8, kw, "compound") and !mem.eql(u8, kw, "enum") and !mem.eql(u8, kw, "quirk")) continue;

                is_public = true;
                decl_kind = kw;
                i = j; // continue parsing as `fun`
            } else {
                continue;
            }

            var j: usize = i + 1;
            while (j < tokens.len and token.is_nl_or_comment_or_newline_separator(tokens[j])) : (j += 1) {}
            if (j >= tokens.len) continue;

            const name_tok = tokens[j];
            if (name_tok.type != .Identifier) continue;

            const name = name_tok.data.sval.items;
            if (!is_public) continue;
            if (decl_kind != null and mem.eql(u8, decl_kind.?, "fun") and mem.eql(u8, name, "main")) continue;

            const key_name = if (import_alias) |alias|
                (try self.make_alias_qualified_symbol_name(alias, name))
            else
                (self.allocator.dupe(u8, name) catch return TranspileError.MemoryAllocationFailed);
            errdefer self.allocator.free(key_name);

            if (self.global_symbols.get(key_name)) |existing| {
                if (!mem.eql(u8, existing.file_path, canon) and !mem.eql(u8, existing.file_path, self.input_file_path)) {
                    self.err("Symbol '{s}' already defined in module '{s}'", .{ key_name, existing.file_path });
                    return TranspileError.DuplicateSymbol;
                }
            }

            const path_copy = self.allocator.dupe(u8, canon) catch |e| {
                std.debug.print("Error duplicating file path '{any}': {s}\\n", .{ canon, @errorName(e) });
                return TranspileError.MemoryAllocationFailed;
            };
            errdefer self.allocator.free(path_copy);

            self.global_symbols.put(key_name, .{
                .symbol_name = key_name,
                .file_path = path_copy,
                .is_function = decl_kind != null and mem.eql(u8, decl_kind.?, "fun"),
                .is_public = true,
            }) catch |e| {
                std.debug.print("Error registering imported symbol '{any}': {s}\\n", .{ key_name, @errorName(e) });
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
        const ifile = blk: {
            const is_abs = fs.path.isAbsolute(ifilepath) or (@import("builtin").target.os.tag == .windows and ifilepath.len >= 2 and ifilepath[1] == ':');
            if (is_abs) {
                break :blk fs.openFileAbsolute(ifilepath, .{ .mode = input_mode }) catch |e| {
                    std.debug.print("Error opening input file '{s}': {s}\n", .{ ifilepath, @errorName(e) });
                    return TranspileError.FileOpenError;
                };
            }
            break :blk fs.cwd().openFile(ifilepath, .{ .mode = input_mode }) catch |e| {
                std.debug.print("Error opening input file '{s}': {s}\n", .{ ifilepath, @errorName(e) });
                return TranspileError.FileOpenError;
            };
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
            ofile = blk: {
                const is_abs = fs.path.isAbsolute(ofilepath) or (@import("builtin").target.os.tag == .windows and ofilepath.len >= 2 and ofilepath[1] == ':');
                if (is_abs) {
                    break :blk fs.createFileAbsolute(ofilepath, .{ .read = true }) catch |e| {
                        std.debug.print("Error creating output file '{s}': {s}\n", .{ ofilepath, @errorName(e) });
                        return TranspileError.FileOpenError;
                    };
                }
                break :blk fs.cwd().createFile(ofilepath, .{ .read = true }) catch |e| {
                    std.debug.print("Error creating output file '{s}': {s}\n", .{ ofilepath, @errorName(e) });
                    return TranspileError.FileOpenError;
                };
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

        const input_source = blk: {
            const stat = ifile.stat() catch |e| {
                std.debug.print("Error stat'ing input file '{s}': {s}\\n", .{ ifilepath, @errorName(e) });
                return TranspileError.FileReadError;
            };
            const max_bytes_u64: u64 = if (stat.size == 0) 1 else stat.size;
            const max_bytes: usize = @intCast(max_bytes_u64);
            const src = ifile.readToEndAlloc(a, max_bytes) catch |e| {
                std.debug.print("Error reading input file '{s}': {s}\\n", .{ ifilepath, @errorName(e) });
                return TranspileError.FileReadError;
            };
            ifile.seekTo(0) catch |e| {
                std.debug.print("Error rewinding input file '{s}': {s}\\n", .{ ifilepath, @errorName(e) });
                return TranspileError.FileSeekError;
            };
            break :blk src;
        };

        imported_files.put(input_file_path, true) catch |e| {
            std.debug.print("Error adding file '{s}' to imported files: {s}\\n", .{ input_file_path, @errorName(e) });
            return TranspileError.MemoryAllocationFailed;
        }; // Mark current file as imported

        import_chain.append(input_file_path) catch |e| {
            std.debug.print("Error adding initial path '{s}' to import chain: {s}\\n", .{ input_file_path, @errorName(e) });
            return TranspileError.MemoryAllocationFailed;
        };

        const discovered_stdlib_dir_raw: ?[]const u8 = if (stdlib_dir_override) |p|
            p
        else blk: {
            if (try discover_stdlib_dir(allocator, a)) |d| break :blk d;
            break :blk try discover_stdlib_dir_near_input(allocator, a, ifilepath);
        };

        const discovered_stdlib_dir: ?[]const u8 = if (discovered_stdlib_dir_raw) |d|
            (try normalize_stdlib_dir(allocator, a, d))
        else
            null;

        return Self{
            .flags = flags,
            .pos = .{ .col = 1, .line = 1, .start_col = 1, .end_col = 1, .filename = input_file_path },
            .ifile = ifile,
            .ofile = ofile,
            .outbuf = outbuf,
            .tokens = utils.Vector(token.Token).init(a),
            .nodes = utils.Vector(ast.Node).init(a),
            .warnings = std.ArrayList(u8).init(a),
            .pending_warning_allows = std.ArrayList(PendingWarningControl).init(a),
            .pending_warning_expects = std.ArrayList(PendingWarningControl).init(a),
            .owned_nodes = std.ArrayList(*ast.Node).init(a),
            .owned_scope_entities = std.ArrayList(*scope.ScopeEntity).init(a),
            .defer_stack = std.ArrayList(*ast.Node).init(a),
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
            .import_aliases = std.StringHashMap([]const u8).init(a),
            .children = std.ArrayList(*TranspileProcess).init(a),
            .std_imports = std.ArrayList([]const u8).init(a),
            .forced_generic_instantiations = std.ArrayList(*const dtype.DataType).init(a),
            .forced_generic_instantiation_keys = std.StringHashMap(bool).init(a),
            .emitted_generic_spec_keys = std.StringHashMap(bool).init(a),
            .generic_fn_instantiations = std.ArrayList(GenericFnInstantiation).init(a),
            .generic_fn_instantiation_keys = std.StringHashMap(bool).init(a),
            .generic_call_overrides = std.StringHashMap([]const u8).init(a),
            .await_call_overrides = std.StringHashMap(AwaitCallOverride).init(a),
            .input_file_path = input_file_path,
            .input_source = input_source,
            .stdlib_dir = discovered_stdlib_dir,
        };
    }

    fn build_stdlib_module_path(self: *Self, import_path: []const u8) TranspileError!?[]const u8 {
        if (!std.mem.startsWith(u8, import_path, "std.")) return null;
        if (self.stdlib_dir == null) return null;

        // Canonical layout:
        // - `std.c.io` => <stdlib>/std/c/io.fn
        // - `std.io`   => <stdlib>/std/io.fn
        const rel_after_std = import_path["std.".len..];
        const has_c_prefix = std.mem.startsWith(u8, rel_after_std, "c.");
        const rel = if (has_c_prefix) rel_after_std["c.".len..] else rel_after_std;

        const StdPathLayout = enum { c, pure };

        const Builder = struct {
            fn build_with_root(self2: *Self, root: []const u8, rel2: []const u8, layout: StdPathLayout) TranspileError![]const u8 {
                var tmp = std.ArrayList(u8).init(self2.backing_allocator);
                defer tmp.deinit();

                tmp.appendSlice(root) catch return TranspileError.MemoryAllocationFailed;
                tmp.append('/') catch return TranspileError.MemoryAllocationFailed;
                tmp.appendSlice("std") catch return TranspileError.MemoryAllocationFailed;
                tmp.append('/') catch return TranspileError.MemoryAllocationFailed;
                if (layout == .c) {
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

        const layout: StdPathLayout = if (has_c_prefix) .c else .pure;
        const full_path = try Builder.build_with_root(self, self.stdlib_dir.?, rel, layout);
        std.fs.cwd().access(full_path, .{}) catch {
            self.backing_allocator.free(full_path);

            if (try discover_stdlib_dir_near_input(self.backing_allocator, self.allocator, self.input_file_path)) |near| {
                const near_norm = try normalize_stdlib_dir(self.backing_allocator, self.allocator, near);
                if (!std.mem.eql(u8, near_norm, self.stdlib_dir.?)) {
                    const near_path = try Builder.build_with_root(self, near_norm, rel, layout);
                    if (std.fs.cwd().access(near_path, .{})) |_| {
                        self.stdlib_dir = near_norm;
                        return near_path;
                    } else |_| {
                        self.backing_allocator.free(near_path);
                    }
                }
            }

            if (try discover_stdlib_dir(self.backing_allocator, self.allocator)) |auto| {
                const auto_norm = try normalize_stdlib_dir(self.backing_allocator, self.allocator, auto);
                if (!std.mem.eql(u8, auto_norm, self.stdlib_dir.?)) {
                    const auto_path = try Builder.build_with_root(self, auto_norm, rel, layout);
                    if (std.fs.cwd().access(auto_path, .{})) |_| {
                        self.stdlib_dir = auto_norm;
                        return auto_path;
                    } else |_| {
                        self.backing_allocator.free(auto_path);
                    }
                }
            }

            return null;
        };
        return full_path;
    }

    /// Best-effort preload of stdlib signature modules (non-fatal).
    ///
    /// This is for tooling/identifier validation: it allows `imp std.c.*;` (and the `std.*` alias)
    /// source of truth when installed, without changing codegen behavior.
    pub fn preload_std_import_global_symbols(self: *Self, import_node: ast.Node, import_path: []const u8, import_alias: ?[]const u8) void {
        if (!self.flags.preload_std_imports) return;
        const full_path_opt = self.build_stdlib_module_path(import_path) catch return;
        if (full_path_opt == null) return;
        const full_path = full_path_opt.?;
        defer self.backing_allocator.free(full_path);

        std.fs.cwd().access(full_path, .{}) catch return;

        const canon_path = std.fs.cwd().realpathAlloc(self.backing_allocator, full_path) catch null;
        defer if (canon_path) |p| self.backing_allocator.free(p);
        const canon = canon_path orelse full_path;

        var import_proc = TranspileProcess.init_with_stdlib_dir(
            self.backing_allocator,
            canon,
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

            const key_name = if (import_alias) |alias|
                (self.make_alias_qualified_symbol_name(alias, name) catch return)
            else
                (self.allocator.dupe(u8, name) catch return);
            errdefer self.allocator.free(key_name);

            if (self.global_symbols.get(key_name)) |existing| {
                if (!mem.eql(u8, existing.file_path, full_path) and !mem.eql(u8, existing.file_path, self.input_file_path)) {
                    // Keep behavior consistent with local preloading.
                    self.report_error(import_node, "Symbol '{s}' already defined in module '{s}'", .{ key_name, existing.file_path });
                    return;
                }
            }

            const path_copy = self.allocator.dupe(u8, canon) catch return;
            errdefer self.allocator.free(path_copy);

            self.global_symbols.put(key_name, .{
                .symbol_name = key_name,
                .file_path = path_copy,
                .is_function = true,
                .is_public = true,
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

    fn queue_warning_control(self: *Self, action: ast.WarningControlAction, id: ast.WarningId, reason: []const u8, pos: ?token.Pos) TranspileError!void {
        const pending: PendingWarningControl = .{
            .id = id,
            .reason = reason,
            .pos = pos,
        };
        switch (action) {
            .allow => self.pending_warning_allows.append(pending) catch return TranspileError.MemoryAllocationFailed,
            .expect => self.pending_warning_expects.append(pending) catch return TranspileError.MemoryAllocationFailed,
        }
    }

    fn consume_warning_control(self: *Self, id: ast.WarningId) bool {
        for (self.pending_warning_expects.items) |*pending| {
            if (pending.id == id and !pending.matched) {
                pending.matched = true;
                return true;
            }
        }
        for (self.pending_warning_allows.items) |*pending| {
            if (pending.id == id and !pending.matched) {
                pending.matched = true;
                return true;
            }
        }
        return false;
    }

    fn report_warning_expectation_error(self: *Self, pending: PendingWarningControl) void {
        if (!self.flags.emit_stderr) return;
        const stderr = std.io.getStdErr().writer();
        stderr.print("\n[Error]\n", .{}) catch unreachable;
        stderr.print(
            "expected warning '{s}' was not emitted; reason: \"{s}\"",
            .{ ast.warning_id_to_string(pending.id), pending.reason },
        ) catch unreachable;

        if (pending.pos) |p| {
            const end_line = if (p.end_line == 0) p.line else p.end_line;
            if (end_line == p.line) {
                stderr.print("\nLocation: {s}:{d}:{d}-{d}\n", .{ p.filename, p.line, p.start_col, p.end_col }) catch unreachable;
            } else {
                stderr.print("\nLocation: {s}:{d}:{d}-{d}:{d}\n", .{ p.filename, p.line, p.start_col, end_line, p.end_col }) catch unreachable;
            }
            return;
        }

        stderr.print("\nLocation: {s}:{d}:{d}\n", .{ self.pos.filename, self.pos.line, self.pos.col }) catch unreachable;
    }

    fn finalize_warning_expectations(self: *Self) TranspileError!void {
        var has_unmet = false;
        for (self.pending_warning_expects.items) |pending| {
            if (pending.matched) continue;
            has_unmet = true;
            self.report_warning_expectation_error(pending);
        }
        if (has_unmet) return TranspileError.UnmetWarningExpectation;
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

    fn warn_if_returning_address_of_local(self: *Self, ret_expr: ast.Node) void {
        const fn_ret = self.current_fn_return orelse return;
        if (fn_ret.pointer_depth == 0) return;

        if (ret_expr.type != .Unary or ret_expr.node_variant == null) return;
        const unary = ret_expr.node_variant.?.unary;
        if (!mem.eql(u8, unary.op, "&")) return;

        const operand = unary.operand.*;
        if (operand.type != .Identifier or operand.data == null) return;
        const name = operand.data.?.sval.items;

        // Only warn for locals: `get_scope_entity` searches the active scope chain,
        // excluding the global/root scope.
        _ = self.get_scope_entity(name) orelse return;

        self.report_warning(.return_local_ptr, operand, "returning address of local variable '{s}' from a pointer-returning function; this pointer will dangle after return", .{name});
    }

    const CheckedType = struct {
        base: dtype.DataTypeType,
        is_array: bool = false,
        pointer_depth: usize = 0,
        /// True when this value is the integer literal 0 (C null pointer constant).
        is_null_literal: bool = false,
        /// For user-defined types, `base` is `.Unknown` and `name` holds the identifier.
        name: ?[]const u8 = null,
        /// For generic specializations, a mangled name (e.g. Vec__num).
        mangled_name: ?[]const u8 = null,
        /// Optional backing dtype (preserves generic args for named types).
        dtype_ref: ?*const dtype.DataType = null,

        fn eql(a: CheckedType, b: CheckedType) bool {
            if (a.base != b.base) return false;
            if (a.is_array != b.is_array) return false;
            if (a.pointer_depth != b.pointer_depth) return false;
            const a_name = a.mangled_name orelse a.name;
            const b_name = b.mangled_name orelse b.name;
            if (a_name == null and b_name == null) return true;
            if (a_name == null or b_name == null) return false;
            return mem.eql(u8, a_name.?, b_name.?);
        }
    };

    const FnSig = struct {
        rtype: CheckedType,
        args: []CheckedType,
        is_variadic: bool = false,
        is_async: bool = false,
        type_params: ?*const utils.Vector(std.ArrayList(u8)) = null,
    };

    const AwaitLoweringInfo = struct {
        callee_name: []const u8,
        receiver_expr: ?*ast.Node = null,
        receiver_pass_by_ref: bool = false,
    };

    const AwaitCallOverride = struct {
        callee_name: []const u8,
        has_receiver: bool = false,
        receiver_pass_by_ref: bool = false,
    };

    const GenericFnInstantiation = struct {
        fn_node: *ast.Node,
        params: *const utils.Vector(std.ArrayList(u8)),
        args: []*dtype.DataType,
        name: []const u8,
    };

    const PendingWarningControl = struct {
        id: ast.WarningId,
        reason: []const u8,
        pos: ?token.Pos,
        matched: bool = false,
    };

    const TypeEnv = struct {
        allocator: mem.Allocator,
        scopes: std.ArrayList(std.StringHashMap(CheckedType)),
        type_params: ?[]const []const u8 = null,

        fn init(allocator: mem.Allocator) TypeEnv {
            return .{
                .allocator = allocator,
                .scopes = std.ArrayList(std.StringHashMap(CheckedType)).init(allocator),
                .type_params = null,
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

        fn set_type_params(self: *TypeEnv, params: ?[]const []const u8) void {
            self.type_params = params;
        }

        fn has_type_param(self: *TypeEnv, name: []const u8) bool {
            if (self.type_params) |params| {
                for (params) |p| {
                    if (mem.eql(u8, p, name)) return true;
                }
            }
            return false;
        }
    };

    fn report_type_error(self: *Self, node: ?ast.Node, comptime fmt: []const u8, args: anytype) void {
        if (!self.flags.emit_stderr) return;
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

    fn report_warning(self: *Self, id: ast.WarningId, node: ?ast.Node, comptime fmt: []const u8, args: anytype) void {
        if (self.consume_warning_control(id)) return;

        const stderr = std.io.getStdErr().writer();
        if (self.flags.emit_stderr) {
            stderr.print("\n[Warning:{s}]\n", .{ast.warning_id_to_string(id)}) catch unreachable;
            stderr.print(fmt, args) catch unreachable;
        }

        self.warnings.writer().print("\n[Warning:{s}]\n", .{ast.warning_id_to_string(id)}) catch unreachable;
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
            .dtype_ref = dt,
        };
    }

    fn type_from_dtype_with_mangled(self: *Self, dt: *const dtype.DataType) TranspileError!CheckedType {
        var t = type_from_dtype(dt);
        if (dt.type == .Unknown and dt.generic_args != null) {
            t.mangled_name = try self.type_name_mangled(dt);
        }
        return t;
    }

    fn ensure_named_type_visible(self: *Self, ref_node: ast.Node, name: []const u8) TranspileError!void {
        const base_name = if (mem.indexOf(u8, name, "__")) |idx| name[0..idx] else name;
        // Builtins are always visible.
        if (mem.eql(u8, base_name, "void") or mem.eql(u8, base_name, "raw") or mem.eql(u8, base_name, "num") or mem.eql(u8, base_name, "dec") or mem.eql(u8, base_name, "str") or mem.eql(u8, base_name, "bin") or mem.eql(u8, base_name, "chr")) {
            return;
        }

        // Known C typedef aliases are treated as externally visible.
        if (utils.get_c_typedef_alias_datatype_type(base_name) != null) {
            return;
        }

        // Allow stdarg.h variadic type.
        if (mem.eql(u8, base_name, "va_list")) {
            return;
        }

        const reg = self.root_registry() orelse {
            self.report_type_error(ref_node, "unknown type '{s}'", .{name});
            return TranspileError.SymbolNotDefined;
        };

        // Prefer the full name (supports alias-qualified types like `m__User`),
        // then fall back to the base prefix for legacy mangled/derived lookups.
        var names_buf: [2][]const u8 = undefined;
        var names_len: usize = 1;
        names_buf[0] = name;
        if (!mem.eql(u8, name, base_name)) {
            names_buf[1] = base_name;
            names_len = 2;
        }

        for (names_buf[0..names_len]) |cand| {
            if (reg.enums_by_name.get(cand)) |enode| {
                if (!self.can_access(&ref_node, enode)) {
                    self.report_type_error(ref_node, "type '{s}' is private", .{cand});
                    return TranspileError.SymbolNotDefined;
                }
                return;
            }

            if (reg.compounds_by_name.get(cand)) |cnode| {
                if (!self.can_access(&ref_node, cnode)) {
                    self.report_type_error(ref_node, "type '{s}' is private", .{cand});
                    return TranspileError.SymbolNotDefined;
                }
                return;
            }

            if (reg.quirk_sig_by_name.get(cand)) |sig| {
                const qnode = reg.quirks_by_sig.get(sig) orelse null;
                if (qnode == null or qnode.?.node_variant == null) {
                    self.report_type_error(ref_node, "unknown type '{s}'", .{cand});
                    return TranspileError.SymbolNotDefined;
                }
                if (!self.can_access(&ref_node, qnode.?)) {
                    self.report_type_error(ref_node, "type '{s}' is private", .{cand});
                    return TranspileError.SymbolNotDefined;
                }
                return;
            }
        }

        self.report_type_error(ref_node, "unknown type '{s}'", .{name});
        return TranspileError.SymbolNotDefined;
    }

    fn ensure_dtype_visible(self: *Self, ref_node: ast.Node, dt: *const dtype.DataType, allow: ?[]const []const u8) TranspileError!void {
        if ((dt.type == null or dt.type == .Unknown) and dt.type_str.items.len > 0) {
            if (allow) |list| {
                for (list) |p| {
                    if (mem.eql(u8, p, dt.type_str.items)) return;
                }
                if (dt.type_str.items.len == 1) {
                    const c = dt.type_str.items[0];
                    if (c >= 'A' and c <= 'Z') return;
                }
            } else if (dt.type_str.items.len == 1) {
                const c = dt.type_str.items[0];
                if (c >= 'A' and c <= 'Z') return;
            }
            try self.ensure_named_type_visible(ref_node, dt.type_str.items);
        }
        if (dt.generic_args) |gargs| {
            for (gargs.items()) |ga| {
                try self.ensure_dtype_visible(ref_node, ga, allow);
            }
        }
    }

    fn is_known_type(t: CheckedType) bool {
        return t.base != .Unknown or t.name != null;
    }

    fn is_user_named_type(t: CheckedType) bool {
        return t.base == .Unknown and t.name != null;
    }

    fn lookup_receiver_dtype(self: *Self, recv: ast.Node) ?*dtype.DataType {
        if (recv.type == .Identifier and recv.data != null) {
            const name = recv.data.?.sval.items;
            if (self.get_scope_entity(name)) |ent| {
                if (ent.node) |ent_node| {
                    if (ent_node.type == .Variable and ent_node.node_variant != null) {
                        return ent_node.node_variant.?.variable.type;
                    }
                }
            }
        }
        return null;
    }

    fn concrete_type_name(self: *Self, recv: ast.Node, recv_t: CheckedType) TranspileError!?[]const u8 {
        if (!is_user_named_type(recv_t)) return null;
        if (recv_t.mangled_name) |mn| return mn;
        if (recv_t.dtype_ref) |dt| {
            if (dt.generic_args != null) {
                return try self.type_name_mangled(dt);
            }
        } else if (self.lookup_receiver_dtype(recv)) |dt| {
            if (dt.generic_args != null) {
                return try self.type_name_mangled(dt);
            }
        }
        return recv_t.name.?;
    }

    fn expected_enum_name(self: *Self, t: CheckedType) ?[]const u8 {
        if (t.base != .Unknown) return null;
        if (t.pointer_depth != 0 or t.is_array) return null;
        const name = t.name orelse return null;
        const reg = self.root_registry() orelse return null;
        if (!reg.enums_by_name.contains(name)) return null;
        return name;
    }

    fn dot_shorthand_variant_name(node: *ast.Node) ?[]const u8 {
        if (node.type != .Expression or node.node_variant == null) return null;
        const exp = node.node_variant.?.exp;
        if (!mem.eql(u8, exp.op, ".")) return null;
        const left = exp.left orelse return null;
        const right = exp.right orelse return null;
        if (left.*.type != .Blank) return null;
        if (right.*.type != .Identifier or right.*.data == null) return null;
        return right.*.data.?.sval.items;
    }

    const AliasEnumVariantParts = struct {
        alias_name: []const u8,
        enum_name: []const u8,
        variant_name: []const u8,
    };

    fn extract_alias_enum_variant_parts(left: *ast.Node, right: *ast.Node) ?AliasEnumVariantParts {
        // Right-associative parse shape:
        //   alias . (Enum . Variant)
        if (left.*.type == .Identifier and left.*.data != null and right.*.type == .Expression and right.*.node_variant != null and mem.eql(u8, right.*.node_variant.?.exp.op, ".")) {
            const inner = right.*.node_variant.?.exp;
            const enum_node = inner.left orelse return null;
            const variant_node = inner.right orelse return null;
            if (enum_node.*.type == .Identifier and enum_node.*.data != null and variant_node.*.type == .Identifier and variant_node.*.data != null) {
                return .{
                    .alias_name = left.*.data.?.sval.items,
                    .enum_name = enum_node.*.data.?.sval.items,
                    .variant_name = variant_node.*.data.?.sval.items,
                };
            }
        }

        // Left-associative parse shape:
        //   (alias . Enum) . Variant
        if (left.*.type == .Expression and left.*.node_variant != null and mem.eql(u8, left.*.node_variant.?.exp.op, ".") and right.*.type == .Identifier and right.*.data != null) {
            const inner = left.*.node_variant.?.exp;
            const alias_node = inner.left orelse return null;
            const enum_node = inner.right orelse return null;
            if (alias_node.*.type == .Identifier and alias_node.*.data != null and enum_node.*.type == .Identifier and enum_node.*.data != null) {
                return .{
                    .alias_name = alias_node.*.data.?.sval.items,
                    .enum_name = enum_node.*.data.?.sval.items,
                    .variant_name = right.*.data.?.sval.items,
                };
            }
        }

        return null;
    }

    fn resolve_enum_variant_constant_type(self: *Self, node: ast.Node, enum_name: []const u8, variant_name: []const u8) TranspileError!?CheckedType {
        const root = self.get_root();
        if (root.type_registry == null) return null;
        const reg = &root.type_registry.?;
        const enode = reg.enums_by_name.get(enum_name) orelse return null;

        if (!self.can_access(&node, enode)) {
            self.report_type_error(node, "enum '{s}' is private", .{enum_name});
            return TranspileError.SymbolNotDefined;
        }

        if (enode.node_variant != null) {
            var ok = false;
            for (enode.node_variant.?.enum_decl.variants.items()) |v| {
                if (mem.eql(u8, v.name.items, variant_name)) {
                    ok = true;
                    break;
                }
            }
            if (!ok) {
                self.report_type_error(node, "enum '{s}' has no variant '{s}'", .{ enum_name, variant_name });
                return TranspileError.UnknownField;
            }
        }

        return .{ .base = .Unknown, .name = enum_name };
    }

    fn resolve_dot_shorthand_enum_variant(self: *Self, node: *ast.Node, enum_name: []const u8) TranspileError!CheckedType {
        const variant_name = dot_shorthand_variant_name(node) orelse return .{ .base = .Unknown };
        const reg = self.root_registry() orelse return .{ .base = .Unknown };
        const enode = reg.enums_by_name.get(enum_name) orelse {
            self.report_type_error(node.*, "unknown enum '{s}'", .{enum_name});
            return TranspileError.TypeMismatch;
        };
        if (!self.can_access(node, enode)) {
            self.report_type_error(node.*, "enum '{s}' is private", .{enum_name});
            return TranspileError.SymbolNotDefined;
        }
        if (enode.node_variant == null) return .{ .base = .Unknown };

        var ok = false;
        for (enode.node_variant.?.enum_decl.variants.items()) |v| {
            if (mem.eql(u8, v.name.items, variant_name)) {
                ok = true;
                break;
            }
        }
        if (!ok) {
            self.report_type_error(node.*, "enum '{s}' has no variant '{s}'", .{ enum_name, variant_name });
            return TranspileError.UnknownField;
        }

        // Rewrite `.Variant` into `Enum.Variant` by mutating the blank LHS node.
        const left_ptr = node.node_variant.?.exp.left.?;
        // AST nodes are arena-owned; allocate via `self.allocator` to keep ownership consistent.
        var sval = std.ArrayList(u8).init(self.allocator);
        sval.appendSlice(enum_name) catch {
            return TranspileError.MemoryAllocationFailed;
        };
        left_ptr.* = ast.Node{
            .type = .Identifier,
            .pos = left_ptr.*.pos orelse node.pos,
            .data = .{ .sval = sval },
            .binded = null,
            .node_variant = null,
        };

        return .{ .base = .Unknown, .name = enum_name };
    }

    fn infer_let_enum_dot_shorthand(self: *Self, node: *ast.Node) TranspileError!?CheckedType {
        const variant_name = dot_shorthand_variant_name(node) orelse return null;
        const reg = self.root_registry() orelse return null;

        var found_enum: ?[]const u8 = null;

        var it = reg.enums_by_name.iterator();
        while (it.next()) |entry| {
            const enum_name = entry.key_ptr.*;
            const enode = entry.value_ptr.*;
            if (!self.can_access(node, enode)) continue;
            if (enode.node_variant == null) continue;

            var has_variant = false;
            for (enode.node_variant.?.enum_decl.variants.items()) |v| {
                if (mem.eql(u8, v.name.items, variant_name)) {
                    has_variant = true;
                    break;
                }
            }
            if (!has_variant) continue;

            if (found_enum != null) {
                self.report_type_error(node.*, "cannot infer enum for '.{s}'; variant exists in both '{s}' and '{s}'", .{ variant_name, found_enum.?, enum_name });
                return TranspileError.TypeMismatch;
            }

            found_enum = enum_name;
        }

        if (found_enum == null) {
            self.report_type_error(node.*, "cannot infer enum for '.{s}'; no matching enum in scope", .{variant_name});
            return TranspileError.TypeMismatch;
        }

        return try self.resolve_dot_shorthand_enum_variant(node, found_enum.?);
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

    fn canonical_compound_name(self: *Self, name: []const u8) []const u8 {
        const root = self.get_root();
        if (root.type_registry == null) return name;
        const reg = &root.type_registry.?;
        const cnode = reg.compounds_by_name.get(name) orelse return name;
        if (cnode.node_variant == null) return name;
        return cnode.node_variant.?.compound.name.items;
    }

    fn lookup_quirk_method(self: *Self, ref_node: ast.Node, quirk_name: []const u8, method_name: []const u8) ?ast.QuirkMethodSig {
        const root = self.get_root();
        if (root.type_registry == null) return null;
        const reg = &root.type_registry.?;

        const sig = reg.quirk_sig_by_name.get(quirk_name) orelse return null;
        const qnode = reg.quirks_by_sig.get(sig) orelse return null;
        if (qnode.node_variant == null) return null;
        if (!self.can_access(&ref_node, qnode)) return null;
        const methods = qnode.node_variant.?.quirk.methods.items();
        for (methods) |m| {
            if (mem.eql(u8, m.name.items, method_name)) return m;
        }
        return null;
    }

    fn infer_compound_field_access_type(self: *Self, node: ast.Node, base: CheckedType, field_name: []const u8) TranspileError!CheckedType {
        if (!is_user_named_type(base)) {
            self.report_type_error(node, "field access requires a compound-typed value", .{});
            return TranspileError.InvalidFieldAccess;
        }

        const tname = base.name.?;
        const base_name = if (mem.indexOf(u8, tname, "__")) |idx| tname[0..idx] else tname;
        try self.ensure_named_type_visible(node, tname);

        if (base.pointer_depth > 1) {
            self.report_type_error(node, "field access supports at most one pointer indirection", .{});
            return TranspileError.InvalidFieldAccess;
        }

        const fdt = self.lookup_compound_field(tname, field_name) orelse
            (if (!mem.eql(u8, tname, base_name)) self.lookup_compound_field(base_name, field_name) else null) orelse {
            self.report_type_error(node, "type '{s}' has no field '{s}'", .{ tname, field_name });
            return TranspileError.UnknownField;
        };
        return try self.type_from_dtype_with_mangled(fdt);
    }

    fn lookup_plain_impl_method_fn_proc(self: *Self, proc: *Self, ref_node: ?*const ast.Node, type_name: []const u8, method_name: []const u8) ?[]const u8 {
        for (proc.owned_nodes.items) |n| {
            if (n.type != .Impl or n.node_variant == null) continue;
            const im = n.node_variant.?.impl;
            if (im.quirk_name != null) continue; // only plain impl
            if (!mem.eql(u8, im.type_name.items, type_name)) {
                if (self.impl_type_params(n) != null) {
                    const base = if (mem.indexOf(u8, type_name, "__")) |idx| type_name[0..idx] else type_name;
                    if (!mem.eql(u8, im.type_name.items, base)) continue;

                    for (im.methods.items()) |m| {
                        if (m.type != .Function or m.node_variant == null) continue;
                        if (!self.can_access_method(ref_node, n, m)) continue;
                        const fnv = m.node_variant.?.function;
                        if (fnv.name == null) continue;
                        const full = fnv.name.?.items;
                        if (!mem.startsWith(u8, full, im.type_name.items)) continue;
                        const base_name = base_method_name_from_generated(full) orelse continue;
                        if (!mem.eql(u8, base_name, method_name)) continue;

                        return std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ type_name, method_name }) catch null;
                    }
                }
                continue;
            }

            for (im.methods.items()) |m| {
                if (m.type != .Function or m.node_variant == null) continue;
                if (!self.can_access_method(ref_node, n, m)) continue;
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
            if (self.lookup_plain_impl_method_fn_proc(child, ref_node, type_name, method_name)) |n| return n;
        }
        return null;
    }

    fn lookup_plain_impl_method_fn(self: *Self, ref_node: ?*const ast.Node, type_name: []const u8, method_name: []const u8) ?[]const u8 {
        const root = self.get_root();
        return self.lookup_plain_impl_method_fn_proc(root, ref_node, type_name, method_name);
    }

    const PlainImplMethodHit = struct {
        impl_node: *ast.Node,
        method_node: *ast.Node,
    };

    fn find_plain_impl_method_node_proc(self: *Self, proc: *Self, type_base: []const u8, method_name: []const u8) ?PlainImplMethodHit {
        for (proc.owned_nodes.items) |n| {
            if (n.type != .Impl or n.node_variant == null) continue;
            const im = n.node_variant.?.impl;
            if (im.quirk_name != null) continue;
            const base = if (mem.indexOf(u8, im.type_name.items, "__")) |idx| im.type_name.items[0..idx] else im.type_name.items;
            if (!mem.eql(u8, base, type_base)) continue;

            for (im.methods.items()) |m| {
                if (m.type != .Function or m.node_variant == null) continue;
                const fnv = m.node_variant.?.function;
                if (fnv.name == null) continue;
                const full = fnv.name.?.items;
                const base_name = base_method_name_from_generated(full) orelse continue;
                if (!mem.eql(u8, base_name, method_name)) continue;
                return .{ .impl_node = n, .method_node = m };
            }
        }

        for (proc.children.items) |child| {
            if (self.find_plain_impl_method_node_proc(child, type_base, method_name)) |hit| return hit;
        }
        return null;
    }

    fn find_plain_impl_method_node(self: *Self, type_base: []const u8, method_name: []const u8) ?PlainImplMethodHit {
        const root = self.get_root();
        return self.find_plain_impl_method_node_proc(root, type_base, method_name);
    }

    fn synthesize_generic_plain_method_sig(self: *Self, recv_dt: *const dtype.DataType, recv_name: []const u8, method_name: []const u8) ?FnSig {
        if (recv_dt.generic_args == null) return null;
        const base = if (mem.indexOf(u8, recv_name, "__")) |idx| recv_name[0..idx] else recv_name;
        const hit = self.find_plain_impl_method_node(base, method_name) orelse return null;
        if (hit.method_node.node_variant == null) return null;
        const fnv = hit.method_node.node_variant.?.function;
        const params = self.impl_type_params(hit.impl_node) orelse return null;
        const gargs = recv_dt.generic_args.?.items();
        if (gargs.len != params.count) return null;

        const args_vec = fnv.args orelse utils.Vector(*ast.Node).init(self.allocator);
        const args_items = args_vec.items();
        var args_slice = self.allocator.alloc(CheckedType, args_items.len) catch return null;

        var i: usize = 0;
        for (args_items) |arg_ptr| {
            const arg = arg_ptr.*;
            if (arg.type == .Variable and arg.node_variant != null) {
                args_slice[i] = self.type_from_dtype_with_subst(arg.node_variant.?.variable.type, params.*, gargs) catch return null;
            } else {
                args_slice[i] = .{ .base = .Unknown };
            }
            i += 1;
        }

        const rtype = if (fnv.rtype) |rt| self.type_from_dtype_with_subst(&rt, params.*, gargs) catch return null else CheckedType{ .base = .Void };
        return .{ .rtype = rtype, .args = args_slice, .is_variadic = fnv.is_variadic, .is_async = fnv.is_async };
    }

    fn find_function_node_proc(self: *Self, proc: *Self, name: []const u8) ?*ast.Node {
        for (proc.nodes.items()) |*n| {
            if (n.type != .Function or n.node_variant == null) continue;
            const fnv = n.node_variant.?.function;
            if (fnv.name != null and mem.eql(u8, fnv.name.?.items, name)) return n;
        }

        for (proc.owned_nodes.items) |impl_node| {
            if (impl_node.type != .Impl or impl_node.node_variant == null) continue;
            const im = impl_node.node_variant.?.impl;
            for (im.methods.items()) |m| {
                if (m.type != .Function or m.node_variant == null) continue;
                const fnv = m.node_variant.?.function;
                if (fnv.name != null and mem.eql(u8, fnv.name.?.items, name)) return m;
            }
        }

        for (proc.children.items) |child| {
            if (self.find_function_node_proc(child, name)) |found| return found;
        }
        return null;
    }

    fn find_function_node(self: *Self, name: []const u8) ?*ast.Node {
        const root = self.get_root();
        return self.find_function_node_proc(root, name);
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

    const DisplayCallResolution = struct {
        fn_name: []const u8,
        pass_by_ref: bool,
    };

    fn resolve_quirk_impl_method_for_concrete(self: *Self, ref_node: ast.Node, type_name: []const u8, method_name: []const u8) QuirkImplMethodResolution {
        const root = self.get_root();
        if (root.type_registry == null) return .{};
        const reg = &root.type_registry.?;

        const base_name = if (mem.indexOf(u8, type_name, "__")) |idx| type_name[0..idx] else type_name;

        var res: QuirkImplMethodResolution = .{};
        var it = reg.impls_by_key.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const matches_exact = mem.eql(u8, key.type_name, type_name);
            const matches_generic = mem.eql(u8, key.type_name, base_name);
            if (!matches_exact and !matches_generic) continue;

            const impl_node = entry.value_ptr.*;
            if (impl_node.node_variant == null) continue;
            const im = impl_node.node_variant.?.impl;
            if (im.quirk_name == null) continue;

            const qnode = reg.quirks_by_sig.get(key.quirk_sig) orelse continue;
            if (qnode.node_variant == null) continue;
            if (!self.can_access(&ref_node, qnode)) continue;
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
                if (!self.can_access_method(&ref_node, impl_node, m)) continue;
                const fnv = m.node_variant.?.function;
                if (fnv.name == null) continue;
                const full = fnv.name.?.items;
                if (mem.endsWith(u8, full, suf)) {
                    if (matches_exact) {
                        fn_name = full;
                    } else {
                        fn_name = std.fmt.allocPrint(self.allocator, "{s}__{s}__{s}", .{ type_name, qname, method_name }) catch null;
                    }
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

    fn resolve_display_call_for_expr(self: *Self, ref_node: ast.Node, expr: ast.Node) ?DisplayCallResolution {
        if (expr.type == .ExpressionParenthesis and expr.node_variant != null) {
            return self.resolve_display_call_for_expr(ref_node, expr.node_variant.?.paren.exp.*);
        }

        if (expr.type == .Identifier and expr.data != null) {
            const nm = expr.data.?.sval.items;
            const dt = self.identifier_declared_dtype(nm) orelse return null;
            if (dt.type != .Unknown) return null;

            const type_name = dt.type_str.items;
            const type_name_canon = self.canonical_compound_name(type_name);
            const res = self.resolve_quirk_impl_method_for_concrete(ref_node, type_name_canon, "to_string");
            if (res.fn_name == null or res.quirk_name == null or res.ambiguous) return null;
            if (!mem.eql(u8, res.quirk_name.?, "Display")) return null;

            return .{
                .fn_name = res.fn_name.?,
                .pass_by_ref = dt.pointer_depth == 0,
            };
        }

        if (expr.type == .Unary and expr.node_variant != null) {
            const u = expr.node_variant.?.unary;
            if (mem.eql(u8, u.op, "&")) {
                const op = u.operand.*;
                if (op.type != .Identifier or op.data == null) return null;
                const nm = op.data.?.sval.items;
                const dt = self.identifier_declared_dtype(nm) orelse return null;
                if (dt.type != .Unknown) return null;

                const type_name = dt.type_str.items;
                const type_name_canon = self.canonical_compound_name(type_name);
                const res = self.resolve_quirk_impl_method_for_concrete(ref_node, type_name_canon, "to_string");
                if (res.fn_name == null or res.quirk_name == null or res.ambiguous) return null;
                if (!mem.eql(u8, res.quirk_name.?, "Display")) return null;

                return .{
                    .fn_name = res.fn_name.?,
                    .pass_by_ref = false,
                };
            }
        }

        return null;
    }

    fn is_enum_named_type(self: *Self, t: CheckedType) bool {
        if (!is_user_named_type(t)) return false;
        if (t.is_array or t.pointer_depth != 0) return false;
        const root = self.get_root();
        if (root.type_registry == null) return false;
        return root.type_registry.?.enums_by_name.contains(t.name.?);
    }

    fn is_compound_named_type(self: *Self, t: CheckedType) bool {
        if (!is_user_named_type(t)) return false;
        const root = self.get_root();
        if (root.type_registry == null) return false;
        return root.type_registry.?.compounds_by_name.contains(t.name.?);
    }

    fn are_same_enum_type(self: *Self, a: CheckedType, b: CheckedType) bool {
        if (!self.is_enum_named_type(a) or !self.is_enum_named_type(b)) return false;
        const root = self.get_root();
        if (root.type_registry == null) return false;
        const reg = &root.type_registry.?;
        const an = a.name orelse return false;
        const bn = b.name orelse return false;
        const a_node = reg.enums_by_name.get(an) orelse return false;
        const b_node = reg.enums_by_name.get(bn) orelse return false;
        return a_node == b_node;
    }

    fn are_same_compound_type(self: *Self, a: CheckedType, b: CheckedType) bool {
        if (!self.is_compound_named_type(a) or !self.is_compound_named_type(b)) return false;
        if (a.is_array != b.is_array or a.pointer_depth != b.pointer_depth) return false;
        const root = self.get_root();
        if (root.type_registry == null) return false;
        const reg = &root.type_registry.?;
        const an = a.name orelse return false;
        const bn = b.name orelse return false;
        const a_node = reg.compounds_by_name.get(an) orelse return false;
        const b_node = reg.compounds_by_name.get(bn) orelse return false;
        return a_node == b_node;
    }

    fn is_numeric_type(self: *Self, t: CheckedType) bool {
        if (t.is_array or t.pointer_depth != 0) return false;
        if (t.base == .Num or t.base == .Dec or t.base == .Chr) return true;
        return self.is_enum_named_type(t);
    }

    fn is_pointer_type(t: CheckedType) bool {
        return !t.is_array and t.pointer_depth > 0;
    }

    fn promote_numeric_type(a: CheckedType, b: CheckedType) dtype.DataTypeType {
        // Assumes numeric-compatible operands.
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

        // Allow equivalent enum types referenced through different visible names
        // (e.g. `ErrorCode` and `err__ErrorCode`).
        if (self.are_same_enum_type(expected, actual)) return true;

        // Allow equivalent compound types referenced through different visible names
        // (e.g. `Vec2` and `geom__Vec2`).
        if (self.are_same_compound_type(expected, actual)) return true;

        // Enums behave as numeric values for coercion with `num`.
        if (self.is_enum_named_type(expected) and !actual.is_array and actual.pointer_depth == 0 and actual.base == .Num) {
            return true;
        }
        if (!expected.is_array and expected.pointer_depth == 0 and expected.base == .Num and self.is_enum_named_type(actual)) {
            return true;
        }

        // Quirk coercion: allow `T*` -> `Quirk` if an `impl T as Quirk { ... }` exists.
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

        // Allow raw pointers to coerce to `str` (malloc-style allocations).
        if (!expected.is_array and expected.pointer_depth == 0 and expected.base == .Str and !actual.is_array and actual.base == .Raw and actual.pointer_depth > 0) {
            return true;
        }

        // Allow chr[] arrays to coerce to str (C-style buffers).
        if (!expected.is_array and expected.pointer_depth == 0 and expected.base == .Str and actual.is_array and actual.base == .Chr) {
            return true;
        }

        // Allow `str` to coerce to `raw*` (C APIs that accept void*).
        if (!expected.is_array and expected.base == .Raw and expected.pointer_depth > 0 and !actual.is_array and actual.base == .Str and actual.pointer_depth == 0) {
            return true;
        }

        // Allow raw pointers to coerce to array-typed values (malloc/realloc patterns).
        if (expected.is_array and !actual.is_array and actual.base == .Raw and actual.pointer_depth > 0) {
            return true;
        }

        // Allow array values to coerce to raw pointers (e.g., realloc/free/memset).
        if (!expected.is_array and expected.base == .Raw and expected.pointer_depth > 0 and actual.is_array) {
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

    fn can_compare_or_match(self: *Self, a: CheckedType, b: CheckedType) bool {
        if (CheckedType.eql(a, b)) return true;

        if (self.are_same_enum_type(a, b)) return true;

        // Numeric comparisons/coercion.
        if (self.is_numeric_type(a) and self.is_numeric_type(b)) return true;

        // Allow chr <-> num comparisons (C-style char/int coercions).
        if ((a.base == .Chr and b.base == .Num) or (a.base == .Num and b.base == .Chr)) return true;

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

    fn is_let_infer_dtype(dt: *const dtype.DataType) bool {
        return (dt.type == null or dt.type == .Unknown) and mem.eql(u8, dt.type_str.items, "__let_infer__");
    }

    fn infer_let_variable_dtype(self: *Self, stmt: *ast.Node, env: *TypeEnv, fns: *const std.StringHashMap(FnSig)) TranspileError!void {
        if (stmt.type != .Variable or stmt.node_variant == null) return;
        const v = stmt.node_variant.?.variable;
        if (!is_let_infer_dtype(v.type)) return;
        const val = v.val orelse {
            self.report_type_error(stmt.*, "'let' variable '{s}' requires an initializer", .{v.name.items});
            return TranspileError.TypeMismatch;
        };
        const inferred_t = blk: {
            if (dot_shorthand_variant_name(val)) |_| {
                if (try self.infer_let_enum_dot_shorthand(val)) |t| {
                    break :blk t;
                }
            }
            break :blk try self.infer_expr_type(val.*, env, fns);
        };
        if (!is_known_type(inferred_t)) {
            self.report_type_error(stmt.*, "cannot infer type for let variable '{s}'", .{v.name.items});
            return TranspileError.TypeMismatch;
        }
        if (self.is_quirk_named_type(inferred_t)) {
            self.report_type_error(stmt.*, "let cannot infer quirk type for '{s}'; declare the quirk type explicitly", .{v.name.items});
            return TranspileError.TypeMismatch;
        }
        const inferred_dt = (try self.checked_type_to_dtype(inferred_t)) orelse {
            self.report_type_error(stmt.*, "cannot infer type for let variable '{s}'", .{v.name.items});
            return TranspileError.TypeMismatch;
        };
        stmt.node_variant.?.variable.type = inferred_dt;
    }

    fn flatten_call_args_ptr(self: *Self, node: *ast.Node, out: *std.ArrayList(*ast.Node)) TranspileError!void {
        // Function call arguments are parsed as a parenthesis node that wraps an expression.
        // For zero-arg calls this inner expression is `.Blank`.
        if (node.type == .ExpressionParenthesis and node.node_variant != null) {
            const inner = node.node_variant.?.paren.exp;
            if (inner.*.type == .Blank) return;
            return try self.flatten_call_args_ptr(inner, out);
        }

        // A `.Blank` node represents an empty argument list.
        if (node.type == .Blank) return;

        if (node.type == .Expression and node.node_variant != null and mem.eql(u8, node.node_variant.?.exp.op, ",")) {
            const exp = node.node_variant.?.exp;
            if (exp.left) |left| try self.flatten_call_args_ptr(left, out);
            if (exp.right) |right| try self.flatten_call_args_ptr(right, out);
            return;
        }
        out.append(node) catch {
            return TranspileError.MemoryAllocationFailed;
        };
    }

    fn validate_async_call_usage(
        self: *Self,
        call_node: ast.Node,
        callee_name: ?[]const u8,
        callee_is_async: bool,
        async_known: bool,
    ) TranspileError!void {
        const display = callee_name orelse "<call>";

        if (self.in_await_operand_inference) {
            if (!async_known) {
                self.report_type_error(call_node, "await target '{s}' must resolve to an async function", .{display});
                return TranspileError.TypeMismatch;
            }
            if (!callee_is_async) {
                self.report_type_error(call_node, "await target '{s}' is not async", .{display});
                return TranspileError.TypeMismatch;
            }
            return;
        }

        if (async_known and callee_is_async) {
            self.report_type_error(call_node, "call to async function '{s}' must be awaited", .{display});
            return TranspileError.TypeMismatch;
        }
    }

    fn resolve_await_lowering_info(self: *Self, call_node: ast.Node) TranspileError!?AwaitLoweringInfo {
        if (call_node.type != .Expression or call_node.node_variant == null or !mem.eql(u8, call_node.node_variant.?.exp.op, "()")) {
            return null;
        }

        if (self.lookup_await_call_override(call_node)) |ov| {
            var receiver_expr: ?*ast.Node = null;
            if (ov.has_receiver) {
                const call = call_node.node_variant.?.exp;
                const callee = call.left orelse return null;
                if (callee.*.type != .Expression or callee.*.node_variant == null or !mem.eql(u8, callee.*.node_variant.?.exp.op, ".")) {
                    return null;
                }
                receiver_expr = callee.*.node_variant.?.exp.left;
                if (receiver_expr == null) return null;
            }

            return .{
                .callee_name = self.allocator.dupe(u8, ov.callee_name) catch {
                    return TranspileError.MemoryAllocationFailed;
                },
                .receiver_expr = receiver_expr,
                .receiver_pass_by_ref = ov.receiver_pass_by_ref,
            };
        }

        if (self.lookup_generic_call_override(call_node)) |ov| {
            return .{
                .callee_name = self.allocator.dupe(u8, ov) catch {
                    return TranspileError.MemoryAllocationFailed;
                },
            };
        }

        const call = call_node.node_variant.?.exp;
        const callee = call.left orelse return null;

        if (callee.*.type == .Identifier and callee.*.data != null) {
            return .{
                .callee_name = self.allocator.dupe(u8, callee.*.data.?.sval.items) catch {
                    return TranspileError.MemoryAllocationFailed;
                },
            };
        }

        if (callee.*.type == .Expression and callee.*.node_variant != null and mem.eql(u8, callee.*.node_variant.?.exp.op, ".")) {
            const dot = callee.*.node_variant.?.exp;
            const left = dot.left orelse return null;
            const right = dot.right orelse return null;
            if (left.*.type == .Identifier and left.*.data != null and right.*.type == .Identifier and right.*.data != null) {
                const left_name = left.*.data.?.sval.items;
                const right_name = right.*.data.?.sval.items;

                if (try self.resolve_alias_qualified_symbol_name(&call_node, left_name, right_name)) |qualified| {
                    return .{ .callee_name = qualified };
                }

                if (self.identifier_is_quirk_typed(left_name)) {
                    return null;
                }

                const recv_dt = self.identifier_declared_dtype(left_name) orelse return null;
                if (recv_dt.type != .Unknown or self.is_quirk_name(recv_dt.type_str.items)) {
                    return null;
                }
                if (recv_dt.pointer_depth != 0 and recv_dt.pointer_depth != 1) {
                    return null;
                }

                var type_name: []const u8 = recv_dt.type_str.items;
                var owned_type_name = false;
                if (recv_dt.generic_args != null) {
                    type_name = try self.type_name_mangled_for_emit(recv_dt);
                    owned_type_name = true;
                }
                defer if (owned_type_name) self.allocator.free(@constCast(type_name));

                const type_name_canon = self.canonical_compound_name(type_name);

                if (self.lookup_plain_impl_method_fn(&call_node, type_name_canon, right_name)) |fn_name| {
                    return .{
                        .callee_name = self.allocator.dupe(u8, fn_name) catch {
                            return TranspileError.MemoryAllocationFailed;
                        },
                        .receiver_expr = left,
                        .receiver_pass_by_ref = recv_dt.pointer_depth == 0,
                    };
                }

                const qres = self.resolve_quirk_impl_method_for_concrete(call_node, type_name_canon, right_name);
                if (!qres.ambiguous) {
                    if (qres.fn_name) |qfn_name| {
                        return .{
                            .callee_name = self.allocator.dupe(u8, qfn_name) catch {
                                return TranspileError.MemoryAllocationFailed;
                            },
                            .receiver_expr = left,
                            .receiver_pass_by_ref = recv_dt.pointer_depth == 0,
                        };
                    }
                }
            }
        }

        return null;
    }

    fn infer_expr_type(self: *Self, node: ast.Node, env: *TypeEnv, fns: *const std.StringHashMap(FnSig)) TranspileError!CheckedType {
        switch (node.type) {
            .CompoundInit => {
                const ci = node.node_variant.?.compound_init;
                if (ci.dtype == null) {
                    return .{ .base = .Unknown };
                }
                try self.validate_compound_init(node, ci.dtype.?, env, fns);
                return try self.type_from_dtype_with_mangled(ci.dtype.?);
            },
            .Bracket => {
                // Array literal: `[a, b, c]`. The parser stores elements under `bracket.inner`.
                var elems = std.ArrayList(*ast.Node).init(self.allocator);
                defer elems.deinit();
                try self.flatten_call_args_ptr(node.node_variant.?.bracket.inner, &elems);

                var elem_type: ?CheckedType = null;
                for (elems.items) |elem_node| {
                    const t = try self.infer_expr_type(elem_node.*, env, fns);
                    if (elem_type == null) {
                        elem_type = t;
                        continue;
                    }
                    if (!CheckedType.eql(t, elem_type.?)) {
                        self.report_type_error(node, "array literal elements must share a type", .{});
                        return TranspileError.TypeMismatch;
                    }
                }

                var out: CheckedType = .{
                    .base = if (elem_type) |et| et.base else .Unknown,
                    .is_array = true,
                    .pointer_depth = 0,
                };
                if (elem_type) |et| {
                    out.name = et.name;
                    out.mangled_name = et.mangled_name;
                    out.dtype_ref = et.dtype_ref;
                }
                return out;
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
                    // `limits.h`
                    mem.eql(u8, name, "CHAR_BIT") or
                    mem.eql(u8, name, "MB_LEN_MAX") or
                    mem.eql(u8, name, "SCHAR_MIN") or mem.eql(u8, name, "SCHAR_MAX") or
                    mem.eql(u8, name, "UCHAR_MAX") or
                    mem.eql(u8, name, "CHAR_MIN") or mem.eql(u8, name, "CHAR_MAX") or
                    mem.eql(u8, name, "SHRT_MIN") or mem.eql(u8, name, "SHRT_MAX") or
                    mem.eql(u8, name, "USHRT_MAX") or
                    mem.eql(u8, name, "INT_MAX") or mem.eql(u8, name, "INT_MIN") or
                    mem.eql(u8, name, "UINT_MAX") or
                    mem.eql(u8, name, "LONG_MAX") or mem.eql(u8, name, "LONG_MIN") or
                    mem.eql(u8, name, "ULONG_MAX") or
                    mem.eql(u8, name, "LLONG_MAX") or mem.eql(u8, name, "LLONG_MIN") or
                    mem.eql(u8, name, "ULLONG_MAX") or
                    // Common extensions / related headers (often visible when importing std c headers)
                    mem.eql(u8, name, "SIZE_MAX") or
                    mem.eql(u8, name, "RSIZE_MAX") or
                    mem.eql(u8, name, "PTRDIFF_MIN") or mem.eql(u8, name, "PTRDIFF_MAX") or
                    mem.eql(u8, name, "WCHAR_MIN") or mem.eql(u8, name, "WCHAR_MAX") or
                    mem.eql(u8, name, "WINT_MIN") or mem.eql(u8, name, "WINT_MAX") or
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

                if (mem.eql(u8, u.op, "await")) {
                    if (!self.current_fn_is_async) {
                        self.report_type_error(node, "await is only allowed inside async functions", .{});
                        return TranspileError.TypeMismatch;
                    }

                    const operand = u.operand.*;
                    if (operand.type != .Expression or operand.node_variant == null or !mem.eql(u8, operand.node_variant.?.exp.op, "()")) {
                        self.report_type_error(node, "await expects a function call", .{});
                        return TranspileError.TypeMismatch;
                    }

                    const prev = self.in_await_operand_inference;
                    self.in_await_operand_inference = true;
                    defer self.in_await_operand_inference = prev;

                    return try self.infer_expr_type(operand, env, fns);
                }

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
                if (self.is_numeric_type(a) and self.is_numeric_type(b)) {
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

                    var args_nodes = std.ArrayList(*ast.Node).init(self.allocator);
                    defer args_nodes.deinit();
                    if (exp.right) |right| {
                        try self.flatten_call_args_ptr(right, &args_nodes);
                    }

                    // Standard function call: `foo(...)`.
                    var maybe_sig: ?FnSig = null;
                    var call_rtype: CheckedType = .{ .base = .Unknown };
                    var method_sig: ?ast.QuirkMethodSig = null;
                    var plain_method_sig: ?FnSig = null;
                    var plain_method_name: ?[]const u8 = null;
                    var skip_signature_typecheck: bool = false;
                    var handled_generic_call: bool = false;
                    var callee_name: ?[]const u8 = null;
                    var callee_is_async: bool = false;
                    var callee_async_known: bool = false;
                    var await_lowering_callee: ?[]const u8 = null;
                    var await_lowering_has_receiver: bool = false;
                    var await_lowering_receiver_by_ref: bool = false;

                    if (callee.type == .Identifier and callee.data != null) {
                        const fname = callee.data.?.sval.items;
                        callee_name = fname;

                        if (self.in_await_operand_inference and
                            (mem.eql(u8, fname, "sizeof") or
                                mem.eql(u8, fname, "va_start") or
                                mem.eql(u8, fname, "va_end") or
                                mem.eql(u8, fname, "va_copy") or
                                mem.eql(u8, fname, "va_arg_num") or
                                mem.eql(u8, fname, "va_arg_dec") or
                                mem.eql(u8, fname, "va_arg_bin") or
                                mem.eql(u8, fname, "va_arg_chr") or
                                mem.eql(u8, fname, "va_arg_str") or
                                mem.eql(u8, fname, "va_arg_raw")))
                        {
                            self.report_type_error(node, "await target '{s}' is not async", .{fname});
                            return TranspileError.TypeMismatch;
                        }

                        if (mem.eql(u8, fname, "va_start")) {
                            if (args_nodes.items.len != 2) {
                                self.report_type_error(node, "va_start expects 2 arguments", .{});
                                return TranspileError.WrongArgCount;
                            }
                            return .{ .base = .Void };
                        }
                        if (mem.eql(u8, fname, "va_end")) {
                            if (args_nodes.items.len != 1) {
                                self.report_type_error(node, "va_end expects 1 argument", .{});
                                return TranspileError.WrongArgCount;
                            }
                            return .{ .base = .Void };
                        }
                        if (mem.eql(u8, fname, "va_copy")) {
                            if (args_nodes.items.len != 2) {
                                self.report_type_error(node, "va_copy expects 2 arguments", .{});
                                return TranspileError.WrongArgCount;
                            }
                            return .{ .base = .Void };
                        }
                        if (mem.eql(u8, fname, "va_arg_num")) {
                            if (args_nodes.items.len != 1) {
                                self.report_type_error(node, "va_arg_num expects 1 argument", .{});
                                return TranspileError.WrongArgCount;
                            }
                            return .{ .base = .Num };
                        }
                        if (mem.eql(u8, fname, "va_arg_dec")) {
                            if (args_nodes.items.len != 1) {
                                self.report_type_error(node, "va_arg_dec expects 1 argument", .{});
                                return TranspileError.WrongArgCount;
                            }
                            return .{ .base = .Dec };
                        }
                        if (mem.eql(u8, fname, "va_arg_bin")) {
                            if (args_nodes.items.len != 1) {
                                self.report_type_error(node, "va_arg_bin expects 1 argument", .{});
                                return TranspileError.WrongArgCount;
                            }
                            return .{ .base = .Bin };
                        }
                        if (mem.eql(u8, fname, "va_arg_chr")) {
                            if (args_nodes.items.len != 1) {
                                self.report_type_error(node, "va_arg_chr expects 1 argument", .{});
                                return TranspileError.WrongArgCount;
                            }
                            return .{ .base = .Chr };
                        }
                        if (mem.eql(u8, fname, "va_arg_str")) {
                            if (args_nodes.items.len != 1) {
                                self.report_type_error(node, "va_arg_str expects 1 argument", .{});
                                return TranspileError.WrongArgCount;
                            }
                            return .{ .base = .Str };
                        }
                        if (mem.eql(u8, fname, "va_arg_raw")) {
                            if (args_nodes.items.len != 1) {
                                self.report_type_error(node, "va_arg_raw expects 1 argument", .{});
                                return TranspileError.WrongArgCount;
                            }
                            return .{ .base = .Raw, .pointer_depth = 1 };
                        }

                        // Builtin: `sizeof(Type)`.
                        if (mem.eql(u8, fname, "sizeof")) {
                            if (args_nodes.items.len != 1) {
                                self.report_type_error(node, "sizeof expects exactly 1 argument", .{});
                                return TranspileError.InvalidSizeof;
                            }
                            const arg0 = args_nodes.items[0].*;
                            if (arg0.type != .Identifier or arg0.data == null) {
                                self.report_type_error(node, "sizeof argument must be a type name", .{});
                                return TranspileError.InvalidSizeof;
                            }

                            const type_name = arg0.data.?.sval.items;
                            const is_builtin = utils.keyword_is_datatype(type_name);

                            const is_declared = blk: {
                                const root = self.get_root();
                                if (root.type_registry == null) break :blk false;
                                const reg = &root.type_registry.?;
                                if (reg.enums_by_name.contains(type_name)) break :blk true;
                                if (reg.compounds_by_name.contains(type_name)) break :blk true;
                                if (reg.quirk_sig_by_name.contains(type_name)) break :blk true;
                                break :blk false;
                            };

                            const is_type_param = env.has_type_param(type_name);

                            if (!is_builtin and !is_declared and !is_type_param) {
                                self.report_type_error(node, "sizeof unknown type '{s}'", .{type_name});
                                return TranspileError.InvalidSizeof;
                            }

                            if (!is_builtin and !is_type_param) {
                                try self.ensure_named_type_visible(node, type_name);
                            }

                            return .{ .base = .Num };
                        }

                        if (fns.get(fname)) |sig| {
                            maybe_sig = sig;
                            call_rtype = sig.rtype;
                            callee_is_async = sig.is_async;
                            callee_async_known = true;
                            await_lowering_callee = fname;
                            if (self.find_function_node(fname)) |fn_node| {
                                if (!self.can_access(&node, fn_node)) {
                                    self.report_type_error(node, "function '{s}' is private", .{fname});
                                    return TranspileError.SymbolNotDefined;
                                }
                            }
                        } else {
                            // If the name is known from preloaded imports/stdlib signatures, treat it
                            // as an external function and skip type checking.
                            // Otherwise, this is a real semantic error (we don't want to defer to C).
                            if (self.global_symbols.get(fname) != null or is_known_extern_function_name(fname)) {
                                skip_signature_typecheck = true;
                                call_rtype = .{ .base = .Unknown };
                            }

                            if (!skip_signature_typecheck) {
                                self.report_type_error(node, "unknown function '{s}'", .{fname});
                                return TranspileError.SymbolNotDefined;
                            }
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

                        // Module alias call: `alias.fn(...)`.
                        if (recv.type == .Identifier and recv.data != null) {
                            const alias_name = recv.data.?.sval.items;
                            const member_name = member.data.?.sval.items;
                            callee_name = member_name;
                            if (try self.resolve_alias_qualified_symbol_name(&node, alias_name, member_name)) |qualified| {
                                defer self.allocator.free(qualified);

                                if (fns.get(qualified)) |sig| {
                                    maybe_sig = sig;
                                    call_rtype = sig.rtype;
                                    callee_is_async = sig.is_async;
                                    callee_async_known = true;
                                } else if (self.global_symbols.get(qualified) != null or is_known_extern_function_name(qualified)) {
                                    skip_signature_typecheck = true;
                                    call_rtype = .{ .base = .Unknown };
                                    callee_async_known = false;
                                } else {
                                    self.report_type_error(node, "unknown function '{s}.{s}'", .{ alias_name, member_name });
                                    return TranspileError.SymbolNotDefined;
                                }

                                for (args_nodes.items) |arg_node| {
                                    _ = try self.infer_expr_type(arg_node.*, env, fns);
                                }
                                try self.validate_async_call_usage(node, callee_name, callee_is_async, callee_async_known);
                                return call_rtype;
                            }
                        }

                        const recv_t = try self.infer_expr_type(recv.*, env, fns);
                        const mname = member.data.?.sval.items;
                        callee_name = mname;
                        if (!is_user_named_type(recv_t)) {
                            self.report_type_error(node, "method calls require a named receiver", .{});
                            return TranspileError.NotCallable;
                        }

                        if (recv_t.dtype_ref) |dt| {
                            if (dt.generic_args != null) {
                                try self.register_generic_instantiation(dt);
                            }
                        } else if (self.lookup_receiver_dtype(recv.*)) |dt| {
                            if (dt.generic_args != null) {
                                try self.register_generic_instantiation(dt);
                            }
                        }

                        const recv_name = try self.concrete_type_name(recv.*, recv_t) orelse {
                            self.report_type_error(node, "method calls require a named receiver", .{});
                            return TranspileError.NotCallable;
                        };
                        const recv_name_owned = if (self.lookup_receiver_dtype(recv.*)) |dt| dt.generic_args != null else false;
                        const recv_name_canon = self.canonical_compound_name(recv_name);

                        if (mem.indexOf(u8, recv_name, "__") != null) {
                            if (try self.dtype_from_mangled_type(recv_name)) |recv_dt_mangled| {
                                try self.register_generic_instantiations_from_dtype(recv_dt_mangled);
                            }
                        }

                        // If the receiver is a quirk type, typecheck against the quirk signature.
                        // Otherwise, treat as a plain impl method call and typecheck against the
                        // generated `Type__method` function signature.
                        const reg = self.root_registry();
                        const recv_is_quirk = if (reg) |r| r.quirk_sig_by_name.contains(recv_name) else false;

                        if (recv_is_quirk) {
                            method_sig = self.lookup_quirk_method(node, recv_name, mname) orelse {
                                self.report_type_error(node, "quirk '{s}' has no method '{s}'", .{ recv_name, mname });
                                return TranspileError.NotCallable;
                            };
                            call_rtype = type_from_dtype(&method_sig.?.rtype);
                            callee_is_async = method_sig.?.is_async;
                            callee_async_known = true;
                        } else {
                            if (recv_t.pointer_depth > 1) {
                                self.report_type_error(node, "method calls support at most one pointer indirection", .{});
                                return TranspileError.NotCallable;
                            }

                            await_lowering_has_receiver = true;
                            await_lowering_receiver_by_ref = recv_t.pointer_depth == 0;

                            const recv_dt = if (recv_t.dtype_ref) |dt| dt else self.lookup_receiver_dtype(recv.*) orelse null;
                            if (recv_dt != null and recv_dt.?.generic_args != null) {
                                if (self.synthesize_generic_plain_method_sig(recv_dt.?, recv_name_canon, mname)) |sig| {
                                    plain_method_sig = sig;
                                    plain_method_name = mname;
                                    call_rtype = sig.rtype;
                                    if (self.lookup_plain_impl_method_fn(&node, recv_name_canon, mname)) |fn_name| {
                                        await_lowering_callee = fn_name;
                                    }
                                }
                            }

                            if (plain_method_sig == null) {
                                if (self.lookup_plain_impl_method_fn(&node, recv_name_canon, mname)) |fn_name| {
                                    plain_method_sig = fns.get(fn_name) orelse blk: {
                                        const recv_dt2 = if (recv_t.dtype_ref) |dt| dt else self.lookup_receiver_dtype(recv.*) orelse null;
                                        if (recv_dt2 != null) {
                                            if (self.synthesize_generic_plain_method_sig(recv_dt2.?, recv_name_canon, mname)) |sig| {
                                                break :blk sig;
                                            }
                                        }
                                        self.report_type_error(node, "type '{s}' has no method '{s}'", .{ recv_name_canon, mname });
                                        return TranspileError.NotCallable;
                                    };
                                    plain_method_name = mname;
                                    call_rtype = plain_method_sig.?.rtype;
                                    await_lowering_callee = fn_name;
                                }
                            }

                            if (plain_method_sig != null) {
                                // Resolved via plain impl.
                            } else {
                                // fallback to alt generic name or quirk impl
                                // Retry with a mangled generic receiver name if available.
                                var alt_name: ?[]const u8 = null;
                                var alt_owned = false;
                                if (recv_t.dtype_ref) |dt| {
                                    if (dt.generic_args != null) {
                                        alt_name = try self.type_name_mangled(dt);
                                        alt_owned = true;
                                    }
                                } else if (self.lookup_receiver_dtype(recv.*)) |dt| {
                                    if (dt.generic_args != null) {
                                        alt_name = try self.type_name_mangled(dt);
                                        alt_owned = true;
                                    }
                                }

                                if (alt_name) |alt| {
                                    if (self.lookup_plain_impl_method_fn(&node, alt, mname)) |fn_name| {
                                        plain_method_sig = fns.get(fn_name) orelse blk: {
                                            const recv_dt_alt = if (recv_t.dtype_ref) |dt| dt else self.lookup_receiver_dtype(recv.*) orelse null;
                                            if (recv_dt_alt != null) {
                                                if (self.synthesize_generic_plain_method_sig(recv_dt_alt.?, alt, mname)) |sig| {
                                                    break :blk sig;
                                                }
                                            }
                                            if (alt_owned) self.allocator.free(@constCast(alt));
                                            self.report_type_error(node, "type '{s}' has no method '{s}'", .{ recv_name_canon, mname });
                                            return TranspileError.NotCallable;
                                        };
                                        plain_method_name = mname;
                                        call_rtype = plain_method_sig.?.rtype;
                                        await_lowering_callee = fn_name;
                                        if (alt_owned) self.allocator.free(@constCast(alt));
                                    } else {
                                        if (alt_owned) self.allocator.free(@constCast(alt));
                                        const qres = self.resolve_quirk_impl_method_for_concrete(node, recv_name_canon, mname);
                                        if (qres.ambiguous) {
                                            self.report_type_error(node, "type '{s}' method '{s}' is ambiguous (quirks: '{s}', '{s}')", .{ recv_t.name.?, mname, qres.quirk_name orelse "<unknown>", qres.other_quirk_name orelse "<unknown>" });
                                            return TranspileError.NotCallable;
                                        }
                                        if (qres.fn_name) |qfn| {
                                            plain_method_sig = fns.get(qfn) orelse {
                                                self.report_type_error(node, "type '{s}' has no method '{s}'", .{ recv_name_canon, mname });
                                                return TranspileError.NotCallable;
                                            };
                                            plain_method_name = mname;
                                            call_rtype = plain_method_sig.?.rtype;
                                            await_lowering_callee = qfn;
                                        } else {
                                            self.report_type_error(node, "type '{s}' has no method '{s}'", .{ recv_name_canon, mname });
                                            return TranspileError.NotCallable;
                                        }
                                    }
                                } else {
                                    // Also allow calling quirk-impl methods directly on concrete types.
                                    // If the type implements exactly one quirk that defines this method name,
                                    // lower/typecheck as a direct call to the generated impl function.
                                    const qres = self.resolve_quirk_impl_method_for_concrete(node, recv_name_canon, mname);
                                    if (qres.ambiguous) {
                                        self.report_type_error(node, "type '{s}' method '{s}' is ambiguous (quirks: '{s}', '{s}')", .{ recv_t.name.?, mname, qres.quirk_name orelse "<unknown>", qres.other_quirk_name orelse "<unknown>" });
                                        return TranspileError.NotCallable;
                                    }
                                    if (qres.fn_name) |qfn| {
                                        plain_method_sig = fns.get(qfn) orelse {
                                            self.report_type_error(node, "type '{s}' has no method '{s}'", .{ recv_name_canon, mname });
                                            return TranspileError.NotCallable;
                                        };
                                        plain_method_name = mname;
                                        call_rtype = plain_method_sig.?.rtype;
                                        await_lowering_callee = qfn;
                                    } else {
                                        self.report_type_error(node, "type '{s}' has no method '{s}'", .{ recv_name_canon, mname });
                                        return TranspileError.NotCallable;
                                    }
                                }
                            }
                        }

                        if (recv_name_owned) {
                            self.allocator.free(recv_name);
                        }

                        if (plain_method_sig != null) {
                            callee_is_async = plain_method_sig.?.is_async;
                            callee_async_known = true;
                        }
                    } else {
                        self.report_type_error(node, "only calling named functions or quirk methods is supported", .{});
                        return TranspileError.NotCallable;
                    }

                    // Even when skipping signature-based type checking (extern functions), we still
                    // need to semantically validate each argument expression so member access, etc.
                    // errors are not missed.
                    if (skip_signature_typecheck) {
                        for (args_nodes.items) |arg_node| {
                            _ = try self.infer_expr_type(arg_node.*, env, fns);
                        }
                        try self.validate_async_call_usage(node, callee_name, callee_is_async, callee_async_known);
                        return call_rtype;
                    }

                    // Generic function call inference.
                    if (callee_name != null) {
                        const fn_node = self.find_function_node(callee_name.?) orelse null;
                        if (fn_node != null and fn_node.?.node_variant != null and fn_node.?.node_variant.?.function.type_params != null) {
                            const fnv = &fn_node.?.node_variant.?.function;
                            const params_ptr = blk: {
                                if (fnv.type_params) |*p| break :blk p;
                                self.report_type_error(node, "unknown function '{s}'", .{callee_name.?});
                                return TranspileError.SymbolNotDefined;
                            };

                            // Infer type arguments from call arguments.
                            var bindings = std.StringHashMap(*dtype.DataType).init(self.allocator);
                            defer bindings.deinit();

                            const expected_items = if (fnv.args) |args| args.items() else &[_]*ast.Node{};
                            const fixed_len = expected_items.len;

                            if (!fnv.is_variadic and args_nodes.items.len != fixed_len) {
                                self.report_type_error(node, "function '{s}' expects {d} args, got {d}", .{ callee_name.?, fixed_len, args_nodes.items.len });
                                return TranspileError.WrongArgCount;
                            }
                            if (fnv.is_variadic and args_nodes.items.len < fixed_len) {
                                self.report_type_error(node, "function '{s}' expects at least {d} args, got {d}", .{ callee_name.?, fixed_len, args_nodes.items.len });
                                return TranspileError.WrongArgCount;
                            }

                            var idx: usize = 0;
                            while (idx < args_nodes.items.len and idx < fixed_len) : (idx += 1) {
                                const arg_node = args_nodes.items[idx];
                                const expected_node = expected_items[idx];
                                if (expected_node.type != .Variable or expected_node.node_variant == null) continue;
                                const expected_dt = expected_node.node_variant.?.variable.type;

                                const actual_ct = try self.infer_expr_type(arg_node.*, env, fns);
                                const actual_dt = (try self.checked_type_to_dtype(actual_ct)) orelse {
                                    self.report_type_error(node, "cannot infer generic argument from value", .{});
                                    return TranspileError.TypeMismatch;
                                };

                                const ok = try self.bind_generic_param(expected_dt, actual_dt, params_ptr, &bindings);
                                if (!ok) {
                                    self.report_type_error(node, "type mismatch in call to '{s}' argument {d}", .{ callee_name.?, idx + 1 });
                                    return TranspileError.TypeMismatch;
                                }
                            }

                            // Ensure all params are bound.
                            var gargs = self.allocator.alloc(*dtype.DataType, params_ptr.count) catch {
                                return TranspileError.MemoryAllocationFailed;
                            };
                            var pi: usize = 0;
                            for (params_ptr.items()) |p| {
                                if (bindings.get(p.items)) |dt_ptr| {
                                    gargs[pi] = dt_ptr;
                                } else {
                                    self.report_type_error(node, "cannot infer generic parameter '{s}' for '{s}'", .{ p.items, callee_name.? });
                                    return TranspileError.TypeMismatch;
                                }
                                pi += 1;
                            }

                            // Typecheck args against substituted signature.
                            idx = 0;
                            while (idx < args_nodes.items.len and idx < fixed_len) : (idx += 1) {
                                const expected_node = expected_items[idx];
                                if (expected_node.type != .Variable or expected_node.node_variant == null) continue;
                                const expected_dt = expected_node.node_variant.?.variable.type;
                                const expected_t = try self.type_from_dtype_with_subst(expected_dt, params_ptr.*, gargs);
                                const actual_t = try self.infer_expr_type(args_nodes.items[idx].*, env, fns);
                                if (is_known_type(expected_t) and is_known_type(actual_t) and !(try self.can_implicit_coerce(expected_t, actual_t))) {
                                    self.report_type_error(node, "type mismatch in call to '{s}' argument {d}", .{ callee_name.?, idx + 1 });
                                    return TranspileError.TypeMismatch;
                                }
                            }

                            // Compute specialized return type.
                            if (fnv.rtype) |rt| {
                                call_rtype = try self.type_from_dtype_with_subst(&rt, params_ptr.*, gargs);
                            } else {
                                call_rtype = .{ .base = .Void };
                            }
                            callee_is_async = fnv.is_async;
                            callee_async_known = true;

                            // Register instantiation and call override for codegen.
                            const spec_name = try self.mangle_generic_fn_name(callee_name.?, gargs);
                            try self.register_generic_fn_instantiation(fn_node.?, params_ptr, gargs, spec_name);
                            await_lowering_callee = spec_name;
                            if (node.pos) |p| {
                                const key = try self.call_pos_key_alloc(p);
                                if (!self.generic_call_overrides.contains(key)) {
                                    self.generic_call_overrides.put(key, spec_name) catch return TranspileError.MemoryAllocationFailed;
                                } else {
                                    self.allocator.free(key);
                                }
                            }

                            handled_generic_call = true;
                        }
                    }

                    if (handled_generic_call) {
                        try self.validate_async_call_usage(node, callee_name, callee_is_async, callee_async_known);
                        return call_rtype;
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
                            // Enum shorthand args: `foo(.Blue)` where param type is `Color`.
                            if (idx < sig.args.len) {
                                const expected = sig.args[idx];
                                if (arg_node.type == .CompoundInit) {
                                    try self.bind_compound_init_expected(arg_node, expected, env, fns);
                                }
                                if (self.expected_enum_name(expected)) |enum_name| {
                                    if (dot_shorthand_variant_name(arg_node)) |_| {
                                        _ = try self.resolve_dot_shorthand_enum_variant(arg_node, enum_name);
                                    }
                                }
                            }

                            const actual = try self.infer_expr_type(arg_node.*, env, fns);
                            if (idx < sig.args.len) {
                                const expected = sig.args[idx];
                                if (is_known_type(expected) and is_known_type(actual) and !(try self.can_implicit_coerce(expected, actual))) {
                                    const fname = callee.data.?.sval.items;
                                    self.report_type_error(node, "type mismatch in call to '{s}' argument {d}", .{ fname, idx + 1 });
                                    return TranspileError.TypeMismatch;
                                }
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
                            const expected = type_from_dtype(expected_args[idx].dtype);
                            if (arg_node.type == .CompoundInit) {
                                try self.bind_compound_init_expected(arg_node, expected, env, fns);
                            }
                            if (self.expected_enum_name(expected)) |enum_name| {
                                if (dot_shorthand_variant_name(arg_node)) |_| {
                                    _ = try self.resolve_dot_shorthand_enum_variant(arg_node, enum_name);
                                }
                            }

                            const actual = try self.infer_expr_type(arg_node.*, env, fns);
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
                            if (sig_idx < psig.args.len) {
                                const expected = psig.args[sig_idx];
                                if (arg_node.type == .CompoundInit) {
                                    try self.bind_compound_init_expected(arg_node, expected, env, fns);
                                }
                                if (self.expected_enum_name(expected)) |enum_name| {
                                    if (dot_shorthand_variant_name(arg_node)) |_| {
                                        _ = try self.resolve_dot_shorthand_enum_variant(arg_node, enum_name);
                                    }
                                }
                            }

                            const actual = try self.infer_expr_type(arg_node.*, env, fns);
                            if (sig_idx < psig.args.len) {
                                const expected = psig.args[sig_idx];
                                if (is_known_type(expected) and is_known_type(actual) and !(try self.can_implicit_coerce(expected, actual))) {
                                    self.report_type_error(node, "type mismatch in call to method '{s}' argument {d}", .{ plain_method_name orelse "<method>", idx + 1 });
                                    return TranspileError.TypeMismatch;
                                }
                            }
                        }
                    }

                    if (await_lowering_callee) |lower_name| {
                        try self.record_await_call_override(node, lower_name, await_lowering_has_receiver, await_lowering_receiver_by_ref);
                    }

                    try self.validate_async_call_usage(node, callee_name, callee_is_async, callee_async_known);
                    return call_rtype;
                }

                if (mem.eql(u8, op, ".")) {
                    const left = exp.left orelse return .{ .base = .Unknown };
                    const right = exp.right orelse return .{ .base = .Unknown };

                    // Aliased enum variant constant:
                    // `alias.Enum.Variant` (supports both parse associativities).
                    if (extract_alias_enum_variant_parts(left, right)) |parts| {
                        if (self.alias_map_for_node(&node).contains(parts.alias_name)) {
                            const qualified_enum = try self.make_alias_qualified_symbol_name(parts.alias_name, parts.enum_name);
                            if (try self.resolve_enum_variant_constant_type(node, qualified_enum, parts.variant_name)) |_| {
                                self.allocator.free(qualified_enum);
                                return .{ .base = .Unknown, .name = parts.enum_name };
                            }
                            self.allocator.free(qualified_enum);
                        }
                    }

                    // Module alias symbol access (`alias.symbol`).
                    if (left.*.type == .Identifier and left.*.data != null and right.*.type == .Identifier and right.*.data != null) {
                        const alias_name = left.*.data.?.sval.items;
                        const member_name = right.*.data.?.sval.items;
                        if (try self.resolve_alias_qualified_symbol_name(&node, alias_name, member_name)) |qualified| {
                            defer self.allocator.free(qualified);
                            return .{ .base = .Unknown };
                        }
                    }

                    // Enum variant constant: `Enum.Variant`.
                    // Treat this form as enum access when `Enum` is a known enum type (even if declared later).
                    if (left.*.type == .Identifier and left.*.data != null and right.*.type == .Identifier and right.*.data != null) {
                        const enum_name = left.*.data.?.sval.items;
                        const variant_name = right.*.data.?.sval.items;
                        if (try self.resolve_enum_variant_constant_type(node, enum_name, variant_name)) |t| {
                            return t;
                        }
                    }

                    var lt = try self.infer_expr_type(left.*, env, fns);

                    // The parser can encode chained field access right-associatively:
                    // `rect.a.x` -> `rect . (a . x)`.
                    // Support both `left . Identifier` and `left . (a . b . c)` forms.
                    if (right.type == .Identifier and right.data != null) {
                        return try self.infer_compound_field_access_type(node, lt, right.data.?.sval.items);
                    }

                    if (right.type == .Expression and right.node_variant != null and mem.eql(u8, right.node_variant.?.exp.op, "[]")) {
                        const rex = right.node_variant.?.exp;
                        const rleft = rex.left orelse {
                            self.report_type_error(node, "field access requires an identifier", .{});
                            return TranspileError.InvalidFieldAccess;
                        };
                        const rright = rex.right orelse {
                            self.report_type_error(node, "array index must be num", .{});
                            return TranspileError.TypeMismatch;
                        };
                        if (rleft.*.type != .Identifier or rleft.*.data == null) {
                            self.report_type_error(node, "field access requires an identifier", .{});
                            return TranspileError.InvalidFieldAccess;
                        }
                        const field_dt = try self.infer_compound_field_access_type(node, lt, rleft.*.data.?.sval.items);
                        const idx_t = try self.infer_expr_type(rright.*, env, fns);
                        if (idx_t.base != .Num) {
                            self.report_type_error(node, "array index must be num", .{});
                            return TranspileError.TypeMismatch;
                        }
                        if (!field_dt.is_array and field_dt.pointer_depth > 0) {
                            return .{ .base = field_dt.base, .is_array = false, .pointer_depth = field_dt.pointer_depth - 1, .name = field_dt.name };
                        }
                        if (!field_dt.is_array) {
                            self.report_type_error(node, "indexing requires an array", .{});
                            return TranspileError.IndexNonArray;
                        }
                        return .{ .base = field_dt.base, .is_array = false, .pointer_depth = field_dt.pointer_depth, .name = field_dt.name };
                    }

                    if (right.type == .Expression and right.node_variant != null and mem.eql(u8, right.node_variant.?.exp.op, ".")) {
                        var cursor: ast.Node = right.*;
                        while (true) {
                            if (cursor.type == .Expression and cursor.node_variant != null and mem.eql(u8, cursor.node_variant.?.exp.op, ".")) {
                                const dot = cursor.node_variant.?.exp;
                                const seg = dot.left orelse {
                                    self.report_type_error(node, "field access requires an identifier", .{});
                                    return TranspileError.InvalidFieldAccess;
                                };
                                if (seg.type == .Identifier and seg.data != null) {
                                    lt = try self.infer_compound_field_access_type(node, lt, seg.data.?.sval.items);
                                } else if (seg.type == .Expression and seg.node_variant != null and mem.eql(u8, seg.node_variant.?.exp.op, "[]")) {
                                    const segexp = seg.node_variant.?.exp;
                                    const segleft = segexp.left orelse {
                                        self.report_type_error(node, "field access requires an identifier", .{});
                                        return TranspileError.InvalidFieldAccess;
                                    };
                                    const segright = segexp.right orelse {
                                        self.report_type_error(node, "array index must be num", .{});
                                        return TranspileError.TypeMismatch;
                                    };
                                    if (segleft.*.type != .Identifier or segleft.*.data == null) {
                                        self.report_type_error(node, "field access requires an identifier", .{});
                                        return TranspileError.InvalidFieldAccess;
                                    }
                                    const field_dt = try self.infer_compound_field_access_type(node, lt, segleft.*.data.?.sval.items);
                                    const idx_t = try self.infer_expr_type(segright.*, env, fns);
                                    if (idx_t.base != .Num) {
                                        self.report_type_error(node, "array index must be num", .{});
                                        return TranspileError.TypeMismatch;
                                    }
                                    if (!field_dt.is_array and field_dt.pointer_depth > 0) {
                                        lt = .{ .base = field_dt.base, .is_array = false, .pointer_depth = field_dt.pointer_depth - 1, .name = field_dt.name };
                                    } else if (!field_dt.is_array) {
                                        self.report_type_error(node, "indexing requires an array", .{});
                                        return TranspileError.IndexNonArray;
                                    } else {
                                        lt = .{ .base = field_dt.base, .is_array = false, .pointer_depth = field_dt.pointer_depth, .name = field_dt.name };
                                    }
                                } else {
                                    self.report_type_error(node, "field access requires an identifier", .{});
                                    return TranspileError.InvalidFieldAccess;
                                }

                                const next = dot.right orelse {
                                    self.report_type_error(node, "field access requires an identifier", .{});
                                    return TranspileError.InvalidFieldAccess;
                                };
                                cursor = next.*;
                                continue;
                            }

                            if (cursor.type == .Identifier and cursor.data != null) {
                                lt = try self.infer_compound_field_access_type(node, lt, cursor.data.?.sval.items);
                                return lt;
                            }

                            self.report_type_error(node, "field access requires an identifier", .{});
                            return TranspileError.InvalidFieldAccess;
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
                    if (lt.base == .Str and !lt.is_array) {
                        if (rt.base != .Num) {
                            self.report_type_error(node, "array index must be num", .{});
                            return TranspileError.TypeMismatch;
                        }
                        return .{ .base = .Chr };
                    }
                    if (!lt.is_array and lt.pointer_depth > 0) {
                        if (rt.base != .Num) {
                            self.report_type_error(node, "array index must be num", .{});
                            return TranspileError.TypeMismatch;
                        }
                        return .{ .base = lt.base, .is_array = false, .pointer_depth = lt.pointer_depth - 1 };
                    }
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
                    // Enum shorthand assignment: `c = .Blue`.
                    // Resolve the shorthand before inferring RHS type.
                    if (self.expected_enum_name(lt)) |enum_name| {
                        if (dot_shorthand_variant_name(right)) |_| {
                            _ = try self.resolve_dot_shorthand_enum_variant(right, enum_name);
                        }
                    }

                    if (right.*.type == .CompoundInit) {
                        try self.bind_compound_init_expected(right, lt, env, fns);
                    }

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

                        if (!self.is_numeric_type(lt) or !self.is_numeric_type(rt)) {
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

                // Equality needs special handling for enum dot shorthand, since `.Variant` cannot
                // be type-inferred without an expected enum type.
                if (mem.eql(u8, op, "==") or mem.eql(u8, op, "!=")) {
                    const left = exp.left orelse return .{ .base = .Unknown };
                    const right = exp.right orelse return .{ .base = .Unknown };

                    const left_is_shorthand = dot_shorthand_variant_name(left) != null;
                    const right_is_shorthand = dot_shorthand_variant_name(right) != null;

                    // If both sides are shorthand, we have no context to infer the enum.
                    if (left_is_shorthand and right_is_shorthand) {
                        self.report_type_error(node, "cannot infer enum type for dot shorthand on both sides of '{s}'", .{op});
                        return TranspileError.TypeMismatch;
                    }

                    var lt: CheckedType = .{ .base = .Unknown };
                    var rt: CheckedType = .{ .base = .Unknown };

                    if (!left_is_shorthand) {
                        lt = try self.infer_expr_type(left.*, env, fns);
                        if (self.expected_enum_name(lt)) |enum_name| {
                            if (right_is_shorthand) {
                                _ = try self.resolve_dot_shorthand_enum_variant(right, enum_name);
                            }
                        }
                        rt = try self.infer_expr_type(right.*, env, fns);
                        if (left_is_shorthand) {
                            if (self.expected_enum_name(rt)) |enum_name| {
                                _ = try self.resolve_dot_shorthand_enum_variant(left, enum_name);
                                lt = .{ .base = .Unknown, .name = enum_name };
                            }
                        }
                    } else {
                        // Left is shorthand, right is not.
                        rt = try self.infer_expr_type(right.*, env, fns);
                        if (self.expected_enum_name(rt)) |enum_name| {
                            _ = try self.resolve_dot_shorthand_enum_variant(left, enum_name);
                            lt = .{ .base = .Unknown, .name = enum_name };
                        } else {
                            // Try to infer the left after resolution attempt; will error with a clearer message elsewhere.
                            lt = try self.infer_expr_type(left.*, env, fns);
                        }
                    }

                    if (is_known_type(lt) and is_known_type(rt) and !self.can_compare_or_match(lt, rt)) {
                        self.report_type_error(node, "equality '{s}' expects both sides to have the same type", .{op});
                        return TranspileError.TypeMismatch;
                    }
                    return .{ .base = .Bin };
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

                    if (!self.is_numeric_type(l) or !self.is_numeric_type(r)) {
                        self.report_type_error(node, "operator '{s}' expects num/dec operands", .{op});
                        return TranspileError.TypeMismatch;
                    }
                    return .{ .base = promote_numeric_type(l, r) };
                }

                if (mem.eql(u8, op, "<") or mem.eql(u8, op, "<=") or mem.eql(u8, op, ">") or mem.eql(u8, op, ">=")) {
                    if (!self.is_numeric_type(l) or !self.is_numeric_type(r)) {
                        self.report_type_error(node, "comparison '{s}' expects num/dec operands", .{op});
                        return TranspileError.TypeMismatch;
                    }
                    return .{ .base = .Bin };
                }

                // NOTE: equality is handled above to support enum dot shorthand.

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
                    try self.infer_let_variable_dtype(stmt_ptr, env, fns);
                    const v = stmt_ptr.node_variant.?.variable;
                    const name = v.name.items;
                    const vtype = try self.type_from_dtype_with_mangled(v.type);
                    try self.ensure_dtype_visible(stmt, v.type, env.type_params);
                    if (v.type.generic_args != null) {
                        try self.register_generic_instantiation(v.type);
                    }
                    try env.put_current(name, vtype);
                    if (v.val) |val| {
                        if (val.*.type == .CompoundInit) {
                            try self.bind_compound_init_expected(val, vtype, env, fns);
                        }
                        if (self.expected_enum_name(vtype)) |enum_name| {
                            if (dot_shorthand_variant_name(val)) |_| {
                                _ = try self.resolve_dot_shorthand_enum_variant(val, enum_name);
                            }
                        }
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
                        if (rv.*.type == .CompoundInit) {
                            try self.bind_compound_init_expected(rv, fn_rtype, env, fns);
                        }
                        if (self.expected_enum_name(fn_rtype)) |enum_name| {
                            if (dot_shorthand_variant_name(rv)) |_| {
                                _ = try self.resolve_dot_shorthand_enum_variant(rv, enum_name);
                            }
                        }
                        const rt = try self.infer_expr_type(rv.*, env, fns);
                        if (is_known_type(fn_rtype) and is_known_type(rt) and !(try self.can_implicit_coerce(fn_rtype, rt))) {
                            self.report_type_error(stmt, "return type mismatch", .{});
                            return TranspileError.ReturnTypeMismatch;
                        }
                    }
                },
                .StatementDefer => {
                    const d = stmt.node_variant.?.statement.defer_stmt;
                    if (d.body.type == .Body) {
                        try self.check_body(d.body, env, fns, fn_rtype);
                    } else {
                        _ = try self.infer_expr_type(d.body.*, env, fns);
                    }
                },
                .StatementAsm => {
                    const asm_s = stmt.node_variant.?.statement.asm_stmt;
                    for (asm_s.outputs.items()) |op| {
                        _ = try self.infer_expr_type(op.expr.*, env, fns);
                    }
                    for (asm_s.inputs.items()) |op| {
                        _ = try self.infer_expr_type(op.expr.*, env, fns);
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
                    const target_enum = self.expected_enum_name(target_t);
                    for (fit.branches.items()) |branch| {
                        if (branch.condition) |cond| {
                            if (target_enum) |enum_name| {
                                if (dot_shorthand_variant_name(cond)) |_| {
                                    _ = try self.resolve_dot_shorthand_enum_variant(cond, enum_name);
                                }
                            }
                            const ct = try self.infer_expr_type(cond.*, env, fns);
                            if (is_known_type(target_t) and is_known_type(ct) and !self.can_compare_or_match(target_t, ct)) {
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
                            var item_t = it_t;
                            item_t.is_array = false;
                            try env.put_current(fi.item_name, item_t);
                            try self.check_body(fi.body, env, fns, fn_rtype);
                        },
                    }
                },
                .Body => {
                    try self.check_body(stmt_ptr, env, fns, fn_rtype);
                },
                .StatementAssert => {
                    const stmtv = stmt.node_variant.?.statement.assert_stmt;
                    const ct = try self.infer_expr_type(stmtv.condition.*, env, fns);
                    if (ct.base != .Bin) {
                        self.report_type_error(stmt, "assert expects bin condition", .{});
                        return TranspileError.TypeMismatch;
                    }
                    if (stmtv.message) |msg| {
                        const mt = try self.infer_expr_type(msg.*, env, fns);
                        if (mt.base != .Str) {
                            self.report_type_error(stmt, "assert message must be str", .{});
                            return TranspileError.TypeMismatch;
                        }
                    }
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
            const args_items = args_vec.items();
            var args_slice = proc.allocator.alloc(CheckedType, args_items.len) catch {
                return TranspileError.MemoryAllocationFailed;
            };
            errdefer proc.allocator.free(args_slice);

            var i: usize = 0;
            for (args_items) |arg_ptr| {
                const arg = arg_ptr.*;
                if (arg.type == .Variable and arg.node_variant != null) {
                    try self.register_generic_instantiations_from_dtype(arg.node_variant.?.variable.type);
                    args_slice[i] = try self.type_from_dtype_with_mangled(arg.node_variant.?.variable.type);
                } else {
                    args_slice[i] = .{ .base = .Unknown };
                }
                try self.register_generic_instantiation_from_checked_type(args_slice[i]);
                i += 1;
            }

            owned_args.append(args_slice) catch {
                return TranspileError.MemoryAllocationFailed;
            };
            const fn_rtype: CheckedType = if (fnv.rtype) |*rt| blk: {
                try self.register_generic_instantiations_from_dtype(rt);
                break :blk try self.type_from_dtype_with_mangled(rt);
            } else .{ .base = .Void };
            try self.register_generic_instantiation_from_checked_type(fn_rtype);
            fns.put(name, .{
                .rtype = fn_rtype,
                .args = args_slice,
                .is_variadic = fnv.is_variadic,
                .is_async = fnv.is_async,
                .type_params = if (fnv.type_params) |*params| params else null,
            }) catch {
                return TranspileError.MemoryAllocationFailed;
            };

            if (proc.import_alias) |alias| {
                const alias_name = try self.make_alias_qualified_symbol_name(alias, name);
                if (!fns.contains(alias_name)) {
                    fns.put(alias_name, .{
                        .rtype = fn_rtype,
                        .args = args_slice,
                        .is_variadic = fnv.is_variadic,
                        .is_async = fnv.is_async,
                        .type_params = if (fnv.type_params) |*params| params else null,
                    }) catch {
                        return TranspileError.MemoryAllocationFailed;
                    };
                } else {
                    self.allocator.free(alias_name);
                }
            }
        }

        // Some modules keep function nodes only in `owned_nodes`.
        for (proc.owned_nodes.items) |node_ptr| {
            const node = node_ptr.*;
            if (node.type != .Function or node.node_variant == null) continue;
            const fnv = node.node_variant.?.function;
            if (fnv.name == null) continue;
            const name = fnv.name.?.items;

            if (fns.contains(name)) continue;

            const args_vec = fnv.args orelse utils.Vector(*ast.Node).init(proc.allocator);
            const args_items = args_vec.items();
            var args_slice = proc.allocator.alloc(CheckedType, args_items.len) catch {
                return TranspileError.MemoryAllocationFailed;
            };
            errdefer proc.allocator.free(args_slice);

            var i: usize = 0;
            for (args_items) |arg_ptr| {
                const arg = arg_ptr.*;
                if (arg.type == .Variable and arg.node_variant != null) {
                    try self.register_generic_instantiations_from_dtype(arg.node_variant.?.variable.type);
                    args_slice[i] = try self.type_from_dtype_with_mangled(arg.node_variant.?.variable.type);
                } else {
                    args_slice[i] = .{ .base = .Unknown };
                }
                try self.register_generic_instantiation_from_checked_type(args_slice[i]);
                i += 1;
            }

            owned_args.append(args_slice) catch {
                return TranspileError.MemoryAllocationFailed;
            };
            const fn_rtype: CheckedType = if (fnv.rtype) |*rt| blk: {
                try self.register_generic_instantiations_from_dtype(rt);
                break :blk try self.type_from_dtype_with_mangled(rt);
            } else .{ .base = .Void };
            try self.register_generic_instantiation_from_checked_type(fn_rtype);
            fns.put(name, .{
                .rtype = fn_rtype,
                .args = args_slice,
                .is_variadic = fnv.is_variadic,
                .is_async = fnv.is_async,
                .type_params = if (fnv.type_params) |*params| params else null,
            }) catch {
                return TranspileError.MemoryAllocationFailed;
            };

            if (proc.import_alias) |alias| {
                const alias_name = try self.make_alias_qualified_symbol_name(alias, name);
                if (!fns.contains(alias_name)) {
                    fns.put(alias_name, .{
                        .rtype = fn_rtype,
                        .args = args_slice,
                        .is_variadic = fnv.is_variadic,
                        .is_async = fnv.is_async,
                        .type_params = if (fnv.type_params) |*params| params else null,
                    }) catch {
                        return TranspileError.MemoryAllocationFailed;
                    };
                } else {
                    self.allocator.free(alias_name);
                }
            }
        }

        // Impl methods are nested under `.Impl` nodes, not in `proc.nodes`.
        // Collect their generated function signatures too so method calls can be typechecked.
        for (proc.owned_nodes.items) |n| {
            if (n.type != .Impl or n.node_variant == null) continue;
            const im = n.node_variant.?.impl;
            if (proc.impl_type_params(n)) |params| {
                var inst_keys = std.StringHashMap(bool).init(self.allocator);
                defer {
                    var it = inst_keys.iterator();
                    while (it.next()) |e| {
                        self.allocator.free(e.key_ptr.*);
                    }
                    inst_keys.deinit();
                }

                var inst_list = std.ArrayList(*const dtype.DataType).init(self.allocator);
                defer inst_list.deinit();
                const base_name = if (mem.indexOf(u8, im.type_name.items, "__")) |idx| im.type_name.items[0..idx] else im.type_name.items;
                try self.collect_generic_instantiations_recursive(self, base_name, &inst_keys, &inst_list);

                for (inst_list.items) |dt| {
                    if (dt.generic_args == null) continue;
                    const gargs = dt.generic_args.?.items();
                    if (gargs.len != params.count) continue;
                    if (!self.generic_args_are_concrete(params, gargs)) continue;
                    if (self.dtype_contains_type_param(dt, params)) continue;

                    const mangled = try self.type_name_mangled(dt);
                    defer self.allocator.free(mangled);
                    if (self.mangled_contains_type_param(mangled, params)) continue;
                    if (self.mangled_contains_unresolved_placeholder(mangled)) continue;

                    for (im.methods.items()) |m| {
                        if (m.type != .Function or m.node_variant == null) continue;
                        const fnv = m.node_variant.?.function;
                        if (fnv.name == null) continue;
                        const base = base_method_name_from_generated(fnv.name.?.items) orelse continue;
                        const spec_name = if (im.quirk_name) |qn|
                            (std.fmt.allocPrint(proc.allocator, "{s}__{s}__{s}", .{ mangled, qn.items, base }) catch {
                                return TranspileError.MemoryAllocationFailed;
                            })
                        else
                            (std.fmt.allocPrint(proc.allocator, "{s}__{s}", .{ mangled, base }) catch {
                                return TranspileError.MemoryAllocationFailed;
                            });

                        if (fns.contains(spec_name)) continue;

                        const args_vec = fnv.args orelse utils.Vector(*ast.Node).init(proc.allocator);
                        const args_items = args_vec.items();
                        var args_slice = proc.allocator.alloc(CheckedType, args_items.len) catch {
                            return TranspileError.MemoryAllocationFailed;
                        };
                        errdefer proc.allocator.free(args_slice);

                        var i: usize = 0;
                        for (args_items) |arg_ptr| {
                            const arg = arg_ptr.*;
                            if (arg.type == .Variable and arg.node_variant != null) {
                                try self.register_generic_instantiations_from_dtype(arg.node_variant.?.variable.type);
                                args_slice[i] = try self.type_from_dtype_with_subst(arg.node_variant.?.variable.type, params.*, gargs);
                            } else {
                                args_slice[i] = .{ .base = .Unknown };
                            }
                            try self.register_generic_instantiation_from_checked_type(args_slice[i]);
                            i += 1;
                        }

                        owned_args.append(args_slice) catch {
                            return TranspileError.MemoryAllocationFailed;
                        };
                        const fn_rtype: CheckedType = if (fnv.rtype) |*rt| blk: {
                            try self.register_generic_instantiations_from_dtype(rt);
                            break :blk try self.type_from_dtype_with_subst(rt, params.*, gargs);
                        } else .{ .base = .Void };
                        try self.register_generic_instantiation_from_checked_type(fn_rtype);
                        fns.put(spec_name, .{
                            .rtype = fn_rtype,
                            .args = args_slice,
                            .is_variadic = fnv.is_variadic,
                            .is_async = fnv.is_async,
                            .type_params = null,
                        }) catch {
                            return TranspileError.MemoryAllocationFailed;
                        };
                    }
                }

                continue;
            }
            for (im.methods.items()) |m| {
                if (m.type != .Function or m.node_variant == null) continue;
                const fnv = m.node_variant.?.function;
                if (fnv.name == null) continue;
                const name = fnv.name.?.items;

                if (fns.contains(name)) continue;

                const args_vec = fnv.args orelse utils.Vector(*ast.Node).init(proc.allocator);
                const args_items = args_vec.items();
                var args_slice = proc.allocator.alloc(CheckedType, args_items.len) catch {
                    return TranspileError.MemoryAllocationFailed;
                };
                errdefer proc.allocator.free(args_slice);

                var i: usize = 0;
                for (args_items) |arg_ptr| {
                    const arg = arg_ptr.*;
                    if (arg.type == .Variable and arg.node_variant != null) {
                        try self.register_generic_instantiations_from_dtype(arg.node_variant.?.variable.type);
                        args_slice[i] = try self.type_from_dtype_with_mangled(arg.node_variant.?.variable.type);
                    } else {
                        args_slice[i] = .{ .base = .Unknown };
                    }
                    try self.register_generic_instantiation_from_checked_type(args_slice[i]);
                    i += 1;
                }

                owned_args.append(args_slice) catch {
                    return TranspileError.MemoryAllocationFailed;
                };
                const fn_rtype: CheckedType = if (fnv.rtype) |*rt| blk: {
                    try self.register_generic_instantiations_from_dtype(rt);
                    break :blk try self.type_from_dtype_with_mangled(rt);
                } else .{ .base = .Void };
                try self.register_generic_instantiation_from_checked_type(fn_rtype);
                fns.put(name, .{
                    .rtype = fn_rtype,
                    .args = args_slice,
                    .is_variadic = fnv.is_variadic,
                    .is_async = fnv.is_async,
                    .type_params = null,
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

        // Check this module and all imported modules recursively.
        const Walker = struct {
            fn walk(proc: *Self, fns_ref: *const std.StringHashMap(FnSig)) TranspileError!void {
                try typecheck_module(proc, fns_ref);
                for (proc.children.items) |child| {
                    try walk(child, fns_ref);
                }
            }
        };
        try Walker.walk(self, &fns);
    }

    // Best-effort helper for LSP indexing: infer let types without failing the caller.
    // This avoids full transpilation while still updating AST variable types so
    // the index can expose concrete types for hover/completion.
    pub fn infer_let_types_best_effort(self: *Self) void {
        var fns = std.StringHashMap(FnSig).init(self.allocator);
        defer fns.deinit();
        var owned_args = std.ArrayList([]CheckedType).init(self.allocator);
        defer {
            for (owned_args.items) |slice| self.allocator.free(slice);
            owned_args.deinit();
        }

        self.collect_fn_sigs(self, &fns, &owned_args) catch return;

        // Ensure the type registry is populated so local type checks can resolve named types.
        self.collect_type_registry_all() catch return;

        var global_env = TypeEnv.init(self.allocator);
        defer global_env.deinit();
        global_env.push() catch return;

        // Infer let types for globals and seed the env where possible.
        for (self.nodes.items()) |*gn| {
            if (gn.type != .Variable or gn.node_variant == null) continue;
            self.infer_let_variable_dtype(gn, &global_env, &fns) catch {};

            const v = gn.node_variant.?.variable;
            const vtype = self.type_from_dtype_with_mangled(v.type) catch continue;
            global_env.put_current(v.name.items, vtype) catch {};
        }

        // Infer let types inside function bodies (best-effort typechecking).
        for (self.nodes.items()) |node| {
            if (node.type != .Function or node.node_variant == null) continue;
            const fnv = node.node_variant.?.function;
            const fn_rtype: CheckedType = if (fnv.rtype) |rt|
                (self.type_from_dtype_with_mangled(&rt) catch CheckedType{ .base = .Unknown })
            else
                CheckedType{ .base = .Void };

            var fn_env = TypeEnv.init(self.allocator);
            defer fn_env.deinit();
            fn_env.push() catch {};

            // Seed globals into function scope for better inference.
            for (self.nodes.items()) |gn| {
                if (gn.type == .Variable and gn.node_variant != null and gn.binded == null) {
                    const v = gn.node_variant.?.variable;
                    const vtype = self.type_from_dtype_with_mangled(v.type) catch continue;
                    fn_env.put_current(v.name.items, vtype) catch {};
                }
            }

            // Seed args.
            if (fnv.args) |args| {
                for (args.items()) |arg_ptr| {
                    const arg = arg_ptr.*;
                    if (arg.type != .Variable or arg.node_variant == null) continue;
                    const v = arg.node_variant.?.variable;
                    const vtype = self.type_from_dtype_with_mangled(v.type) catch continue;
                    fn_env.put_current(v.name.items, vtype) catch {};
                }
            }

            if (fnv.is_variadic) {
                const vdt = self.make_vec_str_dtype() catch null;
                if (vdt) |dt| {
                    const vtype = self.type_from_dtype_with_mangled(dt) catch null;
                    if (vtype) |vt| fn_env.put_current("vargs", vt) catch {};
                }
            }

            if (fnv.body) |b| {
                const prev_async = self.current_fn_is_async;
                self.current_fn_is_async = fnv.is_async;
                defer self.current_fn_is_async = prev_async;
                self.check_body(b, &fn_env, &fns, fn_rtype) catch {};
            }
        }

        // Best-effort inference inside impl methods too.
        for (self.owned_nodes.items) |n| {
            if (n.type != .Impl or n.node_variant == null) continue;
            const im = n.node_variant.?.impl;
            const self_base = if (mem.indexOf(u8, im.type_name.items, "__")) |idx| im.type_name.items[0..idx] else im.type_name.items;
            const self_type: CheckedType = .{ .base = .Unknown, .name = self_base, .mangled_name = im.type_name.items, .pointer_depth = 1 };

            for (im.methods.items()) |m| {
                if (m.type != .Function or m.node_variant == null) continue;
                const fnv = m.node_variant.?.function;
                const fn_rtype: CheckedType = if (fnv.rtype) |rt|
                    (self.type_from_dtype_with_mangled(&rt) catch CheckedType{ .base = .Unknown })
                else
                    CheckedType{ .base = .Void };

                var fn_env = TypeEnv.init(self.allocator);
                defer fn_env.deinit();
                fn_env.push() catch {};

                // Seed globals.
                for (self.nodes.items()) |gn| {
                    if (gn.type == .Variable and gn.node_variant != null and gn.binded == null) {
                        const v = gn.node_variant.?.variable;
                        const vtype = self.type_from_dtype_with_mangled(v.type) catch continue;
                        fn_env.put_current(v.name.items, vtype) catch {};
                    }
                }

                // Seed implicit self.
                fn_env.put_current("self", self_type) catch {};

                // Seed args.
                if (fnv.args) |args| {
                    for (args.items()) |arg_ptr| {
                        const arg = arg_ptr.*;
                        if (arg.type != .Variable or arg.node_variant == null) continue;
                        const v = arg.node_variant.?.variable;
                        const vtype = self.type_from_dtype_with_mangled(v.type) catch continue;
                        fn_env.put_current(v.name.items, vtype) catch {};
                    }
                }

                if (fnv.is_variadic) {
                    const vdt = self.make_vec_str_dtype() catch null;
                    if (vdt) |dt| {
                        const vtype = self.type_from_dtype_with_mangled(dt) catch null;
                        if (vtype) |vt| fn_env.put_current("vargs", vt) catch {};
                    }
                }

                if (fnv.body) |b| {
                    const prev_async = self.current_fn_is_async;
                    self.current_fn_is_async = fnv.is_async;
                    defer self.current_fn_is_async = prev_async;
                    self.check_body(b, &fn_env, &fns, fn_rtype) catch {};
                }
            }
        }
    }

    fn typecheck_module(proc: *Self, fns: *const std.StringHashMap(FnSig)) TranspileError!void {
        var global_env = TypeEnv.init(proc.allocator);
        defer global_env.deinit();
        try global_env.push();

        for (proc.nodes.items()) |*gn| {
            if (gn.type != .Variable or gn.node_variant == null or gn.binded != null) continue;
            try proc.infer_let_variable_dtype(gn, &global_env, fns);

            const v = gn.node_variant.?.variable;
            const vtype = try proc.type_from_dtype_with_mangled(v.type);
            try proc.ensure_dtype_visible(gn.*, v.type, null);
            if (v.type.generic_args != null) {
                try proc.register_generic_instantiation(v.type);
            }
            try global_env.put_current(v.name.items, vtype);

            if (v.val) |val| {
                if (val.*.type == .CompoundInit) {
                    try proc.bind_compound_init_expected(val, vtype, &global_env, fns);
                }
                if (proc.expected_enum_name(vtype)) |enum_name| {
                    if (dot_shorthand_variant_name(val)) |_| {
                        _ = try proc.resolve_dot_shorthand_enum_variant(val, enum_name);
                    }
                }
                const init_t = try proc.infer_expr_type(val.*, &global_env, fns);
                if (is_known_type(vtype) and is_known_type(init_t) and !(try proc.can_implicit_coerce(vtype, init_t))) {
                    proc.report_type_error(gn.*, "type mismatch in initialization of '{s}'", .{v.name.items});
                    return TranspileError.TypeMismatch;
                }
            }
        }

        for (proc.nodes.items()) |node| {
            if (node.type != .Function or node.node_variant == null) continue;
            const fnv = node.node_variant.?.function;

            if (fnv.is_async and fnv.is_variadic) {
                proc.report_type_error(node, "async variadic functions are not supported yet", .{});
                return TranspileError.TypeMismatch;
            }

            const fn_rtype: CheckedType = if (fnv.rtype) |rt| try proc.type_from_dtype_with_mangled(&rt) else CheckedType{ .base = .Void };

            var allow_params: ?[]const []const u8 = null;
            var allow_store: ?std.ArrayList([]const u8) = null;
            defer if (allow_store) |*s| s.deinit();
            if (fnv.type_params) |params| {
                var buf = std.ArrayList([]const u8).init(proc.allocator);
                for (params.items()) |p| {
                    buf.append(p.items) catch return TranspileError.MemoryAllocationFailed;
                }
                allow_store = buf;
                allow_params = allow_store.?.items;
            }

            if (fnv.rtype) |rt| {
                try proc.ensure_dtype_visible(node, &rt, allow_params);
            }

            var fn_env = TypeEnv.init(proc.allocator);
            defer fn_env.deinit();
            try fn_env.push();
            fn_env.set_type_params(allow_params);

            // Add module-level globals (nodes without binded context).
            for (proc.nodes.items()) |gn| {
                if (gn.type == .Variable and gn.node_variant != null and gn.binded == null) {
                    const v = gn.node_variant.?.variable;
                    try fn_env.put_current(v.name.items, try proc.type_from_dtype_with_mangled(v.type));
                }
            }

            // Add args.
            if (fnv.args) |args| {
                for (args.items()) |arg_ptr| {
                    const arg = arg_ptr.*;
                    if (arg.type != .Variable or arg.node_variant == null) continue;
                    const v = arg.node_variant.?.variable;
                    try proc.ensure_dtype_visible(node, v.type, allow_params);
                    try fn_env.put_current(v.name.items, try proc.type_from_dtype_with_mangled(v.type));
                }
            }

            if (fnv.is_variadic) {
                const vdt = try proc.make_vec_str_dtype();
                try fn_env.put_current("vargs", try proc.type_from_dtype_with_mangled(vdt));
            }

            if (fnv.body) |body| {
                const prev_async = proc.current_fn_is_async;
                proc.current_fn_is_async = fnv.is_async;
                defer proc.current_fn_is_async = prev_async;
                try proc.check_body(body, &fn_env, fns, fn_rtype);
            }
        }

        // Impl methods live under `.Impl` nodes in `proc.owned_nodes`.
        // Typecheck them too, with an implicit `self` binding.
        for (proc.owned_nodes.items) |n| {
            if (n.type != .Impl or n.node_variant == null) continue;
            const im = n.node_variant.?.impl;
            const self_base = if (mem.indexOf(u8, im.type_name.items, "__")) |idx| im.type_name.items[0..idx] else im.type_name.items;
            const self_type: CheckedType = .{ .base = .Unknown, .name = self_base, .mangled_name = im.type_name.items, .pointer_depth = 1 };

            var allow_params: ?[]const []const u8 = null;
            var allow_store: ?std.ArrayList([]const u8) = null;
            defer if (allow_store) |*s| s.deinit();
            if (im.type_params) |*params| {
                var buf = std.ArrayList([]const u8).init(proc.allocator);
                for (params.items()) |p| {
                    buf.append(p.items) catch return TranspileError.MemoryAllocationFailed;
                }
                allow_store = buf;
                allow_params = allow_store.?.items;
            } else if (proc.impl_type_params(n)) |params| {
                var buf = std.ArrayList([]const u8).init(proc.allocator);
                for (params.items()) |p| {
                    buf.append(p.items) catch return TranspileError.MemoryAllocationFailed;
                }
                allow_store = buf;
                allow_params = allow_store.?.items;
            }

            if (allow_params == null) {
                if (mem.indexOf(u8, im.type_name.items, "__")) |_| {
                    var buf = std.ArrayList([]const u8).init(proc.allocator);
                    var i: usize = 0;
                    var seg_start: usize = 0;
                    while (i + 1 < im.type_name.items.len) : (i += 1) {
                        if (im.type_name.items[i] == '_' and im.type_name.items[i + 1] == '_') {
                            if (seg_start != 0 and i > seg_start) {
                                buf.append(im.type_name.items[seg_start..i]) catch return TranspileError.MemoryAllocationFailed;
                            }
                            i += 1;
                            seg_start = i + 1;
                        }
                    }
                    if (seg_start != 0 and seg_start < im.type_name.items.len) {
                        buf.append(im.type_name.items[seg_start..]) catch return TranspileError.MemoryAllocationFailed;
                    }
                    if (buf.items.len > 0) {
                        allow_store = buf;
                        allow_params = allow_store.?.items;
                    } else {
                        buf.deinit();
                    }
                }
            }

            try proc.ensure_named_type_visible(n.*, im.type_name.items);
            if (im.quirk_name) |qn| {
                try proc.ensure_named_type_visible(n.*, qn.items);
            }

            for (im.methods.items()) |m_ptr| {
                const m = m_ptr.*;
                if (m.type != .Function or m.node_variant == null) continue;
                const fnv = m.node_variant.?.function;

                if (fnv.is_async and fnv.is_variadic) {
                    proc.report_type_error(m, "async variadic methods are not supported yet", .{});
                    return TranspileError.TypeMismatch;
                }

                const fn_rtype: CheckedType = if (fnv.rtype) |rt| try proc.type_from_dtype_with_mangled(&rt) else CheckedType{ .base = .Void };

                if (fnv.rtype) |rt| {
                    try proc.ensure_dtype_visible(n.*, &rt, allow_params);
                }

                var fn_env = TypeEnv.init(proc.allocator);
                defer fn_env.deinit();
                try fn_env.push();
                fn_env.set_type_params(allow_params);

                // Add module-level globals.
                for (proc.nodes.items()) |gn| {
                    if (gn.type == .Variable and gn.node_variant != null and gn.binded == null) {
                        const v = gn.node_variant.?.variable;
                        try fn_env.put_current(v.name.items, try proc.type_from_dtype_with_mangled(v.type));
                    }
                }

                // Add implicit `self`.
                try fn_env.put_current("self", self_type);

                // Add explicit args.
                if (fnv.args) |args| {
                    for (args.items()) |arg_ptr| {
                        const arg = arg_ptr.*;
                        if (arg.type != .Variable or arg.node_variant == null) continue;
                        const v = arg.node_variant.?.variable;
                        try proc.ensure_dtype_visible(n.*, v.type, allow_params);
                        try fn_env.put_current(v.name.items, try proc.type_from_dtype_with_mangled(v.type));
                    }
                }

                if (fnv.body) |body| {
                    const prev_async = proc.current_fn_is_async;
                    proc.current_fn_is_async = fnv.is_async;
                    defer proc.current_fn_is_async = prev_async;
                    try proc.check_body(body, &fn_env, fns, fn_rtype);
                }
            }
        }
    }

    fn warn_if_fit_not_exhausted(self: *Self, fit_stmt: ast.Node, condition: *ast.Node, branches: []const ast.FitBranch) void {
        // If there is any default branch, treat it as exhausted.
        for (branches) |branch| {
            if (branch.condition == null) return;
        }

        // Boolean (`bin`) and enums are the only types we can treat as exhaustive without a catch-all.
        // Everything else (num/dec/chr/str/raw*/unknown pointers, etc) should warn unless
        // there is a `_ -> ...` default branch.
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

        // Exhaustive boolean fit: true + false present.
        if (has_true and has_false) return;

        const resolve_enum_name = struct {
            fn call(self_: *Self, cond: *ast.Node) ?[]const u8 {
                var node = cond.*;
                if (node.type == .ExpressionParenthesis and node.node_variant != null) {
                    node = node.node_variant.?.paren.exp.*;
                }

                if (node.type == .Identifier and node.data != null) {
                    const vname = node.data.?.sval.items;
                    if (self_.get_scope_entity(vname)) |ent| {
                        if (ent.node) |ent_node| {
                            if (ent_node.type == .Variable and ent_node.node_variant != null) {
                                const dt = ent_node.node_variant.?.variable.type;
                                if (dt.type == .Unknown and dt.pointer_depth == 0 and dt.type_str.items.len > 0) {
                                    return dt.type_str.items;
                                }
                            }
                        }
                    }
                    return null;
                }

                if (node.type == .Expression and node.node_variant != null and mem.eql(u8, node.node_variant.?.exp.op, ".")) {
                    const exp = node.node_variant.?.exp;
                    const left = exp.left orelse return null;
                    const right = exp.right orelse return null;
                    if (left.type != .Identifier or left.data == null) return null;
                    if (right.type != .Identifier or right.data == null) return null;

                    const base_name = left.data.?.sval.items;
                    if (self_.get_scope_entity(base_name)) |ent| {
                        if (ent.node) |ent_node| {
                            if (ent_node.type == .Variable and ent_node.node_variant != null) {
                                const dt = ent_node.node_variant.?.variable.type;
                                if (dt.type == .Unknown and dt.type_str.items.len > 0) {
                                    const field_dt = self_.lookup_compound_field(dt.type_str.items, right.data.?.sval.items) orelse return null;
                                    if (field_dt.type == .Unknown and field_dt.pointer_depth == 0 and field_dt.type_str.items.len > 0) {
                                        return field_dt.type_str.items;
                                    }
                                }
                            }
                        }
                    }
                }

                return null;
            }
        }.call;

        // Try enum exhaustiveness for variables and field accesses (e.g. `self.color`).
        const root = self.get_root();
        if (root.type_registry != null) {
            if (resolve_enum_name(self, condition)) |enum_name| {
                const reg = &root.type_registry.?;
                if (reg.enums_by_name.get(enum_name)) |enode| {
                    if (enode.node_variant != null) {
                        const variants = enode.node_variant.?.enum_decl.variants.items();

                        var covered = std.StringHashMap(bool).init(self.backing_allocator);
                        defer covered.deinit();

                        for (branches) |branch| {
                            const bcond = branch.condition orelse continue;
                            if (dot_shorthand_variant_name(bcond)) |short_name| {
                                covered.put(short_name, true) catch {};
                                continue;
                            }
                            if (bcond.type != .Expression or bcond.node_variant == null) continue;
                            const exp = bcond.node_variant.?.exp;
                            if (!mem.eql(u8, exp.op, ".")) continue;
                            const left = exp.left orelse continue;
                            const right = exp.right orelse continue;
                            if (left.type != .Identifier or left.data == null) continue;
                            if (right.type != .Identifier or right.data == null) continue;
                            if (!mem.eql(u8, left.data.?.sval.items, enum_name)) continue;
                            covered.put(right.data.?.sval.items, true) catch {};
                        }

                        var missing = std.ArrayList(u8).init(self.backing_allocator);
                        defer missing.deinit();
                        const mw = missing.writer();

                        var missing_count: usize = 0;
                        for (variants) |v| {
                            if (covered.contains(v.name.items)) continue;
                            if (missing_count > 0) {
                                mw.writeAll(", ") catch {};
                            }
                            mw.print("{s}.{s}", .{ enum_name, v.name.items }) catch {};
                            missing_count += 1;
                        }

                        if (missing_count == 0) return;

                        self.report_warning(
                            .fit_non_exhaustive,
                            fit_stmt,
                            "fit statement is not exhausted for enum '{s}' condition (missing: {s}; add catch-all '_' branch to silence)",
                            .{ enum_name, missing.items },
                        );
                        return;
                    }
                }
            }
        }

        const cond_type = self.infer_simple_dtype(condition.*) orelse {
            self.report_warning(.fit_non_exhaustive, fit_stmt, "fit statement is not exhausted for unknown condition (missing catch-all '_' branch)", .{});
            return;
        };

        if (cond_type != .Bin) {
            self.report_warning(.fit_non_exhaustive, fit_stmt, "fit statement is not exhausted for {s} condition (missing catch-all '_' branch)", .{@tagName(cond_type)});
            return;
        }

        if (!(has_true and has_false)) {
            if (!has_true and !has_false) {
                self.report_warning(.fit_non_exhaustive, fit_stmt, "fit statement is not exhausted for bin condition (missing true and false branches)", .{});
            } else if (!has_true) {
                self.report_warning(.fit_non_exhaustive, fit_stmt, "fit statement is not exhausted for bin condition (missing true branch)", .{});
            } else {
                self.report_warning(.fit_non_exhaustive, fit_stmt, "fit statement is not exhausted for bin condition (missing false branch)", .{});
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

        // Determine if this is a function symbol and whether it is public.
        var is_function = false;
        var is_public = false;
        if (s.type == symbol.SymbolType.Node) {
            if (s.data) |data| {
                is_function = data.node.type == .Function;
                is_public = node_is_public(&data.node);
            }
        }

        // Register the symbol in global registry to detect conflicts in other modules.
        // Only public symbols are visible across modules.
        if (is_public and !mem.eql(u8, s.name, "main")) {
            self.global_symbols.put(s.name, .{
                .symbol_name = s.name,
                .file_path = self.input_file_path,
                .is_function = is_function,
                .is_public = true,
            }) catch |e| {
                std.debug.print("Error registering symbol '{s}': {s}\n", .{ s.name, @errorName(e) });
                return TranspileError.MemoryAllocationFailed;
            };
        }

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

                if (node_is_public(&node)) {
                    // Register the symbol in global registry
                    self.global_symbols.put(variable.name.items, .{
                        .symbol_name = variable.name.items,
                        .file_path = self.input_file_path,
                        .is_function = false,
                        .is_public = true,
                    }) catch |e| {
                        std.debug.print("Error registering symbol '{s}': {s}\n", .{ variable.name.items, @errorName(e) });
                        return TranspileError.MemoryAllocationFailed;
                    };
                }

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

                if (node_is_public(&node)) {
                    // Register the symbol in global registry
                    self.global_symbols.put(function.name.?.items, .{
                        .symbol_name = function.name.?.items,
                        .file_path = self.input_file_path,
                        .is_function = true,
                        .is_public = true,
                    }) catch |e| {
                        std.debug.print("Error registering symbol '{s}': {s}\n", .{ function.name.?.items, @errorName(e) });
                        return TranspileError.MemoryAllocationFailed;
                    };
                }

                try self.register_symbol(s);
            },
            .compound => |compound| {
                const is_public = node_is_public(&node);
                if (is_public) {
                    self.global_symbols.put(compound.name.items, .{
                        .symbol_name = compound.name.items,
                        .file_path = self.input_file_path,
                        .is_function = false,
                        .is_public = true,
                    }) catch |e| {
                        std.debug.print("Error registering symbol '{s}': {s}\n", .{ compound.name.items, @errorName(e) });
                        return TranspileError.MemoryAllocationFailed;
                    };
                }
            },
            .enum_decl => |enum_decl| {
                const is_public = node_is_public(&node);
                if (is_public) {
                    self.global_symbols.put(enum_decl.name.items, .{
                        .symbol_name = enum_decl.name.items,
                        .file_path = self.input_file_path,
                        .is_function = false,
                        .is_public = true,
                    }) catch |e| {
                        std.debug.print("Error registering symbol '{s}': {s}\n", .{ enum_decl.name.items, @errorName(e) });
                        return TranspileError.MemoryAllocationFailed;
                    };
                }
            },
            .quirk => |quirk| {
                const is_public = node_is_public(&node);
                if (is_public) {
                    self.global_symbols.put(quirk.name.items, .{
                        .symbol_name = quirk.name.items,
                        .file_path = self.input_file_path,
                        .is_function = false,
                        .is_public = true,
                    }) catch |e| {
                        std.debug.print("Error registering symbol '{s}': {s}\n", .{ quirk.name.items, @errorName(e) });
                        return TranspileError.MemoryAllocationFailed;
                    };
                }
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
                    if (imp.alias) |alias| self.allocator.free(alias);
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
                    if (variable.type.generic_args) |*gargs| {
                        for (gargs.items()) |ga| {
                            ga.type_str.deinit();
                            if (ga.array) |array| {
                                if (!array.brackets.is_empty()) {
                                    for (array.brackets.items()) |bracket| {
                                        self.deinit_node(bracket);
                                    }
                                }
                                array.brackets.deinit();
                            }
                            allocator.destroy(ga);
                        }
                        gargs.deinit();
                    }
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
                .compound_init => |cinit| {
                    if (cinit.dtype) |dt| {
                        dt.type_str.deinit();
                        if (dt.generic_args) |*gargs| {
                            for (gargs.items()) |ga| {
                                ga.type_str.deinit();
                                if (ga.array) |array| {
                                    if (!array.brackets.is_empty()) {
                                        for (array.brackets.items()) |bracket| {
                                            self.deinit_node(bracket);
                                        }
                                    }
                                    array.brackets.deinit();
                                }
                                allocator.destroy(ga);
                            }
                            gargs.deinit();
                        }
                        if (dt.array) |array| {
                            if (!array.brackets.is_empty()) {
                                for (array.brackets.items()) |bracket| {
                                    self.deinit_node(bracket);
                                }
                            }
                            array.brackets.deinit();
                        }
                        allocator.destroy(dt);
                    }
                    for (cinit.fields.items()) |f| {
                        f.name.deinit();
                        self.deinit_node(f.value.*);
                        allocator.destroy(f.value);
                    }
                    cinit.fields.deinit();
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
                    if (function.type_params) |*params| {
                        for (params.items()) |*p| {
                            p.deinit();
                        }
                        params.deinit();
                    }
                    if (function.rtype) |rtype| {
                        rtype.type_str.deinit();
                        if (rtype.generic_args) |*gargs| {
                            for (gargs.items()) |ga| {
                                ga.type_str.deinit();
                                if (ga.array) |array| {
                                    if (!array.brackets.is_empty()) {
                                        for (array.brackets.items()) |bracket| {
                                            self.deinit_node(bracket);
                                        }
                                    }
                                    array.brackets.deinit();
                                }
                                allocator.destroy(ga);
                            }
                            gargs.deinit();
                        }
                    }
                    if (function.name) |name| {
                        name.deinit();
                    }
                },
                .compound => |c| {
                    c.name.deinit();
                    if (c.type_params) |*params| {
                        for (params.items()) |*p| {
                            p.deinit();
                        }
                        params.deinit();
                    }
                    for (c.fields.items()) |f| {
                        f.name.deinit();
                        f.dtype.type_str.deinit();
                        if (f.dtype.generic_args) |*gargs| {
                            for (gargs.items()) |ga| {
                                ga.type_str.deinit();
                                if (ga.array) |array| {
                                    if (!array.brackets.is_empty()) {
                                        for (array.brackets.items()) |bracket| {
                                            self.deinit_node(bracket);
                                        }
                                    }
                                    array.brackets.deinit();
                                }
                                allocator.destroy(ga);
                            }
                            gargs.deinit();
                        }
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
                        if (m.rtype.generic_args) |*gargs| {
                            for (gargs.items()) |ga| {
                                ga.type_str.deinit();
                                if (ga.array) |array| {
                                    if (!array.brackets.is_empty()) {
                                        for (array.brackets.items()) |bracket| {
                                            self.deinit_node(bracket);
                                        }
                                    }
                                    array.brackets.deinit();
                                }
                                allocator.destroy(ga);
                            }
                            gargs.deinit();
                        }
                        for (m.args.items()) |a| {
                            a.name.deinit();
                            a.dtype.type_str.deinit();
                            if (a.dtype.generic_args) |*gargs| {
                                for (gargs.items()) |ga| {
                                    ga.type_str.deinit();
                                    if (ga.array) |array| {
                                        if (!array.brackets.is_empty()) {
                                            for (array.brackets.items()) |bracket| {
                                                self.deinit_node(bracket);
                                            }
                                        }
                                        array.brackets.deinit();
                                    }
                                    allocator.destroy(ga);
                                }
                                gargs.deinit();
                            }
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
                .enum_decl => |e| {
                    e.name.deinit();
                    for (e.variants.items()) |v| {
                        v.name.deinit();
                    }
                    e.variants.deinit();
                },
                .impl => |im| {
                    im.type_name.deinit();
                    if (im.type_params) |*params| {
                        for (params.items()) |*p| {
                            p.deinit();
                        }
                        params.deinit();
                    }
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
                        .defer_stmt => |d| {
                            _ = d;
                            // Defer bodies are owned elsewhere in the AST; avoid double-free.
                        },
                        .asm_stmt => |a| {
                            a.template.deinit();
                            if (a.arch) |*arch| {
                                arch.deinit();
                            }
                            for (a.outputs.items()) |op| {
                                op.name.deinit();
                                op.constraint.deinit();
                                self.deinit_node(op.expr.*);
                                allocator.destroy(op.expr);
                            }
                            a.outputs.deinit();
                            for (a.inputs.items()) |op| {
                                op.name.deinit();
                                op.constraint.deinit();
                                self.deinit_node(op.expr.*);
                                allocator.destroy(op.expr);
                            }
                            a.inputs.deinit();
                            for (a.clobbers.items()) |cl| {
                                cl.deinit();
                            }
                            a.clobbers.deinit();
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
                        .assert_stmt => |asrt| {
                            self.deinit_node(asrt.condition.*);
                            allocator.destroy(asrt.condition);
                            if (asrt.message) |msg| {
                                self.deinit_node(msg.*);
                                allocator.destroy(msg);
                            }
                        },
                        .warning_ctrl => |_| {
                            // reason points into token memory and is not owned by AST nodes.
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
        self.pending_warning_allows.deinit();
        self.pending_warning_expects.deinit();

        // Most allocations in a `TranspileProcess` are arena-backed; deinit the
        // containers, then release the arena at the end.
        self.owned_scope_entities.deinit();
        self.owned_nodes.deinit();
        self.defer_stack.deinit();
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

        if (self.import_aliases.count() > 0) {
            var ait = self.import_aliases.iterator();
            while (ait.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
        }
        self.import_aliases.deinit();

        // Deinit children TranspileProcesses
        for (self.children.items) |child| {
            child.deinit();
            self.backing_allocator.destroy(child);
        }
        self.children.deinit();

        self.std_imports.deinit();

        if (self.emitted_generic_spec_keys.count() > 0) {
            var esit = self.emitted_generic_spec_keys.iterator();
            while (esit.next()) |e| {
                self.allocator.free(e.key_ptr.*);
            }
        }
        self.emitted_generic_spec_keys.deinit();

        // Generic function instantiation tracking.
        if (self.generic_fn_instantiation_keys.count() > 0) {
            var it = self.generic_fn_instantiation_keys.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
            }
        }
        self.generic_fn_instantiation_keys.deinit();
        self.generic_fn_instantiations.deinit();

        if (self.generic_call_overrides.count() > 0) {
            var it2 = self.generic_call_overrides.iterator();
            while (it2.next()) |e| {
                self.allocator.free(e.key_ptr.*);
            }
        }
        self.generic_call_overrides.deinit();

        if (self.await_call_overrides.count() > 0) {
            var it3 = self.await_call_overrides.iterator();
            while (it3.next()) |e| {
                self.allocator.free(e.key_ptr.*);
            }
        }
        self.await_call_overrides.deinit();

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

    fn emit_defer_body(self: *Self, node: *ast.Node) TranspileError!void {
        if (node.type == .Body) {
            try self.transpile_node(node.*);
            return;
        }
        try self.transpile_node(node.*);
        if (node.type == .Expression or node.type == .ExpressionParenthesis or node.type == .Unary) {
            try self.write(";");
        }
    }

    fn emit_defers(self: *Self) TranspileError!void {
        if (self.defer_stack.items.len == 0) return;
        var i: usize = self.defer_stack.items.len;
        while (i > 0) : (i -= 1) {
            const d = self.defer_stack.items[i - 1];
            try self.write_indent();
            try self.emit_defer_body(d);
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
        if (mem.eql(u8, type_str, "num")) return "int64_t";
        if (mem.eql(u8, type_str, "dec")) return "double";
        if (mem.eql(u8, type_str, "f32")) return "float";
        if (mem.eql(u8, type_str, "f64")) return "double";
        if (mem.eql(u8, type_str, "i8")) return "int8_t";
        if (mem.eql(u8, type_str, "i16")) return "int16_t";
        if (mem.eql(u8, type_str, "i32")) return "int32_t";
        if (mem.eql(u8, type_str, "i64")) return "int64_t";
        if (mem.eql(u8, type_str, "u8")) return "uint8_t";
        if (mem.eql(u8, type_str, "u16")) return "uint16_t";
        if (mem.eql(u8, type_str, "u32")) return "uint32_t";
        if (mem.eql(u8, type_str, "u64")) return "uint64_t";
        if (mem.eql(u8, type_str, "str")) return "char*";
        if (mem.eql(u8, type_str, "bin")) return "bool";
        if (mem.eql(u8, type_str, "chr")) return "char";
        if (mem.eql(u8, type_str, "raw")) return "void";
        return type_str;
    }

    fn write_dynamic_int_type(self: *Self, type_str: []const u8) TranspileError!bool {
        const dyn = utils.parse_dynamic_int_datatype(type_str) orelse return false;
        switch (dyn.bits) {
            8 => {
                try self.write(if (dyn.is_signed) "int8_t" else "uint8_t");
                return true;
            },
            16 => {
                try self.write(if (dyn.is_signed) "int16_t" else "uint16_t");
                return true;
            },
            32 => {
                try self.write(if (dyn.is_signed) "int32_t" else "uint32_t");
                return true;
            },
            64 => {
                try self.write(if (dyn.is_signed) "int64_t" else "uint64_t");
                return true;
            },
            else => {
                if (dyn.is_signed) {
                    try self.print("_BitInt({d})", .{dyn.bits});
                } else {
                    try self.print("unsigned _BitInt({d})", .{dyn.bits});
                }
                return true;
            },
        }
    }

    fn append_mangled_type(self: *Self, buf: *std.ArrayList(u8), dt: *const dtype.DataType) TranspileError!void {
        if (dt.type_str.items.len > 0 and @intFromPtr(dt.type_str.items.ptr) == 0) {
            return TranspileError.TypeMismatch;
        }
        buf.appendSlice(dt.type_str.items) catch return TranspileError.MemoryAllocationFailed;
        if (dt.generic_args) |gargs| {
            for (gargs.items()) |ga| {
                buf.appendSlice("__") catch return TranspileError.MemoryAllocationFailed;
                try self.append_mangled_type(buf, ga);
            }
        }
    }

    fn type_name_mangled(self: *Self, dt: *const dtype.DataType) TranspileError![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();
        try self.append_mangled_type(&buf, dt);
        return buf.toOwnedSlice() catch return TranspileError.MemoryAllocationFailed;
    }

    fn append_mangled_type_with_subst(self: *Self, buf: *std.ArrayList(u8), dt: *const dtype.DataType, params: utils.Vector(std.ArrayList(u8)), args: []*dtype.DataType) TranspileError!void {
        if ((dt.type == null or dt.type == .Unknown) and dt.type_str.items.len > 0) {
            for (params.items(), 0..) |p, i| {
                if (mem.eql(u8, p.items, dt.type_str.items)) {
                    try self.append_mangled_type(buf, args[i]);
                    return;
                }
            }
        }

        buf.appendSlice(dt.type_str.items) catch return TranspileError.MemoryAllocationFailed;
        if (dt.generic_args) |gargs| {
            for (gargs.items()) |ga| {
                buf.appendSlice("__") catch return TranspileError.MemoryAllocationFailed;
                try self.append_mangled_type_with_subst(buf, ga, params, args);
            }
        }
    }

    fn type_name_mangled_with_subst(self: *Self, dt: *const dtype.DataType, params: utils.Vector(std.ArrayList(u8)), args: []*dtype.DataType) TranspileError![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();
        try self.append_mangled_type_with_subst(&buf, dt, params, args);
        return buf.toOwnedSlice() catch return TranspileError.MemoryAllocationFailed;
    }

    fn type_name_mangled_for_emit(self: *Self, dt: *const dtype.DataType) TranspileError![]const u8 {
        if (self.type_subst_params != null and self.type_subst_args != null) {
            if (self.dtype_needs_subst(dt)) {
                return self.type_name_mangled_with_subst(dt, self.type_subst_params.?.*, self.type_subst_args.?);
            }
        }
        return self.type_name_mangled(dt);
    }

    fn type_from_dtype_with_subst(self: *Self, dt: *const dtype.DataType, params: utils.Vector(std.ArrayList(u8)), args: []*dtype.DataType) TranspileError!CheckedType {
        if ((dt.type == null or dt.type == .Unknown) and dt.type_str.items.len > 0) {
            const params_items = params.items();
            var i: usize = 0;
            while (i < params_items.len and i < args.len) : (i += 1) {
                const p = params_items[i];
                if (mem.eql(u8, p.items, dt.type_str.items)) {
                    var sub = args[i].*;
                    if (dt.pointer_depth > 0) {
                        var flags = sub.flags orelse dtype.DataTypeFlags{};
                        flags.is_pointer = true;
                        sub.flags = flags;
                        sub.pointer_depth += dt.pointer_depth;
                    }
                    return try self.type_from_dtype_with_mangled(&sub);
                }
            }
        }

        var out = type_from_dtype(dt);
        if (dt.generic_args != null and (dt.type == null or dt.type == .Unknown)) {
            out.mangled_name = try self.type_name_mangled_with_subst(dt, params, args);
        }
        return out;
    }

    fn dtype_needs_subst(self: *Self, dt: *const dtype.DataType) bool {
        const params = self.type_subst_params orelse return false;
        if ((dt.type == null or dt.type == .Unknown) and dt.type_str.items.len > 0) {
            for (params.items()) |p| {
                if (mem.eql(u8, p.items, dt.type_str.items)) return true;
            }
        }
        if (dt.generic_args) |gargs| {
            for (gargs.items()) |ga| {
                if (self.dtype_needs_subst(ga)) return true;
            }
        }
        return false;
    }

    fn dtype_contains_type_param(self: *Self, dt: *const dtype.DataType, params: *const utils.Vector(std.ArrayList(u8))) bool {
        if ((dt.type == null or dt.type == .Unknown) and dt.type_str.items.len > 0) {
            for (params.items()) |p| {
                if (mem.eql(u8, p.items, dt.type_str.items)) return true;
            }
        }
        if (dt.generic_args) |gargs| {
            for (gargs.items()) |ga| {
                if (self.dtype_contains_type_param(ga, params)) return true;
            }
        }
        return false;
    }

    fn mangled_contains_type_param(self: *Self, mangled: []const u8, params: *const utils.Vector(std.ArrayList(u8))) bool {
        _ = self;
        for (params.items()) |p| {
            const needle = p.items;
            if (needle.len == 0) continue;
            var start: usize = 0;
            while (true) {
                const idx_opt = mem.indexOfPos(u8, mangled, start, "__") orelse break;
                const seg_start = idx_opt + 2;
                if (seg_start + needle.len <= mangled.len and mem.eql(u8, mangled[seg_start .. seg_start + needle.len], needle)) {
                    const seg_end = seg_start + needle.len;
                    if (seg_end == mangled.len or (seg_end + 1 <= mangled.len and mem.eql(u8, mangled[seg_end .. seg_end + 2], "__"))) {
                        return true;
                    }
                }
                start = seg_start;
            }
        }
        return false;
    }

    fn mangled_contains_unresolved_placeholder(_: *Self, mangled: []const u8) bool {
        var i: usize = 0;
        while (i + 2 <= mangled.len) {
            const sep = mem.indexOfPos(u8, mangled, i, "__") orelse break;
            const seg_start = sep + 2;
            if (seg_start >= mangled.len) break;

            const next_sep = mem.indexOfPos(u8, mangled, seg_start, "__") orelse mangled.len;
            const seg = mangled[seg_start..next_sep];
            if (seg.len == 1 and seg[0] >= 'A' and seg[0] <= 'Z') return true;
            i = next_sep;
        }
        return false;
    }

    fn generic_args_are_concrete(self: *Self, params: *const utils.Vector(std.ArrayList(u8)), gargs: []*dtype.DataType) bool {
        for (gargs) |ga| {
            if (self.dtype_contains_type_param(ga, params)) return false;
        }
        return true;
    }

    fn dtype_has_unresolved_placeholder(self: *Self, dt: *const dtype.DataType) bool {
        if ((dt.type == null or dt.type == .Unknown) and dt.type_str.items.len == 1) {
            const c = dt.type_str.items[0];
            if (c >= 'A' and c <= 'Z') return true;
        }
        if (dt.generic_args) |gargs| {
            for (gargs.items()) |ga| {
                if (self.dtype_has_unresolved_placeholder(ga)) return true;
            }
        }
        return false;
    }

    fn function_has_unresolved_placeholder(self: *Self, node: ast.Node) bool {
        if (node.type != .Function or node.node_variant == null) return false;
        const function = node.node_variant.?.function;
        if (function.rtype) |rt| {
            if (self.dtype_has_unresolved_placeholder(&rt)) return true;
        }
        if (function.args) |args| {
            for (args.items()) |arg| {
                if (arg.*.type != .Variable or arg.*.node_variant == null) continue;
                if (self.dtype_has_unresolved_placeholder(arg.*.node_variant.?.variable.type)) return true;
            }
        }
        return false;
    }

    /// Helper function to write data type to output (no substitutions).
    fn write_type_no_subst(self: *Self, data_type: dtype.DataType) TranspileError!void {
        if (data_type.generic_args != null and data_type.type == .Unknown) {
            const mangled = try self.type_name_mangled(&data_type);
            defer self.allocator.free(mangled);
            try self.write(mangled);
        } else {
            const type_name = if ((data_type.type == null or data_type.type == .Unknown) and data_type.type_str.items.len > 0)
                self.c_type_name_for_user_type(data_type.type_str.items)
            else
                data_type.type_str.items;

            if (!(try self.write_dynamic_int_type(type_name))) {
                const c_type = map_type_to_c(type_name);
                try self.write(c_type);
            }
        }

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

    /// Helper function to write data type to output
    fn write_type(self: *Self, data_type: dtype.DataType) TranspileError!void {
        if (self.type_subst_params != null and self.type_subst_args != null) {
            if (self.dtype_needs_subst(&data_type)) {
                return self.write_type_with_subst(&data_type, self.type_subst_params.?.*, self.type_subst_args.?);
            }
        }
        return self.write_type_no_subst(data_type);
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

    fn c_type_name_for_user_type(self: *Self, name: []const u8) []const u8 {
        const reg = self.root_registry() orelse return name;

        if (reg.enums_by_name.get(name)) |enode| {
            if (enode.node_variant != null) {
                return enode.node_variant.?.enum_decl.name.items;
            }
        }

        if (reg.compounds_by_name.get(name)) |cnode| {
            if (cnode.node_variant != null) {
                return cnode.node_variant.?.compound.name.items;
            }
        }

        if (reg.quirk_sig_by_name.get(name)) |sig| {
            if (reg.quirks_by_sig.get(sig)) |qnode| {
                if (qnode.node_variant != null) {
                    return qnode.node_variant.?.quirk.name.items;
                }
            }
        }

        return name;
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

    fn expr_named_type_from_scope(self: *Self, node: ast.Node) ?[]const u8 {
        switch (node.type) {
            .Identifier => {
                if (node.data == null) return null;
                const dt = self.identifier_declared_dtype(node.data.?.sval.items) orelse return null;
                if (dt.type != .Unknown) return null;
                return dt.type_str.items;
            },
            .ExpressionParenthesis => {
                if (node.node_variant == null) return null;
                return self.expr_named_type_from_scope(node.node_variant.?.paren.exp.*);
            },
            .Expression => {
                if (node.node_variant == null) return null;
                const exp = node.node_variant.?.exp;
                if (!mem.eql(u8, exp.op, ".")) return null;

                const left = exp.left orelse return null;
                const right = exp.right orelse return null;
                if (right.*.type != .Identifier or right.*.data == null) return null;

                const left_name = self.expr_named_type_from_scope(left.*) orelse return null;
                const left_name_canon = self.canonical_compound_name(left_name);
                const fdt = self.lookup_compound_field(left_name_canon, right.*.data.?.sval.items) orelse return null;
                if (fdt.type != .Unknown) return null;
                return fdt.type_str.items;
            },
            else => return null,
        }
    }

    fn expr_is_quirk_typed_from_scope(self: *Self, node: ast.Node) bool {
        const tname = self.expr_named_type_from_scope(node) orelse return false;
        return self.is_quirk_name(tname);
    }

    fn node_is_public(node: *const ast.Node) bool {
        return node.flags != null and node.flags.?.is_public;
    }

    fn same_module(ref_node: ?*const ast.Node, def_node: *const ast.Node) bool {
        if (ref_node == null) return true;
        const ref_pos = ref_node.?.pos orelse return true;
        const def_pos = def_node.pos orelse return true;
        return mem.eql(u8, ref_pos.filename, def_pos.filename);
    }

    fn can_access(self: *Self, ref_node: ?*const ast.Node, def_node: *const ast.Node) bool {
        _ = self;
        return node_is_public(def_node) or same_module(ref_node, def_node);
    }

    fn method_is_public(self: *Self, impl_node: *const ast.Node, method_node: *const ast.Node) bool {
        _ = self;
        return node_is_public(method_node) or node_is_public(impl_node);
    }

    fn can_access_method(self: *Self, ref_node: ?*const ast.Node, impl_node: *const ast.Node, method_node: *const ast.Node) bool {
        return self.method_is_public(impl_node, method_node) or same_module(ref_node, method_node);
    }

    fn same_node_file(self: *Self, a: *const ast.Node, b: *const ast.Node) bool {
        _ = self;
        const apos = a.pos orelse return false;
        const bpos = b.pos orelse return false;
        return mem.eql(u8, apos.filename, bpos.filename);
    }

    fn is_std_c_signature_node(self: *Self, node: *const ast.Node) bool {
        _ = self;
        const pos = node.pos orelse return false;
        if (std.mem.indexOf(u8, pos.filename, "/std/c/") != null) return true;
        if (std.mem.indexOf(u8, pos.filename, "\\std\\c\\") != null) return true;
        return false;
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

        const registry = self.root_registry() orelse return;

        try self.write("// --- User types ---\n\n");

        // Enums (must come before compounds that use them by-value)
        var enum_nodes = std.ArrayList(*ast.Node).init(self.allocator);
        defer enum_nodes.deinit();

        var seen_enum_names = std.StringHashMap(bool).init(self.allocator);
        defer seen_enum_names.deinit();

        var e_it = registry.enums_by_name.iterator();
        while (e_it.next()) |entry| {
            const enode = entry.value_ptr.*;
            if (enode.node_variant == null) continue;
            const e = enode.node_variant.?.enum_decl;
            if (seen_enum_names.contains(e.name.items)) continue;
            seen_enum_names.put(e.name.items, true) catch {
                return TranspileError.MemoryAllocationFailed;
            };
            enum_nodes.append(enode) catch {
                return TranspileError.MemoryAllocationFailed;
            };
        }

        std.sort.pdq(*ast.Node, enum_nodes.items, {}, struct {
            fn lessThan(_: void, a: *ast.Node, b: *ast.Node) bool {
                if (a.node_variant == null or b.node_variant == null) return false;
                return mem.lessThan(u8, a.node_variant.?.enum_decl.name.items, b.node_variant.?.enum_decl.name.items);
            }
        }.lessThan);

        var emitted_enum_names = std.StringHashMap(bool).init(self.allocator);
        defer emitted_enum_names.deinit();

        for (enum_nodes.items) |enode| {
            if (enode.node_variant == null) continue;
            if (self.is_std_c_signature_node(enode)) continue;
            const e = enode.node_variant.?.enum_decl;
            if (emitted_enum_names.contains(e.name.items)) continue;
            emitted_enum_names.put(e.name.items, true) catch {
                return TranspileError.MemoryAllocationFailed;
            };
            try self.write("typedef enum ");
            try self.write(e.name.items);
            try self.write(" {\n");
            for (e.variants.items()) |v| {
                try self.write("  ");
                try self.write(e.name.items);
                try self.write("_");
                try self.write(v.name.items);
                if (v.value) |val| {
                    try self.write(" = ");
                    try self.print("{d}", .{val});
                }
                try self.write(",\n");
            }
            try self.write("} ");
            try self.write(e.name.items);
            try self.write(";\n\n");
        }

        // Compounds
        // NOTE: `std.StringHashMap` iteration order is not stable and can place
        // dependent compounds before their dependencies (e.g. Rectangle before Point).
        // Emit compounds in a stable order that respects by-value dependencies.

        var compound_nodes = std.ArrayList(*ast.Node).init(self.allocator);
        defer compound_nodes.deinit();

        var seen_compound_names = std.StringHashMap(bool).init(self.allocator);
        defer seen_compound_names.deinit();

        var c_it = registry.compounds_by_name.iterator();
        while (c_it.next()) |entry| {
            const cnode = entry.value_ptr.*;
            if (cnode.node_variant == null) continue;
            const c = cnode.node_variant.?.compound;
            if (seen_compound_names.contains(c.name.items)) continue;
            seen_compound_names.put(c.name.items, true) catch {
                return TranspileError.MemoryAllocationFailed;
            };
            compound_nodes.append(cnode) catch {
                return TranspileError.MemoryAllocationFailed;
            };
        }

        std.sort.pdq(*ast.Node, compound_nodes.items, {}, struct {
            fn lessThan(_: void, a: *ast.Node, b: *ast.Node) bool {
                if (a.node_variant == null or b.node_variant == null) return false;
                return mem.lessThan(u8, a.node_variant.?.compound.name.items, b.node_variant.?.compound.name.items);
            }
        }.lessThan);

        var emitted_compounds = std.StringHashMap(bool).init(self.allocator);
        defer emitted_compounds.deinit();

        var remaining = std.ArrayList(*ast.Node).init(self.allocator);
        defer remaining.deinit();
        remaining.appendSlice(compound_nodes.items) catch {
            return TranspileError.MemoryAllocationFailed;
        };

        var spec_keys = std.StringHashMap(bool).init(self.allocator);
        defer spec_keys.deinit();

        var specs = std.ArrayList(GenericSpec).init(self.allocator);
        defer {
            for (specs.items) |s| self.allocator.free(s.mangled);
            specs.deinit();
        }

        // Collect concrete generic compound specializations.
        for (compound_nodes.items) |cnode| {
            if (cnode.node_variant == null) continue;
            if (self.is_std_c_signature_node(cnode)) continue;
            const c = cnode.node_variant.?.compound;
            const params = c.type_params orelse continue;

            var inst_keys = std.StringHashMap(bool).init(self.allocator);
            defer {
                var it = inst_keys.iterator();
                while (it.next()) |e| {
                    self.allocator.free(e.key_ptr.*);
                }
                inst_keys.deinit();
            }

            var inst_list = std.ArrayList(*const dtype.DataType).init(self.allocator);
            defer inst_list.deinit();

            try self.collect_generic_instantiations_recursive(self, c.name.items, &inst_keys, &inst_list);

            for (inst_list.items) |dt| {
                if (dt.generic_args == null) continue;
                const gargs = dt.generic_args.?.items();
                if (gargs.len != params.count) continue;
                if (self.dtype_contains_type_param(dt, &params)) continue;

                // Ensure field-level generic dependencies are registered with concrete args.
                for (c.fields.items()) |f| {
                    if (f.dtype.generic_args == null) continue;
                    const dep = try self.clone_dtype_with_subst_for_inst(f.dtype, &params, gargs);
                    try self.register_generic_instantiations_from_dtype(dep);
                }

                const mangled = try self.type_name_mangled(dt);
                if (self.mangled_contains_type_param(mangled, &params)) {
                    self.allocator.free(mangled);
                    continue;
                }
                if (self.mangled_contains_unresolved_placeholder(mangled)) {
                    self.allocator.free(mangled);
                    continue;
                }
                if (!spec_keys.contains(mangled)) {
                    spec_keys.put(mangled, true) catch return TranspileError.MemoryAllocationFailed;
                    specs.append(.{ .cnode = cnode, .dt = dt, .mangled = mangled }) catch {
                        return TranspileError.MemoryAllocationFailed;
                    };
                } else {
                    self.allocator.free(mangled);
                }
            }

            // Include forced generic instantiations for this compound.
            const root = self.get_root();
            for (root.forced_generic_instantiations.items) |dt| {
                if (dt.generic_args == null) continue;
                const dt_base = if (mem.indexOf(u8, dt.type_str.items, "__")) |idx| dt.type_str.items[0..idx] else dt.type_str.items;
                if (!mem.eql(u8, dt_base, c.name.items)) continue;
                const gargs = dt.generic_args.?.items();
                if (gargs.len != params.count) continue;
                if (self.dtype_contains_type_param(dt, &params)) continue;
                const mangled = try self.type_name_mangled(dt);
                if (self.mangled_contains_type_param(mangled, &params)) {
                    self.allocator.free(mangled);
                    continue;
                }
                if (self.mangled_contains_unresolved_placeholder(mangled)) {
                    self.allocator.free(mangled);
                    continue;
                }
                if (!spec_keys.contains(mangled)) {
                    spec_keys.put(mangled, true) catch return TranspileError.MemoryAllocationFailed;
                    specs.append(.{ .cnode = cnode, .dt = dt, .mangled = mangled }) catch {
                        return TranspileError.MemoryAllocationFailed;
                    };
                } else {
                    self.allocator.free(mangled);
                }
            }
        }

        // Expand specs with field-level generic dependencies (e.g. Set<str> -> Map<str, bin>).
        var si_expand: usize = 0;
        while (si_expand < specs.items.len) {
            const s = specs.items[si_expand];
            si_expand += 1;
            if (s.cnode.node_variant == null) continue;
            const c = s.cnode.node_variant.?.compound;
            const params = c.type_params orelse continue;
            const gargs_vec = s.dt.generic_args orelse continue;
            const gargs = gargs_vec.items();

            for (c.fields.items()) |f| {
                if (f.dtype.generic_args == null) continue;
                const dep_dt = try self.clone_dtype_with_subst_for_inst(f.dtype, &params, gargs);
                if (dep_dt.generic_args == null) continue;
                if (self.dtype_has_unresolved_placeholder(dep_dt)) continue;

                const dep_base = if (mem.indexOf(u8, dep_dt.type_str.items, "__")) |idx| dep_dt.type_str.items[0..idx] else dep_dt.type_str.items;
                const dep_cnode = registry.compounds_by_name.get(dep_base) orelse continue;
                if (dep_cnode.node_variant == null) continue;
                if (dep_cnode.node_variant.?.compound.type_params == null) continue;

                const dep_mangled = try self.type_name_mangled(dep_dt);
                if (self.mangled_contains_unresolved_placeholder(dep_mangled)) {
                    self.allocator.free(dep_mangled);
                    continue;
                }
                if (!spec_keys.contains(dep_mangled)) {
                    spec_keys.put(dep_mangled, true) catch return TranspileError.MemoryAllocationFailed;
                    specs.append(.{ .cnode = dep_cnode, .dt = dep_dt, .mangled = dep_mangled }) catch {
                        return TranspileError.MemoryAllocationFailed;
                    };
                } else {
                    self.allocator.free(dep_mangled);
                }
            }
        }

        // Expand specs with impl signature dependencies (e.g. Map<K,V>::values -> Vec<V>).
        var si_impl: usize = 0;
        while (si_impl < specs.items.len) {
            const s = specs.items[si_impl];
            si_impl += 1;
            if (s.cnode.node_variant == null) continue;
            const c = s.cnode.node_variant.?.compound;
            const params = c.type_params orelse continue;
            const gargs_vec = s.dt.generic_args orelse continue;
            const gargs = gargs_vec.items();

            var proc_stack = std.ArrayList(*Self).init(self.allocator);
            defer proc_stack.deinit();
            const root_proc = self.get_root();
            proc_stack.append(root_proc) catch return TranspileError.MemoryAllocationFailed;

            while (proc_stack.items.len > 0) {
                const proc_opt = proc_stack.pop();
                const proc = proc_opt orelse continue;
                for (proc.nodes.items()) |node| {
                    var node_copy = node;
                    const node_ptr = &node_copy;
                    if (node_ptr.type != .Impl or node_ptr.node_variant == null) continue;
                    const im = node_ptr.node_variant.?.impl;
                    if (im.quirk_name != null) continue;
                    const base_name = if (mem.indexOf(u8, im.type_name.items, "__")) |idx| im.type_name.items[0..idx] else im.type_name.items;
                    if (!mem.eql(u8, base_name, c.name.items)) continue;
                    const impl_params = self.impl_type_params(node_ptr) orelse continue;
                    if (impl_params.count != params.count) continue;
                    if (gargs.len != impl_params.count) continue;

                    for (im.methods.items()) |m| {
                        if (m.type != .Function or m.node_variant == null) continue;
                        const fnv = m.node_variant.?.function;
                        if (fnv.rtype) |rt| {
                            const rt_sub = try self.clone_dtype_with_subst_for_inst(&rt, impl_params, gargs);
                            if (!self.dtype_has_unresolved_placeholder(rt_sub)) {
                                try self.register_generic_instantiations_from_dtype(rt_sub);
                                try self.add_spec_from_dtype(registry, rt_sub, &spec_keys, &specs);
                            }
                        }
                        if (fnv.args) |args_nodes| {
                            for (args_nodes.items()) |arg| {
                                if (arg.type != .Variable or arg.node_variant == null) continue;
                                const adt = arg.node_variant.?.variable.type;
                                const adt_sub = try self.clone_dtype_with_subst_for_inst(adt, impl_params, gargs);
                                if (!self.dtype_has_unresolved_placeholder(adt_sub)) {
                                    try self.register_generic_instantiations_from_dtype(adt_sub);
                                    try self.add_spec_from_dtype(registry, adt_sub, &spec_keys, &specs);
                                }
                            }
                        }
                    }
                }

                for (proc.owned_nodes.items) |n| {
                    if (n.type != .Impl or n.node_variant == null) continue;
                    const im = n.node_variant.?.impl;
                    if (im.quirk_name != null) continue;
                    const base_name = if (mem.indexOf(u8, im.type_name.items, "__")) |idx| im.type_name.items[0..idx] else im.type_name.items;
                    if (!mem.eql(u8, base_name, c.name.items)) continue;
                    const impl_params = self.impl_type_params(n) orelse continue;
                    if (impl_params.count != params.count) continue;
                    if (gargs.len != impl_params.count) continue;

                    for (im.methods.items()) |m| {
                        if (m.type != .Function or m.node_variant == null) continue;
                        const fnv = m.node_variant.?.function;
                        if (fnv.rtype) |rt| {
                            const rt_sub = try self.clone_dtype_with_subst_for_inst(&rt, impl_params, gargs);
                            if (!self.dtype_has_unresolved_placeholder(rt_sub)) {
                                try self.register_generic_instantiations_from_dtype(rt_sub);
                                try self.add_spec_from_dtype(registry, rt_sub, &spec_keys, &specs);
                            }
                        }
                        if (fnv.args) |args_nodes| {
                            for (args_nodes.items()) |arg| {
                                if (arg.type != .Variable or arg.node_variant == null) continue;
                                const adt = arg.node_variant.?.variable.type;
                                const adt_sub = try self.clone_dtype_with_subst_for_inst(adt, impl_params, gargs);
                                if (!self.dtype_has_unresolved_placeholder(adt_sub)) {
                                    try self.register_generic_instantiations_from_dtype(adt_sub);
                                    try self.add_spec_from_dtype(registry, adt_sub, &spec_keys, &specs);
                                }
                            }
                        }
                    }
                }

                for (proc.children.items) |child| {
                    proc_stack.append(child) catch return TranspileError.MemoryAllocationFailed;
                }
            }
        }

        // Ensure impl emission sees all emitted generic specializations.
        for (specs.items) |s| {
            try self.register_generic_instantiations_from_dtype(s.dt);
        }

        // Forward typedefs allow pointer fields (including self-pointers) to refer to
        // types declared later.
        for (compound_nodes.items) |cnode| {
            if (cnode.node_variant == null) continue;
            if (self.is_std_c_signature_node(cnode)) continue;
            const c = cnode.node_variant.?.compound;

            if (c.type_params != null) continue;
            try self.write("typedef struct ");
            try self.write(c.name.items);
            try self.write(" ");
            try self.write(c.name.items);
            try self.write(";\n");
        }
        if (compound_nodes.items.len > 0) try self.write("\n");

        var remaining_specs = std.ArrayList(GenericSpec).init(self.allocator);
        defer remaining_specs.deinit();
        remaining_specs.appendSlice(specs.items) catch {
            return TranspileError.MemoryAllocationFailed;
        };

        while (remaining.items.len > 0 or remaining_specs.items.len > 0) {
            var progress = false;

            var si: usize = 0;
            while (si < remaining_specs.items.len) {
                const s = remaining_specs.items[si];
                if (!try self.generic_spec_deps_satisfied(s.cnode, s.dt, &emitted_compounds)) {
                    si += 1;
                    continue;
                }

                try self.emit_generic_compound_specialization(s.cnode, s.dt);
                emitted_compounds.put(s.mangled, true) catch {
                    return TranspileError.MemoryAllocationFailed;
                };
                const root = self.get_root();
                if (!root.emitted_generic_spec_keys.contains(s.mangled)) {
                    const key = root.allocator.dupe(u8, s.mangled) catch {
                        return TranspileError.MemoryAllocationFailed;
                    };
                    root.emitted_generic_spec_keys.put(key, true) catch {
                        return TranspileError.MemoryAllocationFailed;
                    };
                }
                _ = remaining_specs.swapRemove(si);
                progress = true;
            }

            var i: usize = 0;
            while (i < remaining.items.len) {
                const cnode = remaining.items[i];
                if (cnode.node_variant == null) {
                    _ = remaining.swapRemove(i);
                    continue;
                }
                const c = cnode.node_variant.?.compound;
                if (c.type_params != null) {
                    _ = remaining.swapRemove(i);
                    continue;
                }

                var deps_satisfied = true;
                for (c.fields.items()) |f| {
                    // Only enforce ordering for by-value named compound dependencies.
                    // Pointer-typed fields can refer to incomplete types.
                    if (f.dtype.flags != null and f.dtype.flags.?.is_array) continue;
                    if (f.dtype.pointer_depth != 0) continue;
                    if (f.dtype.type != .Unknown) continue;
                    if (f.dtype.type_str.items.len == 0) continue;
                    if (f.dtype.generic_args != null) {
                        const dep = try self.type_name_mangled(f.dtype);
                        defer self.allocator.free(dep);
                        if (!emitted_compounds.contains(dep)) {
                            deps_satisfied = false;
                            break;
                        }
                    } else {
                        const dep = f.dtype.type_str.items;
                        if (!registry.compounds_by_name.contains(dep)) continue;
                        if (!emitted_compounds.contains(dep)) {
                            deps_satisfied = false;
                            break;
                        }
                    }
                }

                if (deps_satisfied) {
                    try self.write("typedef struct ");
                    try self.write(c.name.items);
                    try self.write(" {\n");

                    for (c.fields.items()) |f| {
                        try self.write("  ");
                        if (f.dtype.flags != null and f.dtype.flags.?.is_array) {
                            var dt = f.dtype.*;
                            if (dt.flags) |*flags| flags.is_array = false;
                            if (dt.pointer_depth == 0) dt.pointer_depth = 1;
                            try self.write_type(dt);
                        } else {
                            try self.write_type(f.dtype.*);
                        }
                        try self.write(" ");
                        try self.write(f.name.items);
                        try self.write(";\n");
                    }
                    try self.write("} ");
                    try self.write(c.name.items);
                    try self.write(";\n\n");

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

        // Quirk canonical structs per signature
        var q_it = registry.quirks_by_sig.iterator();
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
        var qn_it = registry.quirk_sig_by_name.iterator();
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

    fn emit_quirk_impl_instance(
        self: *Self,
        impl_node: *ast.Node,
        type_name: []const u8,
        quirk_name: []const u8,
        sig_h: u64,
        q: anytype,
        params: ?*const utils.Vector(std.ArrayList(u8)),
        gargs: ?[]*dtype.DataType,
    ) TranspileError!void {
        if (impl_node.node_variant == null) return;
        const im = impl_node.node_variant.?.impl;

        const names = try write_quirk_c_names_hash(sig_h);
        const quirk_c = names.quirk[0..names.quirk_len];
        const vtable_c = names.vtable[0..names.vtable_len];

        const prev_params = self.type_subst_params;
        const prev_args = self.type_subst_args;
        self.type_subst_params = params;
        self.type_subst_args = gargs;
        defer {
            self.type_subst_params = prev_params;
            self.type_subst_args = prev_args;
        }

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
            const base = base_method_name_from_generated(fnv.name.?.items) orelse continue;

            var impl_fn_name = fnv.name.?.items;
            var impl_fn_owned = false;
            if (!mem.eql(u8, type_name, im.type_name.items)) {
                impl_fn_name = std.fmt.allocPrint(self.allocator, "{s}__{s}__{s}", .{ type_name, quirk_name, base }) catch {
                    return TranspileError.MemoryAllocationFailed;
                };
                impl_fn_owned = true;
            }
            defer if (impl_fn_owned) self.allocator.free(impl_fn_name);

            if (fnv.rtype) |rt| {
                try self.write_type(rt);
            } else {
                try self.write("void");
            }
            try self.write(" ");
            try self.write(impl_fn_name);
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

            if (fnv.is_async) {
                const prev_override = self.override_fn_name;
                self.override_fn_name = impl_fn_name;
                defer self.override_fn_name = prev_override;
                try self.write_async_function_support_prototypes(m.*);
            }
        }
        try self.write("\n");

        // Emit method bodies.
        for (im.methods.items()) |m| {
            if (m.type != .Function or m.node_variant == null) continue;
            const fnv = m.node_variant.?.function;
            if (fnv.body == null) continue;
            if (fnv.name == null) continue;
            const base = base_method_name_from_generated(fnv.name.?.items) orelse continue;

            var impl_fn_name = fnv.name.?.items;
            var impl_fn_owned = false;
            if (!mem.eql(u8, type_name, im.type_name.items)) {
                impl_fn_name = std.fmt.allocPrint(self.allocator, "{s}__{s}__{s}", .{ type_name, quirk_name, base }) catch {
                    return TranspileError.MemoryAllocationFailed;
                };
                impl_fn_owned = true;
            }
            const prev_override = self.override_fn_name;
            self.override_fn_name = impl_fn_name;
            defer self.override_fn_name = prev_override;

            try self.transpile_node(m.*);
            if (impl_fn_owned) self.allocator.free(impl_fn_name);
            try self.write("\n\n");
        }

        // Wrappers with `void* self` to match vtable signature.
        for (q.methods.items()) |m| {
            var impl_fn_name: ?[]const u8 = null;
            var impl_fn_owned = false;
            if (!mem.eql(u8, type_name, im.type_name.items)) {
                impl_fn_name = std.fmt.allocPrint(self.allocator, "{s}__{s}__{s}", .{ type_name, quirk_name, m.name.items }) catch {
                    return TranspileError.MemoryAllocationFailed;
                };
                impl_fn_owned = true;
            } else {
                for (im.methods.items()) |fm| {
                    if (fm.type != .Function or fm.node_variant == null) continue;
                    const fnv = fm.node_variant.?.function;
                    if (fnv.name == null) continue;
                    const base = base_method_name_from_generated(fnv.name.?.items) orelse continue;
                    if (mem.eql(u8, base, m.name.items)) {
                        impl_fn_name = fnv.name.?.items;
                        break;
                    }
                }
            }
            if (impl_fn_name == null) continue;
            defer if (impl_fn_owned) self.allocator.free(impl_fn_name.?);

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
            if (m.is_async) {
                try self.write("__fun_async_call_");
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
        try self.emit_plain_impl_method_prototypes_registry(&plain_emitted);
        try self.emit_plain_impl_method_prototypes_module(self, &plain_emitted);
        try self.write("\n");

        // Impl wrappers/vtables/coercions
        try self.write("// --- Quirk impl vtables ---\n\n");
        var impl_it = reg.impls_by_key.iterator();
        while (impl_it.next()) |entry| {
            const impl_node = entry.value_ptr.*;
            if (impl_node.node_variant == null) continue;
            const im = impl_node.node_variant.?.impl;
            if (self.mangled_contains_unresolved_placeholder(im.type_name.items)) continue;
            const quirk_name = if (im.quirk_name) |qn| qn.items else continue;
            const sig = reg.quirk_sig_by_name.get(quirk_name) orelse continue;
            const sig_h = self.quirk_sig_hash_cached(sig);
            const qnode = reg.quirks_by_sig.get(sig) orelse continue;
            if (qnode.node_variant == null) continue;
            const q = qnode.node_variant.?.quirk;

            if (self.impl_type_params(impl_node)) |params| {
                var inst_keys = std.StringHashMap(bool).init(self.allocator);
                defer {
                    var it = inst_keys.iterator();
                    while (it.next()) |e| {
                        self.allocator.free(e.key_ptr.*);
                    }
                    inst_keys.deinit();
                }

                var inst_list = std.ArrayList(*const dtype.DataType).init(self.allocator);
                defer inst_list.deinit();
                const base_name = if (mem.indexOf(u8, im.type_name.items, "__")) |idx| im.type_name.items[0..idx] else im.type_name.items;
                try self.collect_generic_instantiations_recursive(self, base_name, &inst_keys, &inst_list);

                for (inst_list.items) |dt| {
                    if (dt.generic_args == null) continue;
                    const gargs = dt.generic_args.?.items();
                    if (gargs.len != params.items().len) continue;
                    if (!self.generic_args_are_concrete(params, gargs)) continue;
                    if (self.dtype_contains_type_param(dt, params)) continue;

                    const mangled = try self.type_name_mangled(dt);
                    defer self.allocator.free(mangled);
                    if (self.mangled_contains_type_param(mangled, params)) continue;
                    if (self.mangled_contains_unresolved_placeholder(mangled)) continue;
                    try self.emit_quirk_impl_instance(impl_node, mangled, quirk_name, sig_h, q, params, gargs);
                }
            } else {
                try self.emit_quirk_impl_instance(impl_node, im.type_name.items, quirk_name, sig_h, q, null, null);
            }
        }

        // Plain impl method bodies (non-quirk): `impl Type { ... }`
        try self.write("// --- Plain impl methods ---\n\n");
        var emitted = std.StringHashMap(bool).init(self.backing_allocator);
        defer emitted.deinit();
        try self.emit_plain_impl_methods_registry(&emitted);
        try self.emit_plain_impl_methods_module(self, &emitted);
    }

    fn emit_plain_impl_method_prototypes_registry(self: *Self, emitted: *std.StringHashMap(bool)) TranspileError!void {
        const reg = self.root_registry() orelse return;
        var it = reg.impls_by_key.iterator();
        while (it.next()) |entry| {
            const impl_node = entry.value_ptr.*;
            try self.emit_plain_impl_method_prototypes_from_node(impl_node, emitted);
        }
    }

    fn emit_plain_impl_method_prototypes_from_node(self: *Self, n: *ast.Node, emitted: *std.StringHashMap(bool)) TranspileError!void {
        if (n.type != .Impl or n.node_variant == null) return;
        const im = n.node_variant.?.impl;
        if (im.quirk_name != null) return;
        if (self.mangled_contains_unresolved_placeholder(im.type_name.items)) return;

        if (self.impl_type_params(n)) |params| {
            var inst_keys = std.StringHashMap(bool).init(self.allocator);
            defer {
                var it = inst_keys.iterator();
                while (it.next()) |e| {
                    self.allocator.free(e.key_ptr.*);
                }
                inst_keys.deinit();
            }

            var inst_list = std.ArrayList(*const dtype.DataType).init(self.allocator);
            defer inst_list.deinit();
            const base_name = if (mem.indexOf(u8, im.type_name.items, "__")) |idx| im.type_name.items[0..idx] else im.type_name.items;
            try self.collect_generic_instantiations_recursive(self, base_name, &inst_keys, &inst_list);

            for (inst_list.items) |dt| {
                if (dt.generic_args == null) continue;
                const gargs = dt.generic_args.?.items();
                if (gargs.len != params.count) continue;
                if (!self.generic_args_are_concrete(params, gargs)) continue;
                if (self.dtype_contains_type_param(dt, params)) continue;

                const mangled = try self.type_name_mangled(dt);
                defer self.allocator.free(mangled);
                if (self.mangled_contains_type_param(mangled, params)) continue;
                if (self.mangled_contains_unresolved_placeholder(mangled)) continue;

                for (im.methods.items()) |m| {
                    if (m.type != .Function or m.node_variant == null) continue;
                    const fnv = m.node_variant.?.function;
                    if (fnv.name == null) continue;
                    const base = base_method_name_from_generated(fnv.name.?.items) orelse continue;
                    const spec_name = std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ mangled, base }) catch {
                        return TranspileError.MemoryAllocationFailed;
                    };

                    const gop = emitted.getOrPut(spec_name) catch return TranspileError.MemoryAllocationFailed;
                    if (gop.found_existing) continue;
                    gop.value_ptr.* = true;

                    {
                        const prev_params = self.type_subst_params;
                        const prev_args = self.type_subst_args;
                        self.type_subst_params = params;
                        self.type_subst_args = gargs;
                        defer {
                            self.type_subst_params = prev_params;
                            self.type_subst_args = prev_args;
                        }

                        if (fnv.rtype) |rt| {
                            try self.write_type(rt);
                        } else {
                            try self.write("void");
                        }
                        try self.write(" ");
                        try self.write(spec_name);
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

                        if (fnv.is_async) {
                            const prev_override = self.override_fn_name;
                            self.override_fn_name = spec_name;
                            defer self.override_fn_name = prev_override;
                            try self.write_async_function_support_prototypes(m.*);
                        }
                    }
                }
            }

            const root = self.get_root();
            var spec_it = root.emitted_generic_spec_keys.iterator();
            while (spec_it.next()) |entry| {
                const mangled_name = entry.key_ptr.*;
                const idx = mem.indexOf(u8, mangled_name, "__") orelse continue;
                const spec_base = mangled_name[0..idx];
                if (!mem.eql(u8, spec_base, base_name)) continue;
                if (self.mangled_contains_unresolved_placeholder(mangled_name)) continue;
                if (self.mangled_contains_type_param(mangled_name, params)) continue;
                const dt = (try self.dtype_from_mangled_type(mangled_name)) orelse continue;
                if (dt.generic_args == null) continue;
                const gargs = dt.generic_args.?.items();
                if (gargs.len != params.count) continue;
                if (!self.generic_args_are_concrete(params, gargs)) continue;
                if (self.dtype_contains_type_param(dt, params)) continue;

                for (im.methods.items()) |m| {
                    if (m.type != .Function or m.node_variant == null) continue;
                    const fnv = m.node_variant.?.function;
                    if (fnv.name == null) continue;
                    const base = base_method_name_from_generated(fnv.name.?.items) orelse continue;
                    const spec_name = std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ mangled_name, base }) catch {
                        return TranspileError.MemoryAllocationFailed;
                    };

                    const gop = emitted.getOrPut(spec_name) catch return TranspileError.MemoryAllocationFailed;
                    if (gop.found_existing) continue;
                    gop.value_ptr.* = true;

                    {
                        const prev_params = self.type_subst_params;
                        const prev_args = self.type_subst_args;
                        self.type_subst_params = params;
                        self.type_subst_args = gargs;
                        defer {
                            self.type_subst_params = prev_params;
                            self.type_subst_args = prev_args;
                        }

                        if (fnv.rtype) |rt| {
                            try self.write_type(rt);
                        } else {
                            try self.write("void");
                        }
                        try self.write(" ");
                        try self.write(spec_name);
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

                        if (fnv.is_async) {
                            const prev_override = self.override_fn_name;
                            self.override_fn_name = spec_name;
                            defer self.override_fn_name = prev_override;
                            try self.write_async_function_support_prototypes(m.*);
                        }
                    }
                }
            }
            return;
        }

        if (mem.indexOf(u8, im.type_name.items, "__") != null) {
            if (!(try self.concrete_impl_is_instantiated(im.type_name.items))) return;
        }

        for (im.methods.items()) |m| {
            if (m.type != .Function or m.node_variant == null) continue;
            const fnv = m.node_variant.?.function;
            if (fnv.name == null) continue;
            const fname = fnv.name.?.items;
            if (emitted.contains(fname)) continue;
            emitted.put(fname, true) catch return TranspileError.MemoryAllocationFailed;

            if (fnv.rtype) |rt| {
                try self.write_type(rt);
            } else {
                try self.write("void");
            }
            try self.write(" ");
            try self.write(fname);
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

            if (fnv.is_async) {
                try self.write_async_function_support_prototypes(m.*);
            }
        }
    }

    fn emit_plain_impl_method_prototypes_module(self: *Self, proc: *Self, emitted: *std.StringHashMap(bool)) TranspileError!void {
        for (proc.nodes.items()) |*n| {
            try self.emit_plain_impl_method_prototypes_from_node(n, emitted);
        }
        for (proc.owned_nodes.items) |n| {
            try self.emit_plain_impl_method_prototypes_from_node(n, emitted);
        }

        for (proc.children.items) |child| {
            try self.emit_plain_impl_method_prototypes_module(child, emitted);
        }
    }

    fn emit_plain_impl_methods_registry(self: *Self, emitted: *std.StringHashMap(bool)) TranspileError!void {
        const reg = self.root_registry() orelse return;
        var it = reg.impls_by_key.iterator();
        while (it.next()) |entry| {
            const impl_node = entry.value_ptr.*;
            const prev_aliases_override = self.import_aliases_override;
            if (impl_node.pos) |p| {
                const root = self.get_root();
                if (root.find_process_for_file(p.filename)) |proc| {
                    self.import_aliases_override = &proc.import_aliases;
                }
            }
            defer self.import_aliases_override = prev_aliases_override;
            try self.emit_plain_impl_methods_from_node(impl_node, emitted);
        }
    }

    fn emit_generic_compound_specializations(self: *Self, cnode: *ast.Node) TranspileError!void {
        const c = cnode.node_variant.?.compound;
        const params = c.type_params orelse return;

        var inst_keys = std.StringHashMap(bool).init(self.allocator);
        defer {
            var it = inst_keys.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
            }
            inst_keys.deinit();
        }

        var inst_list = std.ArrayList(*const dtype.DataType).init(self.allocator);
        defer inst_list.deinit();

        try self.collect_generic_instantiations_recursive(self, c.name.items, &inst_keys, &inst_list);

        for (inst_list.items) |dt| {
            if (dt.generic_args == null) continue;
            const gargs = dt.generic_args.?.items();
            if (gargs.len != params.count) continue;
            if (!self.generic_args_are_concrete(&params, gargs)) continue;
            if (self.dtype_contains_type_param(dt, &params)) continue;

            const mangled = try self.type_name_mangled(dt);
            defer self.allocator.free(mangled);
            if (self.mangled_contains_type_param(mangled, &params)) continue;
            if (self.mangled_contains_unresolved_placeholder(mangled)) continue;

            try self.emit_generic_compound_specialization(cnode, dt);
        }
    }

    fn emit_generic_compound_specialization(self: *Self, cnode: *ast.Node, dt: *const dtype.DataType) TranspileError!void {
        const c = cnode.node_variant.?.compound;
        const params = c.type_params orelse return;
        const gargs = dt.generic_args orelse return;

        const mangled = try self.type_name_mangled(dt);
        defer self.allocator.free(mangled);

        try self.write("typedef struct ");
        try self.write(mangled);
        try self.write(" {\n");

        for (c.fields.items()) |f| {
            try self.write("  ");
            if (f.dtype.flags != null and f.dtype.flags.?.is_array) {
                var field_dt = f.dtype.*;
                if (field_dt.flags) |*flags| flags.is_array = false;
                if (field_dt.pointer_depth == 0) field_dt.pointer_depth = 1;
                try self.write_type_with_subst(&field_dt, params, gargs.items());
            } else {
                try self.write_type_with_subst(f.dtype, params, gargs.items());
            }
            try self.write(" ");
            try self.write(f.name.items);
            try self.write(";\n");
        }

        try self.write("} ");
        try self.write(mangled);
        try self.write(";\n\n");
    }

    fn generic_spec_deps_satisfied(self: *Self, cnode: *ast.Node, dt: *const dtype.DataType, emitted: *std.StringHashMap(bool)) TranspileError!bool {
        const c = cnode.node_variant.?.compound;
        const params = c.type_params orelse return true;
        const gargs = dt.generic_args orelse return true;

        for (c.fields.items()) |f| {
            if (f.dtype.flags != null and f.dtype.flags.?.is_array) continue;
            if (f.dtype.pointer_depth != 0) continue;

            var dep_name: ?[]const u8 = null;
            var needs_free = false;

            if (f.dtype.generic_args != null) {
                dep_name = try self.type_name_mangled_with_subst(f.dtype, params, gargs.items());
                needs_free = true;
            } else if (f.dtype.type == .Unknown and f.dtype.type_str.items.len > 0) {
                const params_items = params.items();
                var matched_param = false;
                for (params_items, 0..) |p, i| {
                    if (!mem.eql(u8, p.items, f.dtype.type_str.items)) continue;
                    matched_param = true;
                    const arg_dt = gargs.items()[i];
                    if (arg_dt.pointer_depth != 0) break;
                    if (arg_dt.flags != null and arg_dt.flags.?.is_array) break;
                    if (arg_dt.type != .Unknown or arg_dt.type_str.items.len == 0) break;
                    if (arg_dt.generic_args != null) {
                        dep_name = try self.type_name_mangled(arg_dt);
                        needs_free = true;
                    } else {
                        dep_name = arg_dt.type_str.items;
                    }
                    break;
                }
                if (!matched_param) {
                    dep_name = f.dtype.type_str.items;
                }
            }

            if (dep_name) |dep| {
                defer if (needs_free) self.allocator.free(dep);
                const reg = self.root_registry() orelse return true;
                const dep_base = if (mem.indexOf(u8, dep, "__")) |idx| dep[0..idx] else dep;
                if (!reg.compounds_by_name.contains(dep_base)) continue;
                if (!emitted.contains(dep)) return false;
            }
        }

        return true;
    }

    fn write_type_with_subst(self: *Self, dt: *const dtype.DataType, params: utils.Vector(std.ArrayList(u8)), args: []*dtype.DataType) TranspileError!void {
        var idx: ?usize = null;
        if ((dt.type == null or dt.type == .Unknown) and dt.type_str.items.len > 0) {
            for (params.items(), 0..) |p, i| {
                if (mem.eql(u8, p.items, dt.type_str.items)) {
                    idx = i;
                    break;
                }
            }
        }

        if (idx != null) {
            var sub = args[idx.?].*;
            if (dt.pointer_depth > 0) {
                var flags = sub.flags orelse dtype.DataTypeFlags{};
                flags.is_pointer = true;
                sub.flags = flags;
                sub.pointer_depth += dt.pointer_depth;
            }
            try self.write_type_no_subst(sub);
            return;
        }

        if (dt.generic_args != null and (dt.type == null or dt.type == .Unknown)) {
            const mangled = try self.type_name_mangled_with_subst(dt, params, args);
            defer self.allocator.free(mangled);
            try self.write(mangled);
            const ptr_depth: usize = if (dt.pointer_depth > 0) dt.pointer_depth else blk: {
                if (dt.flags != null and dt.flags.?.is_pointer) break :blk 1;
                break :blk 0;
            };
            if (ptr_depth > 0) {
                var i: usize = 0;
                while (i < ptr_depth) : (i += 1) {
                    try self.write("*");
                }
            }
            return;
        }

        try self.write_type_no_subst(dt.*);
    }

    fn collect_generic_instantiations(self: *Self, proc: *Self, name: []const u8, keys: *std.StringHashMap(bool), out: *std.ArrayList(*const dtype.DataType)) TranspileError!void {
        for (proc.nodes.items()) |node| {
            try self.collect_generic_instantiations_node(node, name, keys, out);
        }
        for (proc.owned_nodes.items) |node| {
            try self.collect_generic_instantiations_node(node.*, name, keys, out);
        }
    }

    fn collect_generic_instantiations_recursive(self: *Self, proc: *Self, name: []const u8, keys: *std.StringHashMap(bool), out: *std.ArrayList(*const dtype.DataType)) TranspileError!void {
        try self.collect_generic_instantiations(proc, name, keys, out);
        for (proc.children.items) |child| {
            try self.collect_generic_instantiations_recursive(child, name, keys, out);
        }

        const root = self.get_root();
        for (root.forced_generic_instantiations.items) |dt| {
            if (dt.type_str.items.len == 0) continue;
            if (@intFromPtr(dt.type_str.items.ptr) == 0) continue;
            const dt_base = if (mem.indexOf(u8, dt.type_str.items, "__")) |idx| dt.type_str.items[0..idx] else dt.type_str.items;
            if (!mem.eql(u8, dt_base, name)) continue;
            if (self.dtype_has_unresolved_placeholder(dt)) continue;

            const key = try self.type_name_mangled(dt);
            if (self.mangled_contains_unresolved_placeholder(key)) {
                self.allocator.free(key);
                continue;
            }
            if (!keys.contains(key)) {
                keys.put(key, true) catch return TranspileError.MemoryAllocationFailed;
                out.append(dt) catch return TranspileError.MemoryAllocationFailed;
            } else {
                self.allocator.free(key);
            }
        }
    }

    fn concrete_impl_is_instantiated(self: *Self, type_name: []const u8) TranspileError!bool {
        const idx_opt = mem.indexOf(u8, type_name, "__") orelse return true;
        const base = type_name[0..idx_opt];
        if (self.mangled_contains_unresolved_placeholder(type_name)) return false;

        var inst_keys = std.StringHashMap(bool).init(self.allocator);
        defer {
            var it = inst_keys.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
            }
            inst_keys.deinit();
        }

        var inst_list = std.ArrayList(*const dtype.DataType).init(self.allocator);
        defer inst_list.deinit();

        try self.collect_generic_instantiations_recursive(self, base, &inst_keys, &inst_list);

        for (inst_list.items) |dt| {
            if (self.dtype_has_unresolved_placeholder(dt)) continue;
            const mangled = try self.type_name_mangled(dt);
            defer self.allocator.free(mangled);
            if (self.mangled_contains_unresolved_placeholder(mangled)) continue;
            if (mem.eql(u8, mangled, type_name)) return true;
        }
        return false;
    }

    fn collect_generic_instantiations_node(self: *Self, node: ast.Node, name: []const u8, keys: *std.StringHashMap(bool), out: *std.ArrayList(*const dtype.DataType)) TranspileError!void {
        switch (node.type) {
            .Variable => if (node.node_variant) |v| try self.collect_generic_instantiations_dtype(v.variable.type, name, keys, out),
            .Function => if (node.node_variant) |f| {
                if (f.function.rtype) |rt| try self.collect_generic_instantiations_dtype(&rt, name, keys, out);
                if (f.function.args) |args| {
                    for (args.items()) |a| {
                        if (a.node_variant) |av| {
                            try self.collect_generic_instantiations_dtype(av.variable.type, name, keys, out);
                        }
                    }
                }
                if (f.function.body) |body| {
                    try self.collect_generic_instantiations_in_body(body, name, keys, out);
                }
            },
            .Compound => if (node.node_variant) |c| {
                for (c.compound.fields.items()) |f| {
                    try self.collect_generic_instantiations_dtype(f.dtype, name, keys, out);
                }
            },
            .Body => if (node.node_variant) |b| {
                const body_node = ast.Node{ .type = .Body, .node_variant = .{ .body = b.body } };
                try self.collect_generic_instantiations_in_body(&body_node, name, keys, out);
            },
            else => {},
        }
    }

    fn collect_generic_instantiations_in_body(self: *Self, body: *const ast.Node, name: []const u8, keys: *std.StringHashMap(bool), out: *std.ArrayList(*const dtype.DataType)) TranspileError!void {
        if (body.type != .Body or body.node_variant == null) return;
        const stmts = body.node_variant.?.body.statements;
        for (stmts.items()) |stmt_ptr| {
            const stmt = stmt_ptr.*;
            switch (stmt.type) {
                .Variable => {
                    const v = stmt.node_variant.?.variable;
                    try self.collect_generic_instantiations_dtype(v.type, name, keys, out);
                },
                .StatementIf => {
                    const ifs = stmt.node_variant.?.statement.if_stmt;
                    try self.collect_generic_instantiations_in_body(ifs.body, name, keys, out);
                },
                .StatementElseIf => {
                    const elif = stmt.node_variant.?.statement.elif_stmt;
                    try self.collect_generic_instantiations_in_body(elif.body, name, keys, out);
                },
                .StatementElse => {
                    const els = stmt.node_variant.?.statement.else_stmt;
                    try self.collect_generic_instantiations_in_body(els.body, name, keys, out);
                },
                .StatementFit => {
                    const fit = stmt.node_variant.?.statement.fit_stmt;
                    for (fit.branches.items()) |br| {
                        try self.collect_generic_instantiations_in_body(br.body, name, keys, out);
                    }
                },
                .StatementFor => {
                    const f = stmt.node_variant.?.statement.for_stmt;
                    switch (f) {
                        .cond => |fc| try self.collect_generic_instantiations_in_body(fc.body, name, keys, out),
                        .iter => |fi| try self.collect_generic_instantiations_in_body(fi.body, name, keys, out),
                        .range => |fr| try self.collect_generic_instantiations_in_body(fr.body, name, keys, out),
                    }
                },
                else => {},
            }
        }
    }

    fn collect_generic_instantiations_dtype(self: *Self, dt: *const dtype.DataType, name: []const u8, keys: *std.StringHashMap(bool), out: *std.ArrayList(*const dtype.DataType)) TranspileError!void {
        if (dt.type_str.items.len > 0 and @intFromPtr(dt.type_str.items.ptr) == 0) return;
        if (dt.type_str.items.len > 0) {
            const dt_base = if (mem.indexOf(u8, dt.type_str.items, "__")) |idx| dt.type_str.items[0..idx] else dt.type_str.items;
            if (!mem.eql(u8, dt_base, name)) {
                if (dt.generic_args) |gargs| {
                    for (gargs.items()) |ga| {
                        try self.collect_generic_instantiations_dtype(ga, name, keys, out);
                    }
                }
                return;
            }
        }
        if (dt.type_str.items.len > 0) {
            if (dt.generic_args != null) {
                if (self.dtype_has_unresolved_placeholder(dt)) return;
                const key = try self.type_name_mangled(dt);
                if (self.mangled_contains_unresolved_placeholder(key)) {
                    self.allocator.free(key);
                    return;
                }
                if (!keys.contains(key)) {
                    keys.put(key, true) catch return TranspileError.MemoryAllocationFailed;
                    out.append(dt) catch return TranspileError.MemoryAllocationFailed;
                } else {
                    self.allocator.free(key);
                }
            } else if (mem.indexOf(u8, dt.type_str.items, "__") != null) {
                if (try self.dtype_from_mangled_type(dt.type_str.items)) |synthetic| {
                    if (!self.dtype_has_unresolved_placeholder(synthetic)) {
                        const key = try self.type_name_mangled(synthetic);
                        if (!keys.contains(key)) {
                            keys.put(key, true) catch return TranspileError.MemoryAllocationFailed;
                            out.append(synthetic) catch return TranspileError.MemoryAllocationFailed;
                        } else {
                            self.allocator.free(key);
                        }
                    }
                }
            }
        }

        if (dt.generic_args) |gargs| {
            for (gargs.items()) |ga| {
                try self.collect_generic_instantiations_dtype(ga, name, keys, out);
            }
        }
    }

    fn clone_dtype_with_subst_for_inst(self: *Self, dt: *const dtype.DataType, params: *const utils.Vector(std.ArrayList(u8)), args: []*dtype.DataType) TranspileError!*dtype.DataType {
        if ((dt.type == null or dt.type == .Unknown) and dt.type_str.items.len > 0) {
            for (params.items(), 0..) |p, i| {
                if (!mem.eql(u8, p.items, dt.type_str.items)) continue;
                const out = try self.clone_dtype(args[i]);
                if (dt.pointer_depth > 0) {
                    var flags = out.flags orelse dtype.DataTypeFlags{};
                    flags.is_pointer = true;
                    out.flags = flags;
                    out.pointer_depth += dt.pointer_depth;
                }
                if (dt.flags != null and dt.flags.?.is_array) {
                    var flags = out.flags orelse dtype.DataTypeFlags{};
                    flags.is_array = true;
                    out.flags = flags;
                }
                return out;
            }
        }

        if (dt.array != null) return TranspileError.TypeMismatch;

        const out = self.allocator.create(dtype.DataType) catch return TranspileError.MemoryAllocationFailed;
        out.* = dt.*;
        out.type_str = std.ArrayList(u8).init(self.allocator);
        out.type_str.appendSlice(dt.type_str.items) catch return TranspileError.MemoryAllocationFailed;
        out.generic_args = null;

        if (dt.generic_args) |gargs| {
            var out_args = utils.Vector(*dtype.DataType).init(self.allocator);
            for (gargs.items()) |ga| {
                const ga_sub = try self.clone_dtype_with_subst_for_inst(ga, params, args);
                out_args.push(ga_sub) catch return TranspileError.MemoryAllocationFailed;
            }
            out.generic_args = out_args;
        }

        return out;
    }

    fn seed_forced_generic_instantiations_from_impl_signatures_node(self: *Self, n: *ast.Node) TranspileError!void {
        if (n.type != .Impl or n.node_variant == null) return;
        const im = n.node_variant.?.impl;
        const params = self.impl_type_params(n) orelse return;

        var inst_keys = std.StringHashMap(bool).init(self.allocator);
        defer {
            var it = inst_keys.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
            }
            inst_keys.deinit();
        }

        var inst_list = std.ArrayList(*const dtype.DataType).init(self.allocator);
        defer inst_list.deinit();
        const base_name = if (mem.indexOf(u8, im.type_name.items, "__")) |idx| im.type_name.items[0..idx] else im.type_name.items;
        try self.collect_generic_instantiations_recursive(self, base_name, &inst_keys, &inst_list);

        for (inst_list.items) |dt| {
            if (dt.generic_args == null) continue;
            const gargs = dt.generic_args.?.items();
            if (gargs.len != params.count) continue;
            if (!self.generic_args_are_concrete(params, gargs)) continue;
            if (self.dtype_contains_type_param(dt, params)) continue;

            const mangled = try self.type_name_mangled(dt);
            defer self.allocator.free(mangled);
            if (self.mangled_contains_type_param(mangled, params)) continue;
            if (self.mangled_contains_unresolved_placeholder(mangled)) continue;

            for (im.methods.items()) |m| {
                if (m.type != .Function or m.node_variant == null) continue;
                const fnv = m.node_variant.?.function;

                if (fnv.rtype) |rt| {
                    const rt_sub = try self.clone_dtype_with_subst_for_inst(&rt, params, gargs);
                    if (!self.dtype_has_unresolved_placeholder(rt_sub)) {
                        try self.register_generic_instantiations_from_dtype(rt_sub);
                    }
                }

                if (fnv.args) |args_nodes| {
                    for (args_nodes.items()) |arg| {
                        if (arg.type != .Variable or arg.node_variant == null) continue;
                        const adt = arg.node_variant.?.variable.type;
                        const adt_sub = try self.clone_dtype_with_subst_for_inst(adt, params, gargs);
                        if (!self.dtype_has_unresolved_placeholder(adt_sub)) {
                            try self.register_generic_instantiations_from_dtype(adt_sub);
                        }
                    }
                }
            }
        }
    }

    fn seed_forced_generic_instantiations_from_impl_signatures_module(self: *Self, proc: *Self) TranspileError!void {
        for (proc.nodes.items()) |*n| {
            try self.seed_forced_generic_instantiations_from_impl_signatures_node(n);
        }
        for (proc.owned_nodes.items) |n| {
            try self.seed_forced_generic_instantiations_from_impl_signatures_node(n);
        }

        for (proc.children.items) |child| {
            try self.seed_forced_generic_instantiations_from_impl_signatures_module(child);
        }
    }

    fn seed_forced_generic_instantiations_from_impl_signatures(self: *Self) TranspileError!void {
        try self.seed_forced_generic_instantiations_from_impl_signatures_module(self.get_root());
    }

    fn emit_plain_impl_methods_from_node(self: *Self, n: *ast.Node, emitted: *std.StringHashMap(bool)) TranspileError!void {
        if (n.type != .Impl or n.node_variant == null) return;
        const im = n.node_variant.?.impl;
        if (im.quirk_name != null) return;
        if (self.mangled_contains_unresolved_placeholder(im.type_name.items)) return;

        if (self.impl_type_params(n)) |params| {
            var inst_keys = std.StringHashMap(bool).init(self.allocator);
            defer {
                var it = inst_keys.iterator();
                while (it.next()) |e| {
                    self.allocator.free(e.key_ptr.*);
                }
                inst_keys.deinit();
            }

            var inst_list = std.ArrayList(*const dtype.DataType).init(self.allocator);
            defer inst_list.deinit();
            const base_name = if (mem.indexOf(u8, im.type_name.items, "__")) |idx| im.type_name.items[0..idx] else im.type_name.items;
            try self.collect_generic_instantiations_recursive(self, base_name, &inst_keys, &inst_list);

            for (inst_list.items) |dt| {
                if (dt.generic_args == null) continue;
                const gargs = dt.generic_args.?.items();
                if (gargs.len != params.count) continue;
                if (self.dtype_contains_type_param(dt, params)) continue;

                const mangled = try self.type_name_mangled(dt);
                defer self.allocator.free(mangled);
                if (self.mangled_contains_type_param(mangled, params)) continue;

                for (im.methods.items()) |m| {
                    if (m.type != .Function or m.node_variant == null) continue;
                    const fnv = m.node_variant.?.function;
                    if (fnv.body == null) continue;
                    if (fnv.name == null) continue;
                    const base = base_method_name_from_generated(fnv.name.?.items) orelse continue;
                    const spec_name = std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ mangled, base }) catch {
                        return TranspileError.MemoryAllocationFailed;
                    };

                    const gop = emitted.getOrPut(spec_name) catch return TranspileError.MemoryAllocationFailed;
                    if (gop.found_existing) continue;
                    gop.value_ptr.* = true;

                    {
                        const prev_params = self.type_subst_params;
                        const prev_args = self.type_subst_args;
                        const prev_override = self.override_fn_name;
                        self.type_subst_params = params;
                        self.type_subst_args = gargs;
                        self.override_fn_name = spec_name;
                        defer {
                            self.type_subst_params = prev_params;
                            self.type_subst_args = prev_args;
                            self.override_fn_name = prev_override;
                        }

                        try self.transpile_node(m.*);
                    }
                    try self.write("\n\n");
                }
            }

            const root = self.get_root();
            var spec_it = root.emitted_generic_spec_keys.iterator();
            while (spec_it.next()) |entry| {
                const mangled_name = entry.key_ptr.*;
                const idx = mem.indexOf(u8, mangled_name, "__") orelse continue;
                const spec_base = mangled_name[0..idx];
                if (!mem.eql(u8, spec_base, base_name)) continue;
                if (self.mangled_contains_unresolved_placeholder(mangled_name)) continue;
                if (self.mangled_contains_type_param(mangled_name, params)) continue;
                const dt = (try self.dtype_from_mangled_type(mangled_name)) orelse continue;
                if (dt.generic_args == null) continue;
                const gargs = dt.generic_args.?.items();
                if (gargs.len != params.count) continue;
                if (self.dtype_contains_type_param(dt, params)) continue;

                for (im.methods.items()) |m| {
                    if (m.type != .Function or m.node_variant == null) continue;
                    const fnv = m.node_variant.?.function;
                    if (fnv.body == null) continue;
                    if (fnv.name == null) continue;
                    const base = base_method_name_from_generated(fnv.name.?.items) orelse continue;
                    const spec_name = std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ mangled_name, base }) catch {
                        return TranspileError.MemoryAllocationFailed;
                    };

                    const gop = emitted.getOrPut(spec_name) catch return TranspileError.MemoryAllocationFailed;
                    if (gop.found_existing) continue;
                    gop.value_ptr.* = true;

                    {
                        const prev_params = self.type_subst_params;
                        const prev_args = self.type_subst_args;
                        const prev_override = self.override_fn_name;
                        self.type_subst_params = params;
                        self.type_subst_args = gargs;
                        self.override_fn_name = spec_name;
                        defer {
                            self.type_subst_params = prev_params;
                            self.type_subst_args = prev_args;
                            self.override_fn_name = prev_override;
                        }

                        try self.transpile_node(m.*);
                    }
                    try self.write("\n\n");
                }
            }
            return;
        }

        if (mem.indexOf(u8, im.type_name.items, "__") != null) {
            if (!(try self.concrete_impl_is_instantiated(im.type_name.items))) return;
        }

        for (im.methods.items()) |m| {
            if (m.type != .Function or m.node_variant == null) continue;
            const fnv = m.node_variant.?.function;
            if (fnv.body == null) continue;
            if (fnv.name == null) continue;
            const fname = fnv.name.?.items;
            if (emitted.contains(fname)) continue;
            emitted.put(fname, true) catch return TranspileError.MemoryAllocationFailed;
            try self.transpile_node(m.*);
            try self.write("\n\n");
        }
    }

    fn emit_plain_impl_methods_module(self: *Self, proc: *Self, emitted: *std.StringHashMap(bool)) TranspileError!void {
        for (proc.nodes.items()) |*n| {
            try self.emit_plain_impl_methods_from_node(n, emitted);
        }
        for (proc.owned_nodes.items) |n| {
            try self.emit_plain_impl_methods_from_node(n, emitted);
        }

        for (proc.children.items) |child| {
            try self.emit_plain_impl_methods_module(child, emitted);
        }
    }

    fn emit_generic_function_specializations(self: *Self) TranspileError!void {
        const root = self.get_root();
        var emitted = std.StringHashMap(bool).init(self.allocator);
        defer emitted.deinit();

        for (root.generic_fn_instantiations.items) |inst| {
            if (self.mangled_contains_unresolved_placeholder(inst.name)) continue;
            if (emitted.contains(inst.name)) continue;
            emitted.put(inst.name, true) catch return TranspileError.MemoryAllocationFailed;

            {
                const prev_params = self.type_subst_params;
                const prev_args = self.type_subst_args;
                const prev_override = self.override_fn_name;
                self.type_subst_params = inst.params;
                self.type_subst_args = inst.args;
                self.override_fn_name = inst.name;
                defer {
                    self.type_subst_params = prev_params;
                    self.type_subst_args = prev_args;
                    self.override_fn_name = prev_override;
                }

                try self.transpile_node(inst.fn_node.*);
            }
            try self.write("\n\n");
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

        // Allow running entrypoint scripts that reference workspace-defined types
        // without explicitly importing their defining modules.
        // This is intentionally conservative: only auto-imports when a single
        // matching declaration is found.
        try self.auto_import_missing_user_types();

        // Imported modules share the same active scope pointers during codegen.
        // This avoids crashes when we transpile function nodes owned by child modules
        // (e.g. when emitting impl method bodies) without calling `child.transpile()`.
        const ScopeOpt = @TypeOf(self.scope);
        const binder = struct {
            fn bind(proc: *Self, shared: ScopeOpt) void {
                proc.scope = shared;
                for (proc.children.items) |child| {
                    bind(child, shared);
                }
            }
        };
        binder.bind(self, self.scope);

        // Collect user-defined type declarations across imports before typechecking.
        try self.collect_type_registry_all();

        // Type check after imports are parsed (so imported signatures are available).
        try self.typecheck_all();

        // Seed generic instantiations from signatures/locals across all modules.
        try self.seed_forced_generic_instantiations_from_signatures();

        // Seed additional generic instantiations that appear only after substituting
        // generic impl method signatures (e.g. Map<K,V>::keys -> Vec<K>).
        try self.seed_forced_generic_instantiations_from_impl_signatures();

        // Write standard library includes and prelude
        try self.transpile_prelude();

        // Emit user-defined types (compounds/quirks) once at the root.
        // NOTE: Impl method bodies/vtables are emitted later so the global function
        // prototype block can appear before any function bodies that might call
        // imported functions.
        if (!self.is_importing) {
            try self.emit_user_types();
        }

        // Re-seed impl signature instantiations after emitting user types so
        // field-driven generic specializations are visible to impl emission.
        try self.seed_forced_generic_instantiations_from_impl_signatures();

        // Emit forward declarations for all functions so calls work even when
        // function bodies are declared later in the file.
        if (!self.is_importing) {
            try self.emit_function_prototypes_all();
        }

        // Emit impl method bodies/vtables/coercions after the prototype block.
        if (!self.is_importing) {
            try self.emit_impls_and_vtables();
        }

        // Emit generic function specializations after impls and before user code.
        if (!self.is_importing) {
            try self.emit_generic_function_specializations();
        }

        // Output content from child imports recursively
        if (!self.is_importing) {
            var seen_children = std.StringHashMap(bool).init(self.backing_allocator);
            defer seen_children.deinit();
            try self.transpile_children_recursive(self, &seen_children);
        }

        // Now output the main file content
        for (self.nodes.items()) |node| {
            if (node.type != .Import) { // Skip import nodes as they've been processed
                if (node.type == .Compound or node.type == .Quirk) continue;
                if (node.type == .Function and node.node_variant != null) {
                    const function = node.node_variant.?.function;
                    if (function.type_params != null) continue;
                    if (self.function_has_unresolved_placeholder(node)) continue;
                    if (function.name) |fname| {
                        if (self.mangled_contains_unresolved_placeholder(fname.items)) continue;
                    }
                }
                try self.transpile_node(node);
                try self.write("\n\n");
            }
        }

        try self.finalize_warning_expectations();
    }

    fn emit_function_prototypes_all(self: *Self) TranspileError!void {
        // Only the root module emits this block.
        if (self.is_importing) return;
        try self.write("\n// Function prototypes (allow out-of-order definitions)\n");
        var emitted = std.StringHashMap(bool).init(self.backing_allocator);
        defer {
            var it = emitted.iterator();
            while (it.next()) |e| {
                self.backing_allocator.free(e.key_ptr.*);
            }
            emitted.deinit();
        }
        try self.emit_function_prototypes_module(self, &emitted);
        try self.emit_generic_function_prototypes(&emitted);
        try self.write("\n");
    }

    fn emit_function_prototypes_module(self: *Self, proc: *Self, emitted: *std.StringHashMap(bool)) TranspileError!void {
        const prev_alias = self.import_alias;
        self.import_alias = proc.import_alias;
        defer self.import_alias = prev_alias;

        for (proc.nodes.items()) |node| {
            if (node.type != .Function or node.node_variant == null) continue;
            if (self.is_std_c_signature_node(&node)) continue;
            const function = node.node_variant.?.function;
            if (function.body == null) continue;
            if (function.type_params != null) continue;
            if (self.function_has_unresolved_placeholder(node)) continue;
            if (function.name != null and mem.eql(u8, function.name.?.items, "main")) continue;

            if (function.name) |fname| {
                var effective_name: []const u8 = fname.items;
                var effective_name_owned = false;
                if (proc.import_alias) |alias| {
                    effective_name = try self.make_alias_qualified_symbol_name(alias, fname.items);
                    effective_name_owned = true;
                }
                defer if (effective_name_owned) self.allocator.free(effective_name);

                if (self.mangled_contains_unresolved_placeholder(effective_name)) continue;
                if (emitted.contains(effective_name)) continue;
                const emitted_key = self.backing_allocator.dupe(u8, effective_name) catch return TranspileError.MemoryAllocationFailed;
                emitted.put(emitted_key, true) catch return TranspileError.MemoryAllocationFailed;
            }

            try self.write_function_prototype(node);
        }

        for (proc.children.items) |child| {
            try self.emit_function_prototypes_module(child, emitted);
        }
    }

    fn emit_generic_function_prototypes(self: *Self, emitted: *std.StringHashMap(bool)) TranspileError!void {
        const root = self.get_root();
        for (root.generic_fn_instantiations.items) |inst| {
            if (self.mangled_contains_unresolved_placeholder(inst.name)) continue;
            if (emitted.contains(inst.name)) continue;
            const emitted_key = self.backing_allocator.dupe(u8, inst.name) catch return TranspileError.MemoryAllocationFailed;
            emitted.put(emitted_key, true) catch return TranspileError.MemoryAllocationFailed;

            {
                const prev_params = self.type_subst_params;
                const prev_args = self.type_subst_args;
                const prev_override = self.override_fn_name;
                self.type_subst_params = inst.params;
                self.type_subst_args = inst.args;
                self.override_fn_name = inst.name;
                defer {
                    self.type_subst_params = prev_params;
                    self.type_subst_args = prev_args;
                    self.override_fn_name = prev_override;
                }

                try self.write_function_prototype(inst.fn_node.*);
            }
        }
    }

    fn write_effective_function_name(self: *Self, node: ast.Node, name: []const u8) TranspileError!void {
        _ = node;
        if (self.override_fn_name) |ov| {
            try self.write(ov);
            return;
        }

        if (self.import_alias) |alias| {
            if (!mem.eql(u8, name, "main")) {
                try self.write(alias);
                try self.write("__");
                try self.write(name);
                return;
            }
        }

        try self.write(name);
    }

    fn alloc_effective_function_name(self: *Self, name: []const u8) TranspileError![]const u8 {
        if (self.override_fn_name) |ov| {
            return self.allocator.dupe(u8, ov) catch {
                return TranspileError.MemoryAllocationFailed;
            };
        }

        if (self.import_alias) |alias| {
            if (!mem.eql(u8, name, "main")) {
                return std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ alias, name }) catch {
                    return TranspileError.MemoryAllocationFailed;
                };
            }
        }

        return self.allocator.dupe(u8, name) catch {
            return TranspileError.MemoryAllocationFailed;
        };
    }

    fn write_async_function_support_prototypes(self: *Self, node: ast.Node) TranspileError!void {
        if (node.type != .Function or node.node_variant == null) return;
        const fnv = node.node_variant.?.function;
        if (!fnv.is_async) return;
        if (fnv.name == null or fnv.body == null) return;

        const effective_name = try self.alloc_effective_function_name(fnv.name.?.items);
        defer self.allocator.free(effective_name);

        try self.write("typedef struct __fun_async_payload_");
        try self.write(effective_name);
        try self.write(" {\n");

        if (fnv.args) |args| {
            for (args.items(), 0..) |arg, i| {
                if (arg.type != .Variable or arg.node_variant == null) continue;
                const v = arg.node_variant.?.variable;
                try self.write("  ");
                try self.write_type(v.type.*);
                try self.write(" __arg");
                try self.print("{d}", .{i});
                try self.write(";\n");
            }
        }

        if (fnv.rtype) |rt| {
            if (rt.type != .Void) {
                try self.write("  ");
                try self.write_type(rt);
                try self.write(" __result;\n");
            }
        }

        try self.write("} __fun_async_payload_");
        try self.write(effective_name);
        try self.write(";\n");

        try self.write("static void* __fun_async_entry_");
        try self.write(effective_name);
        try self.write("(void* __arg);\n");

        try self.write("static int __fun_async_spawn_");
        try self.write(effective_name);
        try self.write("(__fun_async_payload_");
        try self.write(effective_name);
        try self.write("* __payload, __fun_thread_t* __thr);\n");

        if (fnv.rtype) |rt| {
            try self.write("static ");
            try self.write_type(rt);
        } else {
            try self.write("static void");
        }
        try self.write(" __fun_async_await_");
        try self.write(effective_name);
        try self.write("(__fun_async_payload_");
        try self.write(effective_name);
        try self.write("* __payload, __fun_thread_t __thr);\n");

        if (fnv.rtype) |rt| {
            try self.write("static ");
            try self.write_type(rt);
        } else {
            try self.write("static void");
        }
        try self.write(" __fun_async_call_");
        try self.write(effective_name);
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

    fn write_async_function_support_definitions(self: *Self, node: ast.Node) TranspileError!void {
        if (node.type != .Function or node.node_variant == null) return;
        const fnv = node.node_variant.?.function;
        if (!fnv.is_async) return;
        if (fnv.name == null or fnv.body == null) return;

        const effective_name = try self.alloc_effective_function_name(fnv.name.?.items);
        defer self.allocator.free(effective_name);

        // Entry trampoline.
        try self.write("static void* __fun_async_entry_");
        try self.write(effective_name);
        try self.write("(void* __arg) {\n");
        try self.write("  __fun_async_payload_");
        try self.write(effective_name);
        try self.write("* __payload = (__fun_async_payload_");
        try self.write(effective_name);
        try self.write("*)__arg;\n");

        if (fnv.rtype) |rt| {
            if (rt.type != .Void) {
                try self.write("  __payload->__result = ");
            } else {
                try self.write("  ");
            }
        } else {
            try self.write("  ");
        }
        try self.write(effective_name);
        try self.write("(");
        if (fnv.args) |args| {
            for (args.items(), 0..) |_, i| {
                if (i > 0) try self.write(", ");
                try self.write("__payload->__arg");
                try self.print("{d}", .{i});
            }
        }
        try self.write(");\n");
        try self.write("  return NULL;\n");
        try self.write("}\n");

        // Spawn helper.
        try self.write("static int __fun_async_spawn_");
        try self.write(effective_name);
        try self.write("(__fun_async_payload_");
        try self.write(effective_name);
        try self.write("* __payload, __fun_thread_t* __thr) {\n");
        try self.write("  return __fun_thread_start(__thr, __fun_async_entry_");
        try self.write(effective_name);
        try self.write(", __payload);\n");
        try self.write("}\n");

        // Await helper.
        if (fnv.rtype) |rt| {
            try self.write("static ");
            try self.write_type(rt);
        } else {
            try self.write("static void");
        }
        try self.write(" __fun_async_await_");
        try self.write(effective_name);
        try self.write("(__fun_async_payload_");
        try self.write(effective_name);
        try self.write("* __payload, __fun_thread_t __thr) {\n");
        try self.write("  (void)__fun_thread_join(__thr);\n");
        if (fnv.rtype) |rt| {
            if (rt.type != .Void) {
                try self.write("  ");
                try self.write_type(rt);
                try self.write(" __result = __payload->__result;\n");
                try self.write("  free(__payload);\n");
                try self.write("  return __result;\n");
            } else {
                try self.write("  free(__payload);\n");
            }
        } else {
            try self.write("  free(__payload);\n");
        }
        try self.write("}\n");

        // High-level call helper used by `await` lowering.
        if (fnv.rtype) |rt| {
            try self.write("static ");
            try self.write_type(rt);
        } else {
            try self.write("static void");
        }
        try self.write(" __fun_async_call_");
        try self.write(effective_name);
        try self.write("(");
        self.in_function_params = true;
        if (fnv.args) |args| {
            for (args.items(), 0..) |arg, i| {
                if (i > 0) try self.write(", ");
                try self.transpile_node(arg.*);
            }
        }
        self.in_function_params = false;
        try self.write(") {\n");

        try self.write("  __fun_async_payload_");
        try self.write(effective_name);
        try self.write("* __payload = (__fun_async_payload_");
        try self.write(effective_name);
        try self.write("*)malloc(sizeof(__fun_async_payload_");
        try self.write(effective_name);
        try self.write("));\n");

        try self.write("  if (__payload == NULL) {\n");
        if (fnv.rtype) |rt| {
            if (rt.type != .Void) {
                try self.write("    return ");
            } else {
                try self.write("    ");
            }
        } else {
            try self.write("    ");
        }
        try self.write(effective_name);
        try self.write("(");
        if (fnv.args) |args| {
            for (args.items(), 0..) |arg, i| {
                if (arg.type != .Variable or arg.node_variant == null) continue;
                if (i > 0) try self.write(", ");
                try self.write(arg.node_variant.?.variable.name.items);
            }
        }
        try self.write(");\n");
        if (fnv.rtype) |rt| {
            if (rt.type == .Void) {
                try self.write("    return;\n");
            }
        }
        try self.write("  }\n");

        if (fnv.args) |args| {
            for (args.items(), 0..) |arg, i| {
                if (arg.type != .Variable or arg.node_variant == null) continue;
                try self.write("  __payload->__arg");
                try self.print("{d}", .{i});
                try self.write(" = ");
                try self.write(arg.node_variant.?.variable.name.items);
                try self.write(";\n");
            }
        }

        try self.write("  __fun_thread_t __thr;\n");
        try self.write("  int __rc = __fun_async_spawn_");
        try self.write(effective_name);
        try self.write("(__payload, &__thr);\n");
        try self.write("  if (__rc != 0) {\n");
        try self.write("    free(__payload);\n");
        if (fnv.rtype) |rt| {
            if (rt.type != .Void) {
                try self.write("    return ");
            } else {
                try self.write("    ");
            }
        } else {
            try self.write("    ");
        }
        try self.write(effective_name);
        try self.write("(");
        if (fnv.args) |args| {
            for (args.items(), 0..) |arg, i| {
                if (arg.type != .Variable or arg.node_variant == null) continue;
                if (i > 0) try self.write(", ");
                try self.write(arg.node_variant.?.variable.name.items);
            }
        }
        try self.write(");\n");
        if (fnv.rtype) |rt| {
            if (rt.type == .Void) {
                try self.write("    return;\n");
            }
        }
        try self.write("  }\n");

        if (fnv.rtype) |rt| {
            if (rt.type != .Void) {
                try self.write("  return ");
            } else {
                try self.write("  ");
            }
        } else {
            try self.write("  ");
        }
        try self.write("__fun_async_await_");
        try self.write(effective_name);
        try self.write("(__payload, __thr);\n");
        if (fnv.rtype) |rt| {
            if (rt.type == .Void) {
                try self.write("  return;\n");
            }
        }
        try self.write("}\n");
    }

    fn write_function_prototype(self: *Self, node: ast.Node) TranspileError!void {
        if (node.type != .Function or node.node_variant == null) return;
        const function = node.node_variant.?.function;
        if (function.body == null) return;

        if (function.name) |name| {
            const out_name = if (self.override_fn_name) |ov| ov else name.items;
            if (self.mangled_contains_unresolved_placeholder(out_name)) return;
        }

        if (function.rtype) |rtype| {
            try self.write_type(rtype);
        } else {
            try self.write("void");
        }

        try self.write(" ");
        if (function.name) |name| {
            try self.write_effective_function_name(node, name.items);
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
            try self.write("const char* __fun_vtags");
            try self.write(", ...");
        }
        self.in_function_params = false;
        try self.write(");\n");

        try self.write_async_function_support_prototypes(node);
    }

    // Helper function to recursively transpile children
    fn transpile_children_recursive(self: *Self, parent_proc: *TranspileProcess, seen: *std.StringHashMap(bool)) TranspileError!void {
        for (parent_proc.children.items) |child| {
            if (seen.contains(child.input_file_path)) continue;
            seen.put(child.input_file_path, true) catch return TranspileError.MemoryAllocationFailed;
            // Recursively transpile the child's children first
            try self.transpile_children_recursive(child, seen);

            const prev_alias = self.import_alias;
            const prev_aliases_override = self.import_aliases_override;
            const prev_emit_input_file_path = self.emit_input_file_path;
            const prev_emit_module_proc = self.emit_module_proc;
            self.import_alias = child.import_alias;
            self.import_aliases_override = &child.import_aliases;
            self.emit_input_file_path = child.input_file_path;
            self.emit_module_proc = child;

            // Then, transpile the child's own nodes (excluding imports and main functions)
            for (child.nodes.items()) |node| {
                if (node.type != .Import) {
                    if (node.type == .Compound or node.type == .Quirk) continue;
                    if (self.is_std_c_signature_node(&node)) continue;
                    // Skip main functions in imported modules
                    if (node.type == .Function and node.node_variant != null) {
                        const function = node.node_variant.?.function;
                        if (function.name != null and mem.eql(u8, function.name.?.items, "main")) {
                            continue; // Skip this main function from an imported module
                        }
                        if (function.type_params != null) {
                            continue;
                        }
                        if (self.function_has_unresolved_placeholder(node)) {
                            continue;
                        }
                        if (function.name) |fname| {
                            if (self.mangled_contains_unresolved_placeholder(fname.items)) {
                                continue;
                            }
                        }
                    }

                    try self.transpile_node(node);
                    try self.write("\n\n");
                }
            }

            self.import_alias = prev_alias;
            self.import_aliases_override = prev_aliases_override;
            self.emit_input_file_path = prev_emit_input_file_path;
            self.emit_module_proc = prev_emit_module_proc;
        }
    }

    fn module_has_function_named(self: *Self, proc: *const TranspileProcess, name: []const u8) bool {
        _ = self;
        for (proc.nodes.items()) |n| {
            if (n.type != .Function or n.node_variant == null) continue;
            const f = n.node_variant.?.function;
            if (f.body == null or f.name == null) continue;
            if (mem.eql(u8, f.name.?.items, name)) return true;
        }
        return false;
    }

    fn write_module_function_ref(self: *Self, name: []const u8) TranspileError!void {
        if (self.import_alias) |alias| {
            if (self.emit_module_proc) |mproc| {
                if (self.module_has_function_named(mproc, name)) {
                    try self.write(alias);
                    try self.write("__");
                    try self.write(name);
                    return;
                }
            }
        }
        try self.write(name);
    }

    /// Transpiles the prelude code to C
    fn transpile_prelude(self: *Self) TranspileError!void {
        try self.write_std_imports();
        try self.write("\n");

        if (!self.is_importing) {
            try self.write("#include <stdlib.h>\n");
            try self.write("#ifdef _WIN32\n");
            try self.write("#include <windows.h>\n");
            try self.write("typedef HANDLE __fun_thread_t;\n");
            try self.write("typedef void* (*__fun_thread_entry_t)(void*);\n");
            try self.write("typedef struct __fun_thread_start_pack { __fun_thread_entry_t entry; void* arg; } __fun_thread_start_pack;\n");
            try self.write("static DWORD WINAPI __fun_thread_entry_win(LPVOID p) { __fun_thread_start_pack* pack = (__fun_thread_start_pack*)p; if (pack) { pack->entry(pack->arg); free(pack); } return 0; }\n");
            try self.write("static int __fun_thread_start(__fun_thread_t* t, __fun_thread_entry_t entry, void* arg) { __fun_thread_start_pack* pack = (__fun_thread_start_pack*)malloc(sizeof(__fun_thread_start_pack)); if (!pack) return -1; pack->entry = entry; pack->arg = arg; HANDLE h = CreateThread(NULL, 0, __fun_thread_entry_win, pack, 0, NULL); if (!h) { free(pack); return -1; } *t = h; return 0; }\n");
            try self.write("static int __fun_thread_join(__fun_thread_t t) { DWORD rc = WaitForSingleObject(t, INFINITE); CloseHandle(t); return rc == WAIT_OBJECT_0 ? 0 : -1; }\n");
            try self.write("#else\n");
            try self.write("#include <pthread.h>\n");
            try self.write("typedef pthread_t __fun_thread_t;\n");
            try self.write("typedef void* (*__fun_thread_entry_t)(void*);\n");
            try self.write("static int __fun_thread_start(__fun_thread_t* t, __fun_thread_entry_t entry, void* arg) { return pthread_create(t, NULL, entry, arg); }\n");
            try self.write("static int __fun_thread_join(__fun_thread_t t) { return pthread_join(t, NULL); }\n");
            try self.write("#endif\n\n");

            try self.write("#define __fun_tag(x) _Generic((x), ");
            try self.write("char*: 's', const char*: 's', ");
            try self.write("long long: 'n', long: 'n', int: 'n', unsigned long long: 'n', unsigned long: 'n', unsigned int: 'n', ");
            try self.write("double: 'd', float: 'd', _Bool: 'b', char: 'c', void*: 'p', default: 'p')\n\n");
        }
    }

    /// Transpiles a node to C code
    fn transpile_node(self: *Self, node: ast.Node) TranspileError!void {
        switch (node.type) {
            .CompoundInit => {
                const ci = node.node_variant.?.compound_init;
                const dt = ci.dtype orelse {
                    self.report_type_error(node, "compound initializer requires a concrete type", .{});
                    return TranspileError.TypeMismatch;
                };

                try self.write("(");
                try self.write_type(dt.*);
                try self.write("){");

                if (ci.fields.count == 0) {
                    try self.write("0");
                } else {
                    for (ci.fields.items(), 0..) |f, i| {
                        if (i > 0) try self.write(", ");
                        try self.write(".");
                        try self.write(f.name.items);
                        try self.write(" = ");
                        try self.transpile_node(f.value.*);
                    }
                }

                try self.write("}");
                return;
            },
            .Expression => {
                const exp = node.node_variant.?.exp;
                if (mem.eql(u8, exp.op, "()")) {
                    if (exp.left) |left| {
                        var callee_base_name: ?[]const u8 = null;
                        if (left.type == .Identifier and left.data != null) {
                            callee_base_name = left.data.?.sval.items;
                        } else if (left.type == .Expression and left.node_variant != null and mem.eql(u8, left.node_variant.?.exp.op, ".")) {
                            const dot = left.node_variant.?.exp;
                            if (dot.right) |rhs| {
                                if (rhs.type == .Identifier and rhs.data != null) {
                                    callee_base_name = rhs.data.?.sval.items;
                                }
                            }
                        }

                        if (callee_base_name) |fname| {
                            const fname_base = if (std.mem.lastIndexOf(u8, fname, "__")) |sep| fname[sep + 2 ..] else fname;
                            if (mem.eql(u8, fname_base, "print_fmt") or mem.eql(u8, fname_base, "println_fmt")) {
                                const is_newline = mem.eql(u8, fname_base, "println_fmt");
                                if (try self.emit_print_fmt_literal(node, is_newline, exp.right)) {
                                    return;
                                }
                            }
                            if (mem.eql(u8, fname_base, "format")) {
                                if (try self.emit_format_literal(node, exp.right)) {
                                    return;
                                }
                            }
                        }
                    }

                    // Builtin: `sizeof(Type)`
                    // The argument is a type name, not a value expression.
                    if (exp.left) |left| {
                        if (left.type == .Identifier and left.data != null and mem.eql(u8, left.data.?.sval.items, "sizeof")) {
                            const right = exp.right orelse {
                                self.report_type_error(node, "sizeof expects exactly 1 argument", .{});
                                return TranspileError.InvalidSizeof;
                            };

                            const inner = if (right.type == .ExpressionParenthesis and right.node_variant != null)
                                right.node_variant.?.paren.exp.*
                            else
                                right.*;

                            if (inner.type != .Identifier or inner.data == null) {
                                self.report_type_error(node, "sizeof argument must be a type name", .{});
                                return TranspileError.InvalidSizeof;
                            }

                            const type_name = inner.data.?.sval.items;
                            if (self.type_subst_params != null and self.type_subst_args != null) {
                                const params = self.type_subst_params.?.*;
                                const args = self.type_subst_args.?;
                                for (params.items(), 0..) |p, i| {
                                    if (mem.eql(u8, p.items, type_name)) {
                                        try self.write("(int)(sizeof(");
                                        try self.write_type_no_subst(args[i].*);
                                        try self.write("))");
                                        return;
                                    }
                                }
                            }

                            const c_type = map_type_to_c(type_name);
                            try self.write("(int)(sizeof(");
                            try self.write(c_type);
                            try self.write("))");
                            return;
                        }
                    }

                    // Quirk method call: `q.method(...)` emits `q.vtable->method(q.self, ...)`.
                    if (exp.left) |left| {
                        if (left.type == .Expression and left.node_variant != null and mem.eql(u8, left.node_variant.?.exp.op, ".")) {
                            const dot = left.node_variant.?.exp;
                            const recv = dot.left orelse null;
                            const member = dot.right orelse null;
                            if (recv != null and member != null and member.?.type == .Identifier and member.?.data != null) {
                                // Special-case quirk method calls for any receiver expression
                                // we can resolve as quirk-typed from the current scope.
                                if (self.expr_is_quirk_typed_from_scope(recv.?.*)) {
                                    const mname = member.?.data.?.sval.items;
                                    const recv_is_identifier = recv.?.type == .Identifier;
                                    try self.write("(");
                                    if (recv_is_identifier) {
                                        try self.transpile_node(recv.?.*);
                                        try self.write(".vtable->");
                                    } else {
                                        try self.write("(");
                                        try self.transpile_node(recv.?.*);
                                        try self.write(").vtable->");
                                    }
                                    try self.write(mname);
                                    try self.write("(");
                                    if (recv_is_identifier) {
                                        try self.transpile_node(recv.?.*);
                                        try self.write(".self");
                                    } else {
                                        try self.write("(");
                                        try self.transpile_node(recv.?.*);
                                        try self.write(").self");
                                    }

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
                                if (recv.?.type == .Expression and recv.?.node_variant != null and mem.eql(u8, recv.?.node_variant.?.exp.op, ".")) {
                                    const fexp = recv.?.node_variant.?.exp;
                                    const fbase = fexp.left orelse null;
                                    const fmember = fexp.right orelse null;
                                    if (fbase != null and fmember != null and fbase.?.type == .Identifier and fbase.?.data != null and fmember.?.type == .Identifier and fmember.?.data != null) {
                                        const base_name = fbase.?.data.?.sval.items;
                                        const field_name = fmember.?.data.?.sval.items;
                                        const base_dt = self.identifier_declared_dtype(base_name) orelse null;
                                        if (base_dt != null and base_dt.?.type == .Unknown and !self.is_quirk_name(base_dt.?.type_str.items) and (base_dt.?.pointer_depth == 0 or base_dt.?.pointer_depth == 1)) {
                                            if (self.lookup_compound_field(base_dt.?.type_str.items, field_name)) |fdt| {
                                                const field_type = type_from_dtype(fdt);
                                                if (field_type.name != null and !self.is_quirk_name(field_type.name.?)) {
                                                    var type_name = field_type.name.?;
                                                    var owned_name = false;
                                                    if (fdt.generic_args != null) {
                                                        type_name = try self.type_name_mangled_for_emit(fdt);
                                                        owned_name = true;
                                                    }
                                                    const type_name_canon = self.canonical_compound_name(type_name);
                                                    const mname = member.?.data.?.sval.items;
                                                    if (self.lookup_plain_impl_method_fn(&node, type_name_canon, mname)) |fn_name| {
                                                        try self.write("(");
                                                        try self.write(fn_name);
                                                        try self.write("(");

                                                        if (field_type.pointer_depth == 0) {
                                                            try self.write("&(");
                                                            try self.transpile_node(recv.?.*);
                                                            try self.write(")");
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
                                                        if (owned_name) self.allocator.free(@constCast(type_name));
                                                        return;
                                                    }

                                                    const qres = self.resolve_quirk_impl_method_for_concrete(node, type_name_canon, mname);
                                                    if (owned_name) self.allocator.free(@constCast(type_name));
                                                    if (!qres.ambiguous) {
                                                        if (qres.fn_name) |qfn_name| {
                                                            try self.write("(");
                                                            try self.write(qfn_name);
                                                            try self.write("(");

                                                            if (field_type.pointer_depth == 0) {
                                                                try self.write("&(");
                                                                try self.transpile_node(recv.?.*);
                                                                try self.write(")");
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

                                if (recv.?.type == .Identifier and recv.?.data != null and !self.identifier_is_quirk_typed(recv.?.data.?.sval.items)) {
                                    const rname = recv.?.data.?.sval.items;
                                    const dt = self.identifier_declared_dtype(rname) orelse null;
                                    if (dt != null and dt.?.type == .Unknown and !self.is_quirk_name(dt.?.type_str.items) and (dt.?.pointer_depth == 0 or dt.?.pointer_depth == 1)) {
                                        var type_name: []const u8 = dt.?.type_str.items;
                                        var owned_name = false;
                                        if (dt.?.generic_args != null) {
                                            type_name = try self.type_name_mangled_for_emit(dt.?);
                                            owned_name = true;
                                        }
                                        const type_name_canon = self.canonical_compound_name(type_name);
                                        const mname = member.?.data.?.sval.items;
                                        if (self.lookup_plain_impl_method_fn(&node, type_name_canon, mname)) |fn_name| {
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
                                            if (owned_name) self.allocator.free(@constCast(type_name));
                                            return;
                                        }

                                        // Also allow calling quirk-impl methods directly on concrete types.
                                        const qres = self.resolve_quirk_impl_method_for_concrete(node, type_name_canon, mname);
                                        if (owned_name) self.allocator.free(@constCast(type_name));
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

                                        // Quirk impl method call on `self` inside `impl Type as Quirk { ... }`.
                                        // `self.method()` is not a struct member call in C; emit a direct call to
                                        // the generated impl function when we can resolve it.
                                        if (mem.eql(u8, rname, "self")) {
                                            if (self.lookup_quirk_impl_method_fn_for_self(type_name_canon, mname)) |qfn_name| {
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
                        var callee_base_name: ?[]const u8 = null;
                        if (left.type == .Identifier and left.data != null) {
                            callee_base_name = left.data.?.sval.items;
                        } else if (left.type == .Expression and left.node_variant != null and mem.eql(u8, left.node_variant.?.exp.op, ".")) {
                            const dot = left.node_variant.?.exp;
                            if (dot.right) |rhs| {
                                if (rhs.type == .Identifier and rhs.data != null) {
                                    callee_base_name = rhs.data.?.sval.items;
                                }
                            }
                        }

                        if (callee_base_name) |fname| {
                            const fname_base = if (std.mem.lastIndexOf(u8, fname, "__")) |sep| fname[sep + 2 ..] else fname;
                            if (mem.eql(u8, fname, "va_start") or mem.eql(u8, fname, "va_end") or mem.eql(u8, fname, "va_copy") or
                                mem.eql(u8, fname, "va_arg_num") or mem.eql(u8, fname, "va_arg_dec") or mem.eql(u8, fname, "va_arg_bin") or
                                mem.eql(u8, fname, "va_arg_chr") or mem.eql(u8, fname, "va_arg_str") or mem.eql(u8, fname, "va_arg_raw"))
                            {
                                var args_nodes = std.ArrayList(*ast.Node).init(self.allocator);
                                defer args_nodes.deinit();
                                if (exp.right) |right| {
                                    try self.flatten_call_args_ptr(right, &args_nodes);
                                }

                                if (mem.eql(u8, fname, "va_start")) {
                                    if (args_nodes.items.len != 2) {
                                        self.report_error(node, "va_start expects 2 arguments", .{});
                                        return;
                                    }
                                    try self.write("va_start(");
                                    try self.transpile_node(args_nodes.items[0].*);
                                    try self.write(", ");
                                    try self.transpile_node(args_nodes.items[1].*);
                                    try self.write(")");
                                    return;
                                }
                                if (mem.eql(u8, fname, "va_end")) {
                                    if (args_nodes.items.len != 1) {
                                        self.report_error(node, "va_end expects 1 argument", .{});
                                        return;
                                    }
                                    try self.write("va_end(");
                                    try self.transpile_node(args_nodes.items[0].*);
                                    try self.write(")");
                                    return;
                                }
                                if (mem.eql(u8, fname, "va_copy")) {
                                    if (args_nodes.items.len != 2) {
                                        self.report_error(node, "va_copy expects 2 arguments", .{});
                                        return;
                                    }
                                    try self.write("va_copy(");
                                    try self.transpile_node(args_nodes.items[0].*);
                                    try self.write(", ");
                                    try self.transpile_node(args_nodes.items[1].*);
                                    try self.write(")");
                                    return;
                                }
                                if (args_nodes.items.len != 1) {
                                    self.report_error(node, "{s} expects 1 argument", .{fname});
                                    return;
                                }

                                if (mem.eql(u8, fname, "va_arg_num")) {
                                    try self.write("va_arg(");
                                    try self.transpile_node(args_nodes.items[0].*);
                                    try self.write(", long long)");
                                    return;
                                }
                                if (mem.eql(u8, fname, "va_arg_dec")) {
                                    try self.write("va_arg(");
                                    try self.transpile_node(args_nodes.items[0].*);
                                    try self.write(", double)");
                                    return;
                                }
                                if (mem.eql(u8, fname, "va_arg_bin")) {
                                    try self.write("(bool)va_arg(");
                                    try self.transpile_node(args_nodes.items[0].*);
                                    try self.write(", int)");
                                    return;
                                }
                                if (mem.eql(u8, fname, "va_arg_chr")) {
                                    try self.write("(char)va_arg(");
                                    try self.transpile_node(args_nodes.items[0].*);
                                    try self.write(", int)");
                                    return;
                                }
                                if (mem.eql(u8, fname, "va_arg_str")) {
                                    try self.write("va_arg(");
                                    try self.transpile_node(args_nodes.items[0].*);
                                    try self.write(", char*)");
                                    return;
                                }
                                if (mem.eql(u8, fname, "va_arg_raw")) {
                                    try self.write("va_arg(");
                                    try self.transpile_node(args_nodes.items[0].*);
                                    try self.write(", void*)");
                                    return;
                                }
                            }

                            const known_variadic_builtin = mem.eql(u8, fname_base, "print_fmt") or mem.eql(u8, fname_base, "println_fmt") or mem.eql(u8, fname_base, "format");

                            var callee_is_variadic = false;
                            var fixed_len: usize = 0;

                            if (self.find_function_node(fname)) |fn_node| {
                                if (fn_node.node_variant != null and fn_node.node_variant.?.function.is_variadic and !self.is_std_c_signature_node(fn_node)) {
                                    callee_is_variadic = true;
                                    const fnv = fn_node.node_variant.?.function;
                                    fixed_len = if (fnv.args) |a| a.count else 0;
                                }
                            } else if (!mem.eql(u8, fname_base, fname)) {
                                if (self.find_function_node(fname_base)) |fn_node| {
                                    if (fn_node.node_variant != null and fn_node.node_variant.?.function.is_variadic and !self.is_std_c_signature_node(fn_node)) {
                                        callee_is_variadic = true;
                                        const fnv = fn_node.node_variant.?.function;
                                        fixed_len = if (fnv.args) |a| a.count else 0;
                                    }
                                }
                            }

                            if (!callee_is_variadic and known_variadic_builtin) {
                                // format/print_fmt/println_fmt take at least the format string.
                                callee_is_variadic = true;
                                fixed_len = 1;
                            }

                            if (callee_is_variadic) {
                                var args_nodes = std.ArrayList(*ast.Node).init(self.allocator);
                                defer args_nodes.deinit();
                                if (exp.right) |right| {
                                    try self.flatten_call_args_ptr(right, &args_nodes);
                                }

                                const total_len: usize = args_nodes.items.len;
                                const var_len: usize = if (total_len > fixed_len) total_len - fixed_len else 0;

                                if (var_len == 0) {
                                    try self.transpile_node(left.*);
                                    try self.write("(");
                                    var idx0: usize = 0;
                                    while (idx0 < fixed_len) : (idx0 += 1) {
                                        if (idx0 > 0) try self.write(", ");
                                        try self.transpile_node(args_nodes.items[idx0].*);
                                    }
                                    if (fixed_len > 0) try self.write(", ");
                                    try self.write("(const char[]){0}");
                                    try self.write(")");
                                    return;
                                }

                                try self.write("({ ");
                                var v: usize = 0;
                                while (v < var_len) : (v += 1) {
                                    var tbuf: [64]u8 = undefined;
                                    const tname = std.fmt.bufPrint(&tbuf, "__fun_va_{d}", .{v}) catch unreachable;
                                    try self.write("__auto_type ");
                                    try self.write(tname);
                                    try self.write(" = ");
                                    const var_node = args_nodes.items[fixed_len + v].*;
                                    if (var_node.type == .Boolean) {
                                        try self.write("(bool)");
                                        try self.transpile_node(var_node);
                                    } else if (var_node.type == .Identifier and var_node.data != null) {
                                        const nm = var_node.data.?.sval.items;
                                        if (self.identifier_declared_dtype(nm)) |dt| {
                                            if (dt.type == .Bin) {
                                                try self.write("(bool)");
                                            }
                                        }
                                        try self.transpile_node(var_node);
                                    } else {
                                        try self.transpile_node(var_node);
                                    }
                                    try self.write("; ");

                                    if (self.resolve_display_call_for_expr(node, var_node)) |disp| {
                                        var dbuf: [64]u8 = undefined;
                                        const dname = std.fmt.bufPrint(&dbuf, "__fun_disp_{d}", .{v}) catch unreachable;
                                        try self.write("char* ");
                                        try self.write(dname);
                                        try self.write(" = ");
                                        try self.write(disp.fn_name);
                                        try self.write("(");
                                        if (disp.pass_by_ref) try self.write("&");
                                        try self.write(tname);
                                        try self.write("); ");
                                    }
                                }

                                try self.transpile_node(left.*);
                                try self.write("(");
                                var i: usize = 0;
                                while (i < fixed_len) : (i += 1) {
                                    if (i > 0) try self.write(", ");
                                    try self.transpile_node(args_nodes.items[i].*);
                                }
                                if (fixed_len > 0) try self.write(", ");

                                try self.write("(const char[]){");
                                v = 0;
                                while (v < var_len) : (v += 1) {
                                    if (v > 0) try self.write(", ");
                                    var tbuf2: [64]u8 = undefined;
                                    const tname2 = std.fmt.bufPrint(&tbuf2, "__fun_va_{d}", .{v}) catch unreachable;
                                    const var_node = args_nodes.items[fixed_len + v].*;
                                    if (self.resolve_display_call_for_expr(node, var_node) != null) {
                                        try self.write("'s'");
                                    } else {
                                        try self.write("__fun_tag(");
                                        try self.write(tname2);
                                        try self.write(")");
                                    }
                                }
                                if (var_len > 0) try self.write(", ");
                                try self.write("0}");

                                v = 0;
                                while (v < var_len) : (v += 1) {
                                    try self.write(", ");
                                    const var_node = args_nodes.items[fixed_len + v].*;
                                    if (self.resolve_display_call_for_expr(node, var_node) != null) {
                                        var dbuf3: [64]u8 = undefined;
                                        const dname3 = std.fmt.bufPrint(&dbuf3, "__fun_disp_{d}", .{v}) catch unreachable;
                                        try self.write(dname3);
                                    } else {
                                        var tbuf3: [64]u8 = undefined;
                                        const tname3 = std.fmt.bufPrint(&tbuf3, "__fun_va_{d}", .{v}) catch unreachable;
                                        try self.write(tname3);
                                    }
                                }
                                try self.write("); })");
                                return;
                            }

                            if (self.lookup_generic_call_override(node)) |ov| {
                                try self.write(ov);
                                try self.write("(");
                                if (exp.right) |right| {
                                    try self.transpile_node(right.*);
                                }
                                try self.write(")");
                                return;
                            }
                        }
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

                    // Aliased enum variant constant:
                    // `alias.Enum.Variant` -> `alias__Enum_Variant` in C.
                    if (extract_alias_enum_variant_parts(left, right)) |parts| {
                        if (self.alias_map_for_node(&node).contains(parts.alias_name)) {
                            const qualified_enum = try self.make_alias_qualified_symbol_name(parts.alias_name, parts.enum_name);
                            defer self.allocator.free(qualified_enum);
                            if (self.root_registry()) |reg| {
                                if (reg.enums_by_name.get(qualified_enum)) |enode| {
                                    if (enode.node_variant == null) return;
                                    const emit_enum_name = enode.node_variant.?.enum_decl.name.items;
                                    try self.write(emit_enum_name);
                                    try self.write("_");
                                    try self.write(parts.variant_name);
                                    return;
                                }
                            }
                        }
                    }

                    // Module alias symbol access: `alias.symbol` -> `alias__symbol`.
                    if (left.*.type == .Identifier and left.*.data != null and right.*.type == .Identifier and right.*.data != null) {
                        const alias_name = left.*.data.?.sval.items;
                        const member_name = right.*.data.?.sval.items;
                        if (try self.resolve_alias_qualified_symbol_name(&node, alias_name, member_name)) |qualified| {
                            defer self.allocator.free(qualified);
                            try self.write(qualified);
                            return;
                        }
                    }

                    // Enum variant constant: `Enum.Variant` -> `Enum_Variant` in C.
                    if (left.*.type == .Identifier and left.*.data != null and right.*.type == .Identifier and right.*.data != null) {
                        const enum_name = left.*.data.?.sval.items;
                        const variant_name = right.*.data.?.sval.items;

                        var is_shadowed_by_variable = false;
                        if (self.get_scope_entity(enum_name)) |ent| {
                            if (ent.node) |ent_node| {
                                if (ent_node.type == .Variable) is_shadowed_by_variable = true;
                            }
                        }

                        if (!is_shadowed_by_variable) {
                            if (self.root_registry()) |reg| {
                                if (reg.enums_by_name.get(enum_name)) |enode| {
                                    if (enode.node_variant == null) return;
                                    const emit_enum_name = enode.node_variant.?.enum_decl.name.items;
                                    try self.write(emit_enum_name);
                                    try self.write("_");
                                    try self.write(variant_name);
                                    return;
                                }
                            }
                        }
                    }

                    try self.transpile_node(left.*);
                    const pd = self.expr_pointer_depth_from_scope(left.*);
                    try self.write(if (pd > 0) "->" else ".");
                    try self.transpile_node(right.*);
                } else if (mem.eql(u8, exp.op, "=")) {
                    // If assigning into a quirk-typed variable, coerce `T*` -> quirk when possible.
                    const left = exp.left orelse return;
                    const right = exp.right orelse return;
                    if (left.type == .Identifier and left.data != null and mem.eql(u8, left.data.?.sval.items, "_")) {
                        try self.write("(void)(");
                        try self.transpile_node(right.*);
                        try self.write(")");
                        return;
                    }
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
                if (exp.*.type == .Blank) {
                    return;
                }
                if (exp.*.type == .Expression and exp.*.node_variant != null and mem.eql(u8, exp.*.node_variant.?.exp.op, ",")) {
                    try self.transpile_node(exp.*);
                } else {
                    try self.write("(");
                    try self.transpile_node(exp.*);
                    try self.write(")");
                }
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
                if (self.import_alias) |alias| {
                    if (self.get_scope_entity(str) == null) {
                        if (self.emit_module_proc) |mproc| {
                            if (!mem.eql(u8, str, "main") and self.module_has_function_named(mproc, str)) {
                                try self.write(alias);
                                try self.write("__");
                                try self.write(str);
                                return;
                            }
                        }

                        if (self.global_symbols.get(str)) |g| {
                            const current_emit_path = self.emit_input_file_path orelse self.input_file_path;
                            if (g.is_function and g.is_public and mem.eql(u8, g.file_path, current_emit_path) and !mem.eql(u8, str, "main")) {
                                try self.write(alias);
                                try self.write("__");
                                try self.write(str);
                                return;
                            }
                        }
                    }
                }
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

                if (function.type_params != null and self.override_fn_name == null) {
                    return;
                }

                if (self.override_fn_name == null) {
                    if (self.function_has_unresolved_placeholder(node)) {
                        return;
                    }
                    if (function.name) |name| {
                        if (self.mangled_contains_unresolved_placeholder(name.items)) {
                            return;
                        }
                    }
                } else if (self.mangled_contains_unresolved_placeholder(self.override_fn_name.?)) {
                    return;
                }

                // Reset defer stack for this function.
                self.defer_stack.clearRetainingCapacity();

                const prev_fn_return = self.current_fn_return;
                defer self.current_fn_return = prev_fn_return;
                self.current_fn_return = if (function.rtype) |rt| type_from_dtype(&rt) else CheckedType{ .base = .Void };

                // Function scope (arguments live here; body gets its own nested scope).
                _ = try self.new_scope();
                defer self.finish_scope();

                if (function.is_async and function.name != null and !mem.eql(u8, function.name.?.items, "main")) {
                    try self.write_async_function_support_definitions(node);
                    try self.write("\n");
                }

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
                        const prev_in_fn_body = self.in_function_body;
                        const prev_body_depth = self.function_body_depth;
                        self.in_main = true;
                        self.in_function_body = true;
                        self.function_body_depth = 0;
                        defer {
                            self.in_main = prev_in_main;
                            self.in_function_body = prev_in_fn_body;
                            self.function_body_depth = prev_body_depth;
                        }
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
                        try self.write_effective_function_name(node, name.items);
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
                        try self.write("const char* __fun_vtags");
                        try self.write(", ...");
                    }
                    self.in_function_params = false;
                    try self.write(") ");

                    if (function.body) |body| {
                        const prev_in_fn_body = self.in_function_body;
                        const prev_body_depth = self.function_body_depth;
                        const prev_var = self.current_fn_is_variadic;
                        self.in_function_body = true;
                        self.function_body_depth = 0;
                        self.current_fn_is_variadic = function.is_variadic;
                        defer {
                            self.in_function_body = prev_in_fn_body;
                            self.function_body_depth = prev_body_depth;
                            self.current_fn_is_variadic = prev_var;
                        }
                        try self.transpile_node(body.*);
                    }
                }
            },
            .Body => {
                const body = node.node_variant.?.body;

                const is_fn_body = self.in_function_body and self.function_body_depth == 0;
                if (self.in_function_body) self.function_body_depth += 1;
                defer {
                    if (self.in_function_body) self.function_body_depth -= 1;
                }

                // Each body introduces a new scope.
                _ = try self.new_scope();
                defer self.finish_scope();

                try self.write("{");
                self.indent();
                if (is_fn_body and self.current_fn_is_variadic) {
                    try self.write("\n");
                    try self.write_indent();
                    try self.write("Vec__str vargs;\n");
                    try self.write_indent();
                    try self.write("vargs.len = 0; vargs.cap = 0; vargs.data = NULL;\n");
                    try self.write_indent();
                    try self.write("if (__fun_vtags) {\n");
                    self.indent();
                    try self.write_indent();
                    try self.write("size_t __fun_vc = 0; while (__fun_vtags[__fun_vc] != 0) { __fun_vc++; }\n");
                    try self.write_indent();
                    try self.write("vargs.len = (long long)__fun_vc; vargs.cap = (long long)__fun_vc;\n");
                    try self.write_indent();
                    try self.write("if (__fun_vc > 0) { vargs.data = (char**)malloc(sizeof(char*) * __fun_vc); }\n");
                    try self.write_indent();
                    try self.write("va_list __fun_ap; va_start(__fun_ap, __fun_vtags);\n");
                    try self.write_indent();
                    try self.write("size_t __fun_vi = 0; while (__fun_vi < __fun_vc) {\n");
                    self.indent();
                    try self.write_indent();
                    try self.write("char __fun_tagc = __fun_vtags[__fun_vi];\n");
                    try self.write_indent();
                    try self.write("switch (__fun_tagc) {\n");
                    self.indent();
                    try self.write_indent();
                    try self.write("case 's': vargs.data[__fun_vi] = va_arg(__fun_ap, char*); break;\n");
                    try self.write_indent();
                    try self.write("case 'n': vargs.data[__fun_vi] = ");
                    try self.write_module_function_ref("fmt_num");
                    try self.write("((long long)va_arg(__fun_ap, long long)); break;\n");
                    try self.write_indent();
                    try self.write("case 'd': vargs.data[__fun_vi] = ");
                    try self.write_module_function_ref("fmt_dec");
                    try self.write("((double)va_arg(__fun_ap, double)); break;\n");
                    try self.write_indent();
                    try self.write("case 'b': vargs.data[__fun_vi] = ");
                    try self.write_module_function_ref("fmt_bin");
                    try self.write("((bool)va_arg(__fun_ap, int)); break;\n");
                    try self.write_indent();
                    try self.write("case 'c': vargs.data[__fun_vi] = ");
                    try self.write_module_function_ref("fmt_chr");
                    try self.write("((char)va_arg(__fun_ap, int)); break;\n");
                    try self.write_indent();
                    try self.write("case 'p': vargs.data[__fun_vi] = ");
                    try self.write_module_function_ref("fmt_raw");
                    try self.write("((void*)va_arg(__fun_ap, void*)); break;\n");
                    try self.write_indent();
                    try self.write("default: vargs.data[__fun_vi] = ");
                    try self.write_module_function_ref("fmt_raw");
                    try self.write("((void*)va_arg(__fun_ap, void*)); break;\n");
                    self.dedent();
                    try self.write_indent();
                    try self.write("}\n");
                    try self.write_indent();
                    try self.write("__fun_vi = __fun_vi + 1;\n");
                    self.dedent();
                    try self.write_indent();
                    try self.write("}\n");
                    try self.write_indent();
                    try self.write("va_end(__fun_ap);\n");
                    self.dedent();
                    try self.write_indent();
                    try self.write("}\n");
                }
                for (body.statements.items()) |statement| {
                    if (statement.type == .Variable) {
                        try self.register_scope_variable(statement);
                    }
                    if (statement.type != .StatementReturn and statement.type != .StatementDefer) {
                        try self.write_indent();
                    }
                    try self.transpile_node(statement.*);
                    if (statement.type == .Expression) {
                        try self.write(";");
                    }
                }
                self.dedent();
                if (is_fn_body) {
                    const stmts = body.statements.items();
                    const last_is_return = stmts.len > 0 and stmts[stmts.len - 1].*.type == .StatementReturn;
                    if (!last_is_return) {
                        try self.emit_defers();
                    }
                }
                try self.write_indent();
                try self.write("}");
            },
            .StatementReturn, .StatementDefer, .StatementAsm, .StatementIf, .StatementElseIf, .StatementElse, .StatementFit, .StatementFor, .StatementAssert, .StatementWarningControl => {
                // `ret;` is represented as StatementReturn with no node_variant.
                if (node.type == .StatementReturn and node.node_variant == null) {
                    try self.emit_defers();
                    try self.write_indent();
                    if (self.in_main) {
                        // `main` always emits as `int main(...)` in C.
                        // For default-void `main`, bare `ret;` maps to success status 0.
                        // For `main() num`, typecheck rejects bare `ret;`, but keep 0 as fallback.
                        try self.write("return 0;");
                    } else {
                        try self.write("return;");
                    }
                    return;
                }

                const statement = node.node_variant.?.statement;
                switch (statement) {
                    .defer_stmt => |d| {
                        // Record defer for later emission; do not emit now.
                        self.defer_stack.append(d.body) catch return TranspileError.MemoryAllocationFailed;
                    },
                    .asm_stmt => |a| {
                        // Validate optional arch selection.
                        if (a.arch) |arch_name| {
                            const arch_ok = blk: {
                                const arch = builtin.target.cpu.arch;
                                if (mem.eql(u8, arch_name.items, "x86_64") or mem.eql(u8, arch_name.items, "amd64")) {
                                    break :blk arch == .x86_64;
                                }
                                if (mem.eql(u8, arch_name.items, "x86") or mem.eql(u8, arch_name.items, "i386")) {
                                    break :blk arch == .x86;
                                }
                                if (mem.eql(u8, arch_name.items, "aarch64") or mem.eql(u8, arch_name.items, "arm64")) {
                                    break :blk arch == .aarch64;
                                }
                                if (mem.eql(u8, arch_name.items, "arm")) {
                                    break :blk arch == .arm;
                                }
                                break :blk false;
                            };
                            if (!arch_ok) {
                                self.report_error(node, "asm arch '{s}' does not match target", .{arch_name.items});
                                return TranspileError.InvalidAsm;
                            }
                        }

                        const escapeAsm = struct {
                            fn call(w: *Self, text: []const u8) TranspileError!void {
                                for (text) |ch| {
                                    switch (ch) {
                                        '\\' => try w.write("\\\\"),
                                        '"' => try w.write("\\\""),
                                        '\n' => try w.write("\\n"),
                                        '\r' => try w.write("\\r"),
                                        '\t' => try w.write("\\t"),
                                        0 => try w.write("\\0"),
                                        else => {
                                            var buf: [1]u8 = .{ch};
                                            try w.write(buf[0..]);
                                        },
                                    }
                                }
                            }
                        }.call;

                        try self.write_indent();
                        try self.write("__asm__");
                        if (a.is_volatile) {
                            try self.write(" __volatile__");
                        }
                        try self.write("(\"");
                        try escapeAsm(self, a.template.items);
                        try self.write("\"");

                        const has_outputs = a.outputs.items().len != 0;
                        const has_inputs = a.inputs.items().len != 0;
                        const has_clobbers = a.clobbers.items().len != 0;

                        if (has_outputs or has_inputs or has_clobbers) {
                            try self.write(" : ");
                            if (has_outputs) {
                                var first = true;
                                for (a.outputs.items()) |op| {
                                    if (!first) try self.write(", ");
                                    first = false;
                                    try self.write("[");
                                    try self.write(op.name.items);
                                    try self.write("] \"");
                                    try escapeAsm(self, op.constraint.items);
                                    try self.write("\"(");
                                    try self.transpile_node(op.expr.*);
                                    try self.write(")");
                                }
                            }

                            if (has_inputs or has_clobbers) {
                                try self.write(" : ");
                                if (has_inputs) {
                                    var first_in = true;
                                    for (a.inputs.items()) |op| {
                                        if (!first_in) try self.write(", ");
                                        first_in = false;
                                        try self.write("[");
                                        try self.write(op.name.items);
                                        try self.write("] \"");
                                        try escapeAsm(self, op.constraint.items);
                                        try self.write("\"(");
                                        try self.transpile_node(op.expr.*);
                                        try self.write(")");
                                    }
                                }

                                if (has_clobbers) {
                                    try self.write(" : ");
                                    var first_cl = true;
                                    for (a.clobbers.items()) |cl| {
                                        if (!first_cl) try self.write(", ");
                                        first_cl = false;
                                        try self.write("\"");
                                        try escapeAsm(self, cl.items);
                                        try self.write("\"");
                                    }
                                }
                            }
                        }

                        try self.write(");");
                    },
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
                    .return_stmt => |rn| {
                        self.warn_if_returning_address_of_local(rn.*);
                        try self.emit_defers();
                        try self.write_indent();
                        if (self.in_main) {
                            const main_ret = self.current_fn_return orelse CheckedType{ .base = .Void };
                            if (main_ret.base == .Num and !main_ret.is_array and main_ret.pointer_depth == 0) {
                                try self.write("return (int)(");
                                try self.transpile_node(rn.*);
                                try self.write(");");
                            } else {
                                // Default-void main ignores expression and returns success.
                                try self.write("return 0;");
                            }
                        } else {
                            const ret_t = self.current_fn_return orelse CheckedType{ .base = .Void };
                            if (self.is_quirk_named_type(ret_t)) {
                                const reg = self.root_registry() orelse {
                                    try self.write("return ");
                                    try self.transpile_node(rn.*);
                                    try self.write(";");
                                    return;
                                };
                                const sig = reg.quirk_sig_by_name.get(ret_t.name.?) orelse null;
                                const actual = self.expr_named_pointee_from_scope(rn.*);
                                if (sig != null and actual != null and reg.impls_by_key.contains(.{ .type_name = actual.?, .quirk_sig = sig.? })) {
                                    var type_stack4: [128]u8 = undefined;
                                    const type_s = try self.c_ident_sanitize_temp(actual.?, &type_stack4);
                                    defer if (type_s.owned) self.backing_allocator.free(type_s.slice);
                                    var coerce_buf: [96]u8 = undefined;
                                    const coerce_name = (std.fmt.bufPrint(&coerce_buf, "__fun_coerce_{s}_{x}", .{ type_s.slice, self.quirk_sig_hash_cached(sig.?) }) catch unreachable);
                                    try self.write("return ");
                                    try self.write(coerce_name);
                                    try self.write("(");
                                    try self.transpile_node(rn.*);
                                    try self.write(");");
                                } else {
                                    try self.write("return ");
                                    try self.transpile_node(rn.*);
                                    try self.write(";");
                                }
                            } else {
                                try self.write("return ");
                                try self.transpile_node(rn.*);
                                try self.write(";");
                            }
                        }
                    },
                    .assert_stmt => |asrt| {
                        try self.write_indent();
                        try self.write("if (!(");
                        try self.transpile_node(asrt.condition.*);
                        try self.write(")) { ");
                        if (asrt.message) |msg| {
                            try self.write("fprintf(stderr, \"Assertion failed at ");
                            if (node.pos) |p| {
                                try self.print("{s}:{d}: ", .{ p.filename, p.line });
                            }
                            try self.write("%s\\n\", ");
                            try self.transpile_node(msg.*);
                            try self.write("); ");
                        }
                        try self.write("abort(); }");
                    },
                    .warning_ctrl => |ctrl| {
                        try self.queue_warning_control(ctrl.action, ctrl.id, ctrl.reason, node.pos);
                        try self.write("/* ");
                        try self.write(@tagName(ctrl.action));
                        try self.write(" ");
                        try self.write(ast.warning_id_to_string(ctrl.id));
                        try self.write(" */");
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

                                try self.write("for (int64_t ");
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

                                try self.write("for (int64_t ");
                                try self.write(idx_name);
                                try self.write(" = 0; ");
                                try self.write(idx_name);
                                try self.write(" < (int64_t)(sizeof(");
                                try self.write(arr_name);
                                try self.write(")/sizeof(");
                                try self.write(arr_name);
                                try self.write("[0])); ");
                                try self.write(idx_name);
                                try self.write("++) {");
                                self.indent();

                                // Declare the item binding each iteration.
                                // If we can find the array type in scope, use it.
                                var item_c_type: []const u8 = "int64_t";
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

                                // Loop body has its own scope. Register the synthetic
                                // item variable with element dtype so method lowering
                                // (e.g. `item.greet()`) can resolve plain impl methods.
                                _ = try self.new_scope();
                                defer self.finish_scope();

                                if (self.get_scope_entity(arr_name)) |arr_ent| {
                                    if (arr_ent.node) |arr_node| {
                                        if (arr_node.type == .Variable and arr_node.node_variant != null) {
                                            const arr_dt = arr_node.node_variant.?.variable.type;
                                            const item_dt = self.allocator.create(dtype.DataType) catch return TranspileError.MemoryAllocationFailed;
                                            item_dt.* = arr_dt.*;
                                            if (item_dt.flags) |flags| {
                                                var fcopy = flags;
                                                fcopy.is_array = false;
                                                item_dt.flags = fcopy;
                                            }
                                            item_dt.array = null;

                                            const item_node = self.allocator.create(ast.Node) catch return TranspileError.MemoryAllocationFailed;
                                            var item_name_buf = std.ArrayList(u8).init(self.allocator);
                                            item_name_buf.appendSlice(fi.item_name) catch return TranspileError.MemoryAllocationFailed;
                                            item_node.* = .{
                                                .type = .Variable,
                                                .node_variant = .{ .variable = .{
                                                    .type = item_dt,
                                                    .name = item_name_buf,
                                                    .val = null,
                                                } },
                                            };
                                            try self.register_scope_variable(item_node);
                                        }
                                    }
                                }

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
                    // return handled above with defers
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
                if (mem.eql(u8, unary.op, "await")) {
                    const operand = unary.operand.*;
                    if (try self.resolve_await_lowering_info(operand)) |lowering| {
                        defer self.allocator.free(lowering.callee_name);

                        const call_exp = operand.node_variant.?.exp;
                        try self.write("__fun_async_call_");
                        try self.write(lowering.callee_name);
                        try self.write("(");

                        var wrote_arg = false;
                        if (lowering.receiver_expr) |recv| {
                            if (lowering.receiver_pass_by_ref) {
                                try self.write("&");
                            }
                            try self.transpile_node(recv.*);
                            wrote_arg = true;
                        }

                        if (call_exp.right) |right| {
                            const inner = if (right.type == .ExpressionParenthesis and right.node_variant != null)
                                right.node_variant.?.paren.exp.*
                            else
                                right.*;
                            if (inner.type != .Blank) {
                                if (wrote_arg) {
                                    try self.write(", ");
                                }
                                try self.transpile_node(inner);
                            }
                        }

                        try self.write(")");
                        return;
                    }

                    if (self.is_await_dynamic_quirk_dispatch(operand)) {
                        try self.transpile_node(operand);
                        return;
                    }

                    self.report_type_error(node, "await currently supports statically resolved async calls only", .{});
                    return TranspileError.TypeMismatch;
                }
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
        const import_alias = node.node_variant.?.import.alias;
        if (import_alias) |alias| {
            try self.register_import_alias(alias, import_path);
        }
        // Canonicalize legacy/local stdlib prefix `stdlib.std.*` to `std.*`
        // so all stdlib imports resolve through the same stdlib root and avoid
        // duplicate symbol loading from mixed roots.
        const canonical_import_path = if (std.mem.startsWith(u8, import_path, "stdlib.std."))
            import_path["stdlib.".len..]
        else
            import_path;

        if (std.mem.startsWith(u8, canonical_import_path, "std.c.")) {
            try self.process_std_import(node, canonical_import_path);
        } else if (std.mem.startsWith(u8, canonical_import_path, "std.")) {
            try self.process_std_module_import(node, canonical_import_path);
        } else {
            try self.process_local_import(node, import_path, import_alias);
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
    fn process_std_import(self: *Self, import_node: ast.Node, import_path: []const u8) GeneralError!void {
        var header_name: []const u8 = undefined;

        if (mem.eql(u8, import_path, "std.c.io")) {
            header_name = self.allocator.dupe(u8, "stdio.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else if (mem.eql(u8, import_path, "std.c.mem")) {
            header_name = self.allocator.dupe(u8, "stdlib.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else if (mem.eql(u8, import_path, "std.c.string")) {
            header_name = self.allocator.dupe(u8, "string.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else if (mem.eql(u8, import_path, "std.c.math")) {
            header_name = self.allocator.dupe(u8, "math.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else if (mem.eql(u8, import_path, "std.c.ctype")) {
            header_name = self.allocator.dupe(u8, "ctype.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else if (mem.eql(u8, import_path, "std.c.time")) {
            header_name = self.allocator.dupe(u8, "time.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else if (mem.eql(u8, import_path, "std.c.net")) {
            header_name = self.allocator.dupe(u8, "sys/socket.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
            // Additional headers needed for inet_addr and sockaddr_in.
            self.std_imports.append(self.allocator.dupe(u8, "netinet/in.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            }) catch return TranspileError.MemoryAllocationFailed;
            self.std_imports.append(self.allocator.dupe(u8, "arpa/inet.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            }) catch return TranspileError.MemoryAllocationFailed;
            self.std_imports.append(self.allocator.dupe(u8, "unistd.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            }) catch return TranspileError.MemoryAllocationFailed;
        } else if (mem.eql(u8, import_path, "std.c.thread") or mem.eql(u8, import_path, "std.c.thread_windows")) {
            self.requires_thread_compat_layer = true;
            // `std.c.thread*` imports are handled specially in `write_std_imports`:
            // - on Windows, emit Win32-backed pthread-compatible definitions
            // - otherwise, include `<pthread.h>`
            try self.process_std_module_import(import_node, import_path);
            return;
        } else if (mem.eql(u8, import_path, "std.c.limits")) {
            header_name = self.allocator.dupe(u8, "limits.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else if (mem.eql(u8, import_path, "std.c.stdint")) {
            header_name = self.allocator.dupe(u8, "stdint.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else if (mem.eql(u8, import_path, "std.c.def")) {
            header_name = self.allocator.dupe(u8, "stddef.h") catch |e| {
                self.err("Failed to allocate memory for header name: {s}", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        } else if (mem.eql(u8, import_path, "std.c.errno")) {
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

        // Also load the std.c signature module so type checking sees function signatures.
        try self.process_std_module_import(import_node, import_path);
    }

    fn process_std_module_import(self: *Self, import_node: ast.Node, import_path: []const u8) GeneralError!void {
        const full_path_opt = try self.build_stdlib_module_path(import_path);
        if (full_path_opt == null) {
            self.report_error(import_node, "Import file not found: {s}", .{import_path});
            return TranspileError.ImportFileNotFound;
        }
        const full_path = full_path_opt.?;
        defer self.backing_allocator.free(full_path);
        try self.process_local_import_full_path(full_path, if (import_node.node_variant) |nv| nv.import.alias else null);
    }

    /// Process a local file import (e.g., "custom" or "folder.file")
    ///
    /// Parameters:
    /// - `self`: The instance of the transpiler.
    /// - `import_path`: The import path as a string.
    ///
    /// Errors:
    /// - Returns an error if processing the import fails.
    fn process_local_import(self: *Self, import_node: ast.Node, import_path: []const u8, import_alias: ?[]const u8) GeneralError!void {
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
        defer self.backing_allocator.free(full_path);

        const canon_path = std.fs.cwd().realpathAlloc(self.allocator, full_path) catch null;
        const canon = canon_path orelse (self.allocator.dupe(u8, full_path) catch return TranspileError.MemoryAllocationFailed);
        errdefer self.allocator.free(canon);

        // Add a comment showing the import attempt
        try self.write("\n/* Attempting to import: ");
        try self.write(full_path);
        try self.write(" */\n");

        // Check if the file exists
        std.fs.cwd().access(canon, .{}) catch {
            // Keep the output comment (useful when dumping partial output), but also
            // emit a real diagnostic tied to the import statement.
            try self.write("\n/* ERROR: Import file not found: ");
            try self.write(full_path);
            try self.write(" */\n");

            self.report_error(import_node, "Import file not found: {s}", .{canon});
            return TranspileError.ImportFileNotFound;
        };

        // Robust direct circular dependency detection
        // First, check if the file being imported already has us in its import chain
        const file_contents = fs.cwd().readFileAlloc(self.backing_allocator, canon, 1024 * 1024) catch |read_err| {
            self.report_error(import_node, "Failed to read import file '{s}': {any}", .{ canon, read_err });
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
        // Avoid importing the same file under different relative paths.
        if (self.imported_files.contains(canon)) {
            self.allocator.free(canon);
            return;
        }
        self.imported_files.put(canon, true) catch |e| {
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

        import_proc.* = try TranspileProcess.init_with_stdlib_dir(self.backing_allocator, canon, "temp.c", .{ .outf = false }, self.stdlib_dir);

        if (import_alias) |alias| {
            import_proc.import_alias = import_proc.allocator.dupe(u8, alias) catch return TranspileError.MemoryAllocationFailed;
        }

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
        const import_path_copy = import_proc.allocator.dupe(u8, canon) catch |e| {
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

            // Skip non-public and main functions entirely
            if (mem.eql(u8, symbol_name, "main")) continue;
            if (!symbol_info.is_public) continue;

            const exported_name = if (self.import_alias) |alias|
                (try self.make_alias_qualified_symbol_name(alias, symbol_name))
            else
                symbol_name;

            // Check if this symbol is already defined in the parent
            if (self.parent.?.global_symbols.get(exported_name)) |existing| {
                // If we find a conflict from a different file, report it.
                // Allow duplicates from the same file path (e.g. when symbols were
                // preloaded earlier for parsing).
                if (!mem.eql(u8, existing.file_path, symbol_info.file_path)) {
                    if (self.import_alias != null) self.allocator.free(exported_name);
                    self.err("Symbol '{s}' in module '{s}' conflicts with same symbol defined in module '{s}'", .{ exported_name, symbol_info.file_path, existing.file_path });
                    return TranspileError.DuplicateSymbol;
                }

                if (self.import_alias != null) self.allocator.free(exported_name);

                continue;
            }

            // Add this symbol to the parent's global registry
            self.parent.?.global_symbols.put(exported_name, .{
                .symbol_name = exported_name,
                .file_path = symbol_info.file_path,
                .is_function = symbol_info.is_function,
                .is_public = symbol_info.is_public,
            }) catch |e| {
                if (self.import_alias != null) self.allocator.free(exported_name);
                std.debug.print("Failed to allocate memory for global symbol: {s}\\n", .{@errorName(e)});
                return TranspileError.MemoryAllocationFailed;
            };
        }
    }

    /// Write standard library imports to the output
    fn write_std_imports(self: *Self) TranspileError!void {
        var seen = std.StringHashMap(bool).init(self.backing_allocator);
        defer seen.deinit();

        const add_header = struct {
            fn call(tp: *Self, map: *std.StringHashMap(bool), name: []const u8) TranspileError!void {
                if (map.contains(name)) return;
                map.put(name, true) catch return TranspileError.MemoryAllocationFailed;
                try tp.write("#include <");
                try tp.write(name);
                try tp.write(">\n");
            }
        }.call;

        const add_headers_recursive = struct {
            fn call(tp: *Self, map: *std.StringHashMap(bool), proc: *Self) TranspileError!void {
                for (proc.std_imports.items) |header| {
                    try add_header(tp, map, header);
                }
                for (proc.children.items) |child| {
                    try call(tp, map, child);
                }
            }
        }.call;

        try add_headers_recursive(self, &seen, self);

        // Always include core headers once.
        try add_header(self, &seen, "stdio.h");
        try add_header(self, &seen, "stdbool.h");
        try add_header(self, &seen, "stdint.h");
        try add_header(self, &seen, "stdarg.h");
        try add_header(self, &seen, "stdlib.h");
        try add_header(self, &seen, "string.h");

        if (requires_thread_compat_recursive(self)) {
            try self.write("\n");
            try self.write("#if defined(_WIN32)\n");
            try self.write("#ifndef WIN32_LEAN_AND_MEAN\n");
            try self.write("#define WIN32_LEAN_AND_MEAN\n");
            try self.write("#endif\n");
            try self.write("#include <windows.h>\n");
            try self.write("#include <process.h>\n");
            try self.write("#include <errno.h>\n");
            try self.write("#include <time.h>\n");
            try self.write("\n");
            try self.write("typedef HANDLE pthread_t;\n");
            try self.write("typedef void pthread_attr_t;\n");
            try self.write("typedef CRITICAL_SECTION pthread_mutex_t;\n");
            try self.write("typedef void pthread_mutexattr_t;\n");
            try self.write("typedef CONDITION_VARIABLE pthread_cond_t;\n");
            try self.write("typedef void pthread_condattr_t;\n");
            try self.write("typedef struct __fun_win_timespec {\n");
            try self.write("    time_t tv_sec;\n");
            try self.write("    long tv_nsec;\n");
            try self.write("} __fun_win_timespec;\n");
            try self.write("\n");
            try self.write("typedef struct __fun_win_thread_ctx {\n");
            try self.write("    void* (*entry)(void*);\n");
            try self.write("    void* arg;\n");
            try self.write("} __fun_win_thread_ctx;\n");
            try self.write("\n");
            try self.write("static unsigned __stdcall __fun_win_thread_start(void* opaque) {\n");
            try self.write("    __fun_win_thread_ctx* ctx = (__fun_win_thread_ctx*)opaque;\n");
            try self.write("    if (ctx == NULL) {\n");
            try self.write("        _endthreadex(0);\n");
            try self.write("        return 0;\n");
            try self.write("    }\n");
            try self.write("\n");
            try self.write("    void* (*entry)(void*) = ctx->entry;\n");
            try self.write("    void* arg = ctx->arg;\n");
            try self.write("    free(ctx);\n");
            try self.write("\n");
            try self.write("    if (entry != NULL) {\n");
            try self.write("        (void)entry(arg);\n");
            try self.write("    }\n");
            try self.write("\n");
            try self.write("    _endthreadex(0);\n");
            try self.write("    return 0;\n");
            try self.write("}\n");
            try self.write("\n");
            try self.write("long long pthread_create(pthread_t* thread, pthread_attr_t* attr, void* start_routine, void* arg) {\n");
            try self.write("    (void)attr;\n");
            try self.write("    if (thread == NULL || start_routine == NULL) {\n");
            try self.write("        return (long long)EINVAL;\n");
            try self.write("    }\n");
            try self.write("\n");
            try self.write("    __fun_win_thread_ctx* ctx = (__fun_win_thread_ctx*)malloc(sizeof(__fun_win_thread_ctx));\n");
            try self.write("    if (ctx == NULL) {\n");
            try self.write("        return (long long)ENOMEM;\n");
            try self.write("    }\n");
            try self.write("\n");
            try self.write("    ctx->entry = (void* (*)(void*))start_routine;\n");
            try self.write("    ctx->arg = arg;\n");
            try self.write("\n");
            try self.write("    uintptr_t thread_raw = _beginthreadex(NULL, 0, __fun_win_thread_start, (void*)ctx, 0, NULL);\n");
            try self.write("    if (thread_raw == 0) {\n");
            try self.write("        free(ctx);\n");
            try self.write("        return (long long)errno;\n");
            try self.write("    }\n");
            try self.write("\n");
            try self.write("    *thread = (HANDLE)thread_raw;\n");
            try self.write("    return 0;\n");
            try self.write("}\n");
            try self.write("\n");
            try self.write("long long pthread_join(pthread_t thread, void* retval) {\n");
            try self.write("    if (thread == NULL) {\n");
            try self.write("        return (long long)EINVAL;\n");
            try self.write("    }\n");
            try self.write("\n");
            try self.write("    DWORD wait_rc = WaitForSingleObject(thread, INFINITE);\n");
            try self.write("    if (wait_rc != WAIT_OBJECT_0) {\n");
            try self.write("        return (long long)GetLastError();\n");
            try self.write("    }\n");
            try self.write("\n");
            try self.write("    if (retval != NULL) {\n");
            try self.write("        *((void**)retval) = NULL;\n");
            try self.write("    }\n");
            try self.write("\n");
            try self.write("    if (CloseHandle(thread) == 0) {\n");
            try self.write("        return (long long)GetLastError();\n");
            try self.write("    }\n");
            try self.write("\n");
            try self.write("    return 0;\n");
            try self.write("}\n");
            try self.write("\n");
            try self.write("long long pthread_detach(pthread_t thread) {\n");
            try self.write("    if (thread == NULL) {\n");
            try self.write("        return (long long)EINVAL;\n");
            try self.write("    }\n");
            try self.write("    if (CloseHandle(thread) == 0) {\n");
            try self.write("        return (long long)GetLastError();\n");
            try self.write("    }\n");
            try self.write("    return 0;\n");
            try self.write("}\n");
            try self.write("\n");
            try self.write("pthread_t pthread_self(void) {\n");
            try self.write("    return GetCurrentThread();\n");
            try self.write("}\n");
            try self.write("\n");
            try self.write("long long pthread_equal(pthread_t t1, pthread_t t2) {\n");
            try self.write("    DWORD id1 = GetThreadId(t1);\n");
            try self.write("    DWORD id2 = GetThreadId(t2);\n");
            try self.write("    if (id1 == 0 || id2 == 0) {\n");
            try self.write("        return (t1 == t2) ? 1 : 0;\n");
            try self.write("    }\n");
            try self.write("    return (id1 == id2) ? 1 : 0;\n");
            try self.write("}\n");
            try self.write("\n");
            try self.write("long long pthread_mutex_init(pthread_mutex_t* mutex, pthread_mutexattr_t* attr) {\n");
            try self.write("    (void)attr;\n");
            try self.write("    if (mutex == NULL) {\n");
            try self.write("        return (long long)EINVAL;\n");
            try self.write("    }\n");
            try self.write("    InitializeCriticalSection(mutex);\n");
            try self.write("    return 0;\n");
            try self.write("}\n");
            try self.write("\n");
            try self.write("long long pthread_mutex_destroy(pthread_mutex_t* mutex) {\n");
            try self.write("    if (mutex == NULL) {\n");
            try self.write("        return (long long)EINVAL;\n");
            try self.write("    }\n");
            try self.write("    DeleteCriticalSection(mutex);\n");
            try self.write("    return 0;\n");
            try self.write("}\n");
            try self.write("\n");
            try self.write("long long pthread_mutex_lock(pthread_mutex_t* mutex) {\n");
            try self.write("    if (mutex == NULL) {\n");
            try self.write("        return (long long)EINVAL;\n");
            try self.write("    }\n");
            try self.write("    EnterCriticalSection(mutex);\n");
            try self.write("    return 0;\n");
            try self.write("}\n");
            try self.write("\n");
            try self.write("long long pthread_mutex_trylock(pthread_mutex_t* mutex) {\n");
            try self.write("    if (mutex == NULL) {\n");
            try self.write("        return (long long)EINVAL;\n");
            try self.write("    }\n");
            try self.write("    return TryEnterCriticalSection(mutex) ? 0 : (long long)EBUSY;\n");
            try self.write("}\n");
            try self.write("\n");
            try self.write("long long pthread_mutex_unlock(pthread_mutex_t* mutex) {\n");
            try self.write("    if (mutex == NULL) {\n");
            try self.write("        return (long long)EINVAL;\n");
            try self.write("    }\n");
            try self.write("    LeaveCriticalSection(mutex);\n");
            try self.write("    return 0;\n");
            try self.write("}\n");
            try self.write("\n");
            try self.write("long long pthread_cond_init(pthread_cond_t* cond, pthread_condattr_t* attr) {\n");
            try self.write("    (void)attr;\n");
            try self.write("    if (cond == NULL) {\n");
            try self.write("        return (long long)EINVAL;\n");
            try self.write("    }\n");
            try self.write("    InitializeConditionVariable(cond);\n");
            try self.write("    return 0;\n");
            try self.write("}\n");
            try self.write("\n");
            try self.write("long long pthread_cond_destroy(pthread_cond_t* cond) {\n");
            try self.write("    if (cond == NULL) {\n");
            try self.write("        return (long long)EINVAL;\n");
            try self.write("    }\n");
            try self.write("    return 0;\n");
            try self.write("}\n");
            try self.write("\n");
            try self.write("long long pthread_cond_wait(pthread_cond_t* cond, pthread_mutex_t* mutex) {\n");
            try self.write("    if (cond == NULL || mutex == NULL) {\n");
            try self.write("        return (long long)EINVAL;\n");
            try self.write("    }\n");
            try self.write("    return SleepConditionVariableCS(cond, mutex, INFINITE) ? 0 : (long long)GetLastError();\n");
            try self.write("}\n");
            try self.write("\n");
            try self.write("long long pthread_cond_timedwait(pthread_cond_t* cond, pthread_mutex_t* mutex, void* abstime) {\n");
            try self.write("    if (cond == NULL || mutex == NULL) {\n");
            try self.write("        return (long long)EINVAL;\n");
            try self.write("    }\n");
            try self.write("    if (abstime == NULL) {\n");
            try self.write("        return (long long)EINVAL;\n");
            try self.write("    }\n");
            try self.write("\n");
            try self.write("    const __fun_win_timespec* ts = (const __fun_win_timespec*)abstime;\n");
            try self.write("    if (ts->tv_nsec < 0 || ts->tv_nsec >= 1000000000L) {\n");
            try self.write("        return (long long)EINVAL;\n");
            try self.write("    }\n");
            try self.write("\n");
            try self.write("    FILETIME ft;\n");
            try self.write("    GetSystemTimeAsFileTime(&ft);\n");
            try self.write("    ULARGE_INTEGER now_filetime;\n");
            try self.write("    now_filetime.LowPart = ft.dwLowDateTime;\n");
            try self.write("    now_filetime.HighPart = ft.dwHighDateTime;\n");
            try self.write("\n");
            try self.write("    const unsigned long long unix_epoch_in_filetime = 116444736000000000ULL;\n");
            try self.write("    unsigned long long now_ns = 0ULL;\n");
            try self.write("    if (now_filetime.QuadPart > unix_epoch_in_filetime) {\n");
            try self.write("        now_ns = (now_filetime.QuadPart - unix_epoch_in_filetime) * 100ULL;\n");
            try self.write("    }\n");
            try self.write("\n");
            try self.write("    long long sec = (long long)ts->tv_sec;\n");
            try self.write("    if (sec < 0) {\n");
            try self.write("        return (long long)ETIMEDOUT;\n");
            try self.write("    }\n");
            try self.write("\n");
            try self.write("    unsigned long long target_ns = ((unsigned long long)sec * 1000000000ULL) + (unsigned long long)ts->tv_nsec;\n");
            try self.write("\n");
            try self.write("    DWORD timeout_ms = 0;\n");
            try self.write("    if (target_ns > now_ns) {\n");
            try self.write("        unsigned long long delta_ns = target_ns - now_ns;\n");
            try self.write("        unsigned long long delta_ms = delta_ns / 1000000ULL;\n");
            try self.write("        if ((delta_ns % 1000000ULL) != 0ULL) {\n");
            try self.write("            delta_ms += 1ULL;\n");
            try self.write("        }\n");
            try self.write("\n");
            try self.write("        if (delta_ms >= 0xFFFFFFFEULL) {\n");
            try self.write("            timeout_ms = 0xFFFFFFFEu;\n");
            try self.write("        } else {\n");
            try self.write("            timeout_ms = (DWORD)delta_ms;\n");
            try self.write("        }\n");
            try self.write("    }\n");
            try self.write("\n");
            try self.write("    BOOL ok = SleepConditionVariableCS(cond, mutex, timeout_ms);\n");
            try self.write("    if (ok != 0) {\n");
            try self.write("        return 0;\n");
            try self.write("    }\n");
            try self.write("    DWORD err = GetLastError();\n");
            try self.write("    if (err == ERROR_TIMEOUT) {\n");
            try self.write("        return (long long)ETIMEDOUT;\n");
            try self.write("    }\n");
            try self.write("    return (long long)err;\n");
            try self.write("}\n");
            try self.write("\n");
            try self.write("long long pthread_cond_signal(pthread_cond_t* cond) {\n");
            try self.write("    if (cond == NULL) {\n");
            try self.write("        return (long long)EINVAL;\n");
            try self.write("    }\n");
            try self.write("    WakeConditionVariable(cond);\n");
            try self.write("    return 0;\n");
            try self.write("}\n");
            try self.write("\n");
            try self.write("long long pthread_cond_broadcast(pthread_cond_t* cond) {\n");
            try self.write("    if (cond == NULL) {\n");
            try self.write("        return (long long)EINVAL;\n");
            try self.write("    }\n");
            try self.write("    WakeAllConditionVariable(cond);\n");
            try self.write("    return 0;\n");
            try self.write("}\n");
            try self.write("#else\n");
            try self.write("#include <pthread.h>\n");
            try self.write("#endif\n");
        }
    }

    fn requires_thread_compat_recursive(proc: *Self) bool {
        if (proc.requires_thread_compat_layer) return true;
        for (proc.children.items) |child| {
            if (requires_thread_compat_recursive(child)) return true;
        }
        return false;
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
