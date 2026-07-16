const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const codegen = @import("codegen");
const TranspileError = codegen.TranspileError;
const lexer = @import("lexer");
const LexError = lexer.LexError;
const token = lexer.token;
const ast = @import("ast");
const expressionable = ast.expressionable;
const utils = @import("utils");
const semantics = @import("semantics");
const dtype = semantics.dtype;
const scope = semantics.scope;
const symbol = semantics.symbol;

/// Compatibility shim: ArrayList with embedded allocator (old-style managed API).
fn ArrayList(comptime T: type) type {
    return std.array_list.Managed(T);
}

/// Maximum recursive-descent depth for the expression parser. Guards against
/// stack-overflow crashes on pathological input. Each nesting level costs several
/// native frames (paren -> expressionable_root -> expressionable -> single ->
/// expression), so this limit translates to several times as many real frames.
/// Set well above any plausible human-written expression (deeply nested parens /
/// very long operator chains would be machine-generated) while staying safely
/// below even a default ~8 MB thread stack — so callers that run the pipeline on
/// the default stack (e.g. the in-process test harness) get a clean
/// `ExpressionTooDeep` error rather than a segfault, and the CLI (which runs on a
/// large dedicated stack) has ample headroom.
const max_parse_expr_depth: usize = 600;

/// Errors that can occur during parsing process.
pub const ParseError = error{
    /// Error indicating an invalid symbol.
    InvalidSymbol,
    /// Error indicating an invalid keyword.
    InvalidKeyword,
    /// Error indicating an invalid datatype.
    InvalidDataType,
    /// Error indicating an invalid token.
    InvalidToken,
    /// Error indicating an invalid identifier.
    InvalidIdentifier,
    /// Error indicating an invalid operand.
    InvalidOperand,
    /// Error indicating an invalid statement.
    InvalidStatement,
    /// Error indicating an invalid string.
    InvalidString,
} || TranspileError || LexError;

/// Represents the parsing process in the transpiler.
///
/// This struct handles the parsing process within the transpiler, including
/// the associated transpilation process and methods for parsing.
pub const ParseProcess = struct {
    /// The transpilation process associated with the parsing process.
    transpile_proc: *codegen.TranspileProcess,
    /// The last token processed by the parser.
    parser_last_token: token.Token = undefined,
    /// The current body node being processed by the parser.
    parser_current_body: ?ast.Node = null,
    /// The current function node being processed by the parser.
    parser_current_function: ?ast.Node = null,

    /// O(1) significant-token lookahead index (see `token_peek_n`).
    ///
    /// `sig_indices[r]` is the physical index of the r-th "significant" token
    /// (a token for which `is_nl_or_comment_or_newline_separator` is false), in
    /// stream order. `phys_to_rank[p]` is the number of significant tokens at
    /// physical indices strictly less than `p` — i.e. the rank of the first
    /// significant token at or after `p`. With these, the n-th significant token
    /// at or after the cursor is `sig_indices[phys_to_rank[pindex] + n]`, an O(1)
    /// lookup instead of an O(n) forward rescan.
    ///
    /// The tables are rebuilt lazily whenever the token stream's structural
    /// `generation` changes (the parser only mutates the stream when splitting
    /// `>>`/`<<`), so they cost one O(n) pass amortized over the whole parse.
    /// They are lazily allocated on first use; storage is reused across rebuilds.
    sig_indices: ?ArrayList(u32) = null,
    phys_to_rank: ?ArrayList(u32) = null,
    /// The token-stream `generation` the tables above were built for; `null`
    /// means "never built". A mismatch with the live generation forces a rebuild.
    sig_table_generation: ?u64 = null,

    /// Set of top-level type names (`compound`/`enum`/`quirk`) declared ANYWHERE
    /// in the file, collected by a cheap O(n) token pre-scan before the main
    /// single-pass parse (see `prescan_forward_type_names`). This lets the
    /// compound-initializer detector accept `Name{...}` expressions whose type is
    /// declared LATER in the file (forward reference), without being fooled by
    /// comparisons like `a > b {` — `b` won't be in this set unless it is an
    /// actual declared type. Null until the pre-scan runs.
    forward_type_names: ?std.StringHashMap(void) = null,

    /// Current native-recursion depth of the recursive-descent expression parser.
    /// Guarded against stack-overflow crashes on pathological input (deeply nested
    /// parentheses, very long flat operator chains) so the parser reports a clean
    /// `ExpressionTooDeep` error instead of segfaulting. This is the EARLIEST pass,
    /// so guarding it here also protects the downstream AST printer, type checker,
    /// and codegen, which recurse over the same tree.
    expr_depth: usize = 0,

    /// True while parsing a `fit` arm CONDITION. A data-carrying-enum pattern like
    /// `Enum.Variant(x, y)` introduces NEW binding identifiers (`x`, `y`) that are
    /// not yet in scope, so the eager "unknown identifier" parse-time check must be
    /// relaxed here; the binding names are registered (and validated) right after
    /// the condition is parsed, and the type-checker enforces correctness.
    in_fit_condition: bool = false,

    const Self = @This();

    /// Initializes a new `ParseProcess` instance.
    ///
    /// This function creates and initializes a new instance of `ParseProcess` with the given transpilation process.
    ///
    /// Parameters:
    /// - `transpile_proc (*transpiler.TranspileProcess)`: The transpilation process to associate with the new `ParseProcess` instance.
    ///
    /// Returns:
    /// - `Self`: The initialized `ParseProcess` instance.
    pub fn init(transpile_proc: *codegen.TranspileProcess) Self {
        return Self{
            .transpile_proc = transpile_proc,
        };
    }

    /// Expects the next token to be a specific symbol.
    ///
    /// This function retrieves the next token and checks if it matches the specified symbol (`c`).
    /// If the next token is not the expected symbol, it logs an error message indicating that
    /// the expected symbol was not found.
    ///
    /// Parameters:
    /// - `c (u8)`: The expected symbol.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    /// - Logs an error message if the next token is not the expected symbol.
    fn expect_sym(self: *Self, c: u8) ParseError!void {
        const t = self.token_next();
        if (t == null or t.?.type != .Symbol or t.?.data.cval != c) {
            self.transpile_proc.err("expected symbol '{c}'", .{c});
            return ParseError.InvalidSymbol;
        }
    }

    /// Expects the next token to be a specific operator.
    ///
    /// This function retrieves the next token and checks if it matches the specified operator (`op`).
    /// If the next token is not the expected operator, it logs an error message indicating that
    /// the expected operator was not found.
    ///
    /// Parameters:
    /// - `op ( []const u8 )`: The expected operator.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    /// - Logs an error message if the next token is not the expected operator.
    fn expect_op(self: *Self, op: []const u8) ParseError!void {
        const t = self.token_next();
        if (t == null or t.?.type != .Operator or !mem.eql(u8, op, t.?.data.sval.items)) {
            self.transpile_proc.err("expected operator '{s}'", .{op});
            return ParseError.InvalidOperator;
        }
    }

    /// Expects the next token to be a specific keyword.
    ///
    /// This function retrieves the next token and checks if it matches the specified keyword (`keyword`).
    /// If the next token is not the expected keyword, it logs an error message indicating that
    /// the expected keyword was not found.
    ///
    /// Parameters:
    /// - `self`: The instance of the parser.
    /// - `keyword ( []const u8 )`: The expected keyword.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    /// - Logs an error message if the next token is not the expected keyword.
    fn expect_keyword(self: *Self, keyword: []const u8) ParseError!void {
        const t = self.token_next();
        if (t == null or t.?.type != .Keyword or !mem.eql(u8, keyword, t.?.data.sval.items)) {
            self.transpile_proc.err("expected keyword '{s}'", .{keyword});
            return ParseError.InvalidKeyword;
        }
    }

    /// Creates and initializes a new node in the transpiler's node list.
    ///
    /// This function sets the `owner` and `function` bindings of the provided node (`n`)
    /// and adds it to the transpiler's node list.
    ///
    /// Parameters:
    /// - `n (*ast.Node)`: The node to create and initialize.
    ///
    /// Errors:
    /// - Returns an error if adding the node to the node list fails.
    fn create_node(self: *Self, n: *ast.Node) ParseError!void {
        var is_bound = false;
        var binded: ast.BindedNode = .{
            .owner = null,
            .function = null,
        };
        if (self.parser_current_body) |body| {
            if (body.binded != null) {
                const owner = self.transpile_proc.allocator.create(ast.Node) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(owner);
                owner.* = body;
                // Binded nodes are only used for context; avoid copying ownership-bearing fields.
                owner.*.binded = null;
                owner.*.data = null;
                owner.*.node_variant = null;
                binded.owner = owner;
                is_bound = true;
            }
        }
        if (self.parser_current_function) |func| {
            const function = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(function);
            function.* = func;
            // Binded nodes are only used for context; avoid copying ownership-bearing fields.
            function.*.binded = null;
            function.*.data = null;
            function.*.node_variant = null;
            binded.function = function;
            is_bound = true;
        }
        if (is_bound) {
            const b = self.transpile_proc.allocator.create(ast.BindedNode) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(b);
            b.*.function = binded.function;
            b.*.owner = binded.owner;
            n.binded = b;
        } else {
            n.binded = null;
        }
        self.transpile_proc.nodes.push(n.*) catch {
            return ParseError.MemoryAllocationFailed;
        };
    }

    ///
    /// This function initializes a new scope entity with the provided node and flags.
    ///
    /// Parameters:
    /// - `self`: The instance of the parser.
    /// - `node (*ast.Node)`: The node to associate with the scope entity.
    /// - `flags (scope.ScopeEntityFlags)`: The flags to set for the scope entity.
    ///
    /// Returns:
    /// - `*scope.ScopeEntity`: The initialized scope entity.
    ///
    /// Errors:
    /// - Returns an error if creating the scope entity fails.
    fn new_scope_entity(self: *Self, node: *ast.Node, flags: scope.ScopeEntityFlags) ParseError!*scope.ScopeEntity {
        var entity = self.transpile_proc.allocator.create(scope.ScopeEntity) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(entity);
        entity.node = node;
        entity.flags = flags;
        entity.name = switch (node.type) {
            .Identifier => node.data.?.sval.items,
            .Function => node.data.?.sval.items,
            .Variable => node.node_variant.?.variable.name.items,
            else => "",
        };
        return entity;
    }

    /// Retrieves the last entity from the current scope, stopping at the global scope.
    ///
    /// This function retrieves the last entity from the current scope, stopping at the global scope.
    ///
    /// Parameters:
    /// - `self`: The instance of the parser.
    ///
    /// Returns:
    /// - `*scope.ScopeEntity`: The last entity from the current scope, or `null` if not found.
    fn scope_last_entity_stop_global_scope(self: *Self) *scope.ScopeEntity {
        return self.transpile_proc.last_scope_entity_stop_at(self.transpile_proc.scope.?.root);
    }

    /// Skips newline, comment, and newline separator tokens.
    ///
    /// This function skips tokens that are either newline, comment, or newline separator
    /// tokens by incrementing the token pointer until a non-skippable token is found.
    ///
    /// Parameters:
    /// - `t (*?token.Token)`: The token pointer to update.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    fn ignore_nl_or_comment(self: *Self, t: *?token.Token) void {
        while (t.* != null and token.is_nl_or_comment_or_newline_separator(t.*)) {
            _ = self.transpile_proc.tokens.peek(); // skip token
            t.* = self.transpile_proc.tokens.peek_no_increment();
        }
    }

    /// Peeks at the next non-skippable token.
    ///
    /// This function peeks at the next token and skips any newline, comment, or
    /// newline separator tokens, returning the first non-skippable token.
    ///
    /// Returns:
    /// - `!?token.Token`: The next non-skippable token, or `null` if no such token exists.
    fn token_peek_next(self: *Self) ?token.Token {
        var next_token = self.transpile_proc.tokens.peek_no_increment();
        self.ignore_nl_or_comment(&next_token);
        const peek_token = self.transpile_proc.tokens.peek_no_increment();
        self.transpile_proc.current_token = peek_token;
        return peek_token;
    }

    /// Rebuilds the significant-token lookahead tables (`sig_indices` /
    /// `phys_to_rank`) from the current token stream, if they are stale.
    ///
    /// Stale means the stream's structural `generation` differs from the
    /// generation the tables were last built for (or they were never built).
    /// This is O(number of tokens), but only runs when the stream actually
    /// changes shape — i.e. once after lexing and again after each `>>`/`<<`
    /// split — so it is amortized O(1) per lookahead over a full parse.
    ///
    /// Storage is allocated once from the (arena-backed) transpiler allocator
    /// and reused via `clearRetainingCapacity` on subsequent rebuilds, so there
    /// is no per-rebuild allocation churn after the first build.
    ///
    /// On allocation failure the tables are left marked stale and lookahead
    /// falls back to the linear scan; correctness is never affected.
    fn ensure_sig_tables(self: *Self) void {
        const tokens = &self.transpile_proc.tokens;
        if (self.sig_table_generation != null and self.sig_table_generation.? == tokens.generation) {
            return;
        }

        if (self.sig_indices == null) {
            self.sig_indices = ArrayList(u32).init(self.transpile_proc.allocator);
        }
        if (self.phys_to_rank == null) {
            self.phys_to_rank = ArrayList(u32).init(self.transpile_proc.allocator);
        }
        var sig = &self.sig_indices.?;
        var rank = &self.phys_to_rank.?;
        sig.clearRetainingCapacity();
        rank.clearRetainingCapacity();

        const items = tokens.items();
        // `phys_to_rank` has one entry per physical token: the count of
        // significant tokens before that index.
        rank.ensureTotalCapacity(items.len) catch {
            self.sig_table_generation = null;
            return;
        };
        sig.ensureTotalCapacity(items.len) catch {
            self.sig_table_generation = null;
            return;
        };
        var seen: u32 = 0;
        for (items, 0..) |t, phys| {
            // Rank of physical index `phys` = significant tokens seen before it.
            rank.appendAssumeCapacity(seen);
            if (!token.is_nl_or_comment_or_newline_separator(t)) {
                sig.appendAssumeCapacity(@intCast(phys));
                seen += 1;
            }
        }

        self.sig_table_generation = tokens.generation;
    }

    /// Peeks at the Nth next non-skippable token without incrementing.
    ///
    /// `n = 0` is equivalent to `token_peek_next()`.
    ///
    /// O(1) amortized: resolved through the `sig_indices`/`phys_to_rank` tables
    /// (see `ensure_sig_tables`) rather than rescanning the stream. The result
    /// is identical to a forward scan from `pindex` that skips newline/comment/
    /// `\` tokens and returns the n-th remaining token.
    fn token_peek_n(self: *Self, n: usize) ?token.Token {
        const tokens = &self.transpile_proc.tokens;
        self.ensure_sig_tables();

        // Fallback to the linear scan if the tables could not be built.
        if (self.sig_table_generation == null) return self.token_peek_n_linear(n);

        const rank = self.phys_to_rank.?.items;
        const sig = self.sig_indices.?.items;

        // Clamp the cursor into range. A negative `pindex` means "before the
        // start", which ranks at 0; a `pindex` past the end has no significant
        // token at or after it.
        const pidx = self.transpile_proc.tokens.pindex;
        const start_rank: usize = if (pidx <= 0)
            0
        else if (@as(usize, @intCast(pidx)) >= rank.len)
            sig.len
        else
            rank[@intCast(pidx)];

        const target = start_rank + n;
        if (target >= sig.len) return null;
        return tokens.at(sig[target]);
    }

    /// Linear fallback for `token_peek_n` (used only if the index tables could
    /// not be allocated). Preserves the original semantics exactly.
    fn token_peek_n_linear(self: *Self, n: usize) ?token.Token {
        var idx: isize = self.transpile_proc.tokens.pindex;
        var seen: usize = 0;
        while (true) {
            const t = self.transpile_proc.tokens.at(@intCast(idx)) orelse return null;
            if (!token.is_nl_or_comment_or_newline_separator(t)) {
                if (seen == n) return t;
                seen += 1;
            }
            idx += 1;
        }
    }

    /// Resolves the n-th significant token strictly before physical index
    /// `exclusive_end` (n = 0 → the closest one), via the rank tables. Returns
    /// null when there is no such token or the tables are unavailable.
    ///
    /// `phys_to_rank[exclusive_end]` is the number of significant tokens at
    /// indices `< exclusive_end`, so the closest significant token before it is
    /// `sig_indices[that_count - 1]`, the next one back `... - 2`, and so on.
    fn token_peek_prev_significant(self: *Self, exclusive_end: isize, n: usize) ?token.Token {
        self.ensure_sig_tables();
        if (self.sig_table_generation == null) {
            // Linear fallback: scan down from `exclusive_end - 1`.
            var idx: isize = exclusive_end - 1;
            var seen: usize = 0;
            while (idx >= 0) : (idx -= 1) {
                const t = self.transpile_proc.tokens.at(@intCast(idx)) orelse return null;
                if (token.is_nl_or_comment_or_newline_separator(t)) continue;
                if (seen == n) return t;
                seen += 1;
            }
            return null;
        }

        const rank = self.phys_to_rank.?.items;
        const sig = self.sig_indices.?.items;
        if (exclusive_end <= 0) return null;
        const end: usize = @intCast(exclusive_end);
        const before: usize = if (end >= rank.len) sig.len else rank[end];
        if (before == 0 or n + 1 > before) return null;
        return self.transpile_proc.tokens.at(sig[before - 1 - n]);
    }

    /// Peeks the previous non-skippable token (relative to the most recently consumed token).
    fn token_peek_prev(self: *Self) ?token.Token {
        return self.token_peek_prev_significant(self.transpile_proc.tokens.pindex - 1, 0);
    }

    /// Peeks the Nth previous non-skippable token (relative to the most recently consumed token).
    ///
    /// `n = 0` is equivalent to `token_peek_prev()`.
    fn token_peek_prev_n(self: *Self, n: usize) ?token.Token {
        return self.token_peek_prev_significant(self.transpile_proc.tokens.pindex - 1, n);
    }

    /// Peeks the Nth previous non-skippable token relative to the *next* token to be consumed.
    ///
    /// I.e. when `token_peek_next()` would return token at index `pindex`, this returns tokens
    /// from `pindex-1`, `pindex-2`, etc. This is often the most intuitive notion of "previous"
    /// when doing context-sensitive parsing.
    fn token_peek_prev_stream_n(self: *Self, n: usize) ?token.Token {
        return self.token_peek_prev_significant(self.transpile_proc.tokens.pindex, n);
    }

    fn is_sizeof_type_operand_context(self: *Self) bool {
        const prev = self.token_peek_prev_stream_n(0) orelse return false;
        if (prev.type != .Operator or !mem.eql(u8, prev.data.sval.items, "(")) return false;
        const prev2 = self.token_peek_prev_stream_n(1) orelse return false;
        if (!(prev2.type == .Identifier or prev2.type == .Keyword)) return false;
        return mem.eql(u8, prev2.data.sval.items, "sizeof");
    }

    /// Retrieves the next token.
    ///
    /// This function peeks at the next token without incrementing the token stream's position.
    /// It ignores newline or comment tokens and updates the current position if a valid token is found.
    ///
    /// Returns:
    /// - `!?token.Token`: The next token, or `null` if there are no more tokens.
    fn token_next(self: *Self) ?token.Token {
        var next_token = self.transpile_proc.tokens.peek_no_increment();
        self.ignore_nl_or_comment(&next_token);
        if (next_token != null) {
            self.transpile_proc.pos = next_token.?.pos;
            self.parser_last_token = next_token.?;
        }
        next_token = self.transpile_proc.tokens.peek();
        self.transpile_proc.current_token = next_token;
        return next_token;
    }

    /// Pops the last node from the transpiler's node stack.
    ///
    /// This function retrieves the last node from the transpiler's node stack,
    /// removes it from the stack, and returns the node.
    ///
    /// Returns:
    /// - `?ast.Node`: The last node in the stack, or `null` if the stack is empty.
    ///
    /// Parameters:
    /// - `self (*Self)`: The pointer to the current instance.
    fn node_pop(self: *Self) ?ast.Node {
        const last_node = self.transpile_proc.nodes.back();
        self.transpile_proc.nodes.pop();
        return last_node;
    }

    /// Checks if the next token is a specific symbol.
    ///
    /// This function peeks at the next token and checks if it matches the specified symbol.
    ///
    /// Parameters:
    /// - `c (u8)`: The symbol to check for.
    ///
    /// Returns:
    /// - `bool`: `true` if the next token is the specified symbol, otherwise `false`.
    fn next_token_is_symbol(self: *Self, c: u8) bool {
        const t = self.token_peek_next();
        return token.is_symbol(t, c);
    }

    /// Parses a statement.
    ///
    /// This function peeks at the next token and determines if it is a keyword.
    /// If it is a keyword, it parses it accordingly. Otherwise, it parses an expressionable root.
    /// It also handles symbols and ensures the statement ends with a semicolon.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_statement(self: *Self, hist: *utils.History) ParseError!void {
        var t = self.token_peek_next();
        if (t == null) {
            self.transpile_proc.err("unexpected end of file", .{});
            return ParseError.FileReadError;
        }
        if (t.?.type == .Keyword) {
            return try self.parse_keyword(hist);
        }

        // User-defined type variable declarations start with an identifier datatype, e.g.:
        // `Point p;`, `Point p = ...;`, `Point* p;`, `Point** p = ...;`
        // Detect `<Identifier> [* ...] <Identifier>` and parse it as a variable declaration.
        if (t.?.type == .Identifier) {
            // If the identifier is already a value in scope (e.g. local variable), do NOT
            // treat `ident * ident` as a pointer declaration. This avoids mis-parsing
            // expression statements like `w * h;` as `w* h;`.
            if (self.transpile_proc.get_scope_entity(t.?.data.sval.items) == null) {
                var off: usize = 1;

                // Optional qualified type segments after the leading identifier:
                // `alias.Type name;`
                while (true) {
                    const dot_tok = self.token_peek_n(off) orelse break;
                    if (!(dot_tok.type == .Operator and mem.eql(u8, dot_tok.data.sval.items, "."))) break;

                    const seg_tok = self.token_peek_n(off + 1) orelse break;
                    if (seg_tok.type != .Identifier) break;
                    off += 2;
                }

                _ = self.skip_generic_args_tokens(&off);
                while (true) {
                    const tn = self.token_peek_n(off);
                    if (tn == null) break;
                    if (tn.?.type == .Operator and mem.eql(u8, tn.?.data.sval.items, "*")) {
                        off += 1;
                        continue;
                    }
                    break;
                }

                // Optional array brackets after the type name: `T[] name;` or
                // `T[64] name;`. Without skipping these, a local declaration of a
                // user-defined array type (e.g. `P[] pts;`) was not recognized here
                // and fell through to the expression path, which emitted the
                // variable at file scope instead of inside the function body.
                while (true) {
                    const tok_b = self.token_peek_n(off) orelse break;
                    if (!(tok_b.type == .Operator and mem.eql(u8, tok_b.data.sval.items, "["))) break;
                    off += 1; // skip '['
                    var closed = false;
                    while (true) {
                        const inner = self.token_peek_n(off) orelse break;
                        if (inner.type == .Symbol and inner.data.cval == ']') {
                            off += 1; // skip ']'
                            closed = true;
                            break;
                        }
                        // Hitting a statement terminator before ']' means this is not a decl.
                        if (inner.type == .Symbol and inner.data.cval == ';') break;
                        off += 1;
                    }
                    if (!closed) break;
                }

                const t1 = self.token_peek_n(off);
                if (t1 != null and t1.?.type == .Identifier) {
                    const dt = self.transpile_proc.allocator.create(dtype.DataType) catch {
                        return ParseError.MemoryAllocationFailed;
                    };
                    // `dt` is arena-allocated and may be stored in the AST; do not destroy it on unwind.
                    dt.* = dtype.DataType{
                        .array = null,
                        .pointer_depth = 0,
                        .type = .Unknown,
                        .type_str = ArrayList(u8).init(self.transpile_proc.allocator),
                        .flags = .{},
                    };
                    try self.parse_datatype(dt);
                    try self.parse_variable(dt, hist, false, false);
                    try self.expect_sym(';');
                    return;
                }
            }
        }

        if (t.?.type == .Symbol and token.is_symbol(t, '{')) {
            return try self.parse_body(hist);
        }
        try self.parse_expressionable_root(hist);
        t = self.token_peek_next();
        if (t != null and t.?.type == .Symbol and t.?.data.cval != ';') {
            return try self.parse_symbol();
        }
        try self.expect_sym(';');
    }

    /// Parses multiple statements within a body.
    ///
    /// This function initializes a vector to hold statement nodes and creates a body node.
    /// It processes each statement within the body, handling nested history contexts, and
    /// ensures proper closure of the body with a closing brace. The resulting body node is added
    /// to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_body_multiple_statements(self: *Self, hist: *utils.History) ParseError!void {
        var stmts = utils.Vector(*ast.Node).init(self.transpile_proc.allocator);
        try self.make_body_node();
        var body_node = self.node_pop();
        // `make_body_node()` already created a binded context for this body (via `create_node`).
        // Do not overwrite `binded.owner` here; doing so can orphan the previous owner allocation.
        if (self.parser_current_body) |body| {
            const has_owner = body_node.?.binded != null and body_node.?.binded.?.owner != null;
            if (!has_owner) {
                const owner = self.transpile_proc.allocator.create(ast.Node) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                // Arena allocation; no per-allocation destroy on unwind.
                owner.* = body;
                // Binded nodes are only used for context; avoid copying ownership-bearing fields.
                owner.*.binded = null;
                owner.*.data = null;
                owner.*.node_variant = null;
                if (body_node.?.binded != null) {
                    body_node.?.binded.?.owner = owner;
                } else {
                    body_node.?.binded = self.transpile_proc.allocator.create(ast.BindedNode) catch {
                        return ParseError.MemoryAllocationFailed;
                    };
                    // Arena allocation; no per-allocation destroy on unwind.
                    body_node.?.binded.?.owner = owner;
                    body_node.?.binded.?.function = null;
                }
            }
        } else if (body_node.?.binded != null) {
            body_node.?.binded.?.owner = null;
        }
        self.parser_current_body = body_node.?;

        const lbrace_token = self.token_peek_next();
        try self.expect_sym('{');
        body_node.?.pos = if (lbrace_token) |t| t.pos else body_node.?.pos;
        var last_stmt_type: ?ast.NodeType = null;
        while (true) {
            const next_non_skippable = self.token_peek_n(0);
            if (next_non_skippable == null) {
                self.transpile_proc.err("unexpected end of file (expected '}}' to close body)", .{});
                return ParseError.FileReadError;
            }
            if (token.is_symbol(next_non_skippable, '}')) break;

            var hist_down = utils.History.down(self.transpile_proc.allocator, hist, hist.flags);
            defer hist_down.deinit();
            try self.parse_statement(&hist_down);
            const stmt_node = self.node_pop();
            if (stmt_node.?.type == .Function) {
                self.transpile_proc.err("invalid function statement", .{});
                return ParseError.InvalidStatement;
            }
            const stmt = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            // Arena allocation; no per-allocation destroy on unwind.
            stmt.* = stmt_node.?;
            if (stmt.type == .StatementElseIf) {
                if (last_stmt_type == null or (last_stmt_type != .StatementIf and last_stmt_type != .StatementElseIf)) {
                    self.transpile_proc.err("invalid 'elif' statement position", .{});
                    return ParseError.InvalidKeyword;
                }
            } else if (stmt.type == .StatementElse) {
                if (last_stmt_type == null or (last_stmt_type != .StatementIf and last_stmt_type != .StatementElseIf)) {
                    self.transpile_proc.err("invalid 'else' statement position", .{});
                    return ParseError.InvalidKeyword;
                }
            }
            // Warning controls are no-op directives and should not break `if/elif/else` chaining.
            if (stmt.type != .StatementWarningControl) {
                last_stmt_type = stmt.type;
            }
            stmts.push(stmt) catch {
                return ParseError.MemoryAllocationFailed;
            };
        }
        try self.expect_sym('}');
        if (body_node.?.binded != null) {
            if (body_node.?.binded.?.owner) |owner| {
                self.parser_current_body = owner.*;
            }
        }
        body_node.?.node_variant = .{ .body = .{ .statements = stmts } };
        self.transpile_proc.nodes.push(body_node.?) catch {
            return ParseError.MemoryAllocationFailed;
        };
    }

    /// Parses a body.
    ///
    /// This function parses multiple statements within a body by delegating to
    /// `parse_body_multiple_statements`.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    fn parse_body(self: *Self, hist: *utils.History) ParseError!void {
        _ = try self.transpile_proc.new_scope();
        try self.parse_body_multiple_statements(hist);
        self.transpile_proc.finish_scope();
    }

    /// Parses a symbol token.
    ///
    /// This function checks if the next token is the '{' symbol. If so, it pops the last
    /// node from the node stack and pushes it back. If the next token is not '{', it logs
    /// an error message indicating an invalid symbol.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails or if pushing the node fails.
    fn parse_symbol(self: *Self) ParseError!void {
        if (self.next_token_is_symbol('{')) {
            var hist = utils.History.init(self.transpile_proc.allocator, .{ .is_global_scope = true });
            try self.parse_body(&hist);
            const body_node = self.node_pop();
            self.transpile_proc.nodes.push(body_node.?) catch {
                return ParseError.MemoryAllocationFailed;
            };
            return;
        }
        self.transpile_proc.err("invalid symbol", .{});
        return ParseError.InvalidSymbol;
    }

    /// Checks if the next token is an operator.
    ///
    /// This function peeks at the next token and checks if it matches the specified
    /// operator. It returns `true` if the next token is the expected operator, `false` otherwise.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `op`: The operator as a byte slice.
    ///
    /// Returns:
    /// - `bool`: `true` if the next token is the expected operator, `false` otherwise.
    fn next_token_is_operator(self: *Self, op: []const u8) bool {
        const t = self.token_peek_next();
        return token.is_operator(t, op);
    }

    /// Checks if the next token is a keyword.
    ///
    /// This function peeks at the next token and checks if it matches the specified
    /// keyword. It returns `true` if the next token is the expected keyword, `false` otherwise.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `keyword`: The keyword as a byte slice.
    ///
    /// Returns:
    /// - `bool`: `true` if the next token is the expected keyword, `false` otherwise.
    fn next_token_is_keyword(self: *Self, keyword: []const u8) bool {
        const t = self.token_peek_next();
        return token.is_keyword(t, keyword);
    }

    /// Gets the pointer depth.
    ///
    /// This function checks the next tokens to determine the depth of pointers (`*`),
    /// incrementing the depth for each pointer token found. It returns the total pointer depth.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Returns:
    /// - `usize`: The total depth of pointers.
    fn parse_get_pointer_depth(self: *Self) usize {
        var depth: u8 = 0;
        while (self.next_token_is_operator("*")) {
            depth += 1;
            _ = self.token_next();
        }
        return depth;
    }

    fn skip_generic_args_tokens(self: *Self, off: *usize) bool {
        const first = self.token_peek_n(off.*) orelse return false;
        if (!(first.type == .Operator and mem.eql(u8, first.data.sval.items, "<"))) return false;

        var depth: isize = 0;
        while (true) {
            const tok = self.token_peek_n(off.*) orelse return false;
            if (tok.type == .Operator) {
                if (mem.eql(u8, tok.data.sval.items, "<")) {
                    depth += 1;
                    off.* += 1;
                    continue;
                }
                if (mem.eql(u8, tok.data.sval.items, ">")) {
                    depth -= 1;
                    off.* += 1;
                    if (depth == 0) break;
                    continue;
                }
                if (mem.eql(u8, tok.data.sval.items, ">>")) {
                    depth -= 2;
                    off.* += 1;
                    if (depth <= 0) break;
                    continue;
                }
            }
            off.* += 1;
        }
        return true;
    }

    fn split_angle_closer_token_if_needed(self: *Self) ParseError!void {
        const t = self.token_peek_next() orelse return;
        if (t.type != .Operator or !mem.eql(u8, t.data.sval.items, ">>")) return;

        const idx: usize = @intCast(self.transpile_proc.tokens.pindex);
        if (idx >= self.transpile_proc.tokens.data.items.len) return;

        var tok_ptr = &self.transpile_proc.tokens.data.items[idx];
        tok_ptr.data.sval.items.len = 0;
        tok_ptr.data.sval.append('>') catch return ParseError.MemoryAllocationFailed;

        var new_sval = ArrayList(u8).init(self.transpile_proc.allocator);
        errdefer new_sval.deinit();
        new_sval.append('>') catch return ParseError.MemoryAllocationFailed;

        const new_tok = token.Token{
            .type = .Operator,
            .data = .{ .sval = new_sval },
            .pos = tok_ptr.pos,
            .num = null,
            .whitespace = tok_ptr.whitespace,
            .between_brackets = null,
            .between_args = null,
        };
        self.transpile_proc.tokens.push_at(idx + 1, new_tok) catch return ParseError.MemoryAllocationFailed;
    }

    fn split_angle_opener_token_if_needed(self: *Self) ParseError!void {
        const t = self.token_peek_next() orelse return;
        if (t.type != .Operator or !mem.eql(u8, t.data.sval.items, "<<")) return;

        const idx: usize = @intCast(self.transpile_proc.tokens.pindex);
        if (idx >= self.transpile_proc.tokens.data.items.len) return;

        var tok_ptr = &self.transpile_proc.tokens.data.items[idx];
        tok_ptr.data.sval.items.len = 0;
        tok_ptr.data.sval.append('<') catch return ParseError.MemoryAllocationFailed;

        var new_sval = ArrayList(u8).init(self.transpile_proc.allocator);
        errdefer new_sval.deinit();
        new_sval.append('<') catch return ParseError.MemoryAllocationFailed;

        const new_tok = token.Token{
            .type = .Operator,
            .data = .{ .sval = new_sval },
            .pos = tok_ptr.pos,
            .num = null,
            .whitespace = tok_ptr.whitespace,
            .between_brackets = null,
            .between_args = null,
        };
        self.transpile_proc.tokens.push_at(idx + 1, new_tok) catch return ParseError.MemoryAllocationFailed;
    }

    fn impl_generic_args_are_params(self: *Self) bool {
        var off: usize = 0;
        const first = self.token_peek_n(off) orelse return false;
        if (!((first.type == .Operator and mem.eql(u8, first.data.sval.items, "<")) or (first.type == .Symbol and first.data.cval == '<'))) return false;
        off += 1;

        var saw_any = false;
        while (true) {
            const tok = self.token_peek_n(off) orelse return false;
            if (tok.type == .Identifier) {
                saw_any = true;
                off += 1;
            } else if (tok.type == .Keyword and utils.keyword_is_datatype(tok.data.sval.items)) {
                return false;
            } else {
                return false;
            }

            const next_tok = self.token_peek_n(off) orelse return false;

            // Handle constrained type param: T: num | dec
            if (next_tok.type == .Operator and next_tok.data.sval.items.len > 0 and next_tok.data.sval.items[0] == ':') {
                off += 1; // skip ':'
                while (true) {
                    const ct = self.token_peek_n(off) orelse return false;
                    if (ct.type == .Keyword or ct.type == .Identifier) {
                        off += 1;
                    } else {
                        return false;
                    }
                    const sep = self.token_peek_n(off) orelse return false;
                    if (sep.type == .Operator and mem.eql(u8, sep.data.sval.items, "|")) {
                        off += 1;
                        continue;
                    }
                    break;
                }
                const after = self.token_peek_n(off) orelse return false;
                if (after.type == .Operator and mem.eql(u8, after.data.sval.items, ",")) {
                    off += 1;
                    continue;
                }
                if (after.type == .Operator and (mem.eql(u8, after.data.sval.items, ">") or mem.eql(u8, after.data.sval.items, ">>"))) {
                    return saw_any;
                }
                if (after.type == .Symbol and after.data.cval == '>') {
                    return saw_any;
                }
                return false;
            }

            if (next_tok.type == .Operator and mem.eql(u8, next_tok.data.sval.items, ",")) {
                off += 1;
                continue;
            }
            if (next_tok.type == .Operator and (mem.eql(u8, next_tok.data.sval.items, ">") or mem.eql(u8, next_tok.data.sval.items, ">>"))) {
                return saw_any;
            }
            if (next_tok.type == .Symbol and next_tok.data.cval == '>') {
                return saw_any;
            }
            return false;
        }
    }

    fn next_token_is_angle_open(self: *Self) bool {
        const t = self.token_peek_next() orelse return false;
        return switch (t.type) {
            .Operator => t.data.sval.items.len > 0 and t.data.sval.items[0] == '<',
            .Symbol => t.data.cval == '<',
            else => false,
        };
    }

    fn parse_generic_type_params(self: *Self) ParseError!?utils.Vector(ArrayList(u8)) {
        try self.split_angle_opener_token_if_needed();
        if (!self.next_token_is_angle_open()) return null;
        _ = self.token_next();

        var params = utils.Vector(ArrayList(u8)).init(self.transpile_proc.allocator);
        errdefer {
            for (params.items()) |*p| p.deinit();
            params.deinit();
        }

        while (true) {
            const tok = self.token_next();
            if (tok == null or tok.?.type != .Identifier) {
                self.transpile_proc.err("expected generic parameter name", .{});
                return ParseError.InvalidIdentifier;
            }

            var name = ArrayList(u8).initCapacity(self.transpile_proc.allocator, tok.?.data.sval.items.len) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer name.deinit();
            name.appendSlice(tok.?.data.sval.items) catch {
                return ParseError.MemoryAllocationFailed;
            };

            params.push(name) catch {
                return ParseError.MemoryAllocationFailed;
            };

            if (self.next_token_is_operator(",")) {
                _ = self.token_next();
                continue;
            }
            break;
        }

        try self.split_angle_closer_token_if_needed();
        if (self.next_token_is_operator(">")) {
            try self.expect_op(">");
        } else {
            try self.expect_sym('>');
        }
        return params;
    }

    /// Result type for `parse_impl_type_params_with_constraints`.
    const ImplTypeParamResult = struct {
        params: ?utils.Vector(ArrayList(u8)),
        forced_insts: ?utils.Vector(utils.Vector(ArrayList(u8))),
    };

    /// Parse `<T>` or `<T: num | dec>` in an impl header.
    /// Returns param names and, when constraints are present, a list of forced
    /// concrete instantiations computed as the Cartesian product of all per-param
    /// constraint sets.  E.g. `<T: num | dec>` → forced_insts = [["num"], ["dec"]].
    fn parse_impl_type_params_with_constraints(self: *Self) ParseError!ImplTypeParamResult {
        try self.split_angle_opener_token_if_needed();
        if (!self.next_token_is_angle_open()) return .{ .params = null, .forced_insts = null };
        _ = self.token_next(); // consume '<'

        var params = utils.Vector(ArrayList(u8)).init(self.transpile_proc.allocator);
        errdefer {
            for (params.items()) |*p| p.deinit();
            params.deinit();
        }

        var has_constraints = false;
        // Per-param constraint lists (parallel to params).
        var param_constraints = ArrayList(utils.Vector(ArrayList(u8))).init(self.transpile_proc.allocator);
        errdefer {
            for (param_constraints.items) |*pc| {
                for (pc.items()) |*t| t.deinit();
                pc.deinit();
            }
            param_constraints.deinit();
        }

        while (true) {
            const tok = self.token_next();
            if (tok == null or tok.?.type != .Identifier) {
                self.transpile_proc.err("expected generic parameter name", .{});
                return ParseError.InvalidIdentifier;
            }

            var name = ArrayList(u8).initCapacity(self.transpile_proc.allocator, tok.?.data.sval.items.len) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer name.deinit();
            name.appendSlice(tok.?.data.sval.items) catch return ParseError.MemoryAllocationFailed;
            params.push(name) catch return ParseError.MemoryAllocationFailed;

            var constraints = utils.Vector(ArrayList(u8)).init(self.transpile_proc.allocator);
            errdefer {
                for (constraints.items()) |*t| t.deinit();
                constraints.deinit();
            }
            if (self.next_token_is_operator(":")) {
                _ = self.token_next(); // consume ':'
                has_constraints = true;
                while (true) {
                    const ct = self.token_next();
                    if (ct == null) {
                        self.transpile_proc.err("expected type name in constraint after ':'", .{});
                        return ParseError.InvalidIdentifier;
                    }
                    if (ct.?.type != .Keyword and ct.?.type != .Identifier) {
                        self.transpile_proc.err("expected type name in constraint", .{});
                        return ParseError.InvalidIdentifier;
                    }
                    var cname = ArrayList(u8).init(self.transpile_proc.allocator);
                    errdefer cname.deinit();
                    cname.appendSlice(ct.?.data.sval.items) catch return ParseError.MemoryAllocationFailed;
                    constraints.push(cname) catch return ParseError.MemoryAllocationFailed;
                    if (self.next_token_is_operator("|")) {
                        _ = self.token_next();
                        continue;
                    }
                    break;
                }
            }
            param_constraints.append(constraints) catch return ParseError.MemoryAllocationFailed;

            if (self.next_token_is_operator(",")) {
                _ = self.token_next();
                continue;
            }
            break;
        }

        try self.split_angle_closer_token_if_needed();
        if (self.next_token_is_operator(">")) {
            try self.expect_op(">");
        } else {
            try self.expect_sym('>');
        }

        var forced_insts: ?utils.Vector(utils.Vector(ArrayList(u8))) = null;
        if (has_constraints) {
            // Compute Cartesian product of per-param constraint lists.
            var combos = ArrayList(utils.Vector(ArrayList(u8))).init(self.transpile_proc.allocator);
            defer {
                // On success the items are moved into forced_insts; this deinit is for
                // the outer ArrayList wrapper only (items() are already consumed).
                combos.deinit();
            }
            // Seed with one empty combination.
            const initial = utils.Vector(ArrayList(u8)).init(self.transpile_proc.allocator);
            combos.append(initial) catch return ParseError.MemoryAllocationFailed;

            for (param_constraints.items) |pc| {
                var new_combos = ArrayList(utils.Vector(ArrayList(u8))).init(self.transpile_proc.allocator);
                errdefer {
                    for (new_combos.items) |*nc| {
                        for (nc.items()) |*t| t.deinit();
                        nc.deinit();
                    }
                    new_combos.deinit();
                }
                for (combos.items) |existing| {
                    for (pc.items()) |ct| {
                        var new_combo = utils.Vector(ArrayList(u8)).init(self.transpile_proc.allocator);
                        errdefer {
                            for (new_combo.items()) |*t| t.deinit();
                            new_combo.deinit();
                        }
                        for (existing.items()) |et| {
                            var et_copy = ArrayList(u8).init(self.transpile_proc.allocator);
                            et_copy.appendSlice(et.items) catch return ParseError.MemoryAllocationFailed;
                            new_combo.push(et_copy) catch return ParseError.MemoryAllocationFailed;
                        }
                        var ct_copy = ArrayList(u8).init(self.transpile_proc.allocator);
                        ct_copy.appendSlice(ct.items) catch return ParseError.MemoryAllocationFailed;
                        new_combo.push(ct_copy) catch return ParseError.MemoryAllocationFailed;
                        new_combos.append(new_combo) catch return ParseError.MemoryAllocationFailed;
                    }
                }
                // Free old combos (string contents were copied into new_combos).
                for (combos.items) |*c| c.deinit();
                combos.clearRetainingCapacity();
                for (new_combos.items) |nc| {
                    combos.append(nc) catch return ParseError.MemoryAllocationFailed;
                }
                new_combos.clearRetainingCapacity();
                new_combos.deinit();
            }

            var fi = utils.Vector(utils.Vector(ArrayList(u8))).init(self.transpile_proc.allocator);
            for (combos.items) |combo| {
                fi.push(combo) catch return ParseError.MemoryAllocationFailed;
            }
            // combos items moved into fi; clear so defer doesn't double-free.
            combos.clearRetainingCapacity();
            forced_insts = fi;
        }

        // Free param_constraints (string contents were copied into forced_insts combos).
        for (param_constraints.items) |*pc| {
            for (pc.items()) |*t| t.deinit();
            pc.deinit();
        }
        param_constraints.deinit();

        return .{ .params = params, .forced_insts = forced_insts };
    }

    fn parse_generic_type_args(self: *Self, dt: *dtype.DataType) ParseError!void {
        try self.split_angle_opener_token_if_needed();
        if (!self.next_token_is_angle_open()) return;
        _ = self.token_next();

        var args = utils.Vector(*dtype.DataType).init(self.transpile_proc.allocator);
        errdefer {
            for (args.items()) |a| {
                a.type_str.deinit();
                if (a.array) |array| {
                    if (!array.brackets.is_empty()) {
                        for (array.brackets.items()) |bracket| self.transpile_proc.deinit_node(bracket);
                    }
                    array.brackets.deinit();
                }
                if (a.generic_args) |*gargs| {
                    for (gargs.items()) |ga| {
                        ga.type_str.deinit();
                        if (ga.array) |array| {
                            if (!array.brackets.is_empty()) {
                                for (array.brackets.items()) |bracket| self.transpile_proc.deinit_node(bracket);
                            }
                            array.brackets.deinit();
                        }
                        self.transpile_proc.allocator.destroy(ga);
                    }
                    gargs.deinit();
                }
                self.transpile_proc.allocator.destroy(a);
            }
            args.deinit();
        }

        while (true) {
            const adt = self.transpile_proc.allocator.create(dtype.DataType) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(adt);
            adt.* = dtype.DataType{
                .array = null,
                .pointer_depth = 0,
                .type = .Unknown,
                .type_str = ArrayList(u8).init(self.transpile_proc.allocator),
                .flags = .{},
                .generic_args = null,
            };

            var hist_tmp = utils.History.init(self.transpile_proc.allocator, .{});
            defer hist_tmp.deinit();
            try self.parse_datatype(adt);
            if (self.next_token_is_operator("[")) {
                try self.parse_array_brackets(adt, &hist_tmp);
            }

            args.push(adt) catch {
                return ParseError.MemoryAllocationFailed;
            };

            if (self.next_token_is_operator(",")) {
                _ = self.token_next();
                continue;
            }
            break;
        }

        try self.split_angle_closer_token_if_needed();
        if (self.next_token_is_operator(">")) {
            try self.expect_op(">");
        } else {
            try self.expect_sym('>');
        }
        dt.generic_args = args;
    }

    fn append_mangled_dtype_name(self: *Self, buf: *ArrayList(u8), dt: *const dtype.DataType) ParseError!void {
        buf.appendSlice(dt.type_str.items) catch return ParseError.MemoryAllocationFailed;
        if (dt.generic_args) |gargs| {
            for (gargs.items()) |ga| {
                buf.appendSlice("__") catch return ParseError.MemoryAllocationFailed;
                try self.append_mangled_dtype_name(buf, ga);
            }
        }
    }

    /// Parses a datatype.
    ///
    /// This function expects a datatype keyword and retrieves its pointer depth,
    /// type, and type string. If the datatype is unknown, it logs an error message.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `dt`: A pointer to the datatype being parsed.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    /// - Logs an error message if the next token is not a datatype keyword.
    fn parse_datatype(self: *Self, dt: *dtype.DataType) ParseError!void {
        const dt_token = self.token_next();
        if (dt_token == null or (dt_token.?.type != .Keyword and dt_token.?.type != .Identifier)) {
            self.transpile_proc.err("expected datatype, got '{s}'", .{if (dt_token) |t| @tagName(t.type) else "null"});
            return ParseError.InvalidDataType;
        }
        // Builtins use `dt.type`, user-defined types keep `.Unknown` and rely on `type_str`.
        if (dt_token.?.type == .Keyword and utils.keyword_is_datatype(dt_token.?.data.sval.items)) {
            dt.*.type = utils.get_datatype_type(dt_token.?.data.sval.items);
            if (dt.*.type.? == .Unknown) {
                self.transpile_proc.err("unknown datatype", .{});
                return ParseError.InvalidDataType;
            }
        } else {
            // Identifier-based types (e.g. C typedefs like `size_t`) are allowed.
            // For a small set of common C typedef names, tag them with a numeric
            // semantic type so arithmetic/comparisons typecheck, while still
            // emitting the original identifier in C via `type_str`.
            if (dt_token.?.type == .Identifier) {
                const ident_type = utils.get_datatype_type(dt_token.?.data.sval.items);
                if (ident_type != .Unknown) {
                    dt.*.type = ident_type;
                } else {
                    dt.*.type = utils.get_c_typedef_alias_datatype_type(dt_token.?.data.sval.items) orelse .Unknown;
                }
            } else {
                dt.*.type = .Unknown;
            }
        }
        dt.*.type_str = ArrayList(u8).initCapacity(self.transpile_proc.allocator, dt_token.?.data.sval.items.len) catch {
            return ParseError.MemoryAllocationFailed;
        };
        dt.*.type_str.appendSlice(dt_token.?.data.sval.items) catch {
            return ParseError.MemoryAllocationFailed;
        };

        // Qualified user-defined types via module alias (e.g. `imp mod as m; m.Type`).
        // Internally we mangle `a.b` as `a__b` to match symbol/type naming.
        if (dt_token.?.type == .Identifier) {
            while (self.next_token_is_operator(".") or self.next_token_is_symbol('.')) {
                _ = self.token_next(); // consume '.'

                const seg_tok = self.token_next();
                if (seg_tok == null or seg_tok.?.type != .Identifier) {
                    self.transpile_proc.err("expected identifier after '.' in qualified datatype", .{});
                    return ParseError.InvalidDataType;
                }

                dt.*.type = .Unknown;
                dt.*.type_str.appendSlice("__") catch {
                    return ParseError.MemoryAllocationFailed;
                };
                dt.*.type_str.appendSlice(seg_tok.?.data.sval.items) catch {
                    return ParseError.MemoryAllocationFailed;
                };
            }
        }

        try self.parse_generic_type_args(dt);

        const ptr_depth = self.parse_get_pointer_depth();
        if (ptr_depth > 0) {
            var flags = dt.*.flags orelse dtype.DataTypeFlags{};
            flags.is_pointer = true;
            dt.*.flags = flags;
            dt.*.pointer_depth = ptr_depth;
        }
    }

    /// Parses a single token to a node.
    ///
    /// This function processes a single token, such as a number, identifier, string,
    /// or boolean, and converts it to the corresponding AST node. If the token is not
    /// of an expected type, it logs an error message.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Returns:
    /// - `bool`: `true` if a single token was successfully parsed, `false` otherwise.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    /// - Logs an error message if the next token is not of an expected type.
    fn parse_single_token_to_node(self: *Self) ParseError!bool {
        const t = self.token_next();
        if (t == null) {
            self.transpile_proc.err("expected token, got eof", .{});
            return ParseError.InvalidToken;
        }
        switch (t.?.type) {
            .Number => {
                switch (t.?.data) {
                    .llnum => |n| {
                        var number_node = ast.Node{
                            .type = .Number,
                            .pos = t.?.pos,
                            .data = .{ .llnum = n },
                        };
                        try self.create_node(&number_node);
                    },
                    .dnum => |n| {
                        var number_node = ast.Node{
                            .type = .Number,
                            .pos = t.?.pos,
                            .data = .{ .dnum = n },
                        };
                        try self.create_node(&number_node);
                    },
                    .cval => |c| {
                        var char_node = ast.Node{
                            .type = .Character,
                            .pos = t.?.pos,
                            .data = .{ .cval = c },
                        };
                        try self.create_node(&char_node);
                    },
                    else => {
                        self.transpile_proc.err("invalid number token", .{});
                        return ParseError.InvalidToken;
                    },
                }
            },
            .Identifier => {
                const prev = self.token_peek_prev();
                const is_member_access = prev != null and prev.?.type == .Operator and mem.eql(u8, prev.?.data.sval.items, ".");

                // Allow type operands inside `sizeof(Type)` even if the identifier isn't declared
                // as a value symbol yet (supports forward-declared custom types).
                const is_sizeof_type_operand = blk: {
                    if (prev == null) break :blk false;
                    if (prev.?.type != .Operator or !mem.eql(u8, prev.?.data.sval.items, "(")) break :blk false;
                    const prev2 = self.token_peek_prev_n(1) orelse break :blk false;
                    if (prev2.type != .Identifier) break :blk false;
                    break :blk mem.eql(u8, prev2.data.sval.items, "sizeof");
                };

                const is_c_macro_ident = struct {
                    fn ok(name: []const u8) bool {
                        if (name.len == 0) return false;
                        const first = name[0];
                        if (!((first >= 'A' and first <= 'Z') or first == '_')) return false;
                        for (name) |c| {
                            const is_upper = (c >= 'A' and c <= 'Z');
                            const is_digit = (c >= '0' and c <= '9');
                            if (!(is_upper or is_digit or c == '_')) return false;
                        }
                        return true;
                    }
                }.ok(t.?.data.sval.items);

                // `_` is a wildcard identifier (used by `fit` default branches).
                // It should be accepted even if it's not declared.
                if (!mem.eql(u8, t.?.data.sval.items, "_")) {
                    if (!is_member_access) {
                        if (!is_sizeof_type_operand and self.transpile_proc.get_scope_entity(t.?.data.sval.items) == null) {
                            if (self.transpile_proc.get_symbol(t.?.data.sval.items) == null and self.transpile_proc.global_symbols.get(t.?.data.sval.items) == null) {
                                // Treat ALL_CAPS identifiers as C macro-style constants.
                                if (!is_c_macro_ident) {
                                    // Allow out-of-order function calls: if an unknown identifier is
                                    // immediately called (`foo(...)`), accept it and defer validation
                                    // to later passes / C compilation.
                                    const is_possible_enum_member_access = self.next_token_is_operator(".");
                                    if (!self.next_token_is_operator("(") and !is_possible_enum_member_access and !self.in_fit_condition) {
                                        self.transpile_proc.err("unknown identifier '{s}'", .{t.?.data.sval.items});
                                        return ParseError.InvalidIdentifier;
                                    }
                                }
                            }
                        }
                    }
                }
                var ident_node = ast.Node{
                    .type = .Identifier,
                    .pos = t.?.pos,
                    .data = .{ .sval = t.?.data.sval },
                };
                try self.create_node(&ident_node);
            },
            .String => {
                var str_node = ast.Node{
                    .type = .String,
                    .pos = t.?.pos,
                    .data = .{ .sval = t.?.data.sval },
                };
                try self.create_node(&str_node);
            },
            .Boolean => {
                var bool_node = ast.Node{
                    .type = .Boolean,
                    .pos = t.?.pos,
                    .data = .{ .bval = t.?.data.bval },
                };
                try self.create_node(&bool_node);
            },
            else => {
                self.transpile_proc.err("expected single token, got '{s}'", .{@tagName(t.?.type)});
                return ParseError.InvalidToken;
            },
        }
        return true;
    }

    /// Parses additional expressions.
    ///
    /// This function checks if the next token is an operator and, if so,
    /// processes it as part of an additional expression.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    fn parse_additional_expression(self: *Self, parent_flags: ?utils.HistoryFlags) ParseError!void {
        const t = self.token_peek_next();
        if (t.?.type == .Operator) {
            // Respect an enclosing `stop_at_comma` (e.g. a compound-initializer
            // field value `name = &x,`): a top-level comma terminates this value
            // and must not be consumed as a binary comma expression.
            const stop_comma = if (parent_flags) |pf| pf.stop_at_comma else false;
            if (stop_comma and mem.eql(u8, t.?.data.sval.items, ",")) return;
            // Respect an enclosing `stop_at_binary_op` (the `await <call>` operand):
            // a following infix operator ends the operand instead of extending it,
            // so `await f(x) + 1` becomes `(await f(x)) + 1`.
            const stop_binary = if (parent_flags) |pf| pf.stop_at_binary_op else false;
            if (stop_binary and utils.is_binary_only_operator(t.?)) return;
            var flags: utils.HistoryFlags = .{};
            if (stop_comma) flags.stop_at_comma = true;
            var hist = utils.History.init(self.transpile_proc.allocator, flags);
            defer hist.deinit();
            try self.parse_expressionable(&hist);
        }
    }

    /// Parses a parenthesis expression.
    ///
    /// This function expects a parenthesis expression, including handling
    /// of left nodes, expressionable roots, and proper closing of the parenthesis.
    /// It adds the resulting parenthesis expression node to the list of nodes
    /// to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_for_parenthesis(self: *Self, hist: *utils.History) ParseError!void {
        const lparen_token = self.token_peek_next();
        try self.expect_op("(");
        var left_node: ?ast.Node = null;
        const tmp_node = self.transpile_proc.nodes.back();
        if (tmp_node != null and ast.node_is_value_type(tmp_node.?)) {
            left_node = tmp_node;
            _ = self.node_pop();
        }
        var exp_node = ast.Node{ .type = .Blank };
        if (!self.next_token_is_symbol(')')) {
            var hist_inner = utils.History.down(self.transpile_proc.allocator, hist, hist.flags);
            defer hist_inner.deinit();
            hist_inner.flags.expression_is_unary = false;
            // A parenthesized sub-expression is a fresh context: operators inside it
            // are not bounded by an enclosing `await <call>` operand. Clear the flag
            // so e.g. `await (*p).f()` parses the full `(*p)` group.
            hist_inner.flags.stop_at_binary_op = false;
            // Likewise, commas INSIDE `(...)` separate call arguments / grouping — they
            // are not the enclosing context's terminator. Clear any inherited
            // `stop_at_comma` (e.g. from a parameter default `= snprintf(a, b, c)` or a
            // compound-init field value) so nested call args parse fully instead of
            // stopping at the first inner comma. Mirrors the `[...]` element handling.
            hist_inner.flags.stop_at_comma = false;
            try self.parse_expressionable_root(&hist_inner);
            exp_node = self.node_pop().?;
        }
        try self.expect_sym(')');
        const exp = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(exp);
        exp.* = exp_node;
        self.transpile_proc.nodes.push(ast.Node{
            .type = .ExpressionParenthesis,
            .pos = if (lparen_token) |t| t.pos else null,
            .node_variant = .{ .paren = .{ .exp = exp } },
        }) catch {
            return ParseError.MemoryAllocationFailed;
        };
        if (left_node != null) {
            const parenthesis_node = self.node_pop();
            const left = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(left);
            left.* = left_node.?;
            const right = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(right);
            right.* = parenthesis_node.?;
            self.transpile_proc.nodes.push(ast.Node{
                .type = .Expression,
                .pos = if (lparen_token) |t| t.pos else left.*.pos,
                .node_variant = .{
                    .exp = .{
                        .left = left,
                        .right = right,
                        .op = "()",
                    },
                },
            }) catch {
                return ParseError.MemoryAllocationFailed;
            };
        }
        try self.parse_additional_expression(hist.flags);
    }

    /// Parses a comma-separated expression.
    ///
    /// This function processes a comma-separated expression, creating and adding
    /// the resulting expression node to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    fn parse_for_comma(self: *Self, hist: *utils.History) ParseError!void {
        const comma_token = self.token_peek_next();
        _ = self.token_next(); // skip ,
        const left_node = self.node_pop();
        try self.parse_expressionable_root(hist);
        const right_node = self.node_pop();
        const left = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(left);
        left.* = left_node.?;
        const right = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(right);
        right.* = right_node.?;
        self.transpile_proc.nodes.push(ast.Node{
            .type = .Expression,
            .pos = if (comma_token) |t| t.pos else left.*.pos,
            .node_variant = .{
                .exp = .{
                    .left = left,
                    .right = right,
                    .op = ",",
                },
            },
        }) catch {
            return ParseError.MemoryAllocationFailed;
        };
    }

    /// Parses a bracket expression.
    ///
    /// This function expects a bracket expression, including handling of left nodes,
    /// expressionable roots, and proper closing of the bracket. It adds the resulting
    /// bracket expression node to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_for_bracket(self: *Self, hist: *utils.History) ParseError!void {
        // Only treat `[...]` as an indexing operation when there's a valid expressionable left operand.
        // Otherwise it's an array literal.
        const left_node = self.node_peek_expressionable_or_null();
        if (left_node != null) {
            _ = self.node_pop();
        }

        const lbracket_token = self.token_peek_next();
        try self.expect_op("[");
        // Inside `[...]`, commas separate array ELEMENTS — they are not the
        // enclosing context's terminator. Clear any inherited `stop_at_comma`
        // (set by e.g. a compound-initializer field value `Row{cols = [1, 2, 3]}`)
        // so a multi-element array literal parses instead of stopping at the first
        // comma with a bogus "expected ']'".
        var bracket_hist = utils.History.down(self.transpile_proc.allocator, hist, hist.flags);
        defer bracket_hist.deinit();
        bracket_hist.flags.stop_at_comma = false;
        try self.parse_expressionable_root(&bracket_hist);
        try self.expect_sym(']');
        const exp_node = self.node_pop();
        const inner = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(inner);
        inner.* = exp_node.?;
        self.transpile_proc.nodes.push(ast.Node{
            .type = .Bracket,
            .pos = if (lbracket_token) |t| t.pos else null,
            .node_variant = .{ .bracket = .{ .inner = inner } },
        }) catch {
            return ParseError.MemoryAllocationFailed;
        };
        if (left_node != null) {
            const bracket_node = self.node_pop();
            const left = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(left);
            left.* = left_node.?;
            const right = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(right);
            right.* = bracket_node.?;
            self.transpile_proc.nodes.push(ast.Node{
                .type = .Expression,
                .pos = if (lbracket_token) |t| t.pos else left.*.pos,
                .node_variant = .{
                    .exp = .{
                        .left = left,
                        .right = right,
                        .op = "[]",
                    },
                },
            }) catch {
                return ParseError.MemoryAllocationFailed;
            };
        }
    }

    fn parse_compound_init(self: *Self, dt: ?*dtype.DataType, hist: *utils.History, pos: ?token.Pos) ParseError!void {
        const lbrace_tok = self.token_peek_next();
        try self.expect_sym('{');

        const deinit_dtype = struct {
            fn call(allocator: mem.Allocator, dtype_ptr: *dtype.DataType) void {
                dtype_ptr.type_str.deinit();
                if (dtype_ptr.generic_args) |*gargs| {
                    for (gargs.items()) |ga| {
                        ga.type_str.deinit();
                        if (ga.array) |array| {
                            if (!array.brackets.is_empty()) {
                                for (array.brackets.items()) |bracket| {
                                    _ = bracket;
                                }
                            }
                            array.brackets.deinit();
                        }
                        allocator.destroy(ga);
                    }
                    gargs.deinit();
                }
                if (dtype_ptr.array) |array| {
                    if (!array.brackets.is_empty()) {
                        for (array.brackets.items()) |bracket| {
                            _ = bracket;
                        }
                    }
                    array.brackets.deinit();
                }
                allocator.destroy(dtype_ptr);
            }
        }.call;

        var fields = utils.Vector(ast.CompoundInitField).init(self.transpile_proc.allocator);
        errdefer {
            for (fields.items()) |f| {
                f.name.deinit();
                self.transpile_proc.deinit_node(f.value.*);
                self.transpile_proc.allocator.destroy(f.value);
            }
            fields.deinit();
            if (dt) |dtype_ptr| {
                deinit_dtype(self.transpile_proc.allocator, dtype_ptr);
            }
        }

        while (!self.next_token_is_symbol('}')) {
            const field_tok = self.token_next();
            if (field_tok == null or field_tok.?.type != .Identifier) {
                self.transpile_proc.err("expected field name in compound initializer", .{});
                return ParseError.InvalidIdentifier;
            }

            var fname = ArrayList(u8).initCapacity(self.transpile_proc.allocator, field_tok.?.data.sval.items.len) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer fname.deinit();
            fname.appendSlice(field_tok.?.data.sval.items) catch {
                return ParseError.MemoryAllocationFailed;
            };

            try self.expect_op("=");

            var hist_down = utils.History.down(self.transpile_proc.allocator, hist, hist.flags);
            hist_down.flags.stop_at_comma = true;
            try self.parse_expressionable_root(&hist_down);
            const value_node = self.node_pop();
            const value_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(value_ptr);
            value_ptr.* = value_node.?;

            fields.push(.{ .name = fname, .value = value_ptr }) catch {
                return ParseError.MemoryAllocationFailed;
            };

            if (self.next_token_is_operator(",")) {
                _ = self.token_next();
                if (self.next_token_is_symbol('}')) break;
                continue;
            }
            break;
        }

        try self.expect_sym('}');

        const init_node = ast.Node{
            .type = .CompoundInit,
            .pos = if (lbrace_tok) |t| t.pos else pos,
            .node_variant = .{ .compound_init = .{ .dtype = dt, .fields = fields } },
        };
        self.transpile_proc.nodes.push(init_node) catch {
            return ParseError.MemoryAllocationFailed;
        };
    }

    /// Peeks at the expressionable node on top of the stack.
    ///
    /// This function returns the node on top of the stack if it is expressionable,
    /// or `null` otherwise.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Returns:
    /// - `?ast.Node`: The expressionable node on top of the stack, or `null` if not found.
    fn node_peek_expressionable_or_null(self: *Self) ?ast.Node {
        const n = self.transpile_proc.nodes.back();
        return if (n != null and ast.node_is_expressionable(n.?)) n.? else null;
    }

    /// Parses an indirection unary expression.
    ///
    /// This function processes an indirection unary expression by retrieving the
    /// pointer depth and creating the corresponding unary node with the operand.
    /// It adds the resulting unary node to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_for_indirection_unary(self: *Self) ParseError!void {
        const star_token = self.token_peek_next();
        const depth = self.parse_get_pointer_depth();
        var hist = utils.History.init(self.transpile_proc.allocator, .{ .expression_is_unary = true });
        defer hist.deinit();
        try self.parse_expressionable(&hist);
        const unary_operand_node = self.node_pop() orelse {
            self.transpile_proc.err("expected operand for pointer indirection", .{});
            return ParseError.InvalidOperand;
        };
        const operand = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(operand);
        operand.* = unary_operand_node;
        self.transpile_proc.nodes.push(ast.Node{
            .type = .Unary,
            .pos = if (star_token) |t| t.pos else operand.*.pos,
            .node_variant = .{
                .unary = .{
                    .op = "*",
                    .operand = operand,
                },
            },
        }) catch {
            return ParseError.MemoryAllocationFailed;
        };
        var unary_node = self.node_pop();
        unary_node.?.node_variant.?.unary.indirection = .{ .depth = depth };
        self.transpile_proc.nodes.push(unary_node.?) catch {
            return ParseError.MemoryAllocationFailed;
        };
    }

    /// Parses a normal unary expression.
    ///
    /// This function processes a normal unary expression, creating the corresponding
    /// unary node with the operand and adding it to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_for_normal_unary(self: *Self, parent_flags: ?utils.HistoryFlags) ParseError!void {
        const unary_tok = self.token_next();
        const unary_op = unary_tok.?.data.sval.items;
        // Carry `stop_at_comma` from the enclosing context (e.g. a compound
        // initializer field `name = &x,`) so the unary operand parse does not
        // greedily consume past the comma into the next field.
        var flags: utils.HistoryFlags = .{ .expression_is_unary = true };
        if (parent_flags) |pf| {
            if (pf.stop_at_comma) flags.stop_at_comma = true;
        }
        var hist = utils.History.init(self.transpile_proc.allocator, flags);
        defer hist.deinit();
        try self.parse_expressionable(&hist);
        const unary_operand_node = self.node_pop() orelse {
            // The operand parse produced no node. Emit a clean diagnostic instead
            // of panicking on the null unwrap (e.g. on certain stacked unaries).
            self.transpile_proc.err("expected operand for unary operator '{s}'", .{unary_op});
            return ParseError.InvalidOperand;
        };
        const operand = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(operand);
        operand.* = unary_operand_node;
        self.transpile_proc.nodes.push(ast.Node{
            .type = .Unary,
            .pos = unary_tok.?.pos,
            .node_variant = .{
                .unary = .{
                    .op = unary_op,
                    .operand = operand,
                },
            },
        }) catch {
            return ParseError.MemoryAllocationFailed;
        };
    }

    /// Parses a unary expression.
    ///
    /// This function processes a unary expression, determining if it is an indirection
    /// or normal unary expression, and then parsing it accordingly. It also handles
    /// additional expressions if present.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_for_unary(self: *Self, parent_flags: ?utils.HistoryFlags) ParseError!void {
        const t = self.token_peek_next();
        const unary_op = t.?.data.sval.items;
        if (utils.is_indirection_operator(unary_op)) {
            try self.parse_for_indirection_unary();
            return;
        }
        try self.parse_for_normal_unary(parent_flags);
        try self.parse_additional_expression(parent_flags);
    }

    /// Parses a left-operanded unary expression.
    ///
    /// This function processes a left-operanded unary expression, creating the
    /// corresponding unary node with the left operand and operator, and adding
    /// it to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `node_left`: A pointer to the left operand node.
    /// - `unary_op`: The unary operator as a byte slice.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    fn parse_for_left_operanded_unary(self: *Self, node_left: *ast.Node, unary_op: []const u8, op_pos: ?token.Pos) ParseError!void {
        self.transpile_proc.nodes.push(ast.Node{
            .type = .Unary,
            .pos = op_pos orelse node_left.*.pos,
            .node_variant = .{
                .unary = .{
                    .op = unary_op,
                    .operand = node_left,
                    .is_left_operanded_unary = true,
                },
            },
        }) catch {
            return ParseError.MemoryAllocationFailed;
        };
    }

    /// Creates an expression node.
    ///
    /// This function creates an expression node with the given left and right nodes
    /// and the specified operator. It then adds the expression node to the list of
    /// nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `left_node`: A pointer to the left node of the expression.
    /// - `right_node`: A pointer to the right node of the expression.
    /// - `op`: The operator as a byte slice.
    ///
    /// Errors:
    /// - Returns an error if creating the node fails.
    fn make_expression_node(self: *Self, left_node: *ast.Node, right_node: *ast.Node, op: []const u8, op_pos: ?token.Pos) ParseError!void {
        const exp_node = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        defer self.transpile_proc.allocator.destroy(exp_node);
        const left = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(left);
        left.* = left_node.*;
        const right = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(right);
        right.* = right_node.*;
        exp_node.* = ast.Node{
            .type = .Expression,
            .pos = op_pos orelse left.*.pos orelse right.*.pos,
            .node_variant = .{
                .exp = .{
                    .left = left,
                    .right = right,
                    .op = op,
                },
            },
        };
        try self.create_node(exp_node);
    }

    /// Desugar a channel operator into a method call and PUSH the resulting node:
    /// `ch <- v` -> `ch.send(v)`, `<-ch` -> `ch.recv()`. Builds two nested
    /// `Expression` nodes — a `.` member-access (`recv.method`) and a `()` call —
    /// so the rest of the pipeline (typecheck + codegen) sees only an ordinary
    /// method call. `arg` is the send value, or null for a zero-arg recv.
    fn push_channel_method_call(self: *Self, recv: *ast.Node, method_name: []const u8, arg: ?*ast.Node, op_pos: ?token.Pos) ParseError!void {
        const alloc = self.transpile_proc.allocator;

        // Method-name identifier node.
        const method_ident = alloc.create(ast.Node) catch return ParseError.MemoryAllocationFailed;
        var name_buf = ArrayList(u8).init(alloc);
        name_buf.appendSlice(method_name) catch return ParseError.MemoryAllocationFailed;
        method_ident.* = ast.Node{
            .type = .Identifier,
            .pos = op_pos,
            .data = .{ .sval = name_buf },
        };
        method_ident.flags = .{ .inside_expression = true };

        const recv_copy = alloc.create(ast.Node) catch return ParseError.MemoryAllocationFailed;
        recv_copy.* = recv.*;

        // `recv . method`
        const dot = alloc.create(ast.Node) catch return ParseError.MemoryAllocationFailed;
        dot.* = ast.Node{
            .type = .Expression,
            .pos = op_pos orelse recv.*.pos,
            .node_variant = .{ .exp = .{ .left = recv_copy, .right = method_ident, .op = "." } },
        };
        dot.flags = .{ .inside_expression = true };

        // Call argument: the send value, or a Blank (zero-arg) for recv.
        const call_arg = alloc.create(ast.Node) catch return ParseError.MemoryAllocationFailed;
        if (arg) |a| {
            call_arg.* = a.*;
        } else {
            call_arg.* = ast.Node{ .type = .Blank, .pos = op_pos };
        }

        // `(recv.method)(arg)`
        const call = alloc.create(ast.Node) catch return ParseError.MemoryAllocationFailed;
        defer alloc.destroy(call);
        call.* = ast.Node{
            .type = .Expression,
            .pos = op_pos orelse recv.*.pos,
            .node_variant = .{ .exp = .{ .left = dot, .right = call_arg, .op = "()" } },
        };
        try self.create_node(call);
    }

    /// Creates a body node.
    ///
    /// This function creates a body node with the given statements and adds it
    /// to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Errors:
    /// - Returns an error if creating the node fails.
    fn make_body_node(self: *Self) ParseError!void {
        const body_node = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(body_node);
        defer self.transpile_proc.allocator.destroy(body_node);
        body_node.* = ast.Node{
            .type = .Body,
            .pos = null,
        };
        try self.create_node(body_node);
    }

    /// Gets the precedence for an operator.
    ///
    /// This function iterates through the operator precedence groups to find
    /// the precedence level of the given operator. It also sets the provided group
    /// pointer to the matching group.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `op`: The operator as a byte slice.
    /// - `group`: A pointer to the optional precedence group.
    ///
    /// Returns:
    /// - `i8`: The precedence level of the operator, or -1 if not found.
    fn parse_get_precedence_for_operator(_: *Self, op: []const u8, group: *?expressionable.OpPrecedenceGroup) i8 {
        for (0..expressionable.TOTAL_OPERATOR_GROUPS) |i| {
            var j: u8 = 0;
            while (expressionable.op_precedence[i].operators[j] != null) {
                const _op = expressionable.op_precedence[i].operators[j];
                if (mem.eql(u8, _op.?, op)) {
                    group.* = expressionable.op_precedence[i];
                    return @intCast(i);
                }
                j += 1;
            }
        }
        return -1;
    }

    /// Checks if the left operator has priority over the right operator.
    ///
    /// This function determines if the left operator has higher or equal precedence
    /// compared to the right operator, taking into account associativity.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `op_left`: The left operator as a byte slice.
    /// - `op_right`: The right operator as a byte slice.
    ///
    /// Returns:
    /// - `bool`: `true` if the left operator has priority, `false` otherwise.
    fn parse_left_has_priority(self: *Self, op_left: []const u8, op_right: []const u8) bool {
        var left_group: ?expressionable.OpPrecedenceGroup = null;
        var right_group: ?expressionable.OpPrecedenceGroup = null;
        const left_prec = self.parse_get_precedence_for_operator(op_left, &left_group);
        const right_prec = self.parse_get_precedence_for_operator(op_right, &right_group);

        // If operators are the same, associativity decides.
        if (mem.eql(u8, op_left, op_right)) {
            return left_group.?.associativity == .LeftToRight;
        }
        if (left_group.?.associativity == .RightToLeft) {
            return false;
        }
        return left_prec <= right_prec;
    }

    /// Shifts the children of an expression node to the left.
    ///
    /// This function rearranges the children of the given expression node,
    /// shifting them to the left to maintain proper precedence order.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `node`: A pointer to the expression node.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    fn parse_node_shift_children_left(self: *Self, node: *ast.Node) ParseError!void {
        const exp = &node.*.node_variant.?.exp;
        const right_expr_ptr = exp.right orelse return;
        if (right_expr_ptr.*.type != .Expression) return;

        const right_exp = &right_expr_ptr.*.node_variant.?.exp;
        const op2 = right_exp.op;

        const a_ptr = exp.left orelse return;
        const b_ptr = right_exp.left orelse return;
        const c_ptr = right_exp.right orelse return;

        const new_left_expr = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(new_left_expr);
        new_left_expr.* = ast.Node{
            .type = .Expression,
            .pos = node.*.pos,
            .binded = null,
            .node_variant = .{
                .exp = .{
                    .left = a_ptr,
                    .right = b_ptr,
                    .op = exp.op,
                },
            },
        };

        // Rewrite: ((a op1 b) op2 c)
        exp.left = new_left_expr;
        exp.right = c_ptr;
        exp.op = op2;

        // Destroy the old right-expression container, without freeing moved children.
        right_exp.left = null;
        right_exp.right = null;
        self.transpile_proc.deinit_node(right_expr_ptr.*);
        self.transpile_proc.allocator.destroy(right_expr_ptr);
    }

    /// Moves the right-left child of an expression node to the left.
    ///
    /// This function rearranges the children of the given expression node,
    /// moving the right-left child to the left to maintain proper precedence order.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `node`: A pointer to the expression node.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    fn parse_node_move_right_left_to_left(self: *Self, node: *ast.Node) ParseError!void {
        const exp = &node.*.node_variant.?.exp;
        const right_expr_ptr = exp.right orelse return;
        if (right_expr_ptr.*.type != .Expression) return;

        const right_exp = &right_expr_ptr.*.node_variant.?.exp;
        const op2 = right_exp.op;

        const a_ptr = exp.left orelse return;
        const b_ptr = right_exp.left orelse return;
        const c_ptr = right_exp.right orelse return;

        const completed = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(completed);
        completed.* = ast.Node{
            .type = .Expression,
            .pos = node.*.pos,
            .binded = null,
            .node_variant = .{
                .exp = .{
                    .left = a_ptr,
                    .right = b_ptr,
                    .op = exp.op,
                },
            },
        };

        exp.left = completed;
        exp.right = c_ptr;
        exp.op = op2;

        right_exp.left = null;
        right_exp.right = null;
        self.transpile_proc.deinit_node(right_expr_ptr.*);
        self.transpile_proc.allocator.destroy(right_expr_ptr);
    }

    /// Reorders an expression node for proper precedence.
    ///
    /// This function recursively reorders the children of the given expression node
    /// to maintain proper operator precedence.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `node`: A pointer to the expression node.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    fn parse_reorder_expression(self: *Self, node: *ast.Node) ParseError!void {
        if (node.*.type != .Expression) {
            return;
        }
        if (node.*.node_variant != null and node.*.node_variant.?.exp.left.?.*.type != .Expression and node.*.node_variant.?.exp.right != null and
            node.*.node_variant.?.exp.right.?.*.type != .Expression)
        {
            return;
        }
        if (node.*.node_variant != null and node.*.node_variant.?.exp.right != null and
            node.*.node_variant.?.exp.right.?.*.type == .Expression)
        {
            const right_op = node.*.node_variant.?.exp.right.?.*.node_variant.?.exp.op;
            if (self.parse_left_has_priority(node.*.node_variant.?.exp.op, right_op)) {
                try self.parse_node_shift_children_left(node);
                try self.parse_reorder_expression(node.*.node_variant.?.exp.left.?);
                try self.parse_reorder_expression(node.*.node_variant.?.exp.right.?);
            }
        }
        if ((node.*.node_variant.?.exp.left != null and ast.node_is_array(node.*.node_variant.?.exp.left.?.*) and node.*.node_variant.?.exp.right != null and ast.node_is_assignment(node.*.node_variant.?.exp.right.?.*)) or
            ((ast.node_is_expression(node.*.node_variant.?.exp.left.?.*, "()") or
                ast.node_is_expression(node.*.node_variant.?.exp.left.?.*, "[]")) and
                ast.node_is_expression(node.*.node_variant.?.exp.right.?.*, ",")))
        {
            try self.parse_node_move_right_left_to_left(node);
        }
    }

    /// Parses a normal expression.
    ///
    /// This function parses a normal expression by handling operators,
    /// expressionable tokens, and rearranging nodes as needed to maintain
    /// proper precedence.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    fn parse_normal_expression(self: *Self, hist: *utils.History) ParseError!void {
        var t = self.token_peek_next();
        if (t == null) {
            self.transpile_proc.err("expected operator in expression", .{});
            return ParseError.InvalidExpression;
        }
        const op = t.?.data.sval.items;
        const op_pos = t.?.pos;
        var node_left = self.node_peek_expressionable_or_null();
        if (node_left == null) {
            // Enum variant shorthand (Zig-style): `.Variant`.
            // Parse as a dot-expression with a blank LHS so later passes can resolve it
            // using the expected enum type from context.
            if (mem.eql(u8, op, ".")) {
                const next_tok = self.token_peek_n(1);
                if (next_tok != null and next_tok.?.type == .Symbol and next_tok.?.data.cval == '{') {
                    _ = self.token_next(); // skip '.'
                    const lbrace_tok = self.token_peek_next();
                    try self.parse_compound_init(null, hist, if (lbrace_tok) |lt| lt.pos else op_pos);
                    return;
                }

                _ = self.token_next(); // skip '.'

                // Expect a single identifier after '.'
                _ = try self.parse_identifier();
                var node_right = self.node_pop() orelse {
                    self.transpile_proc.err("expected identifier after '.'", .{});
                    return ParseError.InvalidOperand;
                };
                node_right.flags = .{ .inside_expression = true };

                var blank_left: ast.Node = .{ .type = .Blank, .pos = op_pos };
                blank_left.flags = .{ .inside_expression = true };
                try self.make_expression_node(&blank_left, &node_right, op, op_pos);

                var exp_node = self.node_pop() orelse {
                    self.transpile_proc.err("expected expression after '.'", .{});
                    return ParseError.InvalidExpression;
                };
                try self.parse_reorder_expression(&exp_node);
                self.transpile_proc.nodes.push(exp_node) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                return;
            }
            // Prefix channel receive: `<-ch` -> `ch.recv()`. Parse the channel
            // operand (bounded so a following binary op ends it), then desugar.
            if (mem.eql(u8, op, "<-")) {
                _ = self.token_next(); // consume '<-'
                var recv_hist = utils.History.down(self.transpile_proc.allocator, hist, hist.flags);
                defer recv_hist.deinit();
                recv_hist.flags.stop_at_binary_op = true;
                const before = self.transpile_proc.nodes.count;
                try self.parse_expressionable(&recv_hist);
                if (self.transpile_proc.nodes.count == before) {
                    self.transpile_proc.err("expected a channel after '<-'", .{});
                    return ParseError.InvalidExpression;
                }
                var ch_node = self.node_pop() orelse {
                    self.transpile_proc.err("expected a channel after '<-'", .{});
                    return ParseError.InvalidExpression;
                };
                try self.push_channel_method_call(&ch_node, "recv", null, op_pos);
                return;
            }
            if (!utils.is_unary_operator(op)) {
                self.transpile_proc.err("expected left operand for '{s}' operator", .{op});
                return ParseError.InvalidOperand;
            }
            return try self.parse_for_unary(hist.flags);
        }
        _ = self.token_next(); // skip operator
        _ = self.node_pop();
        if (utils.is_left_operanded_unary_operator(op)) {
            return try self.parse_for_left_operanded_unary(&node_left.?, op, op_pos);
        }
        node_left.?.flags = .{ .inside_expression = true };
        t = self.token_peek_next();
        if (t == null) {
            self.transpile_proc.err("expected expressionable for '{s}' operator", .{op});
            return ParseError.InvalidOperand;
        }
        if (t.?.type == .Operator) {
            if (mem.eql(u8, t.?.data.sval.items, "(")) {
                var hist_down = utils.History.down(self.transpile_proc.allocator, hist, hist.flags);
                defer hist_down.deinit();
                hist_down.flags.parenthesis_not_function_call = true;
                try self.parse_for_parenthesis(&hist_down);
            } else if (mem.eql(u8, t.?.data.sval.items, ".") or mem.eql(u8, t.?.data.sval.items, "<-")) {
                // Allow enum variant shorthand `.Variant` AND a prefix channel
                // receive `<-ch` as a valid RHS operand after a binary operator
                // (`sum + <-ch`, `x == .Variant`). `parse_normal_expression` sees no
                // left operand here and routes to the `.`/`<-` prefix handler.
                try self.parse_normal_expression(hist);
            } else if (utils.is_unary_operator(t.?.data.sval.items)) {
                try self.parse_for_unary(hist.flags);
            } else {
                self.transpile_proc.err("expected expressionable for '{s}' operator", .{op});
                return ParseError.InvalidOperand;
            }
        } else {
            var hist_down = utils.History.down(self.transpile_proc.allocator, hist, hist.flags);
            defer hist_down.deinit();
            try self.parse_expressionable(&hist_down);
        }
        var node_right = self.node_pop() orelse {
            self.transpile_proc.err("expected expressionable for '{s}' operator", .{op});
            return ParseError.InvalidOperand;
        };
        node_right.flags = .{ .inside_expression = true };
        // Binary channel send: `ch <- v` -> `ch.send(v)`. The RHS was already parsed
        // as a full sub-expression, so `a <- b + c` desugars to `a.send(b + c)`.
        if (mem.eql(u8, op, "<-")) {
            try self.push_channel_method_call(&node_left.?, "send", &node_right, op_pos);
            return;
        }
        try self.make_expression_node(&node_left.?, &node_right, op, op_pos);
        var exp_node = self.node_pop() orelse {
            self.transpile_proc.err("expected expression node for '{s}' operator", .{op});
            return ParseError.InvalidExpression;
        };
        try self.parse_reorder_expression(&exp_node);
        self.transpile_proc.nodes.push(exp_node) catch {
            return ParseError.MemoryAllocationFailed;
        };
    }

    /// Parses an expression.
    ///
    /// This function parses an expression, handling different types of tokens
    /// such as parenthesis, commas, brackets, and operators. It rearranges nodes
    /// as needed to maintain proper precedence.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Returns:
    /// - `bool`: `true` if an expression was successfully parsed, `false` otherwise.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_expression(self: *Self, hist: *utils.History) ParseError!bool {
        const t = self.token_peek_next();
        if (t == null) return false;
        if (hist.flags.expression_is_unary and t.?.type == .Operator and !utils.is_unary_operand_compatible(t.?)) {
            return false;
        }
        if (mem.eql(u8, "(", t.?.data.sval.items)) {
            try self.parse_for_parenthesis(hist);
        } else if (mem.eql(u8, ",", t.?.data.sval.items)) {
            try self.parse_for_comma(hist);
        } else if (mem.eql(u8, "[", t.?.data.sval.items)) {
            try self.parse_for_bracket(hist);
        } else {
            try self.parse_normal_expression(hist);
        }
        return true;
    }

    /// Parses an identifier token.
    ///
    /// This function peeks at the next token and checks if it is an identifier.
    /// If it is not an identifier, it logs an error message. It then parses the token
    /// to a node if it is valid.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    /// - Logs an error message if the next token is not an identifier.
    fn parse_identifier(self: *Self) ParseError!bool {
        const t = self.token_peek_next();
        if (t == null) {
            self.transpile_proc.err("expected identifier, got eof", .{});
            return ParseError.InvalidIdentifier;
        }
        if (t.?.type != .Identifier) {
            // Allow primitive type keywords as operands to the builtin `sizeof(Type)`.
            // Example: `sizeof(num)`.
            if (t.?.type == .Keyword) {
                const kw = t.?.data.sval.items;
                const is_prim_type_kw = mem.eql(u8, kw, "void") or
                    mem.eql(u8, kw, "raw") or
                    mem.eql(u8, kw, "chr") or
                    mem.eql(u8, kw, "str") or
                    mem.eql(u8, kw, "dec") or
                    mem.eql(u8, kw, "num") or
                    mem.eql(u8, kw, "bin");

                const is_sizeof_type_operand = self.is_sizeof_type_operand_context();

                if (is_prim_type_kw and is_sizeof_type_operand) {
                    const consumed = self.token_next() orelse {
                        self.transpile_proc.err("expected identifier, got eof", .{});
                        return ParseError.InvalidIdentifier;
                    };
                    // Fold a trailing pointer suffix (`sizeof(num*)`, `sizeof(raw*)`)
                    // into the operand name so it isn't mis-parsed as a `*` binary op.
                    var sz_name = ArrayList(u8).init(self.transpile_proc.allocator);
                    errdefer sz_name.deinit();
                    sz_name.appendSlice(consumed.data.sval.items) catch return ParseError.MemoryAllocationFailed;
                    while (self.next_token_is_operator("*")) {
                        _ = self.token_next();
                        sz_name.append('*') catch return ParseError.MemoryAllocationFailed;
                    }
                    var ident_node = ast.Node{
                        .type = .Identifier,
                        .pos = consumed.pos,
                        .data = .{ .sval = sz_name },
                    };
                    try self.create_node(&ident_node);
                    return true;
                }
            }

            self.transpile_proc.err("expected identifier, got '{s}'", .{@tagName(t.?.type)});
            return ParseError.InvalidIdentifier;
        }

        // `sizeof(Box<num>)`: a generic type argument as the sizeof operand. The
        // base name is followed by `<...>`. Consume the generic-arg tokens and
        // fold them into a single mangled identifier (`Box__num`, matching
        // `type_name_mangled`'s `base__arg` scheme) so the existing sizeof
        // codegen emits `sizeof(Box__num)`. Only do this in sizeof context so
        // normal `a < b` comparisons are unaffected.
        if (self.is_sizeof_type_operand_context()) {
            const after = self.token_peek_n(1);
            if (after != null and after.?.type == .Operator and mem.eql(u8, after.?.data.sval.items, "<")) {
                return try self.parse_sizeof_generic_type_operand();
            }
        }

        return try self.parse_single_token_to_node();
    }

    /// Parses a generic type operand inside `sizeof(...)`, e.g. `Box<num>` or
    /// `Map<str, num>` or nested `Box<Box<num>>`, producing a single Identifier
    /// node whose name is the mangled C type (`Box__num`, `Map__str__num`,
    /// `Box__Box__num`). The leading base-name token has already been confirmed
    /// to be an identifier followed by `<`.
    fn parse_sizeof_generic_type_operand(self: *Self) ParseError!bool {
        const base = self.token_next() orelse {
            self.transpile_proc.err("expected type name in sizeof", .{});
            return ParseError.InvalidIdentifier;
        };
        var mangled = ArrayList(u8).init(self.transpile_proc.allocator);
        errdefer mangled.deinit();
        mangled.appendSlice(base.data.sval.items) catch return ParseError.MemoryAllocationFailed;

        // Walk the balanced `<...>` block, emitting `__` before each type-name
        // segment and ignoring the angle/comma punctuation. `>>` closes two levels.
        var depth: isize = 0;
        while (true) {
            const tk = self.token_next() orelse {
                self.transpile_proc.err("unterminated generic type in sizeof", .{});
                return ParseError.InvalidDataType;
            };
            if (tk.type == .Operator and mem.eql(u8, tk.data.sval.items, "<")) {
                depth += 1;
                continue;
            }
            if (tk.type == .Operator and mem.eql(u8, tk.data.sval.items, ">")) {
                depth -= 1;
                if (depth <= 0) break;
                continue;
            }
            if (tk.type == .Operator and mem.eql(u8, tk.data.sval.items, ">>")) {
                depth -= 2;
                if (depth <= 0) break;
                continue;
            }
            // Commas separating type args lex as Operators (lexer.zig:1129),
            // though a Symbol form is tolerated too. Either way: skip them.
            if (tk.type == .Operator and mem.eql(u8, tk.data.sval.items, ",")) continue;
            if (tk.type == .Symbol and tk.data.cval == ',') continue;
            if (tk.type == .Identifier or tk.type == .Keyword) {
                mangled.appendSlice("__") catch return ParseError.MemoryAllocationFailed;
                mangled.appendSlice(tk.data.sval.items) catch return ParseError.MemoryAllocationFailed;
                continue;
            }
            // Anything else (e.g. `*`) is unexpected here; bail to a clean error.
            self.transpile_proc.err("unexpected token in sizeof generic type", .{});
            return ParseError.InvalidDataType;
        }

        var ident_node = ast.Node{
            .type = .Identifier,
            .pos = base.pos,
            .data = .{ .sval = mangled },
        };
        try self.create_node(&ident_node);
        return true;
    }

    /// Parses a string token.
    ///
    /// This function peeks at the next token and checks if it is a string.
    /// If it is not a string, it logs an error message. It then parses the token
    /// to a node if it is valid.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    /// - Logs an error message if the next token is not a string.
    fn parse_string(self: *Self) !bool {
        const t = self.token_peek_next();
        if (t == null) {
            self.transpile_proc.err("expected string, got eof", .{});
            return ParseError.InvalidString;
        }
        if (t.?.type != .String) {
            self.transpile_proc.err("expected string, got '{s}'", .{@tagName(t.?.type)});
            return ParseError.InvalidString;
        }
        return try self.parse_single_token_to_node();
    }

    /// Parses a single expressionable token.
    ///
    /// This function peeks at the next token and attempts to parse it if it is
    /// a number, boolean, operator, identifier, keyword, or string. It handles
    /// specific cases within a fit statement.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Returns:
    /// - `bool`: `true` if a token was successfully parsed, `false` otherwise.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_await_operand(self: *Self, hist: *utils.History) ParseError!bool {
        const await_tok = self.token_next(); // skip await
        if (!hist.*.flags.inside_function_body) {
            self.transpile_proc.err("await statement outside of function", .{});
            return ParseError.InvalidStatement;
        }
        const next_tok = self.token_peek_next() orelse {
            self.transpile_proc.err("expected expression after 'await'", .{});
            return ParseError.InvalidExpression;
        };
        if (next_tok.type == .Symbol and next_tok.data.cval == ';') {
            self.transpile_proc.err("expected expression after 'await'", .{});
            return ParseError.InvalidExpression;
        }
        const before_count = self.transpile_proc.nodes.count;
        // Parse only the awaited primary/call — `stop_at_binary_op` ends the operand
        // at a following binary operator so `await f(x) + 1` is `(await f(x)) + 1`.
        var await_hist = utils.History.down(self.transpile_proc.allocator, hist, hist.flags);
        defer await_hist.deinit();
        await_hist.flags.stop_at_binary_op = true;
        try self.parse_expressionable(&await_hist);
        if (self.transpile_proc.nodes.count == before_count) {
            self.transpile_proc.err("expected expression after 'await'", .{});
            return ParseError.InvalidExpression;
        }

        const await_operand_node = self.node_pop();
        if (await_operand_node == null) {
            self.transpile_proc.err("expected expression after 'await'", .{});
            return ParseError.InvalidExpression;
        }
        const operand = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(operand);
        operand.* = await_operand_node.?;

        self.transpile_proc.nodes.push(ast.Node{
            .type = .Unary,
            .pos = if (await_tok) |t| t.pos else operand.*.pos,
            .node_variant = .{
                .unary = .{
                    .op = "await",
                    .operand = operand,
                },
            },
        }) catch {
            return ParseError.MemoryAllocationFailed;
        };
        return true;
    }

    /// Parse a `fork <call>;` statement — a fire-and-forget virtual-thread spawn.
    /// The operand is parsed as a call expression; whether it is actually a `()`
    /// call is validated at codegen (mirroring `await`'s deferred validation).
    fn parse_fork_statement(self: *Self, hist: *utils.History) ParseError!void {
        const fork_tok = self.token_next(); // consume 'fork'
        if (!hist.*.flags.inside_function_body) {
            self.transpile_proc.err("fork statement outside of function", .{});
            return ParseError.InvalidStatement;
        }
        const next_tok = self.token_peek_next() orelse {
            self.transpile_proc.err("expected a function call after 'fork'", .{});
            return ParseError.InvalidExpression;
        };
        if (next_tok.type == .Symbol and next_tok.data.cval == ';') {
            self.transpile_proc.err("expected a function call after 'fork'", .{});
            return ParseError.InvalidExpression;
        }

        const before_count = self.transpile_proc.nodes.count;
        var fork_hist = utils.History.down(self.transpile_proc.allocator, hist, hist.flags);
        defer fork_hist.deinit();
        try self.parse_expressionable(&fork_hist);
        if (self.transpile_proc.nodes.count == before_count) {
            self.transpile_proc.err("expected a function call after 'fork'", .{});
            return ParseError.InvalidExpression;
        }

        const call_node = self.node_pop() orelse {
            self.transpile_proc.err("expected a function call after 'fork'", .{});
            return ParseError.InvalidExpression;
        };
        const expr = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(expr);
        expr.* = call_node;

        self.transpile_proc.nodes.push(ast.Node{
            .type = .StatementFork,
            .pos = if (fork_tok) |t| t.pos else expr.*.pos,
            .node_variant = .{ .statement = .{ .fork_stmt = .{ .expr = expr } } },
        }) catch {
            return ParseError.MemoryAllocationFailed;
        };
        try self.expect_sym(';');
    }

    fn parse_expressionable_single(self: *Self, hist: *utils.History) ParseError!bool {
        if (self.expr_depth >= max_parse_expr_depth) {
            self.transpile_proc.err("expression nests too deeply to parse (limit {d})", .{max_parse_expr_depth});
            return ParseError.ExpressionTooDeep;
        }
        self.expr_depth += 1;
        defer self.expr_depth -= 1;
        const t = self.token_peek_next();
        if (t == null) {
            return false;
        }
        if (hist.flags.stop_at_comma and t.?.type == .Operator and mem.eql(u8, t.?.data.sval.items, ",")) {
            return false;
        }
        // For `await <call>`: once a primary has been parsed (`inside_expression`),
        // a following binary operator ends the await operand so `await f(x) + 1`
        // parses as `(await f(x)) + 1`. Postfix operators (`(`, `[`, `.`) and the
        // address/deref `&`/`*` are allowed to continue the primary.
        if (hist.flags.stop_at_binary_op and hist.flags.inside_expression and
            t.?.type == .Operator and utils.is_binary_only_operator(t.?))
        {
            return false;
        }
        hist.flags.inside_expression = true;
        return switch (t.?.type) {
            .Number, .Boolean => try self.parse_single_token_to_node(),
            .Operator => {
                if (hist.*.flags.in_fit_statement and mem.eql(u8, t.?.data.sval.items, "->")) {
                    return false;
                }
                return try self.parse_expression(hist);
            },
            .Identifier => blk: {
                const looks_like_compound_init = struct {
                    fn check(p: *Self, _: token.Token) bool {
                        var off: usize = 1;
                        _ = p.skip_generic_args_tokens(&off);
                        const next_tok = p.token_peek_n(off) orelse return false;
                        return next_tok.type == .Symbol and next_tok.data.cval == '{';
                    }
                }.check;

                const is_known_compound = blk2: {
                    const sym = self.transpile_proc.get_symbol(t.?.data.sval.items) orelse break :blk2 false;
                    const node_opt = symbol.get_node_symbol(sym) orelse break :blk2 false;
                    break :blk2 node_opt.type == .Compound;
                };

                const is_known_imported = blk3: {
                    const hit = self.transpile_proc.global_symbols.get(t.?.data.sval.items) orelse break :blk3 false;
                    break :blk3 !hit.is_function;
                };

                const is_value_in_scope = self.transpile_proc.get_scope_entity(t.?.data.sval.items) != null;

                // A compound declared later in the file is not yet in the symbol
                // table during this single pass; the forward pre-scan lets us still
                // recognize its initializer. The pre-scan only contains real
                // top-level type names, so comparisons like `a > b {` are never
                // misread (b is not a declared type).
                const is_forward_compound = self.is_forward_declared_type(t.?.data.sval.items);

                if (!is_value_in_scope and (is_known_compound or is_known_imported or is_forward_compound) and looks_like_compound_init(self, t.?)) {
                    const dt = self.transpile_proc.allocator.create(dtype.DataType) catch {
                        return ParseError.MemoryAllocationFailed;
                    };
                    errdefer self.transpile_proc.allocator.destroy(dt);
                    dt.* = dtype.DataType{
                        .array = null,
                        .pointer_depth = 0,
                        .type = .Unknown,
                        .type_str = ArrayList(u8).init(self.transpile_proc.allocator),
                        .flags = .{},
                    };
                    try self.parse_datatype(dt);
                    const lbrace_tok = self.token_peek_next();
                    try self.parse_compound_init(dt, hist, if (lbrace_tok) |lt| lt.pos else null);
                    break :blk true;
                }
                // Support user-defined types at statement level: `Point p;`.
                // If the next token is a known type name and the following token looks like a declaration,
                // parse it as a variable declaration instead of an identifier expression.
                const looks_like_decl = struct {
                    fn check(p: *Self) bool {
                        var off: usize = 1;

                        // Optional qualified type segments after the leading identifier:
                        // `alias.Type name;`
                        while (true) {
                            const dot_tok = p.token_peek_n(off) orelse break;
                            if (!(dot_tok.type == .Operator and mem.eql(u8, dot_tok.data.sval.items, "."))) break;

                            const seg_tok = p.token_peek_n(off + 1) orelse return false;
                            if (seg_tok.type != .Identifier) return false;
                            off += 2;
                        }

                        // Optional generic args after the type name.
                        _ = p.skip_generic_args_tokens(&off);

                        // Optional pointer stars after the type name.
                        while (true) {
                            const tok = p.token_peek_n(off) orelse break;
                            if (tok.type == .Operator and mem.eql(u8, tok.data.sval.items, "*")) {
                                off += 1;
                                continue;
                            }
                            break;
                        }

                        // Optional array brackets after the type name: `T[] name;` or `T[64] name;`.
                        while (true) {
                            const tok = p.token_peek_n(off) orelse break;
                            if (!(tok.type == .Operator and mem.eql(u8, tok.data.sval.items, "["))) break;

                            off += 1; // skip '['
                            // Skip until matching ']'. We don't need to fully parse the inner expression here.
                            while (true) {
                                const inner = p.token_peek_n(off) orelse return false;
                                if (inner.type == .Symbol and inner.data.cval == ']') {
                                    off += 1; // skip ']'
                                    break;
                                }
                                // If we hit a statement terminator before closing, it's not a declaration.
                                if (inner.type == .Symbol and inner.data.cval == ';') return false;
                                off += 1;
                            }
                        }

                        // A declaration must have an identifier name after the type.
                        const name_tok = p.token_peek_n(off) orelse return false;
                        if (name_tok.type != .Identifier) return false;

                        // And should be followed by `;` or `=`.
                        const next_tok = p.token_peek_n(off + 1) orelse return false;
                        if (next_tok.type == .Operator and mem.eql(u8, next_tok.data.sval.items, "=")) return true;
                        if (next_tok.type == .Symbol and next_tok.data.cval == ';') return true;
                        return false;
                    }
                }.check;

                // Avoid mis-parsing expressions like `w * h` as a pointer declaration `w* h`.
                // Only consider this declaration fast-path when the leading identifier is not
                // a known value in the current scope.
                //
                // Also skip it when this identifier is the right-hand operand of a member
                // access: in `s.id * x`, after the `.` we are at `id`, and `looks_like_decl`
                // would otherwise read the trailing `* x ;` as a pointer declaration `id* x;`.
                // An identifier immediately following `.` is always a field name, never a
                // declaration type.
                const prev_significant = self.token_peek_prev_stream_n(0);
                const after_member_access = prev_significant != null and
                    prev_significant.?.type == .Operator and
                    mem.eql(u8, prev_significant.?.data.sval.items, ".");

                if (!after_member_access and self.transpile_proc.get_scope_entity(t.?.data.sval.items) == null and looks_like_decl(self)) {
                    // Parse datatype + variable.
                    const dt = self.transpile_proc.allocator.create(dtype.DataType) catch {
                        return ParseError.MemoryAllocationFailed;
                    };
                    errdefer self.transpile_proc.allocator.destroy(dt);
                    dt.* = dtype.DataType{
                        .array = null,
                        .pointer_depth = 0,
                        .type = .Unknown,
                        .type_str = ArrayList(u8).init(self.transpile_proc.allocator),
                        .flags = .{},
                    };
                    try self.parse_datatype(dt);
                    try self.parse_variable(dt, hist, false, false);
                    try self.expect_sym(';');
                    break :blk true;
                }
                break :blk try self.parse_identifier();
            },
            .Keyword => {
                const kw = t.?.data.sval.items;

                // `nil` as a primary EXPRESSION operand. Handling it here (rather than
                // only in parse_keyword) ensures a following binary operator binds to it
                // as its left/right operand: `x != nil && y` must parse `nil` as the RHS
                // of `!=`, leaving the `!=` expression as the left operand of `&&`.
                // Routing through parse_keyword instead pushed a bare .Nil node without
                // the operand-completion the binary-op loop relies on.
                if (mem.eql(u8, kw, "nil")) {
                    const nil_tok = self.token_next();
                    self.transpile_proc.nodes.push(ast.Node{ .type = .Nil, .pos = nil_tok.?.pos }) catch {
                        return ParseError.MemoryAllocationFailed;
                    };
                    return true;
                }

                // Phase 1 async surface: parse `await expr` and lower it as `expr`.
                if (mem.eql(u8, kw, "await")) {
                    return try self.parse_await_operand(hist);
                }

                // Allow primitive type keywords as operands to the builtin `sizeof(Type)`.
                // Example: `sizeof(num)`.
                const is_prim_type_kw = utils.keyword_is_datatype(kw);

                const is_sizeof_type_operand = self.is_sizeof_type_operand_context();

                if (is_prim_type_kw and is_sizeof_type_operand) {
                    const consumed = self.token_next() orelse {
                        self.transpile_proc.err("expected identifier, got eof", .{});
                        return ParseError.InvalidIdentifier;
                    };
                    // Fold a trailing pointer suffix (`sizeof(num*)`, `sizeof(raw*)`)
                    // into the operand name so it isn't mis-parsed as a `*` binary op.
                    var sz_name = ArrayList(u8).init(self.transpile_proc.allocator);
                    errdefer sz_name.deinit();
                    sz_name.appendSlice(consumed.data.sval.items) catch return ParseError.MemoryAllocationFailed;
                    while (self.next_token_is_operator("*")) {
                        _ = self.token_next();
                        sz_name.append('*') catch return ParseError.MemoryAllocationFailed;
                    }
                    var ident_node = ast.Node{
                        .type = .Identifier,
                        .pos = consumed.pos,
                        .data = .{ .sval = sz_name },
                    };
                    try self.create_node(&ident_node);
                    return true;
                }

                try self.parse_keyword(hist);
                return true;
            },
            .String => try self.parse_string(),
            else => false,
        };
    }

    fn parse_compound(self: *Self, is_public: bool) ParseError!void {
        try self.expect_keyword("compound");

        const name_tok = self.token_next();
        if (name_tok == null or name_tok.?.type != .Identifier) {
            self.transpile_proc.err("expected identifier after 'compound'", .{});
            return ParseError.InvalidIdentifier;
        }

        var name = ArrayList(u8).initCapacity(self.transpile_proc.allocator, name_tok.?.data.sval.items.len) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer name.deinit();
        name.appendSlice(name_tok.?.data.sval.items) catch {
            return ParseError.MemoryAllocationFailed;
        };

        const type_params = try self.parse_generic_type_params();

        try self.expect_sym('{');

        var fields = utils.Vector(ast.CompoundField).init(self.transpile_proc.allocator);
        errdefer {
            for (fields.items()) |f| {
                f.name.deinit();
                f.dtype.type_str.deinit();
                if (f.dtype.array) |array| {
                    if (!array.brackets.is_empty()) {
                        for (array.brackets.items()) |bracket| self.transpile_proc.deinit_node(bracket);
                    }
                    array.brackets.deinit();
                }
                self.transpile_proc.allocator.destroy(f.dtype);
            }
            fields.deinit();
        }

        while (!self.next_token_is_symbol('}')) {
            // Parse field datatype
            const dt = self.transpile_proc.allocator.create(dtype.DataType) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(dt);
            dt.* = dtype.DataType{
                .array = null,
                .pointer_depth = 0,
                .type = .Unknown,
                .type_str = ArrayList(u8).init(self.transpile_proc.allocator),
                .flags = .{},
            };
            var hist_tmp = utils.History.init(self.transpile_proc.allocator, .{});
            defer hist_tmp.deinit();
            try self.parse_datatype(dt);
            // Allow array brackets after type name in field declarations.
            if (self.next_token_is_operator("[")) {
                try self.parse_array_brackets(dt, &hist_tmp);
            }

            // Parse one or more field names: `dec x, y;`
            var field_count: usize = 0;
            while (true) {
                const field_tok = self.token_next();
                if (field_tok == null or field_tok.?.type != .Identifier) {
                    self.transpile_proc.err("expected field name", .{});
                    return ParseError.InvalidIdentifier;
                }
                var fname = ArrayList(u8).initCapacity(self.transpile_proc.allocator, field_tok.?.data.sval.items.len) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer fname.deinit();
                fname.appendSlice(field_tok.?.data.sval.items) catch {
                    return ParseError.MemoryAllocationFailed;
                };

                // Each field owns its dtype (deep-copy type_str). For multi-name decls,
                // only allow non-array types (arrays require bracket AST cloning).
                if (field_count > 0 and dt.array != null) {
                    self.transpile_proc.err("array fields cannot be declared in a combined list; declare them separately", .{});
                    return ParseError.InvalidDataType;
                }

                const field_dt = self.transpile_proc.allocator.create(dtype.DataType) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(field_dt);
                field_dt.* = dt.*;
                field_dt.*.type_str = ArrayList(u8).initCapacity(self.transpile_proc.allocator, dt.type_str.items.len) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                field_dt.*.type_str.appendSlice(dt.type_str.items) catch {
                    return ParseError.MemoryAllocationFailed;
                };

                field_dt.*.generic_args = dt.generic_args;

                if (field_count > 0) {
                    field_dt.*.array = null;
                }

                fields.push(.{ .name = fname, .dtype = field_dt }) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                field_count += 1;

                if (!self.next_token_is_operator(",")) break;
                _ = self.token_next(); // skip comma
            }

            // Original dt storage is now unused; destroy it.
            dt.*.type_str.deinit();
            dt.*.generic_args = null;
            self.transpile_proc.allocator.destroy(dt);

            try self.expect_sym(';');
        }
        try self.expect_sym('}');

        const node = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer {
            self.transpile_proc.deinit_node(node.*);
            self.transpile_proc.allocator.destroy(node);
        }
        node.* = ast.Node{
            .type = .Compound,
            .pos = name_tok.?.pos,
            .flags = .{ .is_public = is_public },
            .node_variant = .{ .compound = .{ .name = name, .fields = fields, .type_params = type_params } },
        };

        // Register as a symbol so it can be used as a datatype identifier.
        try self.transpile_proc.push_symbol(.{ .type = .Node, .name = node.*.node_variant.?.compound.name.items, .data = .{ .node = node.* }, .symbol_table = null });

        self.transpile_proc.nodes.push(node.*) catch {
            return ParseError.MemoryAllocationFailed;
        };
        self.transpile_proc.owned_nodes.append(node) catch {
            return ParseError.MemoryAllocationFailed;
        };
    }

    fn parse_quirk(self: *Self, is_public: bool) ParseError!void {
        try self.expect_keyword("quirk");

        const name_tok = self.token_next();
        if (name_tok == null or name_tok.?.type != .Identifier) {
            self.transpile_proc.err("expected identifier after 'quirk'", .{});
            return ParseError.InvalidIdentifier;
        }

        var name = ArrayList(u8).initCapacity(self.transpile_proc.allocator, name_tok.?.data.sval.items.len) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer name.deinit();
        name.appendSlice(name_tok.?.data.sval.items) catch {
            return ParseError.MemoryAllocationFailed;
        };

        // Allow a generic quirk, e.g. `quirk Iterator<T> { next() Option<T>; }`.
        // The type parameters are abstract over the method signatures; an `impl`
        // binds them. Method signatures treat `T` as an unresolved type name, so we
        // only need to consume the params here (they are not stored on the node) and
        // record that the quirk is generic so codegen skips its monomorphic vtable.
        var quirk_is_generic = false;
        const quirk_type_params = try self.parse_generic_type_params();
        if (quirk_type_params) |*tp| {
            quirk_is_generic = true;
            for (tp.items()) |*p| p.deinit();
            var mtp = tp.*;
            mtp.deinit();
        }

        try self.expect_sym('{');

        var methods = utils.Vector(ast.QuirkMethodSig).init(self.transpile_proc.allocator);
        errdefer {
            for (methods.items()) |m| {
                m.name.deinit();
                m.rtype.type_str.deinit();
                for (m.args.items()) |a| {
                    a.name.deinit();
                    a.dtype.type_str.deinit();
                    if (a.dtype.array) |array| {
                        if (!array.brackets.is_empty()) {
                            for (array.brackets.items()) |bracket| self.transpile_proc.deinit_node(bracket);
                        }
                        array.brackets.deinit();
                    }
                    self.transpile_proc.allocator.destroy(a.dtype);
                }
                m.args.deinit();
            }
            methods.deinit();
        }

        while (!self.next_token_is_symbol('}')) {
            var method_is_async = false;
            if (self.next_token_is_keyword("async")) {
                _ = self.token_next();
                method_is_async = true;
            }

            const mname_tok = self.token_next();
            if (mname_tok == null or mname_tok.?.type != .Identifier) {
                self.transpile_proc.err("expected method name", .{});
                return ParseError.InvalidIdentifier;
            }
            var mname = ArrayList(u8).initCapacity(self.transpile_proc.allocator, mname_tok.?.data.sval.items.len) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer mname.deinit();
            mname.appendSlice(mname_tok.?.data.sval.items) catch {
                return ParseError.MemoryAllocationFailed;
            };

            try self.expect_op("(");

            var args = utils.Vector(ast.QuirkArg).init(self.transpile_proc.allocator);
            errdefer args.deinit();
            while (!self.next_token_is_symbol(')')) {
                const adt = self.transpile_proc.allocator.create(dtype.DataType) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(adt);
                adt.* = dtype.DataType{ .type_str = ArrayList(u8).init(self.transpile_proc.allocator), .flags = .{} };
                var hist_tmp = utils.History.init(self.transpile_proc.allocator, .{});
                defer hist_tmp.deinit();
                try self.parse_datatype(adt);
                if (self.next_token_is_operator("[")) {
                    try self.parse_array_brackets(adt, &hist_tmp);
                }

                const aname_tok = self.token_next();
                if (aname_tok == null or aname_tok.?.type != .Identifier) {
                    self.transpile_proc.err("expected argument name", .{});
                    return ParseError.InvalidIdentifier;
                }
                var aname = ArrayList(u8).initCapacity(self.transpile_proc.allocator, aname_tok.?.data.sval.items.len) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer aname.deinit();
                aname.appendSlice(aname_tok.?.data.sval.items) catch {
                    return ParseError.MemoryAllocationFailed;
                };

                args.push(.{ .name = aname, .dtype = adt }) catch {
                    return ParseError.MemoryAllocationFailed;
                };

                if (!self.next_token_is_operator(",")) break;
                _ = self.token_next();
            }
            try self.expect_sym(')');

            // Optional return type; default to void.
            var rtype: dtype.DataType = .{ .type_str = ArrayList(u8).init(self.transpile_proc.allocator) };
            const rtok = self.token_peek_next();
            if (rtok != null and (rtok.?.type == .Keyword and utils.keyword_is_datatype(rtok.?.data.sval.items)) or rtok.?.type == .Identifier) {
                try self.parse_datatype(&rtype);
            } else {
                rtype.type = .Void;
                rtype.type_str.appendSlice("void") catch {
                    return ParseError.MemoryAllocationFailed;
                };
            }

            try self.expect_sym(';');
            methods.push(.{ .name = mname, .rtype = rtype, .args = args, .is_async = method_is_async }) catch {
                return ParseError.MemoryAllocationFailed;
            };
        }

        try self.expect_sym('}');

        const node = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer {
            self.transpile_proc.deinit_node(node.*);
            self.transpile_proc.allocator.destroy(node);
        }
        node.* = ast.Node{
            .type = .Quirk,
            .pos = name_tok.?.pos,
            .flags = .{ .is_public = is_public },
            .node_variant = .{ .quirk = .{ .name = name, .methods = methods, .is_generic = quirk_is_generic } },
        };

        // Register as a symbol so it can be used as a datatype identifier.
        try self.transpile_proc.push_symbol(.{ .type = .Node, .name = node.*.node_variant.?.quirk.name.items, .data = .{ .node = node.* }, .symbol_table = null });

        self.transpile_proc.nodes.push(node.*) catch {
            return ParseError.MemoryAllocationFailed;
        };
        self.transpile_proc.owned_nodes.append(node) catch {
            return ParseError.MemoryAllocationFailed;
        };
    }

    fn parse_enum(self: *Self, is_public: bool) ParseError!void {
        try self.expect_keyword("enum");

        const name_tok = self.token_next();
        if (name_tok == null or name_tok.?.type != .Identifier) {
            self.transpile_proc.err("expected identifier after 'enum'", .{});
            return ParseError.InvalidIdentifier;
        }

        var name = ArrayList(u8).initCapacity(self.transpile_proc.allocator, name_tok.?.data.sval.items.len) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer name.deinit();
        name.appendSlice(name_tok.?.data.sval.items) catch {
            return ParseError.MemoryAllocationFailed;
        };

        // Optional generic type parameters: `enum Option<T> { ... }`,
        // `enum Result<T, E> { ... }`. Mirrors `parse_compound`.
        const type_params = try self.parse_generic_type_params();

        try self.expect_sym('{');

        var variants = utils.Vector(ast.EnumVariant).init(self.transpile_proc.allocator);
        errdefer {
            for (variants.items()) |v| {
                v.name.deinit();
            }
            variants.deinit();
        }

        while (!self.next_token_is_symbol('}')) {
            const vtok = self.token_next();
            if (vtok == null or vtok.?.type != .Identifier) {
                self.transpile_proc.err("expected enum variant name", .{});
                return ParseError.InvalidIdentifier;
            }

            var vname = ArrayList(u8).initCapacity(self.transpile_proc.allocator, vtok.?.data.sval.items.len) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer vname.deinit();
            vname.appendSlice(vtok.?.data.sval.items) catch {
                return ParseError.MemoryAllocationFailed;
            };

            // Optional positional payload for a data-carrying variant:
            // `Circle(num)`, `Rect(num, num)`. The `(` makes this a tagged-union
            // variant; the comma-separated types become its positional fields.
            var payload: ?utils.Vector(*dtype.DataType) = null;
            if (self.next_token_is_operator("(")) {
                _ = self.token_next(); // consume '('
                var ptypes = utils.Vector(*dtype.DataType).init(self.transpile_proc.allocator);
                errdefer ptypes.deinit();
                while (!self.next_token_is_symbol(')')) {
                    const pdt = self.transpile_proc.allocator.create(dtype.DataType) catch {
                        return ParseError.MemoryAllocationFailed;
                    };
                    pdt.* = dtype.DataType{
                        .array = null,
                        .pointer_depth = 0,
                        .type = .Unknown,
                        .type_str = ArrayList(u8).init(self.transpile_proc.allocator),
                        .flags = .{},
                    };
                    var phist = utils.History.init(self.transpile_proc.allocator, .{});
                    defer phist.deinit();
                    try self.parse_datatype(pdt);
                    if (self.next_token_is_operator("[")) {
                        try self.parse_array_brackets(pdt, &phist);
                    }
                    ptypes.push(pdt) catch return ParseError.MemoryAllocationFailed;
                    if (self.next_token_is_operator(",")) {
                        _ = self.token_next();
                        continue;
                    }
                    break;
                }
                if (!self.next_token_is_symbol(')')) {
                    self.transpile_proc.err("expected ')' to close enum variant payload", .{});
                    return ParseError.InvalidToken;
                }
                _ = self.token_next(); // consume ')'
                if (ptypes.count == 0) {
                    self.transpile_proc.err("enum variant payload '()' must list at least one type", .{});
                    return ParseError.InvalidToken;
                }
                payload = ptypes;
            }

            var value: ?i64 = null;
            if (self.next_token_is_operator("=")) {
                _ = self.token_next(); // skip '='
                // Optional leading minus for a negative explicit value (`A = -1`).
                // The lexer emits `-` and the number as separate tokens, so consume
                // the sign here and negate the parsed literal below.
                var negate = false;
                if (self.next_token_is_operator("-")) {
                    _ = self.token_next(); // skip '-'
                    negate = true;
                }
                const ntok = self.token_next();
                if (ntok == null or ntok.?.type != .Number) {
                    self.transpile_proc.err("expected integer literal after '='", .{});
                    return ParseError.InvalidToken;
                }
                switch (ntok.?.data) {
                    .inum => |n| value = @as(i64, @intCast(n)),
                    .lnum => |n| value = @as(i64, @intCast(n)),
                    .llnum => |n| value = @as(i64, @intCast(n)),
                    else => {
                        self.transpile_proc.err("enum variant value must be an integer literal", .{});
                        return ParseError.InvalidToken;
                    },
                }
                if (negate) value = -value.?;
            }

            // Variants are separated by commas (preferred) or semicolons (legacy).
            // Trailing separators are allowed.
            if (self.next_token_is_operator(",")) {
                _ = self.token_next();
            } else if (self.next_token_is_symbol(';')) {
                _ = self.token_next();
            } else if (!self.next_token_is_symbol('}')) {
                self.transpile_proc.err("expected ',' or ';' after enum variant", .{});
                return ParseError.InvalidToken;
            }
            variants.push(.{ .name = vname, .value = value, .payload = payload }) catch {
                return ParseError.MemoryAllocationFailed;
            };
        }

        try self.expect_sym('}');

        const node = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer {
            self.transpile_proc.deinit_node(node.*);
            self.transpile_proc.allocator.destroy(node);
        }

        node.* = ast.Node{
            .type = .Enum,
            .pos = name_tok.?.pos,
            .flags = .{ .is_public = is_public },
            .node_variant = .{ .enum_decl = .{ .name = name, .variants = variants, .type_params = type_params } },
        };

        // Register as a symbol so it can be used as a datatype identifier.
        try self.transpile_proc.push_symbol(.{ .type = .Node, .name = node.*.node_variant.?.enum_decl.name.items, .data = .{ .node = node.* }, .symbol_table = null });

        self.transpile_proc.nodes.push(node.*) catch {
            return ParseError.MemoryAllocationFailed;
        };
        self.transpile_proc.owned_nodes.append(node) catch {
            return ParseError.MemoryAllocationFailed;
        };
    }

    fn parse_impl(self: *Self, is_public: bool) ParseError!void {
        try self.expect_keyword("impl");
        const type_tok = self.token_next();
        if (type_tok == null or type_tok.?.type != .Identifier) {
            self.transpile_proc.err("expected type name after 'impl'", .{});
            return ParseError.InvalidIdentifier;
        }

        var type_params: ?utils.Vector(ArrayList(u8)) = null;
        var type_param_forced_insts: ?utils.Vector(utils.Vector(ArrayList(u8))) = null;
        errdefer if (type_param_forced_insts) |*insts| {
            for (insts.items()) |*combo| {
                for (combo.items()) |*t| t.deinit();
                combo.deinit();
            }
            insts.deinit();
        };

        // `impl Type as Quirk { ... }` (quirk impl) OR `impl Type { ... }` (plain impl).
        var peek_after_type = self.token_peek_next();
        var quirk_tok: ?token.Token = null;
        var type_name_override: ?ArrayList(u8) = null;
        errdefer if (type_name_override) |*o| o.deinit();

        if (self.next_token_is_angle_open()) {
            if (self.impl_generic_args_are_params()) {
                const parsed = try self.parse_impl_type_params_with_constraints();
                type_params = parsed.params;
                type_param_forced_insts = parsed.forced_insts;
                peek_after_type = self.token_peek_next();
            } else {
                var dt: dtype.DataType = .{
                    .array = null,
                    .pointer_depth = 0,
                    .type = .Unknown,
                    .type_str = ArrayList(u8).init(self.transpile_proc.allocator),
                    .flags = .{},
                    .generic_args = null,
                };
                defer dt.type_str.deinit();
                dt.type_str.appendSlice(type_tok.?.data.sval.items) catch return ParseError.MemoryAllocationFailed;
                try self.parse_generic_type_args(&dt);

                var mangled = ArrayList(u8).init(self.transpile_proc.allocator);
                errdefer mangled.deinit();
                try self.append_mangled_dtype_name(&mangled, &dt);
                type_name_override = mangled;
                peek_after_type = self.token_peek_next();
            }
        } else {
            type_params = try self.parse_generic_type_params();
            peek_after_type = self.token_peek_next();
        }
        if (peek_after_type != null and peek_after_type.?.type == .Keyword and mem.eql(u8, peek_after_type.?.data.sval.items, "as")) {
            _ = self.token_next(); // consume `as`
            const maybe_quirk = self.token_next();
            if (maybe_quirk == null or maybe_quirk.?.type != .Identifier) {
                self.transpile_proc.err("expected quirk name after 'as'", .{});
                return ParseError.InvalidIdentifier;
            }
            quirk_tok = maybe_quirk;

            // Allow a generic quirk binding, e.g. `impl VecIter<T> as Iterator<T>`.
            // The type arguments describe which T the quirk is satisfied for; method
            // mangling keys off only the base quirk name, so parse and discard them.
            if (self.next_token_is_angle_open()) {
                var quirk_dt: dtype.DataType = .{
                    .array = null,
                    .pointer_depth = 0,
                    .type = .Unknown,
                    .type_str = ArrayList(u8).init(self.transpile_proc.allocator),
                    .flags = .{},
                    .generic_args = null,
                };
                defer quirk_dt.type_str.deinit();
                quirk_dt.type_str.appendSlice(maybe_quirk.?.data.sval.items) catch return ParseError.MemoryAllocationFailed;
                try self.parse_generic_type_args(&quirk_dt);
            }
        } else if (peek_after_type != null and peek_after_type.?.type == .Identifier) {
            self.transpile_proc.err("expected 'as' before quirk name in impl header", .{});
            return ParseError.InvalidIdentifier;
        } else if (peek_after_type == null or peek_after_type.?.type != .Symbol or peek_after_type.?.data.cval != '{') {
            self.transpile_proc.err("expected 'as <Quirk>' or '{{' after type name", .{});
            return ParseError.InvalidIdentifier;
        }

        var type_name = if (type_name_override) |o|
            o
        else
            ArrayList(u8).initCapacity(self.transpile_proc.allocator, type_tok.?.data.sval.items.len) catch {
                return ParseError.MemoryAllocationFailed;
            };
        if (type_name_override == null) {
            errdefer type_name.deinit();
            type_name.appendSlice(type_tok.?.data.sval.items) catch {
                return ParseError.MemoryAllocationFailed;
            };
        }

        var quirk_name: ?ArrayList(u8) = null;
        errdefer if (quirk_name) |*qn| qn.deinit();
        if (quirk_tok) |qt| {
            var qn = ArrayList(u8).initCapacity(self.transpile_proc.allocator, qt.data.sval.items.len) catch {
                return ParseError.MemoryAllocationFailed;
            };
            qn.appendSlice(qt.data.sval.items) catch {
                qn.deinit();
                return ParseError.MemoryAllocationFailed;
            };
            quirk_name = qn;
        }

        try self.expect_sym('{');

        var methods = utils.Vector(*ast.Node).init(self.transpile_proc.allocator);
        errdefer {
            for (methods.items()) |m| {
                self.transpile_proc.deinit_node(m.*);
                self.transpile_proc.allocator.destroy(m);
            }
            methods.deinit();
        }

        // Parse methods with syntax similar to functions but without the leading `fun` keyword.
        // Example: `fun1() void { ... }`
        while (!self.next_token_is_symbol('}')) {
            var method_is_public = is_public;
            var method_is_async = false;

            while (true) {
                const peek = self.token_peek_next();
                if (peek == null or peek.?.type != .Keyword) break;
                const kw = peek.?.data.sval.items;

                if (mem.eql(u8, kw, "pub")) {
                    _ = self.token_next();
                    method_is_public = true;
                    continue;
                }
                if (mem.eql(u8, kw, "async")) {
                    _ = self.token_next();
                    method_is_async = true;
                    continue;
                }
                break;
            }

            const name_tok = self.token_next();
            if (name_tok == null or name_tok.?.type != .Identifier) {
                self.transpile_proc.err("expected method name in impl", .{});
                return ParseError.InvalidIdentifier;
            }

            // Build a regular function node with a generated name:
            // - Quirk impl: `<Type>__<Quirk>__<method>`
            // - Plain impl: `<Type>__<method>`
            var fn_node = ast.Node{
                .type = .Function,
                .pos = name_tok.?.pos,
                .flags = .{ .is_public = method_is_public },
                .node_variant = .{ .function = .{ .is_async = method_is_async } },
            };

            const gen_name = if (quirk_name) |qn|
                (std.fmt.allocPrint(self.transpile_proc.allocator, "{s}__{s}__{s}", .{ type_name.items, qn.items, name_tok.?.data.sval.items }) catch {
                    return ParseError.MemoryAllocationFailed;
                })
            else
                (std.fmt.allocPrint(self.transpile_proc.allocator, "{s}__{s}", .{ type_name.items, name_tok.?.data.sval.items }) catch {
                    return ParseError.MemoryAllocationFailed;
                });
            defer self.transpile_proc.allocator.free(gen_name);
            fn_node.node_variant.?.function.name = ArrayList(u8).initCapacity(self.transpile_proc.allocator, gen_name.len) catch {
                return ParseError.MemoryAllocationFailed;
            };
            fn_node.node_variant.?.function.name.?.appendSlice(gen_name) catch {
                return ParseError.MemoryAllocationFailed;
            };

            // Mark that we're inside a function for statement parsing (`if`, `for`, `ret`, etc).
            const prev_func = self.parser_current_function;
            self.parser_current_function = fn_node;
            defer self.parser_current_function = prev_func;

            // Function scope.
            _ = try self.transpile_proc.new_scope();

            try self.expect_op("(");

            // Implicit `self` arg: `<Type>* self`
            const self_dt = self.transpile_proc.allocator.create(dtype.DataType) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(self_dt);
            self_dt.* = dtype.DataType{
                .array = null,
                .pointer_depth = 1,
                .type = .Unknown,
                .type_str = ArrayList(u8).init(self.transpile_proc.allocator),
                .flags = .{ .is_pointer = true },
                .generic_args = null,
            };
            self_dt.type_str.appendSlice(type_name.items) catch {
                return ParseError.MemoryAllocationFailed;
            };

            if (type_params) |params| {
                var gargs = utils.Vector(*dtype.DataType).init(self.transpile_proc.allocator);
                errdefer {
                    for (gargs.items()) |ga| {
                        ga.type_str.deinit();
                        self.transpile_proc.allocator.destroy(ga);
                    }
                    gargs.deinit();
                }

                for (params.items()) |p| {
                    const ga = self.transpile_proc.allocator.create(dtype.DataType) catch {
                        return ParseError.MemoryAllocationFailed;
                    };
                    errdefer self.transpile_proc.allocator.destroy(ga);
                    ga.* = dtype.DataType{
                        .array = null,
                        .pointer_depth = 0,
                        .type = .Unknown,
                        .type_str = ArrayList(u8).init(self.transpile_proc.allocator),
                        .flags = .{},
                        .generic_args = null,
                    };
                    ga.type_str.appendSlice(p.items) catch {
                        return ParseError.MemoryAllocationFailed;
                    };
                    gargs.push(ga) catch {
                        return ParseError.MemoryAllocationFailed;
                    };
                }

                self_dt.generic_args = gargs;
            }

            var self_name = ArrayList(u8).init(self.transpile_proc.allocator);
            errdefer self_name.deinit();
            self_name.appendSlice("self") catch {
                return ParseError.MemoryAllocationFailed;
            };

            const self_var_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(self_var_ptr);
            self_var_ptr.* = ast.Node{
                .type = .Variable,
                .pos = name_tok.?.pos,
                .node_variant = .{ .variable = .{ .name = self_name, .type = self_dt, .val = null } },
            };
            // Register `self` in scope for parsing identifier uses.
            const self_entity = try self.new_scope_entity(self_var_ptr, .{});
            self.transpile_proc.owned_scope_entities.append(self_entity) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer _ = self.transpile_proc.owned_scope_entities.pop();
            try self.transpile_proc.push_scope_entity(self_entity);

            var args = utils.Vector(*ast.Node).init(self.transpile_proc.allocator);
            args.push(self_var_ptr) catch {
                return ParseError.MemoryAllocationFailed;
            };

            // Parse additional explicit args (datatype name pairs), if any.
            var hist_args = utils.History.init(self.transpile_proc.allocator, .{});
            defer hist_args.deinit();
            while (!self.next_token_is_symbol(')')) {
                try self.parse_full_variable(&hist_args);
                const arg_node = self.node_pop();
                const arg_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(arg_ptr);
                arg_ptr.* = arg_node.?;
                args.push(arg_ptr) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                if (!self.next_token_is_operator(",")) break;
                _ = self.token_next();
            }
            try self.expect_sym(')');

            fn_node.node_variant.?.function.args = args;

            // Optional return type; default void.
            var rtype: dtype.DataType = .{ .type_str = ArrayList(u8).init(self.transpile_proc.allocator) };
            const rtok = self.token_peek_next();
            if (rtok != null and ((rtok.?.type == .Keyword and utils.keyword_is_datatype(rtok.?.data.sval.items)) or rtok.?.type == .Identifier)) {
                try self.parse_datatype(&rtype);
                fn_node.node_variant.?.function.rtype = rtype;
            }

            // Body
            if (self.next_token_is_symbol('{')) {
                var hist_body = utils.History.init(self.transpile_proc.allocator, .{ .inside_function_body = true });
                defer hist_body.deinit();
                try self.parse_body(&hist_body);
                const body_node = self.node_pop();
                const body_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(body_ptr);
                body_ptr.* = body_node.?;
                fn_node.node_variant.?.function.body = body_ptr;
            } else {
                try self.expect_sym(';');
            }

            // End function scope opened above.
            self.transpile_proc.finish_scope();

            const fn_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(fn_ptr);
            fn_ptr.* = fn_node;
            methods.push(fn_ptr) catch {
                return ParseError.MemoryAllocationFailed;
            };
        }

        try self.expect_sym('}');

        const node = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer {
            self.transpile_proc.deinit_node(node.*);
            self.transpile_proc.allocator.destroy(node);
        }
        node.* = ast.Node{
            .type = .Impl,
            .pos = type_tok.?.pos,
            .flags = .{ .is_public = is_public },
            .node_variant = .{ .impl = .{ .type_name = type_name, .type_params = type_params, .type_param_forced_insts = type_param_forced_insts, .quirk_name = quirk_name, .methods = methods } },
        };

        self.transpile_proc.nodes.push(node.*) catch {
            return ParseError.MemoryAllocationFailed;
        };
        self.transpile_proc.owned_nodes.append(node) catch {
            return ParseError.MemoryAllocationFailed;
        };
    }

    /// Parses multiple expressionable tokens.
    ///
    /// This function continues to parse tokens until no more expressionable tokens
    /// are found.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    fn parse_expressionable(self: *Self, hist: *utils.History) ParseError!void {
        while (try self.parse_expressionable_single(hist)) {}
    }

    /// Parses the root of an expressionable token.
    ///
    /// This function parses expressionable tokens and adds the resulting node
    /// to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    fn parse_expressionable_root(self: *Self, hist: *utils.History) ParseError!void {
        try self.parse_expressionable(hist);
        const n = self.node_pop() orelse {
            self.transpile_proc.err("expected expression", .{});
            return ParseError.InvalidExpression;
        };
        self.transpile_proc.nodes.push(n) catch {
            return ParseError.MemoryAllocationFailed;
        };
    }

    /// Parses array brackets.
    ///
    /// This function processes array bracket tokens, updating the datatype with
    /// array information and adding bracket nodes to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `dt`: A pointer to the datatype being parsed.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_array_brackets(self: *Self, dt: *dtype.DataType, hist: *utils.History) ParseError!void {
        var brackets = utils.Vector(ast.Node).init(self.transpile_proc.allocator);
        var depth: usize = 0;
        while (self.next_token_is_operator("[")) {
            const lbracket_token = self.token_peek_next();
            try self.expect_op("[");
            dt.*.flags.?.is_array = true;
            depth += 1;
            if (self.next_token_is_symbol(']')) {
                try self.expect_sym(']');
                continue;
            }
            try self.parse_expressionable_root(hist);
            try self.expect_sym(']');
            const exp_node = self.node_pop();
            const exp = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(exp);
            exp.* = exp_node.?;
            self.transpile_proc.nodes.push(ast.Node{
                .type = .Bracket,
                .pos = if (lbracket_token) |t| t.pos else null,
                .node_variant = .{ .bracket = .{ .inner = exp } },
            }) catch {
                return ParseError.MemoryAllocationFailed;
            };
            const bracket_node = self.node_pop();
            brackets.push(bracket_node.?) catch {
                return ParseError.MemoryAllocationFailed;
            };
        }
        dt.*.array_depth = depth;
        if (brackets.count > 0) {
            dt.*.array = .{ .brackets = brackets };
        }
    }

    /// Parses a variable declaration.
    ///
    /// This function processes variable declaration tokens, including array brackets
    /// and assignment. It adds the variable node to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `dt`: A pointer to the datatype being parsed.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_variable(self: *Self, dt: *dtype.DataType, hist: *utils.History, is_public: bool, require_initializer: bool) ParseError!void {
        if (self.next_token_is_operator("[")) {
            try self.parse_array_brackets(dt, hist);
        }
        const ident_token = self.token_next();
        if (ident_token == null or ident_token.?.type != .Identifier) {
            self.transpile_proc.err("expected indentifier", .{});
            return ParseError.InvalidIdentifier;
        }

        // Variable nodes own their name string (and deinit it). Token strings are also deinitialized
        // by `TranspileProcess.deinit()`, so we must deep-copy here to avoid double-free.
        var name = ArrayList(u8).initCapacity(self.transpile_proc.allocator, ident_token.?.data.sval.items.len) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer name.deinit();
        name.appendSlice(ident_token.?.data.sval.items) catch {
            return ParseError.MemoryAllocationFailed;
        };
        var value_node: ?ast.Node = null;
        const has_value = self.next_token_is_operator("=");
        if (!has_value and require_initializer) {
            self.transpile_proc.err("'let' declarations require an initializer", .{});
            return ParseError.InvalidStatement;
        }
        if (has_value) {
            _ = self.token_next(); // skip =
            // Stop the value expression at a TOP-LEVEL comma so a function PARAMETER
            // default (`fun f(num b = 2, num c = 3)`) terminates at the param-separator
            // `,` rather than greedily consuming the next parameter. Commas inside nested
            // `(...)`/`[...]` are NOT terminators — `parse_for_parenthesis`/bracket
            // parsing clear this flag — so call/array defaults (`= f(a, b)`) parse fully.
            // Harmless for `let`/var decls (a top-level comma after the value is invalid).
            var val_hist = utils.History.down(self.transpile_proc.allocator, hist, hist.flags);
            val_hist.flags.stop_at_comma = true;
            try self.parse_expressionable_root(&val_hist);
            value_node = self.node_pop();
            const val = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(val);
            val.* = value_node.?;
            const node = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer {
                self.transpile_proc.deinit_node(node.*);
                self.transpile_proc.allocator.destroy(node);
            }
            node.* = ast.Node{
                .type = .Variable,
                .pos = ident_token.?.pos,
                .flags = if (is_public) .{ .is_public = true } else null,
                .node_variant = .{
                    .variable = .{
                        .name = name,
                        .type = dt,
                        .val = val,
                    },
                },
            };
            // Ownership of `name` transferred to the node.
            name = ArrayList(u8).init(self.transpile_proc.allocator);
            const scope_entity = try self.new_scope_entity(node, .{});
            if (self.transpile_proc.get_scope_entity(scope_entity.name) != null) {
                self.transpile_proc.err("variable '{s}' already declared", .{scope_entity.name});
                return ParseError.VariableAlreadyDeclared;
            }
            self.transpile_proc.nodes.push(node.*) catch {
                return ParseError.MemoryAllocationFailed;
            };
            self.transpile_proc.owned_nodes.append(node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer _ = self.transpile_proc.owned_nodes.pop();
            self.transpile_proc.owned_scope_entities.append(scope_entity) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer _ = self.transpile_proc.owned_scope_entities.pop();
            try self.transpile_proc.push_scope_entity(scope_entity);
        } else {
            const node = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer {
                self.transpile_proc.deinit_node(node.*);
                self.transpile_proc.allocator.destroy(node);
            }
            node.* = ast.Node{
                .type = .Variable,
                .pos = ident_token.?.pos,
                .flags = if (is_public) .{ .is_public = true } else null,
                .node_variant = .{
                    .variable = .{
                        .name = name,
                        .type = dt,
                    },
                },
            };
            // Ownership of `name` transferred to the node.
            name = ArrayList(u8).init(self.transpile_proc.allocator);
            const scope_entity = try self.new_scope_entity(node, .{});
            self.transpile_proc.nodes.push(node.*) catch {
                return ParseError.MemoryAllocationFailed;
            };
            self.transpile_proc.owned_nodes.append(node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer _ = self.transpile_proc.owned_nodes.pop();
            self.transpile_proc.owned_scope_entities.append(scope_entity) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer _ = self.transpile_proc.owned_scope_entities.pop();
            try self.transpile_proc.push_scope_entity(scope_entity);
        }
    }

    /// Parses a full variable declaration.
    ///
    /// This function processes the datatype and the variable declaration,
    /// adding the variable node to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    fn parse_full_variable(self: *Self, hist: *utils.History) ParseError!void {
        const dt = self.transpile_proc.allocator.create(dtype.DataType) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(dt);
        dt.* = dtype.DataType{
            .array = null,
            .pointer_depth = 0,
            .type = .Unknown,
            .type_str = ArrayList(u8).init(self.transpile_proc.allocator),
            .flags = .{},
        };
        try self.parse_datatype(dt);
        try self.parse_variable(dt, hist, false, false);
    }

    fn parse_let_declaration(self: *Self, hist: *utils.History, is_public: bool) ParseError!void {
        const let_token = self.token_next();
        if (let_token == null or let_token.?.type != .Keyword or !mem.eql(u8, let_token.?.data.sval.items, "let")) {
            self.transpile_proc.err("expected keyword 'let'", .{});
            return ParseError.InvalidKeyword;
        }

        const dt = self.transpile_proc.allocator.create(dtype.DataType) catch {
            return ParseError.MemoryAllocationFailed;
        };
        dt.* = dtype.DataType{
            .array = null,
            .pointer_depth = 0,
            .type = .Unknown,
            .type_str = ArrayList(u8).init(self.transpile_proc.allocator),
            .flags = .{},
        };
        dt.*.type_str.appendSlice("__let_infer__") catch {
            return ParseError.MemoryAllocationFailed;
        };

        try self.parse_variable(dt, hist, is_public, true);
        try self.expect_sym(';');
    }

    /// Parses function arguments.
    ///
    /// This function processes tokens representing function arguments,
    /// including handling of variadic arguments.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    const ParsedFunctionArgs = struct {
        args: utils.Vector(*ast.Node),
        is_variadic: bool,
    };

    /// Returns:
    /// - `ParsedFunctionArgs`: Parsed argument nodes and a variadic flag.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    fn parse_function_args(self: *Self, hist: *utils.History) ParseError!ParsedFunctionArgs {
        var args = utils.Vector(*ast.Node).init(self.transpile_proc.allocator);
        var is_variadic = false;
        while (!self.next_token_is_symbol(')')) {
            if (self.next_token_is_operator("...")) { // variadic
                _ = self.token_next();
                is_variadic = true;
                break;
            }
            try self.parse_full_variable(hist);
            const arg_node = self.node_pop();
            if (arg_node == null) {
                self.transpile_proc.err("expected argument", .{});
                return ParseError.InvalidIdentifier;
            }
            const arg = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(arg);
            arg.* = arg_node.?;
            args.push(arg) catch {
                return ParseError.MemoryAllocationFailed;
            };
            if (!self.next_token_is_operator(",")) {
                break;
            }
            _ = self.token_next(); // skip ,
        }
        return .{ .args = args, .is_variadic = is_variadic };
    }

    /// Parses a function declaration.
    ///
    /// This function expects the 'fun' keyword, followed by the function's name, arguments,
    /// return type, and body. It creates a function node and adds it to the list of nodes
    /// to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_function(self: *Self, is_public: bool, is_async: bool) ParseError!void {
        _ = try self.transpile_proc.new_scope();
        errdefer self.transpile_proc.finish_scope();
        _ = self.token_next(); // skip fun
        var function_node = ast.Node{
            .type = .Function,
            // Set once we read the function name token.
            .pos = self.*.transpile_proc.*.pos,
            .flags = .{ .is_public = is_public },
            .node_variant = .{ .function = .{ .is_async = is_async } },
        };
        // Initialize `dt` so optional fields are well-defined before `parse_datatype()`.
        // `parse_datatype()` will set `type`/`flags` and overwrite `type_str`.
        var dt: dtype.DataType = .{ .type_str = ArrayList(u8).init(self.transpile_proc.allocator) };
        const ident_token = self.token_next();
        if (ident_token == null) {
            self.transpile_proc.err("expected identifier after 'fun'", .{});
            return ParseError.InvalidIdentifier;
        }
        if (ident_token.?.type != .Identifier) {
            self.transpile_proc.err("expected indentifier, got '{}'", .{ident_token.?.type});
            return ParseError.InvalidIdentifier;
        }
        // Prefer pointing at the identifier for diagnostics and tooling.
        function_node.pos = ident_token.?.pos;
        // Function nodes must own their name buffer. Token sval buffers are owned by the token stream
        // and are deinitialized in `TranspileProcess.deinit()`.
        var fname = ArrayList(u8).initCapacity(self.transpile_proc.allocator, ident_token.?.data.sval.items.len) catch {
            return ParseError.MemoryAllocationFailed;
        };
        // `fname` is allocated from the transpiler arena allocator; on parse errors we rely
        // on arena teardown for cleanup instead of deinit during unwinding (which can be
        // fragile when parsing invalid/incomplete input).
        fname.appendSlice(ident_token.?.data.sval.items) catch {
            return ParseError.MemoryAllocationFailed;
        };
        function_node.node_variant.?.function.name = fname;
        self.parser_current_function = function_node;
        {
            const parsed_tp = try self.parse_impl_type_params_with_constraints();
            function_node.node_variant.?.function.type_params = parsed_tp.params;
            // Constraints (forced_insts) are only relevant for eager impl-method
            // instantiation; generic free functions are monomorphized lazily from
            // call sites, so the constraint set is used solely for validation and
            // can be discarded here.
        }
        try self.expect_op("(");
        var hist_args = utils.History.init(self.transpile_proc.allocator, .{});
        defer hist_args.deinit();
        const parsed_args = try self.parse_function_args(&hist_args);
        try self.expect_sym(')');
        function_node.node_variant.?.function.args = parsed_args.args;
        function_node.node_variant.?.function.is_variadic = parsed_args.is_variadic;

        if (parsed_args.is_variadic) {
            const vnode = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(vnode);
            vnode.* = ast.Node{
                .type = .Variable,
                .pos = function_node.pos,
                .node_variant = .{
                    .variable = .{
                        .name = blk: {
                            var name = ArrayList(u8).init(self.transpile_proc.allocator);
                            name.appendSlice("vargs") catch {
                                return ParseError.MemoryAllocationFailed;
                            };
                            break :blk name;
                        },
                        .type = blk: {
                            const vdt = self.transpile_proc.allocator.create(dtype.DataType) catch {
                                return ParseError.MemoryAllocationFailed;
                            };
                            vdt.* = .{ .type_str = ArrayList(u8).init(self.transpile_proc.allocator) };
                            vdt.type = .Unknown;
                            vdt.type_str.appendSlice("Vec") catch {
                                return ParseError.MemoryAllocationFailed;
                            };
                            break :blk vdt;
                        },
                    },
                },
            };

            const scope_entity = try self.new_scope_entity(vnode, .{});
            self.transpile_proc.owned_nodes.append(vnode) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer _ = self.transpile_proc.owned_nodes.pop();
            self.transpile_proc.owned_scope_entities.append(scope_entity) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer _ = self.transpile_proc.owned_scope_entities.pop();
            try self.transpile_proc.push_scope_entity(scope_entity);
        }
        const rtype_token = self.token_peek_next();
        if (rtype_token != null and ((rtype_token.?.type == .Keyword and utils.keyword_is_datatype(rtype_token.?.data.sval.items)) or rtype_token.?.type == .Identifier)) {
            try self.parse_datatype(&dt);
        } else {
            var type_str = ArrayList(u8).init(self.transpile_proc.allocator);
            type_str.appendSlice("void") catch {
                return ParseError.MemoryAllocationFailed;
            };
            dt = dtype.DataType{
                .type = .Void,
                .type_str = type_str,
            };
        }
        function_node.node_variant.?.function.rtype = dt;
        try self.transpile_proc.register_global_node_symbol(function_node);
        if (self.next_token_is_symbol('{')) {
            var hist_body = utils.History.init(self.transpile_proc.allocator, .{ .inside_function_body = true });
            defer hist_body.deinit();
            try self.parse_body(&hist_body);
            const body_node = self.node_pop();
            if (body_node == null) {
                self.transpile_proc.err("expected function body", .{});
                return ParseError.InvalidStatement;
            }
            const body = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(body);
            body.* = body_node.?;
            function_node.node_variant.?.function.body = body;
        } else {
            try self.expect_sym(';');
        }
        self.parser_current_function = null;
        self.transpile_proc.nodes.push(function_node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        self.transpile_proc.finish_scope();
    }

    /// Parses a return statement.
    ///
    /// This function expects the 'ret' keyword, followed by an optional expression, and a semicolon.
    /// It creates a return statement node and adds it to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_return(self: *Self, hist: *utils.History) ParseError!void {
        const ret_token = self.token_peek_next();
        _ = self.token_next(); // skip ret
        if (self.next_token_is_symbol(';')) {
            try self.expect_sym(';');
            self.transpile_proc.nodes.push(ast.Node{
                .type = .StatementReturn,
                .pos = if (ret_token) |t| t.pos else null,
            }) catch {
                return ParseError.MemoryAllocationFailed;
            };
            return;
        }
        try self.parse_expressionable_root(hist);
        const exp_node = self.node_pop();
        const exp = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(exp);
        exp.* = exp_node.?;
        self.transpile_proc.nodes.push(ast.Node{
            .type = .StatementReturn,
            .pos = if (ret_token) |t| t.pos else null,
            .node_variant = .{ .statement = .{ .return_stmt = exp } },
        }) catch {
            return ParseError.MemoryAllocationFailed;
        };
        try self.expect_sym(';');
    }

    /// Parses an elif statement.
    ///
    /// This function expects the 'elif' keyword, followed by a condition expression and a body.
    /// It creates an elif statement node and adds it to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_elif_statement(self: *Self, hist: *utils.History) ParseError!void {
        if (self.next_token_is_keyword("elif")) {
            const elif_token = self.token_peek_next();
            if (self.parser_current_function == null) {
                self.transpile_proc.err("elif statement outside of function", .{});
                return ParseError.InvalidStatement;
            }
            _ = self.token_next(); // skip elif

            // Parse condition. If written as `elif (cond) ...`, do not let the condition
            // parse consume the following statement tokens.
            var condition_node: ?ast.Node = null;
            if (self.next_token_is_operator("(")) {
                try self.expect_op("(");
                try self.parse_expressionable_root(hist);
                condition_node = self.node_pop();
                try self.expect_sym(')');
            } else {
                try self.parse_expressionable_root(hist);
                condition_node = self.node_pop();
            }
            if (condition_node.?.type == .Expression and mem.eql(u8, condition_node.?.node_variant.?.exp.op, "=")) {
                self.transpile_proc.err("expected expression, got assignment", .{});
                return ParseError.InvalidExpression;
            }
            const condition = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(condition);
            condition.* = condition_node.?;

            // Body can be a block `{ ... }` or a single statement.
            var body_ptr: *ast.Node = undefined;
            if (self.next_token_is_symbol('{')) {
                try self.parse_body(hist);
                const body_node = self.node_pop();
                body_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(body_ptr);
                body_ptr.* = body_node.?;
            } else {
                var hist_down = utils.History.down(self.transpile_proc.allocator, hist, hist.flags);
                defer hist_down.deinit();
                try self.parse_statement(&hist_down);
                const stmt_node = self.node_pop();
                body_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(body_ptr);
                body_ptr.* = stmt_node.?;
            }
            var elif_node = ast.Node{
                .type = .StatementElseIf,
                .pos = if (elif_token) |t| t.pos else null,
                .node_variant = .{ .statement = .{ .elif_stmt = .{ .condition = condition, .body = body_ptr } } },
            };
            try self.create_node(&elif_node);
        }
    }

    /// Parses an else statement.
    ///
    /// This function expects the 'else' keyword followed by a body. It creates an else statement
    /// node and adds it to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_else_statement(self: *Self, hist: *utils.History) ParseError!void {
        if (self.next_token_is_keyword("else")) {
            const else_token = self.token_peek_next();
            if (self.parser_current_function == null) {
                self.transpile_proc.err("else statement outside of function", .{});
                return ParseError.InvalidStatement;
            }
            _ = self.token_next(); // skip else

            // Body can be a block `{ ... }` or a single statement.
            var body_ptr: *ast.Node = undefined;
            if (self.next_token_is_symbol('{')) {
                try self.parse_body(hist);
                const body_node = self.node_pop();
                body_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(body_ptr);
                body_ptr.* = body_node.?;
            } else {
                var hist_down = utils.History.down(self.transpile_proc.allocator, hist, hist.flags);
                defer hist_down.deinit();
                try self.parse_statement(&hist_down);
                const stmt_node = self.node_pop();
                body_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(body_ptr);
                body_ptr.* = stmt_node.?;
            }
            var else_node = ast.Node{
                .type = .StatementElse,
                .pos = if (else_token) |t| t.pos else null,
                .node_variant = .{ .statement = .{ .else_stmt = .{ .body = body_ptr } } },
            };
            try self.create_node(&else_node);
        }
    }

    /// Parses an if statement.
    ///
    /// This function expects the 'if' keyword, followed by a condition expression, a body,
    /// and optionally elif and else clauses. It creates an if statement node and adds it to
    /// the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_if_statement(self: *Self, hist: *utils.History) ParseError!void {
        const if_token = self.token_peek_next();
        try self.expect_keyword("if");
        if (self.parser_current_function == null) {
            self.transpile_proc.err("if statement outside of function", .{});
            return ParseError.InvalidStatement;
        }

        // Parse condition. If written as `if (cond) ...`, do not let the condition
        // parse consume the following statement tokens.
        var condition_node: ?ast.Node = null;
        if (self.next_token_is_operator("(")) {
            try self.expect_op("(");
            try self.parse_expressionable_root(hist);
            condition_node = self.node_pop();
            try self.expect_sym(')');
        } else {
            try self.parse_expressionable_root(hist);
            condition_node = self.node_pop();
        }
        if (condition_node.?.type == .Expression and mem.eql(u8, condition_node.?.node_variant.?.exp.op, "=")) {
            self.transpile_proc.err("expected expression, got assignment", .{});
            return ParseError.InvalidExpression;
        }
        const condition = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(condition);
        condition.* = condition_node.?;

        // Body can be a block `{ ... }` or a single statement.
        var body_ptr: *ast.Node = undefined;
        if (self.next_token_is_symbol('{')) {
            try self.parse_body(hist);
            const body_node = self.node_pop();
            body_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(body_ptr);
            body_ptr.* = body_node.?;
        } else {
            var hist_down = utils.History.down(self.transpile_proc.allocator, hist, hist.flags);
            defer hist_down.deinit();
            try self.parse_statement(&hist_down);
            const stmt_node = self.node_pop();
            body_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(body_ptr);
            body_ptr.* = stmt_node.?;
        }
        const if_node = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(if_node);
        defer self.transpile_proc.allocator.destroy(if_node);
        if_node.* = ast.Node{
            .type = .StatementIf,
            .pos = if (if_token) |t| t.pos else null,
            .node_variant = .{
                .statement = .{
                    .if_stmt = .{ .condition = condition, .body = body_ptr },
                },
            },
        };
        try self.create_node(if_node);
    }

    /// Parses the body of a fit statement.
    ///
    /// This function expects the body of a fit statement, starting with '{' and ending with '}'.
    /// It processes each branch within the body and adds it to the fit_node.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `fit_node`: A pointer to the fit statement node.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    /// Flatten a fit-arm destructuring argument list into positional binding names.
    /// `args` is the call's argument node: either a single identifier (`r`), or a
    /// comma expression tree (`w, h`). Each leaf must be a plain identifier; if any
    /// leaf is something else, sets `ok.* = false` (so the caller treats the arm as
    /// a non-destructuring pattern rather than a binding).
    fn collect_fit_binding_names(self: *Self, args: *ast.Node, out: *utils.Vector(ArrayList(u8)), ok: *bool) ParseError!void {
        if (args.type == .Expression and args.node_variant != null and
            mem.eql(u8, args.node_variant.?.exp.op, ","))
        {
            const cexp = args.node_variant.?.exp;
            if (cexp.left) |l| try self.collect_fit_binding_names(l, out, ok);
            if (cexp.right) |r| try self.collect_fit_binding_names(r, out, ok);
            return;
        }
        if (args.type == .Identifier and args.data != null) {
            var name = ArrayList(u8).init(self.transpile_proc.allocator);
            name.appendSlice(args.data.?.sval.items) catch return ParseError.MemoryAllocationFailed;
            out.push(name) catch return ParseError.MemoryAllocationFailed;
            return;
        }
        ok.* = false;
    }

    /// Try to parse a data-carrying-enum destructuring fit pattern at the cursor:
    ///   `Enum.Variant(a, b)`  or shorthand  `.Variant(a, b)`
    /// On a match, consumes those tokens, sets `condition_out` to the variant-path
    /// `.` expression (`Enum.Variant`, or `<blank>.Variant` for shorthand), fills
    /// `bindings_out` with the positional binding identifiers, and returns true. On
    /// no match, consumes NOTHING and returns false (caller parses normally).
    /// Detection requires the trailing `(` so a plain `Enum.Variant` arm (no
    /// payload binding) still goes through the ordinary path.
    fn try_parse_fit_destructure(self: *Self, condition_out: *?ast.Node, bindings_out: *?utils.Vector(ArrayList(u8))) ParseError!bool {
        // Two shapes, distinguished by lookahead of the significant tokens:
        //   shorthand:  . Ident (        -> peek(0)='.', peek(1)=Ident, peek(2)='('
        //   qualified:  Ident . Ident (  -> peek(0)=Ident, peek(1)='.', peek(2)=Ident, peek(3)='('
        const p0 = self.token_peek_n(0);
        const p1 = self.token_peek_n(1);
        if (p0 == null or p1 == null) return false;

        const is_op = struct {
            fn f(tk: ?token.Token, s: []const u8) bool {
                return tk != null and tk.?.type == .Operator and mem.eql(u8, tk.?.data.sval.items, s);
            }
        }.f;

        var is_shorthand = false;
        var enum_tok: ?token.Token = null;
        var variant_tok: ?token.Token = null;

        if (is_op(p0, ".") and p1.?.type == .Identifier) {
            // `.Variant(` ?
            if (!is_op(self.token_peek_n(2), "(")) return false;
            is_shorthand = true;
            variant_tok = p1;
        } else if (p0.?.type == .Identifier and is_op(p1, ".")) {
            const p2 = self.token_peek_n(2);
            if (p2 == null or p2.?.type != .Identifier) return false;
            if (!is_op(self.token_peek_n(3), "(")) return false;
            enum_tok = p0;
            variant_tok = p2;
        } else {
            return false;
        }

        // Commit: consume the path tokens.
        if (is_shorthand) {
            _ = self.token_next(); // '.'
            _ = self.token_next(); // Variant
        } else {
            _ = self.token_next(); // Enum
            _ = self.token_next(); // '.'
            _ = self.token_next(); // Variant
        }
        _ = self.token_next(); // '('

        // Collect binding identifiers until ')'.
        var binds = utils.Vector(ArrayList(u8)).init(self.transpile_proc.allocator);
        errdefer binds.deinit();
        while (!self.next_token_is_symbol(')')) {
            const bt = self.token_next();
            if (bt == null or bt.?.type != .Identifier) {
                self.transpile_proc.err("expected binding name in fit destructuring pattern", .{});
                return ParseError.InvalidIdentifier;
            }
            var bn = ArrayList(u8).init(self.transpile_proc.allocator);
            bn.appendSlice(bt.?.data.sval.items) catch return ParseError.MemoryAllocationFailed;
            binds.push(bn) catch return ParseError.MemoryAllocationFailed;
            if (self.next_token_is_operator(",")) {
                _ = self.token_next();
                continue;
            }
            break;
        }
        if (!self.next_token_is_symbol(')')) {
            self.transpile_proc.err("expected ')' to close fit destructuring pattern", .{});
            return ParseError.InvalidToken;
        }
        _ = self.token_next(); // ')'
        if (binds.count == 0) {
            self.transpile_proc.err("fit destructuring pattern '()' must bind at least one field", .{});
            return ParseError.InvalidToken;
        }

        // Build the variant-path `.` expression: left = Enum ident (or Blank for
        // shorthand), right = Variant ident.
        const vpos = variant_tok.?.pos;
        var right_node = ast.Node{ .type = .Identifier, .pos = vpos, .data = .{ .sval = variant_tok.?.data.sval } };
        right_node.flags = .{ .inside_expression = true };
        var left_node: ast.Node = undefined;
        if (is_shorthand) {
            left_node = .{ .type = .Blank, .pos = vpos };
        } else {
            left_node = .{ .type = .Identifier, .pos = enum_tok.?.pos, .data = .{ .sval = enum_tok.?.data.sval } };
        }
        left_node.flags = .{ .inside_expression = true };
        try self.make_expression_node(&left_node, &right_node, ".", vpos);
        const exp_node = self.node_pop() orelse {
            self.transpile_proc.err("failed to build fit destructuring variant path", .{});
            return ParseError.InvalidExpression;
        };

        condition_out.* = exp_node;
        bindings_out.* = binds;
        return true;
    }

    fn parse_fit_body(self: *Self, fit_node: *ast.Node, hist: *utils.History) ParseError!void {
        try self.expect_sym('{');
        fit_node.*.node_variant.?.statement.fit_stmt.branches = utils.Vector(ast.FitBranch).init(self.transpile_proc.allocator);
        while (!self.next_token_is_symbol('}')) {
            var hist_down = utils.History.down(self.transpile_proc.allocator, hist, hist.flags);
            defer hist_down.deinit();
            var condition_node: ?ast.Node = null;
            var manual_bindings: ?utils.Vector(ArrayList(u8)) = null;
            // Relax the unknown-identifier check while parsing the arm condition so
            // a destructuring pattern's new binding names (`Variant(x, y)`) don't
            // trip it; they're registered + validated immediately after.
            const prev_in_fit_cond = self.in_fit_condition;
            self.in_fit_condition = true;

            // Destructuring pattern: `Enum.Variant(a, b)` or shorthand `.Variant(a, b)`.
            // Detect via lookahead and parse the variant path + binding names by hand
            // (the general expression parser doesn't carry a member-call cleanly here).
            if (try self.try_parse_fit_destructure(&condition_node, &manual_bindings)) {
                // condition_node + manual_bindings are set; fall through to '->'.
                self.in_fit_condition = prev_in_fit_cond;
            } else {
                // Always allow dot operator as fit branch pattern root.
                const t = self.token_peek_next();
                if (t != null and t.?.type == .Operator and mem.eql(u8, t.?.data.sval.items, ".")) {
                    // Directly parse `.Variant` as fit branch pattern, bypassing normal root logic.
                    _ = self.token_next(); // skip '.'
                    _ = try self.parse_identifier();
                    var node_right = self.node_pop() orelse {
                        self.in_fit_condition = prev_in_fit_cond;
                        self.transpile_proc.err("expected identifier after '.' in fit pattern", .{});
                        return ParseError.InvalidExpression;
                    };
                    node_right.flags = .{ .inside_expression = true };
                    var blank_left: ast.Node = .{ .type = .Blank, .pos = t.?.pos };
                    blank_left.flags = .{ .inside_expression = true };
                    try self.make_expression_node(&blank_left, &node_right, ".", t.?.pos);
                    var exp_node = self.node_pop() orelse {
                        self.in_fit_condition = prev_in_fit_cond;
                        self.transpile_proc.err("expected fit branch condition expression", .{});
                        return ParseError.InvalidExpression;
                    };
                    try self.parse_reorder_expression(&exp_node);
                    condition_node = exp_node;
                } else {
                    // If not dot, use normal root logic.
                    try self.parse_expressionable_root(&hist_down);
                    condition_node = self.node_pop() orelse {
                        self.in_fit_condition = prev_in_fit_cond;
                        self.transpile_proc.err("expected fit branch condition expression", .{});
                        return ParseError.InvalidExpression;
                    };
                }
                self.in_fit_condition = prev_in_fit_cond;
            } // end non-destructuring condition parse
            if (condition_node.?.type == .Expression and mem.eql(u8, condition_node.?.node_variant.?.exp.op, "=")) {
                self.transpile_proc.err("expected expression, got assignment", .{});
                return ParseError.InvalidExpression;
            }
            if (condition_node.?.type == .Identifier and mem.eql(u8, condition_node.?.data.?.sval.items, "_")) {
                // `_` is a special wildcard for the default branch. The parsed identifier node
                // is not part of the resulting AST (condition=null), so we must free it now.
                self.transpile_proc.deinit_node(condition_node.?);
                // default case after should be the last branch
                try self.expect_op("->");
                try self.parse_body(&hist_down);
                const body_node = self.node_pop();
                const body = self.transpile_proc.allocator.create(ast.Node) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(body);
                body.* = body_node.?;
                fit_node.*.node_variant.?.statement.fit_stmt.branches.push(.{ .body = body, .condition = null }) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                if (self.next_token_is_operator(",")) {
                    _ = self.token_next(); // skip ,
                }
                break;
            }

            const condition = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(condition);
            condition.* = condition_node.?;

            // Destructuring binding names captured by `try_parse_fit_destructure`
            // (the condition is already the bare variant path at this point).
            const bindings: ?utils.Vector(ArrayList(u8)) = manual_bindings;

            try self.expect_op("->");
            // Register destructuring binding names in a scope so the arm body can
            // reference them at parse time (identifier resolution checks scope). The
            // scope is opened here and closed after the body is parsed, so bindings
            // don't leak to sibling arms or past the fit.
            const has_binds = bindings != null and bindings.?.count > 0;
            if (has_binds) {
                _ = try self.transpile_proc.new_scope();
                for (bindings.?.items()) |bname| {
                    var bn = ArrayList(u8).init(self.transpile_proc.allocator);
                    bn.appendSlice(bname.items) catch return ParseError.MemoryAllocationFailed;
                    const bvar = self.transpile_proc.allocator.create(ast.Node) catch {
                        return ParseError.MemoryAllocationFailed;
                    };
                    const bdt = self.transpile_proc.allocator.create(dtype.DataType) catch {
                        return ParseError.MemoryAllocationFailed;
                    };
                    bdt.* = dtype.DataType{
                        .array = null,
                        .pointer_depth = 0,
                        .type = .Unknown,
                        .type_str = ArrayList(u8).init(self.transpile_proc.allocator),
                        .flags = .{},
                    };
                    bvar.* = ast.Node{
                        .type = .Variable,
                        .pos = condition.*.pos,
                        .node_variant = .{ .variable = .{ .name = bn, .type = bdt, .val = null } },
                    };
                    const bentity = try self.new_scope_entity(bvar, .{});
                    self.transpile_proc.owned_scope_entities.append(bentity) catch {
                        return ParseError.MemoryAllocationFailed;
                    };
                    try self.transpile_proc.push_scope_entity(bentity);
                }
            }
            try self.parse_body(&hist_down);
            if (has_binds) self.transpile_proc.finish_scope();
            const body_node = self.node_pop();
            const body = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(body);
            body.* = body_node.?;
            fit_node.*.node_variant.?.statement.fit_stmt.branches.push(.{ .body = body, .condition = condition, .bindings = bindings }) catch {
                return ParseError.MemoryAllocationFailed;
            };
            if (self.next_token_is_operator(",")) {
                _ = self.token_next(); // skip ,
            }
        }
        try self.expect_sym('}');
    }

    /// Parses a fit statement.
    ///
    /// This function expects the 'fit' keyword followed by an expression and a body.
    /// It creates a new fit statement node and adds it to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    /// - `hist`: A pointer to the history of parsing operations.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_fit_statement(self: *Self, hist: *utils.History) ParseError!void {
        const fit_token = self.token_peek_next();
        var fit_node: ast.Node = .{
            .type = .StatementFit,
            .pos = if (fit_token) |t| t.pos else null,
            .node_variant = .{
                .statement = .{ .fit_stmt = undefined },
            },
        };
        try self.expect_keyword("fit");
        // Preserve ambient parsing context (notably inside_function_body) while
        // enabling fit-specific parsing behavior.
        var new_hist = utils.History.down(self.transpile_proc.allocator, hist, .{ .in_fit_statement = true });
        defer new_hist.deinit();
        try self.parse_expressionable_root(&new_hist);
        const condition_node = self.node_pop();
        const condition = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(condition);
        condition.* = condition_node.?;
        if (condition_node.?.type == .Expression) {
            condition.*.node_variant.?.exp.left = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(condition.*.node_variant.?.exp.left.?);
            condition.*.node_variant.?.exp.left.?.* = condition_node.?.node_variant.?.exp.left.?.*;
            condition.*.node_variant.?.exp.right = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(condition.*.node_variant.?.exp.right.?);
            condition.*.node_variant.?.exp.right.?.* = condition_node.?.node_variant.?.exp.right.?.*;
            condition.*.node_variant.?.exp.op = condition_node.?.node_variant.?.exp.op;
        }
        fit_node.node_variant.?.statement.fit_stmt.exp = condition;
        try self.parse_fit_body(&fit_node, &new_hist);
        self.transpile_proc.nodes.push(fit_node) catch {
            return ParseError.MemoryAllocationFailed;
        };
    }

    /// Parses an import statement.
    ///
    /// This function expects an import statement, retrieves the folder and file identifiers,
    /// and adds the import node to the list of nodes to be transpiled.
    ///
    /// Parameters:
    /// - `self`: A pointer to the current parser instance.
    ///
    /// Errors:
    /// - Returns an error if any parsing operation fails.
    /// - Logs an error message if any expected token is not found.
    fn parse_import(self: *Self) ParseError!void {
        _ = self.token_next(); // skip imp
        // Support parent traversal via leading dots, e.g. `imp ..defs.user;`.
        // Each pair of leading dots (`..`) means "go up one directory".
        const isDotRunOperator = struct {
            fn call(t: token.Token) bool {
                if (t.type != .Operator) return false;
                const s = t.data.sval.items;
                if (s.len == 0) return false;
                for (s) |ch| if (ch != '.') return false;
                return true;
            }
        }.call;

        var leading_dots: usize = 0;
        while (true) {
            const t = self.token_peek_next() orelse break;
            if (!isDotRunOperator(t)) break;
            _ = self.token_next();
            leading_dots += t.data.sval.items.len;
        }
        if (leading_dots % 2 != 0) {
            self.transpile_proc.err("invalid import path: expected '.' after '.'", .{});
            return ParseError.InvalidIdentifier;
        }

        const folder_token = self.token_next();
        if (folder_token == null) {
            self.transpile_proc.err("expected folder identifier after import", .{});
            return ParseError.InvalidIdentifier;
        }
        if (folder_token.?.type != .Identifier) {
            self.transpile_proc.err("expected folder identifier, got '{s}'", .{@tagName(folder_token.?.type)});
            return ParseError.InvalidIdentifier;
        }

        const import_pos = folder_token.?.pos;

        var import_name = ArrayList(u8).init(self.transpile_proc.allocator);
        defer import_name.deinit();
        if (leading_dots > 0) {
            import_name.appendNTimes('.', leading_dots) catch {
                return ParseError.MemoryAllocationFailed;
            };
        }
        import_name.appendSlice(folder_token.?.data.sval.items) catch {
            return ParseError.MemoryAllocationFailed;
        };

        while (true) {
            const next_token = self.token_peek_next();
            if (next_token == null or !isDotRunOperator(next_token.?)) {
                break; // Stop if there's no dot-run operator
            }

            const dot_op = self.token_next().?; // consume dot-run operator
            const part_token = self.token_next();
            if (part_token == null) {
                self.transpile_proc.err("expected identifier after '.'", .{});
                return ParseError.InvalidIdentifier;
            }
            if (part_token.?.type != .Identifier) {
                self.transpile_proc.err("expected identifier after '.', got '{s}'", .{@tagName(part_token.?.type)});
                return ParseError.InvalidIdentifier;
            }
            import_name.appendSlice(dot_op.data.sval.items) catch {
                return ParseError.MemoryAllocationFailed;
            };
            import_name.appendSlice(part_token.?.data.sval.items) catch {
                return ParseError.MemoryAllocationFailed;
            };
        }

        var import_alias: ?[]const u8 = null;
        const maybe_as = self.token_peek_next();
        if (maybe_as != null and maybe_as.?.type == .Keyword and mem.eql(u8, maybe_as.?.data.sval.items, "as")) {
            _ = self.token_next(); // consume `as`
            const alias_tok = self.token_next();
            if (alias_tok == null or alias_tok.?.type != .Identifier) {
                self.transpile_proc.err("expected alias identifier after 'as'", .{});
                return ParseError.InvalidIdentifier;
            }
            const alias_copy = self.transpile_proc.allocator.dupe(u8, alias_tok.?.data.sval.items) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.free(alias_copy);
            import_alias = alias_copy;
        }

        try self.expect_sym(';');
        const path = import_name.toOwnedSlice() catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.free(path);

        const import_node = ast.Node{
            .type = .Import,
            .pos = import_pos,
            .node_variant = .{ .import = .{ .path = path, .alias = import_alias } },
        };

        // Preload imported function names so identifier validation during parsing works.
        // Standard library imports are handled specially.
        if (std.mem.startsWith(u8, path, "std.")) {
            self.transpile_proc.preload_std_import_global_symbols(import_node, path, import_alias);
        } else {
            try self.transpile_proc.preload_import_global_symbols(import_node, path, import_alias);
        }

        self.transpile_proc.nodes.push(import_node) catch {
            return ParseError.MemoryAllocationFailed;
        };

        // Standard library imports may provide names (e.g. printf) that should be
        // usable in the current module, but must not participate in cross-module
        // duplicate detection.
        if (mem.eql(u8, path, "std.c.io")) {
            const names = [_][]const u8{
                "printf",
                "fprintf",
                "sprintf",
                "snprintf",
                "scanf",
                "sscanf",
                "puts",
                "putchar",
                "getchar",
                "fopen",
                "freopen",
                "fclose",
                "fflush",
                "fgetc",
                "fputc",
                "fgets",
                "fputs",
                "fread",
                "fwrite",
                "fseek",
                "ftell",
                "rewind",
                "feof",
                "ferror",
                "perror",
                "remove",
                "rename",
                "tmpfile",
                "tmpnam",
            };
            for (names) |name| {
                if (self.transpile_proc.get_symbol(name) == null) {
                    try self.transpile_proc.push_symbol(.{
                        .type = symbol.SymbolType.NativeFunction,
                        .name = name,
                        .data = null,
                        .symbol_table = null,
                    });
                }
            }
        } else if (mem.eql(u8, path, "std.c.mem")) {
            const names = [_][]const u8{
                "malloc",
                "calloc",
                "realloc",
                "free",
                "exit",
                "abort",
                "atexit",
                "system",
                "getenv",
                "atoi",
                "atol",
                "atof",
                "strtol",
                "strtoul",
                "strtod",
                "rand",
                "srand",
                "bsearch",
                "qsort",
            };
            for (names) |name| {
                if (self.transpile_proc.get_symbol(name) == null) {
                    try self.transpile_proc.push_symbol(.{
                        .type = symbol.SymbolType.NativeFunction,
                        .name = name,
                        .data = null,
                        .symbol_table = null,
                    });
                }
            }
        } else if (mem.eql(u8, path, "std.c.string")) {
            const names = [_][]const u8{
                "strlen",
                "strcmp",
                "strncmp",
                "strchr",
                "strrchr",
                "strcspn",
                "strspn",
                "strpbrk",
                "strtok",
                "strerror",
                "strcpy",
                "strncpy",
                "strcat",
                "strncat",
                "strstr",
                "memcpy",
                "memset",
                "memmove",
                "memcmp",
                "memchr",
            };
            for (names) |name| {
                if (self.transpile_proc.get_symbol(name) == null) {
                    try self.transpile_proc.push_symbol(.{
                        .type = symbol.SymbolType.NativeFunction,
                        .name = name,
                        .data = null,
                        .symbol_table = null,
                    });
                }
            }
        } else if (mem.eql(u8, path, "std.c.ctype")) {
            const names = [_][]const u8{
                "isalnum",
                "isalpha",
                "isblank",
                "iscntrl",
                "isdigit",
                "isgraph",
                "islower",
                "isprint",
                "ispunct",
                "isspace",
                "isupper",
                "isxdigit",
                "tolower",
                "toupper",
            };
            for (names) |name| {
                if (self.transpile_proc.get_symbol(name) == null) {
                    try self.transpile_proc.push_symbol(.{
                        .type = symbol.SymbolType.NativeFunction,
                        .name = name,
                        .data = null,
                        .symbol_table = null,
                    });
                }
            }
        } else if (mem.eql(u8, path, "std.c.time")) {
            const names = [_][]const u8{
                "time",
                "clock",
                "clock_gettime",
                "difftime",
                "mktime",
                "asctime",
                "ctime",
                "gmtime",
                "localtime",
                "strftime",
            };
            for (names) |name| {
                if (self.transpile_proc.get_symbol(name) == null) {
                    try self.transpile_proc.push_symbol(.{
                        .type = symbol.SymbolType.NativeFunction,
                        .name = name,
                        .data = null,
                        .symbol_table = null,
                    });
                }
            }
        } else if (mem.eql(u8, path, "std.c.net")) {
            const names = [_][]const u8{
                "socket",
                "bind",
                "listen",
                "accept",
                "recv",
                "send",
                "close",
                "htons",
                "htonl",
                "ntohs",
                "ntohl",
                "inet_addr",
            };
            for (names) |name| {
                if (self.transpile_proc.get_symbol(name) == null) {
                    try self.transpile_proc.push_symbol(.{
                        .type = symbol.SymbolType.NativeFunction,
                        .name = name,
                        .data = null,
                        .symbol_table = null,
                    });
                }
            }
        } else if (mem.eql(u8, path, "std.c.thread") or mem.eql(u8, path, "std.c.thread_windows")) {
            const names = [_][]const u8{
                "pthread_create",
                "pthread_join",
                "pthread_detach",
                "pthread_self",
                "pthread_equal",
                "pthread_mutex_init",
                "pthread_mutex_destroy",
                "pthread_mutex_lock",
                "pthread_mutex_trylock",
                "pthread_mutex_unlock",
                "pthread_cond_init",
                "pthread_cond_destroy",
                "pthread_cond_wait",
                "pthread_cond_timedwait",
                "pthread_cond_signal",
                "pthread_cond_broadcast",
            };
            for (names) |name| {
                if (self.transpile_proc.get_symbol(name) == null) {
                    try self.transpile_proc.push_symbol(.{
                        .type = symbol.SymbolType.NativeFunction,
                        .name = name,
                        .data = null,
                        .symbol_table = null,
                    });
                }
            }
        } else if (mem.eql(u8, path, "std.c.math")) {
            const names = [_][]const u8{
                "sin",
                "cos",
                "tan",
                "asin",
                "acos",
                "atan",
                "atan2",
                "sqrt",
                "pow",
                "floor",
                "ceil",
                "fabs",
            };
            for (names) |name| {
                if (self.transpile_proc.get_symbol(name) == null) {
                    try self.transpile_proc.push_symbol(.{
                        .type = symbol.SymbolType.NativeFunction,
                        .name = name,
                        .data = null,
                        .symbol_table = null,
                    });
                }
            }
        }
    }

    /// Parses a keyword token.
    ///
    /// This function checks if the next token matches any known keywords.
    /// If the token is a datatype keyword, it proceeds to parse a variable.
    /// If the token matches other specific keywords,
    /// it handles each case accordingly. If the token doesn't match any valid keyword,
    /// it logs an error message indicating an invalid keyword.
    ///
    /// Parameters:
    /// - `hist (*utils.History)`: The history context for the parse operation.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    fn parse_keyword(self: *Self, hist: *utils.History) ParseError!void {
        const t = self.token_peek_next();
        const sval = t.?.data.sval.items;
        if (utils.keyword_is_datatype(sval)) {
            const dt = self.transpile_proc.allocator.create(dtype.DataType) catch {
                return ParseError.MemoryAllocationFailed;
            };
            // `dt` is arena-allocated and may be stored in the AST; do not destroy it on unwind.
            dt.* = dtype.DataType{
                .array = null,
                .pointer_depth = 0,
                .type = .Unknown,
                .type_str = ArrayList(u8).init(self.transpile_proc.allocator),
                .flags = .{},
            };
            try self.parse_datatype(dt);
            try self.parse_variable(dt, hist, false, false);
            try self.expect_sym(';');
            return;
        }

        if (mem.eql(u8, "let", sval)) {
            return try self.parse_let_declaration(hist, false);
        }

        if (mem.eql(u8, "pub", sval)) {
            return try self.parse_pub_declaration();
        } else if (mem.eql(u8, "imp", sval)) {
            return try self.parse_import();
        } else if (mem.eql(u8, "enum", sval)) {
            return try self.parse_enum(false);
        } else if (mem.eql(u8, "compound", sval)) {
            return try self.parse_compound(false);
        } else if (mem.eql(u8, "quirk", sval)) {
            return try self.parse_quirk(false);
        } else if (mem.eql(u8, "impl", sval)) {
            return try self.parse_impl(false);
        } else if (mem.eql(u8, "async", sval)) {
            _ = self.token_next(); // skip async
            const next_tok = self.token_peek_next() orelse {
                self.transpile_proc.err("expected 'fun' after 'async'", .{});
                return ParseError.InvalidKeyword;
            };
            if (!(next_tok.type == .Keyword and mem.eql(u8, "fun", next_tok.data.sval.items))) {
                self.transpile_proc.err("expected 'fun' after 'async'", .{});
                return ParseError.InvalidKeyword;
            }
            return try self.parse_function(false, true);
        } else if (mem.eql(u8, "fun", sval)) {
            return try self.parse_function(false, false);
        } else if (mem.eql(u8, "for", sval)) {
            return try self.parse_for_statement(hist);
        } else if (mem.eql(u8, "if", sval)) {
            return try self.parse_if_statement(hist);
        } else if (mem.eql(u8, "elif", sval)) {
            return try self.parse_elif_statement(hist);
        } else if (mem.eql(u8, "else", sval)) {
            return try self.parse_else_statement(hist);
        } else if (mem.eql(u8, "fit", sval)) {
            return try self.parse_fit_statement(hist);
        } else if (mem.eql(u8, "defer", sval)) {
            return try self.parse_defer_statement(hist);
        } else if (mem.eql(u8, "asm", sval)) {
            return try self.parse_asm_statement(hist);
        } else if (mem.eql(u8, "ret", sval)) {
            return try self.parse_return(hist);
        } else if (mem.eql(u8, "await", sval)) {
            _ = try self.parse_await_operand(hist);
            try self.expect_sym(';');
            return;
        } else if (mem.eql(u8, "fork", sval)) {
            return try self.parse_fork_statement(hist);
        } else if (mem.eql(u8, "nil", sval)) {
            // The `nil` literal (a null pointer/string sentinel). `parse_keyword`
            // only PEEKS, so we must consume the token here (unlike `true`/`false`,
            // which arrive as `.Boolean` tokens consumed by parse_single_token_to_node).
            _ = self.token_next(); // consume 'nil'
            self.transpile_proc.nodes.push(ast.Node{ .type = .Nil, .pos = t.?.pos }) catch {
                return ParseError.MemoryAllocationFailed;
            };
            return;
        } else if (mem.eql(u8, "allow", sval)) {
            return try self.parse_warning_control(.allow);
        } else if (mem.eql(u8, "expect", sval)) {
            return try self.parse_warning_control(.expect);
        } else if (mem.eql(u8, "assert", sval)) {
            return try self.parse_assert(hist);
        } else if (mem.eql(u8, "break", sval)) {
            _ = self.token_next(); // skip break
            self.transpile_proc.nodes.push(ast.Node{ .type = .StatementBreak, .pos = t.?.pos }) catch {
                return ParseError.MemoryAllocationFailed;
            };
            try self.expect_sym(';');
            return;
        } else if (mem.eql(u8, "continue", sval)) {
            _ = self.token_next(); // skip continue
            self.transpile_proc.nodes.push(ast.Node{ .type = .StatementContinue, .pos = t.?.pos }) catch {
                return ParseError.MemoryAllocationFailed;
            };
            try self.expect_sym(';');
            return;
        } else if (mem.eql(u8, "true", sval)) {
            self.transpile_proc.nodes.push(ast.Node{
                .type = .Boolean,
                .pos = t.?.pos,
                .node_variant = .{ .boolean = .{ .val = true } },
            }) catch {
                return ParseError.MemoryAllocationFailed;
            };
            return;
        } else if (mem.eql(u8, "false", sval)) {
            self.transpile_proc.nodes.push(ast.Node{
                .type = .Boolean,
                .pos = t.?.pos,
                .node_variant = .{ .boolean = .{ .val = false } },
            }) catch {
                return ParseError.MemoryAllocationFailed;
            };
            return;
        }

        self.transpile_proc.err("invalid keyword", .{});
    }

    fn warning_control_is_valid_in_module_scope(id: ast.WarningId) bool {
        return switch (id) {
            .unused_variable, .unused_import, .unused_function, .unused_compound => true,
            else => false,
        };
    }

    /// Parses a warning control statement.
    ///
    /// Syntax:
    /// - `allow <warning_id>, "reason";`
    /// - `expect <warning_id>, "reason";`
    fn parse_warning_control(self: *Self, action: ast.WarningControlAction) ParseError!void {
        const ctrl_token = self.token_peek_next();
        _ = self.token_next(); // skip allow/expect

        const id_tok = self.token_next();
        if (id_tok == null or id_tok.?.type != .Identifier) {
            self.transpile_proc.err("expected warning id after '{s}'", .{@tagName(action)});
            return ParseError.InvalidIdentifier;
        }

        const warning_id = ast.warning_id_from_string(id_tok.?.data.sval.items) orelse {
            self.transpile_proc.err(
                "unknown warning id '{s}' (expected one of: return_local_ptr, fit_non_exhaustive, fit_unreachable_branch, unreachable_code, assert_constant, unused_variable, unused_import, unused_function, unused_compound, missing_return)",
                .{id_tok.?.data.sval.items},
            );
            return ParseError.InvalidIdentifier;
        };

        if (self.parser_current_function == null and !warning_control_is_valid_in_module_scope(warning_id)) {
            self.transpile_proc.err(
                "warning id '{s}' is only valid inside functions; only unused_variable, unused_import, unused_function, and unused_compound may be controlled at module scope",
                .{id_tok.?.data.sval.items},
            );
            return ParseError.InvalidStatement;
        }

        try self.expect_op(",");

        const reason_tok = self.token_next();
        if (reason_tok == null or reason_tok.?.type != .String) {
            self.transpile_proc.err("expected string reason after warning id", .{});
            return ParseError.InvalidString;
        }

        self.transpile_proc.nodes.push(ast.Node{
            .type = .StatementWarningControl,
            .pos = if (ctrl_token) |t| t.pos else null,
            .node_variant = .{ .statement = .{ .warning_ctrl = .{
                .action = action,
                .id = warning_id,
                .reason = reason_tok.?.data.sval.items,
            } } },
        }) catch {
            return ParseError.MemoryAllocationFailed;
        };

        try self.expect_sym(';');
    }

    /// Parses an assert statement.
    ///
    /// Syntax: `assert <expr>;`
    fn parse_assert(self: *Self, hist: *utils.History) ParseError!void {
        const assert_token = self.token_peek_next();
        _ = self.token_next(); // skip assert

        try self.parse_expressionable_root(hist);
        const exp_node = self.node_pop();

        var cond_ptr: ?*ast.Node = null;
        var msg_ptr: ?*ast.Node = null;

        if (exp_node != null and exp_node.?.type == .Expression and exp_node.?.node_variant != null and mem.eql(u8, exp_node.?.node_variant.?.exp.op, ",")) {
            const expv = exp_node.?.node_variant.?.exp;
            cond_ptr = expv.left;
            msg_ptr = expv.right;
        } else {
            const exp = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(exp);
            exp.* = exp_node.?;
            cond_ptr = exp;

            const next_tok = self.token_peek_next();
            if (next_tok != null and next_tok.?.type == .Operator and mem.eql(u8, next_tok.?.data.sval.items, ",")) {
                _ = self.token_next(); // skip ','
                try self.parse_expressionable_root(hist);
                const msg_node = self.node_pop();
                const msg = self.transpile_proc.allocator.create(ast.Node) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(msg);
                msg.* = msg_node.?;
                msg_ptr = msg;
            }
        }

        self.transpile_proc.nodes.push(ast.Node{
            .type = .StatementAssert,
            .pos = if (assert_token) |t| t.pos else null,
            .node_variant = .{ .statement = .{ .assert_stmt = .{ .condition = cond_ptr.?, .message = msg_ptr } } },
        }) catch {
            return ParseError.MemoryAllocationFailed;
        };
        try self.expect_sym(';');
    }

    fn parse_pub_declaration(self: *Self) ParseError!void {
        _ = self.token_next(); // skip pub
        const t = self.token_peek_next() orelse {
            self.transpile_proc.err("expected declaration after 'pub'", .{});
            return ParseError.InvalidKeyword;
        };
        if (t.type == .Keyword) {
            const kw = t.data.sval.items;
            if (utils.keyword_is_datatype(kw)) {
                const dt = self.transpile_proc.allocator.create(dtype.DataType) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                dt.* = dtype.DataType{
                    .array = null,
                    .pointer_depth = 0,
                    .type = .Unknown,
                    .type_str = ArrayList(u8).init(self.transpile_proc.allocator),
                    .flags = .{},
                };
                var hist = utils.History.init(self.transpile_proc.allocator, .{});
                defer hist.deinit();
                try self.parse_datatype(dt);
                try self.parse_variable(dt, &hist, true, false);
                try self.expect_sym(';');
                return;
            }
            if (mem.eql(u8, "let", kw)) {
                var hist = utils.History.init(self.transpile_proc.allocator, .{});
                defer hist.deinit();
                return try self.parse_let_declaration(&hist, true);
            }
            if (mem.eql(u8, "enum", kw)) {
                return try self.parse_enum(true);
            } else if (mem.eql(u8, "compound", kw)) {
                return try self.parse_compound(true);
            } else if (mem.eql(u8, "quirk", kw)) {
                return try self.parse_quirk(true);
            } else if (mem.eql(u8, "impl", kw)) {
                return try self.parse_impl(true);
            } else if (mem.eql(u8, "async", kw)) {
                _ = self.token_next(); // skip async
                const next_tok = self.token_peek_next() orelse {
                    self.transpile_proc.err("expected 'fun' after 'async'", .{});
                    return ParseError.InvalidKeyword;
                };
                if (!(next_tok.type == .Keyword and mem.eql(u8, "fun", next_tok.data.sval.items))) {
                    self.transpile_proc.err("expected 'fun' after 'async'", .{});
                    return ParseError.InvalidKeyword;
                }
                return try self.parse_function(true, true);
            } else if (mem.eql(u8, "fun", kw)) {
                return try self.parse_function(true, false);
            }
        } else if (t.type == .Identifier) {
            // public variable with user-defined type: `pub User u;`
            const dt = self.transpile_proc.allocator.create(dtype.DataType) catch {
                return ParseError.MemoryAllocationFailed;
            };
            dt.* = dtype.DataType{
                .array = null,
                .pointer_depth = 0,
                .type = .Unknown,
                .type_str = ArrayList(u8).init(self.transpile_proc.allocator),
                .flags = .{},
            };
            var hist = utils.History.init(self.transpile_proc.allocator, .{});
            defer hist.deinit();
            try self.parse_datatype(dt);
            try self.parse_variable(dt, &hist, true, false);
            try self.expect_sym(';');
            return;
        }

        self.transpile_proc.err("invalid declaration after 'pub'", .{});
        return ParseError.InvalidKeyword;
    }

    fn parse_defer_statement(self: *Self, hist: *utils.History) ParseError!void {
        const t = self.token_peek_next();
        if (!hist.*.flags.inside_function_body) {
            self.transpile_proc.err("defer statement outside of function", .{});
            return ParseError.InvalidStatement;
        }

        _ = self.token_next(); // skip defer

        const next_tok = self.token_peek_next() orelse {
            self.transpile_proc.err("expected expression or body after 'defer'", .{});
            return ParseError.InvalidStatement;
        };

        var body_ptr: *ast.Node = undefined;

        if (next_tok.type == .Symbol and next_tok.data.cval == '{') {
            // Defer block: `defer { ... }`
            try self.parse_body(hist);
            const last = self.node_pop() orelse {
                self.transpile_proc.err("expected body after 'defer'", .{});
                return ParseError.InvalidStatement;
            };
            body_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            body_ptr.* = last;
        } else {
            // Defer expression: `defer expr;`
            try self.parse_expressionable_root(hist);
            const expr_node = self.node_pop() orelse {
                self.transpile_proc.err("expected expression after 'defer'", .{});
                return ParseError.InvalidStatement;
            };
            body_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            body_ptr.* = expr_node;
            try self.expect_sym(';');
        }

        var defer_node = ast.Node{ .type = .StatementDefer, .pos = t.?.pos };
        defer_node.node_variant = .{ .statement = .{ .defer_stmt = .{ .body = body_ptr } } };
        self.transpile_proc.nodes.push(defer_node) catch {
            return ParseError.MemoryAllocationFailed;
        };
    }

    fn parse_asm_statement(self: *Self, hist: *utils.History) ParseError!void {
        const asm_tok = self.token_peek_next();
        if (!hist.*.flags.inside_function_body) {
            self.transpile_proc.err("asm statement outside of function", .{});
            return ParseError.InvalidStatement;
        }

        _ = self.token_next(); // skip asm

        var is_volatile = false;
        var arch_name: ?ArrayList(u8) = null;

        if (self.token_peek_next()) |t| {
            if ((t.type == .Keyword or t.type == .Identifier) and mem.eql(u8, t.data.sval.items, "volatile")) {
                _ = self.token_next();
                is_volatile = true;
            }
        }

        if (self.token_peek_next()) |t| {
            if ((t.type == .Keyword or t.type == .Identifier) and mem.eql(u8, t.data.sval.items, "arch")) {
                _ = self.token_next();
                const arch_tok = self.token_next();
                if (arch_tok == null or (arch_tok.?.type != .Identifier and arch_tok.?.type != .Keyword)) {
                    self.transpile_proc.err("expected architecture name after 'arch'", .{});
                    return ParseError.InvalidIdentifier;
                }
                arch_name = ArrayList(u8).initCapacity(self.transpile_proc.allocator, arch_tok.?.data.sval.items.len) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                arch_name.?.appendSlice(arch_tok.?.data.sval.items) catch {
                    return ParseError.MemoryAllocationFailed;
                };
            }
        }

        var outputs = utils.Vector(ast.AsmOperand).init(self.transpile_proc.allocator);
        var inputs = utils.Vector(ast.AsmOperand).init(self.transpile_proc.allocator);
        var clobbers = utils.Vector(ArrayList(u8)).init(self.transpile_proc.allocator);

        const parse_operand_list = struct {
            fn call(self_: *Self, list: *utils.Vector(ast.AsmOperand), hist_: *utils.History) ParseError!void {
                while (true) {
                    while (token.is_nl_or_comment_or_newline_separator(self_.token_peek_next())) {
                        _ = self_.token_next();
                    }
                    const name_tok = self_.token_next();
                    if (name_tok == null or name_tok.?.type != .Identifier) {
                        self_.transpile_proc.err("expected operand name", .{});
                        return ParseError.InvalidIdentifier;
                    }
                    var name = ArrayList(u8).initCapacity(self_.transpile_proc.allocator, name_tok.?.data.sval.items.len) catch {
                        return ParseError.MemoryAllocationFailed;
                    };
                    name.appendSlice(name_tok.?.data.sval.items) catch {
                        return ParseError.MemoryAllocationFailed;
                    };

                    const colon = self_.token_next();
                    if (colon == null or !((colon.?.type == .Operator and mem.eql(u8, colon.?.data.sval.items, ":")) or (colon.?.type == .Symbol and colon.?.data.cval == ':'))) {
                        self_.transpile_proc.err("expected ':' after operand name", .{});
                        return ParseError.InvalidOperator;
                    }

                    const constraint_tok = self_.token_next();
                    if (constraint_tok == null or constraint_tok.?.type != .String) {
                        self_.transpile_proc.err("expected constraint string", .{});
                        return ParseError.InvalidString;
                    }
                    var constraint = ArrayList(u8).initCapacity(self_.transpile_proc.allocator, constraint_tok.?.data.sval.items.len) catch {
                        return ParseError.MemoryAllocationFailed;
                    };
                    constraint.appendSlice(constraint_tok.?.data.sval.items) catch {
                        return ParseError.MemoryAllocationFailed;
                    };

                    try self_.expect_op("=");
                    try self_.parse_expressionable_root(hist_);
                    const expr_node = self_.node_pop() orelse {
                        self_.transpile_proc.err("expected operand expression", .{});
                        return ParseError.InvalidOperand;
                    };
                    const expr_ptr = self_.transpile_proc.allocator.create(ast.Node) catch {
                        return ParseError.MemoryAllocationFailed;
                    };
                    expr_ptr.* = expr_node;

                    list.push(.{ .name = name, .constraint = constraint, .expr = expr_ptr }) catch {
                        return ParseError.MemoryAllocationFailed;
                    };

                    const peek_tok = self_.token_peek_next() orelse return;
                    if (token.is_symbol(peek_tok, ',') or token.is_operator(peek_tok, ",")) {
                        _ = self_.token_next();
                        continue;
                    }
                    if (token.is_symbol(peek_tok, ';') or token.is_operator(peek_tok, ";")) {
                        _ = self_.token_next();
                        return;
                    }
                    if (token.is_symbol(peek_tok, ')') or token.is_operator(peek_tok, ")")) {
                        return;
                    }
                    self_.transpile_proc.err("expected ',', ';', or ')' after operand", .{});
                    return ParseError.InvalidOperator;
                }
            }
        }.call;

        const parse_clobbers = struct {
            fn call(self_: *Self, list: *utils.Vector(ArrayList(u8))) ParseError!void {
                while (true) {
                    while (token.is_nl_or_comment_or_newline_separator(self_.token_peek_next())) {
                        _ = self_.token_next();
                    }
                    const ctok = self_.token_next();
                    if (ctok == null or ctok.?.type != .String) {
                        self_.transpile_proc.err("expected clobber string", .{});
                        return ParseError.InvalidString;
                    }
                    var cname = ArrayList(u8).initCapacity(self_.transpile_proc.allocator, ctok.?.data.sval.items.len) catch {
                        return ParseError.MemoryAllocationFailed;
                    };
                    cname.appendSlice(ctok.?.data.sval.items) catch {
                        return ParseError.MemoryAllocationFailed;
                    };
                    list.push(cname) catch {
                        return ParseError.MemoryAllocationFailed;
                    };

                    const peek_tok = self_.token_peek_next() orelse return;
                    if (token.is_symbol(peek_tok, ',') or token.is_operator(peek_tok, ",")) {
                        _ = self_.token_next();
                        continue;
                    }
                    if (token.is_symbol(peek_tok, ';') or token.is_operator(peek_tok, ";")) {
                        _ = self_.token_next();
                        return;
                    }
                    if (token.is_symbol(peek_tok, ')') or token.is_operator(peek_tok, ")")) {
                        return;
                    }
                    self_.transpile_proc.err("expected ',', ';', or ')' after clobber", .{});
                    return ParseError.InvalidOperator;
                }
            }
        }.call;

        if (self.next_token_is_symbol('(') or token.is_operator(self.token_peek_next(), "(")) {
            _ = self.token_next(); // skip '('
            while (true) {
                while (token.is_nl_or_comment_or_newline_separator(self.token_peek_next())) {
                    _ = self.token_next();
                }
                const peek_tok = self.token_peek_next() orelse {
                    self.transpile_proc.err("expected ')' to close asm operands", .{});
                    return ParseError.InvalidStatement;
                };
                if (token.is_symbol(peek_tok, ')') or token.is_operator(peek_tok, ")")) {
                    _ = self.token_next();
                    break;
                }
                const section_tok = self.token_next();
                if (section_tok == null or (section_tok.?.type != .Identifier and section_tok.?.type != .Keyword)) {
                    self.transpile_proc.err("expected asm operand section", .{});
                    return ParseError.InvalidKeyword;
                }
                const section = section_tok.?.data.sval.items;
                if (mem.eql(u8, section, "in")) {
                    try parse_operand_list(self, &inputs, hist);
                } else if (mem.eql(u8, section, "out")) {
                    try parse_operand_list(self, &outputs, hist);
                } else if (mem.eql(u8, section, "clobber")) {
                    try parse_clobbers(self, &clobbers);
                } else {
                    self.transpile_proc.err("unknown asm section '{s}'", .{section});
                    return ParseError.InvalidKeyword;
                }
            }
        }

        var template_buf = ArrayList(u8).init(self.transpile_proc.allocator);
        var is_string_literal = false;

        while (token.is_nl_or_comment_or_newline_separator(self.token_peek_next())) {
            _ = self.token_next();
        }

        const next_tok = self.token_peek_next() orelse {
            self.transpile_proc.err("expected asm body", .{});
            return ParseError.InvalidStatement;
        };

        if (next_tok.type == .String) {
            _ = self.token_next();
            template_buf.appendSlice(next_tok.data.sval.items) catch return ParseError.MemoryAllocationFailed;
            is_string_literal = true;
        } else if (next_tok.type == .Symbol and next_tok.data.cval == '{') {
            const open_brace_tok = self.token_next() orelse {
                self.transpile_proc.err("expected '{{' to start asm block", .{});
                return ParseError.InvalidStatement;
            };
            try self.append_raw_asm_block_template(&template_buf, open_brace_tok);
        } else {
            self.transpile_proc.err("expected asm body (string or block)", .{});
            return ParseError.InvalidStatement;
        }

        try self.expect_sym(';');

        var asm_node = ast.Node{ .type = .StatementAsm, .pos = if (asm_tok) |t| t.pos else null };
        asm_node.node_variant = .{ .statement = .{ .asm_stmt = .{
            .template = template_buf,
            .is_volatile = is_volatile,
            .arch = arch_name,
            .outputs = outputs,
            .inputs = inputs,
            .clobbers = clobbers,
            .is_string_literal = is_string_literal,
        } } };

        self.transpile_proc.nodes.push(asm_node) catch {
            return ParseError.MemoryAllocationFailed;
        };
    }

    fn source_index_from_line_col(self: *Self, line: u32, col: u32) ?usize {
        if (line == 0 or col == 0) return null;

        const src = self.transpile_proc.input_source;
        var current_line: u32 = 1;
        var line_start: usize = 0;
        var i: usize = 0;

        while (i < src.len and current_line < line) : (i += 1) {
            if (src[i] == '\n') {
                current_line += 1;
                line_start = i + 1;
            }
        }

        if (current_line != line) return null;

        const offset: usize = @intCast(col - 1);
        const idx = line_start + offset;
        if (idx > src.len) return null;
        return idx;
    }

    fn append_raw_asm_block_template(self: *Self, template_buf: *ArrayList(u8), open_brace_tok: token.Token) ParseError!void {
        var depth: usize = 1;
        var close_brace_tok: ?token.Token = null;

        while (true) {
            const t = self.transpile_proc.tokens.peek() orelse {
                self.transpile_proc.err("unexpected end of file in asm block", .{});
                return ParseError.InvalidStatement;
            };

            if (t.type == .Symbol and t.data.cval == '{') {
                depth += 1;
            } else if (t.type == .Symbol and t.data.cval == '}') {
                depth -= 1;
                if (depth == 0) {
                    close_brace_tok = t;
                    break;
                }
            }
        }

        const close_tok = close_brace_tok orelse {
            self.transpile_proc.err("unexpected end of file in asm block", .{});
            return ParseError.InvalidStatement;
        };

        const start_idx = self.source_index_from_line_col(open_brace_tok.pos.end_line, open_brace_tok.pos.end_col) orelse {
            self.transpile_proc.err("internal parser error: invalid asm block start", .{});
            return ParseError.InvalidStatement;
        };
        const end_idx = self.source_index_from_line_col(close_tok.pos.line, close_tok.pos.start_col) orelse {
            self.transpile_proc.err("internal parser error: invalid asm block end", .{});
            return ParseError.InvalidStatement;
        };

        if (end_idx < start_idx or end_idx > self.transpile_proc.input_source.len) {
            self.transpile_proc.err("internal parser error: malformed asm block span", .{});
            return ParseError.InvalidStatement;
        }

        template_buf.appendSlice(self.transpile_proc.input_source[start_idx..end_idx]) catch return ParseError.MemoryAllocationFailed;
    }

    fn alloc_node_copy_shallow(self: *Self, node: ast.Node) ParseError!*ast.Node {
        const out = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(out);
        out.* = node;
        if (node.type == .Expression) {
            if (node.node_variant.?.exp.left) |left| {
                out.*.node_variant.?.exp.left = self.transpile_proc.allocator.create(ast.Node) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(out.*.node_variant.?.exp.left.?);
                out.*.node_variant.?.exp.left.?.* = left.*;
            }
            if (node.node_variant.?.exp.right) |right| {
                out.*.node_variant.?.exp.right = self.transpile_proc.allocator.create(ast.Node) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(out.*.node_variant.?.exp.right.?);
                out.*.node_variant.?.exp.right.?.* = right.*;
            }
            out.*.node_variant.?.exp.op = node.node_variant.?.exp.op;
        }
        return out;
    }

    fn push_loop_scope_entity(self: *Self, entity: *scope.ScopeEntity) ParseError!void {
        if (self.transpile_proc.get_scope_entity(entity.name) != null) {
            self.transpile_proc.err("variable '{s}' already declared", .{entity.name});
            return ParseError.VariableAlreadyDeclared;
        }
        self.transpile_proc.push_scope_entity(entity) catch {
            return ParseError.MemoryAllocationFailed;
        };
    }

    fn parse_for_statement(self: *Self, hist: *utils.History) ParseError!void {
        const for_token = self.token_peek_next();
        try self.expect_keyword("for");
        if (self.parser_current_function == null) {
            self.transpile_proc.err("for statement outside of function", .{});
            return ParseError.InvalidStatement;
        }

        // New syntax:
        // - `for { ... }`           (infinite)
        // - `for <cond> { ... }`    (condition loop)
        // Existing syntax remains:
        // - `for i : start..end { ... }`
        // - `for item : arr { ... }` / `for i, item :: arr { ... }`
        const next_tok = self.token_peek_next();
        if (token.is_symbol(next_tok, '{')) {
            // Infinite loop with no header.
            _ = try self.transpile_proc.new_scope();
            try self.parse_body_multiple_statements(hist);
            self.transpile_proc.finish_scope();
            const body_node = self.node_pop().?;

            const body_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(body_ptr);
            body_ptr.* = body_node;

            var for_node = ast.Node{ .type = .StatementFor, .pos = if (for_token) |t| t.pos else null };
            for_node.node_variant = .{ .statement = .{ .for_stmt = .{ .cond = .{ .condition = null, .body = body_ptr } } } };
            try self.create_node(&for_node);
            return;
        }

        // Disambiguate legacy `for <ident> : ...` from the new condition-loop form
        // that can also start with an identifier: `for x != 0 { ... }`.
        if (next_tok != null and next_tok.?.type == .Identifier) {
            const after_ident = self.token_peek_n(1);
            const is_legacy = token.is_operator(after_ident, ",") or token.is_operator(after_ident, ":");
            if (!is_legacy) {
                try self.parse_expressionable_root(hist);
                const cond_node = self.node_pop().?;

                _ = try self.transpile_proc.new_scope();
                try self.parse_body_multiple_statements(hist);
                self.transpile_proc.finish_scope();
                const body_node = self.node_pop().?;

                const cond_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(cond_ptr);
                cond_ptr.* = cond_node;

                const body_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                    return ParseError.MemoryAllocationFailed;
                };
                errdefer self.transpile_proc.allocator.destroy(body_ptr);
                body_ptr.* = body_node;

                var for_node = ast.Node{ .type = .StatementFor, .pos = if (for_token) |t| t.pos else null };
                for_node.node_variant = .{ .statement = .{ .for_stmt = .{ .cond = .{ .condition = cond_ptr, .body = body_ptr } } } };
                try self.create_node(&for_node);
                return;
            }
        } else if (next_tok != null and next_tok.?.type != .Identifier) {
            // Condition-loop starting with a non-identifier token (e.g. `true`, `(<expr>)`).
            try self.parse_expressionable_root(hist);
            const cond_node = self.node_pop().?;

            _ = try self.transpile_proc.new_scope();
            try self.parse_body_multiple_statements(hist);
            self.transpile_proc.finish_scope();
            const body_node = self.node_pop().?;

            const cond_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(cond_ptr);
            cond_ptr.* = cond_node;

            const body_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(body_ptr);
            body_ptr.* = body_node;

            var for_node = ast.Node{ .type = .StatementFor, .pos = if (for_token) |t| t.pos else null };
            for_node.node_variant = .{ .statement = .{ .for_stmt = .{ .cond = .{ .condition = cond_ptr, .body = body_ptr } } } };
            try self.create_node(&for_node);
            return;
        }

        const first = self.token_next();
        if (first == null or first.?.type != .Identifier) {
            self.transpile_proc.err("expected identifier after 'for'", .{});
            return ParseError.InvalidIdentifier;
        }

        var index_name: ?[]const u8 = null;
        var item_name: []const u8 = first.?.data.sval.items;
        var used_double_colon = false;

        if (self.next_token_is_operator(",")) {
            index_name = item_name;
            _ = self.token_next(); // skip ,
            const second = self.token_next();
            if (second == null or second.?.type != .Identifier) {
                self.transpile_proc.err("expected identifier after ',' in for loop", .{});
                return ParseError.InvalidIdentifier;
            }
            item_name = second.?.data.sval.items;
            try self.expect_op("::");
            used_double_colon = true;
        } else {
            try self.expect_op(":");
        }

        try self.parse_expressionable_root(hist);
        const iterable_node = self.node_pop().?;

        // Parse body in a loop scope (so loop variables are valid identifiers).
        _ = try self.transpile_proc.new_scope();

        var index_entity: ?scope.ScopeEntity = null;
        var item_entity: ?scope.ScopeEntity = null;

        if (iterable_node.type == .Expression and std.mem.eql(u8, iterable_node.node_variant.?.exp.op, "..")) {
            if (used_double_colon) {
                self.transpile_proc.err("range for loop does not support 'i, item ::' form", .{});
                return ParseError.InvalidStatement;
            }
            item_entity = .{ .flags = .{ .on_stack = true }, .node = null, .name = item_name };
            try self.push_loop_scope_entity(&item_entity.?);
        } else {
            // For now, iterable for-loops require an identifier (array variable).
            if (iterable_node.type != .Identifier) {
                self.transpile_proc.err("for-each loops currently require an array identifier", .{});
                return ParseError.InvalidExpression;
            }
            if (index_name) |iname| {
                index_entity = .{ .flags = .{ .on_stack = true }, .node = null, .name = iname };
                try self.push_loop_scope_entity(&index_entity.?);
            }
            item_entity = .{ .flags = .{ .on_stack = true }, .node = null, .name = item_name };
            try self.push_loop_scope_entity(&item_entity.?);
        }

        try self.parse_body_multiple_statements(hist);
        self.transpile_proc.finish_scope();
        const body_node = self.node_pop().?;

        // Transfer ownership of the already-allocated AST subtrees into the for-statement.
        const body_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
            return ParseError.MemoryAllocationFailed;
        };
        errdefer self.transpile_proc.allocator.destroy(body_ptr);
        body_ptr.* = body_node;

        var for_node = ast.Node{ .type = .StatementFor, .pos = if (for_token) |t| t.pos else null };
        if (iterable_node.type == .Expression and std.mem.eql(u8, iterable_node.node_variant.?.exp.op, "..")) {
            const range_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(range_ptr);
            range_ptr.* = iterable_node;
            for_node.node_variant = .{ .statement = .{ .for_stmt = .{ .range = .{ .index_name = item_name, .range = range_ptr, .body = body_ptr } } } };
        } else {
            const iterable_ptr = self.transpile_proc.allocator.create(ast.Node) catch {
                return ParseError.MemoryAllocationFailed;
            };
            errdefer self.transpile_proc.allocator.destroy(iterable_ptr);
            iterable_ptr.* = iterable_node;
            for_node.node_variant = .{ .statement = .{ .for_stmt = .{ .iter = .{ .index_name = index_name, .item_name = item_name, .iterable = iterable_ptr, .body = body_ptr } } } };
        }

        try self.create_node(&for_node);
    }

    /// Parses a global keyword token.
    ///
    /// This function initializes a `History` instance with global scope
    /// and calls the `parse_keyword` function to handle the keyword parsing.
    ///
    /// Errors:
    /// - Returns an error if initializing the history or parsing the keyword fails.
    fn parse_global_keyword(self: *Self) ParseError!void {
        var hist = utils.History.init(
            self.transpile_proc.allocator,
            .{ .is_global_scope = true },
        );
        defer hist.deinit();

        try self.parse_keyword(&hist);
        const n = self.node_pop() orelse {
            self.transpile_proc.err("expected declaration after keyword", .{});
            return ParseError.InvalidStatement;
        };
        if (n.type != .Function) {
            try self.transpile_proc.register_global_node_symbol(n);
        }
        self.transpile_proc.nodes.push(n) catch {
            return ParseError.MemoryAllocationFailed;
        };
    }

    /// Processes the next token in the input.
    ///
    /// This function processes the next token, handling different token types
    /// and returning `true` if a valid token is found, or `false` if there are
    /// no more tokens.
    ///
    /// Returns:
    /// - `bool`: `true` if a valid token is found, otherwise `false`.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    fn next(self: *Self) ParseError!bool {
        const t = self.token_peek_next();
        if (t == null) {
            return false;
        }
        try switch (t.?.type) {
            .Number, .Identifier, .String => {
                var hist = utils.History.init(self.transpile_proc.allocator, .{});
                defer hist.deinit();
                try self.parse_expressionable(&hist);
            },
            .Keyword => self.parse_global_keyword(),
            .Symbol => self.parse_symbol(),
            // Any other token kind at the top level (e.g. a stray operator) is a
            // syntax error, not an internal invariant violation. Report it cleanly
            // instead of `unreachable`, which would panic + abort the compiler.
            else => {
                self.transpile_proc.err("unexpected token '{s}' at top level", .{@tagName(t.?.type)});
                return ParseError.InvalidToken;
            },
        };
        return true;
    }

    /// Parses the entire input sequence of tokens.
    ///
    /// This function repeatedly processes tokens until there are no more tokens
    /// to process.
    ///
    /// Errors:
    /// - Returns an error if reading the next token fails.
    /// One-time O(n) token pre-scan that records every top-level type name
    /// introduced by `compound`/`enum`/`quirk Name`. Populates
    /// `forward_type_names` so the single-pass parser can recognize a
    /// `Name{...}` compound initializer even when `Name` is declared later in
    /// the file. Best-effort: on allocation failure the set is left empty and the
    /// parser simply falls back to its prior (declaration-order-sensitive)
    /// behavior — never a hard failure.
    fn prescan_forward_type_names(self: *Self) void {
        if (self.forward_type_names != null) return;
        var set = std.StringHashMap(void).init(self.transpile_proc.allocator);
        const items = self.transpile_proc.tokens.items();
        var i: usize = 0;
        while (i < items.len) : (i += 1) {
            const t = items[i];
            if (t.type != .Keyword) continue;
            const kw = t.data.sval.items;
            if (!(mem.eql(u8, kw, "compound") or mem.eql(u8, kw, "enum") or mem.eql(u8, kw, "quirk"))) continue;
            // Find the next non-skippable token: the type name.
            var j = i + 1;
            while (j < items.len and token.is_nl_or_comment_or_newline_separator(items[j])) : (j += 1) {}
            if (j < items.len and items[j].type == .Identifier) {
                set.put(items[j].data.sval.items, {}) catch {
                    // On OOM, discard the partial set and bail (fall back to
                    // declaration-order behavior). Don't leave a half-built set.
                    set.deinit();
                    return;
                };
            }
        }
        self.forward_type_names = set;
    }

    /// True if `name` is a top-level compound/enum/quirk declared anywhere in the
    /// file (per the forward pre-scan). Used to accept forward-referenced
    /// compound initializers.
    fn is_forward_declared_type(self: *Self, name: []const u8) bool {
        const set = self.forward_type_names orelse return false;
        return set.contains(name);
    }

    pub fn parse(self: *Self) ParseError!void {
        self.prescan_forward_type_names();
        _ = try self.transpile_proc.init_root_scope();
        errdefer {
            // On parse errors (common while editing and in negative test fixtures),
            // avoid scope teardown here. The transpile process is arena-backed and will
            // be released by `TranspileProcess.deinit()`. Trying to deinit scopes on a
            // partially-parsed/invalid program has historically been crash-prone.
            if (self.transpile_proc.scope) |*sc| {
                sc.root = null;
                sc.current = null;
            }
            self.transpile_proc.scope = null;
        }

        while (try self.next()) {}
        self.transpile_proc.deinit_root_scope();
    }

    // --- Test-support API ---------------------------------------------------
    // These thin wrappers exist solely so the test suite (tests/parser_test.zig)
    // can exercise the otherwise-private lookahead functions and verify that the
    // O(1) significant-token index produces exactly the same results as a naive
    // linear scan. They are not used by the parser itself.

    /// Test-only: the O(1) `token_peek_n` result.
    pub fn testPeekN(self: *Self, n: usize) ?token.Token {
        return self.token_peek_n(n);
    }

    /// Test-only: a reference linear scan equivalent to the original
    /// `token_peek_n`, used as the oracle in equivalence tests.
    pub fn testPeekNLinear(self: *Self, n: usize) ?token.Token {
        return self.token_peek_n_linear(n);
    }

    /// Test-only: the O(1) `token_peek_prev_n` result.
    pub fn testPeekPrevN(self: *Self, n: usize) ?token.Token {
        return self.token_peek_prev_n(n);
    }

    /// Test-only: the O(1) `token_peek_prev_stream_n` result.
    pub fn testPeekPrevStreamN(self: *Self, n: usize) ?token.Token {
        return self.token_peek_prev_stream_n(n);
    }

    /// Test-only: move the read cursor to a physical index (does not bump the
    /// stream generation, so it must not invalidate the lookahead tables).
    pub fn testSetCursor(self: *Self, index: usize) void {
        self.transpile_proc.tokens.set_peek_pointer(index);
    }
};
