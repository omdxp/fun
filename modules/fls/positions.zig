const std = @import("std");
const token = @import("lexer").token;
const types = @import("types.zig");

fn ArrayList(comptime T: type) type {
    return std.array_list.Managed(T);
}

const Allocator = std.mem.Allocator;

const Position = types.Position;
const Range = types.Range;
const TokenLite = types.TokenLite;
const TokenLiteKind = types.TokenLiteKind;
const SymbolLite = types.SymbolLite;

const _skip_lsp_tests_in_ci = blk: {
    if (@hasDecl(@import("std").process, "getEnvVar")) {
        if (@import("std").process.getEnvVar("CI", null)) |ci| {
            if (ci.len > 0) break :blk true;
        }
    }
    break :blk false;
};

pub fn posInRange(p: Position, r: Range) bool {
    if (p.line < r.start.line or p.line > r.end.line) return false;
    if (p.line == r.start.line and p.character < r.start.character) return false;
    // LSP ranges are end-exclusive.
    if (p.line == r.end.line and p.character >= r.end.character) return false;
    return true;
}

pub fn findTokenAt(tokens: []const TokenLite, p: Position) ?TokenLite {
    for (tokens) |t| {
        if (posInRange(p, t.range)) return t;
    }
    // If cursor is just after the token, treat it as within (helpful for completion).
    if (tokens.len != 0) {
        for (tokens) |t| {
            if (t.range.end.line == p.line and t.range.end.character == p.character) return t;
        }
    }
    return null;
}

pub fn findTokenIndexAt(tokens: []const TokenLite, p: Position) ?usize {
    for (tokens, 0..) |t, i| {
        if (posInRange(p, t.range)) return i;
    }
    // If cursor is just after the token, treat it as within (helpful for completion).
    if (tokens.len != 0) {
        for (tokens, 0..) |t, i| {
            if (t.range.end.line == p.line and t.range.end.character == p.character) return i;
        }
    }
    return null;
}

pub fn isDotToken(t: TokenLite) bool {
    return (t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, ".");
}

fn isPunct(t: TokenLite, s: []const u8) bool {
    return (t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, s);
}

pub fn isOpenParen(t: TokenLite) bool {
    return isPunct(t, "(");
}
pub fn isCloseParen(t: TokenLite) bool {
    return isPunct(t, ")");
}
pub fn isOpenBracket(t: TokenLite) bool {
    return isPunct(t, "[");
}
pub fn isCloseBracket(t: TokenLite) bool {
    return isPunct(t, "]");
}
pub fn isCommaToken(t: TokenLite) bool {
    return isPunct(t, ",");
}
pub fn isOpenBrace(t: TokenLite) bool {
    return isPunct(t, "{");
}
pub fn isCloseBrace(t: TokenLite) bool {
    return isPunct(t, "}");
}

/// From `start_i` (e.g. the `fit`/`impl` keyword token), find the FIRST `{`
/// not nested inside parens (skipping over a `fit <expr>` subject or an
/// `impl Type as Quirk` clause, either of which may itself contain parens),
/// then its matching `}` via brace-depth tracking. Used by code actions that
/// need to insert content just before a block's closing brace.
pub fn findBlockBraceRange(tokens: []const TokenLite, start_i: usize) ?struct { open_i: usize, close_i: usize } {
    var paren_depth: i64 = 0;
    var i = start_i;
    var open_i: ?usize = null;
    while (i < tokens.len) : (i += 1) {
        const t = tokens[i];
        if (isOpenParen(t)) {
            paren_depth += 1;
            continue;
        }
        if (isCloseParen(t)) {
            paren_depth -= 1;
            continue;
        }
        if (paren_depth == 0 and isOpenBrace(t)) {
            open_i = i;
            break;
        }
    }
    const ob = open_i orelse return null;
    var depth: i64 = 0;
    var j = ob;
    while (j < tokens.len) : (j += 1) {
        const t = tokens[j];
        if (isOpenBrace(t)) depth += 1;
        if (isCloseBrace(t)) {
            depth -= 1;
            if (depth == 0) return .{ .open_i = ob, .close_i = j };
        }
    }
    return null;
}

/// Extracts the parameter *name* from a parameter label such as `num a`,
/// `Point* p`, or `str[] names` → `a`, `p`, `names`. The name is the last
/// whitespace-separated token with any leading pointer markers stripped.
/// Returns the whole label if there is no space (e.g. a bare type with no name).
pub fn paramNameFromLabel(label: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, label, " \t");
    if (trimmed.len == 0) return trimmed;
    const last_sp = std.mem.lastIndexOfScalar(u8, trimmed, ' ') orelse return trimmed;
    return std.mem.trim(u8, trimmed[last_sp + 1 ..], " \t*");
}

pub fn nextNonTrivialTokenLite(tokens: []const TokenLite, start_index: usize) ?usize {
    var i = start_index;
    while (i < tokens.len) : (i += 1) {
        const t = tokens[i];
        if (t.kind == .comment) continue;
        return i;
    }
    return null;
}

pub fn prevNonTrivialTokenLite(tokens: []const TokenLite, start_index: usize) ?usize {
    if (start_index == 0) return null;
    var i: isize = @as(isize, @intCast(start_index)) - 1;
    while (i >= 0) : (i -= 1) {
        const t = tokens[@intCast(i)];
        if (t.kind == .comment) continue;
        return @intCast(i);
    }
    return null;
}

pub fn findMatchingRParenLite(tokens: []const TokenLite, lparen_i: usize) ?usize {
    var depth: i64 = 0;
    var i = lparen_i;
    while (i < tokens.len) : (i += 1) {
        const t = tokens[i];
        if (t.kind == .comment) continue;
        for (t.text) |ch| {
            if (ch == '(') depth += 1;
            if (ch == ')') {
                depth -= 1;
                if (depth == 0) return i;
            }
        }
    }
    return null;
}

/// Given an `(` at `lparen_i` whose preceding token is an identifier, decides
/// whether this is a function/method *declaration* (the parameter list of a
/// `[pub] [async] name(params) [RetType] {` definition) rather than a *call*.
/// Inlay parameter-name hints must be suppressed for declarations — the names
/// are already written there.
///
/// Two signals, either of which marks a declaration:
///   1. The token before the name is a declaration keyword (`fun`/`pub`/`async`)
///      — methods inside `impl` blocks are written `pub name(...)` with no `fun`.
///   2. The matching `)` is followed (after an optional return type, which is
///      only type-ish tokens: identifiers, builtin type keywords, `*`, `[`, `]`,
///      `<`, `>`, `,`) by a `{` — a call's `)` is never followed by a block.
pub fn callParenIsDeclaration(tokens: []const TokenLite, name_i: usize, lparen_i: usize) bool {
    // Signal 1: preceding keyword.
    if (prevNonTrivialTokenLite(tokens, name_i)) |pi| {
        const p = tokens[pi];
        if (p.kind == .keyword and
            (std.mem.eql(u8, p.text, "fun") or std.mem.eql(u8, p.text, "pub") or std.mem.eql(u8, p.text, "async")))
        {
            return true;
        }
    }

    // Signal 2 guard: a declaration name sits at a statement boundary — preceded by
    // `{`/`}`/`;` or nothing (Signal 1 already handled `fun`/`pub`/`async`). If `name`
    // is instead preceded by an expression-introducing token, `name(...)` is a CALL,
    // and the `)`-then-`{` brace heuristic below would misfire. The canonical case is
    // a `fit`/`if`/`while`/`for` subject whose body brace follows: `fit parse(src) {`.
    if (prevNonTrivialTokenLite(tokens, name_i)) |pi| {
        const p = tokens[pi];
        const at_stmt_boundary = (p.kind == .symbol or p.kind == .operator) and
            (std.mem.eql(u8, p.text, "{") or std.mem.eql(u8, p.text, "}") or std.mem.eql(u8, p.text, ";"));
        if (!at_stmt_boundary) return false;
    }

    // Signal 2: matching `)` eventually followed by `{`, over only type-ish tokens.
    const rparen = findMatchingRParenLite(tokens, lparen_i) orelse return false;
    var k = nextNonTrivialTokenLite(tokens, rparen + 1) orelse return false;
    var steps: usize = 0;
    while (steps < 8) : (steps += 1) {
        const t = tokens[k];
        if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, "{")) return true;
        // Only a return type may sit between `)` and `{`. Anything else
        // (`;`, `.`, `=`, `,`, `(`, operators…) means this was a call/expression.
        const is_typeish = t.kind == .identifier or t.kind == .keyword or
            ((t.kind == .symbol or t.kind == .operator) and
                (std.mem.eql(u8, t.text, "*") or std.mem.eql(u8, t.text, "[") or
                    std.mem.eql(u8, t.text, "]") or std.mem.eql(u8, t.text, "<") or
                    std.mem.eql(u8, t.text, ">") or std.mem.eql(u8, t.text, ",")));
        if (!is_typeish) return false;
        k = nextNonTrivialTokenLite(tokens, k + 1) orelse return false;
    }
    return false;
}

pub fn findMatchingLParenLite(tokens: []const TokenLite, rparen_i: usize) ?usize {
    var depth: i64 = 0;
    var i: isize = @as(isize, @intCast(rparen_i));
    while (i >= 0) : (i -= 1) {
        const t = tokens[@intCast(i)];
        if (t.kind == .comment) continue;
        var j: isize = @as(isize, @intCast(t.text.len));
        while (j > 0) {
            j -= 1;
            const ch = t.text[@intCast(j)];
            if (ch == ')') {
                depth += 1;
                continue;
            }
            if (ch == '(') {
                depth -= 1;
                if (depth == 0) return @intCast(i);
            }
        }
    }
    return null;
}

pub fn skipGenericArgsLite(tokens: []const TokenLite, start_index: usize) usize {
    if (start_index >= tokens.len) return start_index;
    const t0 = tokens[start_index];
    if (!((t0.kind == .symbol or t0.kind == .operator) and std.mem.eql(u8, t0.text, "<"))) return start_index;
    var depth: i64 = 0;
    var i: usize = start_index;
    while (i < tokens.len) : (i += 1) {
        const t = tokens[i];
        if (t.kind == .comment) continue;
        if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, "<")) depth += 1;
        if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, ">")) {
            depth -= 1;
            if (depth == 0) return nextNonTrivialTokenLite(tokens, i + 1) orelse (i + 1);
        }
    }
    return i;
}

pub fn concreteGenericTypeAtToken(allocator: Allocator, tokens: []const TokenLite, tok_i: usize) !?[]u8 {
    if (tok_i >= tokens.len) return null;
    const base_tok = tokens[tok_i];
    if (base_tok.kind != .identifier) return null;

    const lt_i = nextNonTrivialTokenLite(tokens, tok_i + 1) orelse return null;
    const lt_tok = tokens[lt_i];
    if (!((lt_tok.kind == .symbol or lt_tok.kind == .operator) and std.mem.eql(u8, lt_tok.text, "<"))) {
        return null;
    }

    var out = ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice(base_tok.text);

    var depth: i64 = 0;
    var i = lt_i;
    while (i < tokens.len) : (i += 1) {
        const t = tokens[i];
        if (t.kind == .comment) continue;

        if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, "<")) {
            depth += 1;
            try out.append('<');
            continue;
        }

        if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, ">")) {
            if (depth <= 0) break;
            depth -= 1;
            try out.append('>');
            if (depth == 0) {
                return try out.toOwnedSlice();
            }
            continue;
        }

        if (depth <= 0) break;
        if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, ",")) {
            try out.appendSlice(", ");
            continue;
        }

        try out.appendSlice(t.text);
    }

    out.deinit();
    return null;
}

pub fn concreteGenericTypeSliceAtPosition(text: []const u8, p: Position) ?[]const u8 {
    if (text.len == 0) return null;

    const isIdentChar = struct {
        fn call(ch: u8) bool {
            return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
        }
    }.call;

    var idx = byteIndexForPosition(text, p);
    if (idx >= text.len or !isIdentChar(text[idx])) {
        if (idx == 0 or !isIdentChar(text[idx - 1])) return null;
        idx -= 1;
    }

    var start_b = idx;
    while (start_b > 0 and isIdentChar(text[start_b - 1])) : (start_b -= 1) {}
    var name_end = idx + 1;
    while (name_end < text.len and isIdentChar(text[name_end])) : (name_end += 1) {}
    if (name_end <= start_b) return null;

    var lt_i = name_end;
    while (lt_i < text.len and (text[lt_i] == ' ' or text[lt_i] == '\t')) : (lt_i += 1) {}
    if (lt_i >= text.len or text[lt_i] != '<') return null;

    var depth: i64 = 0;
    var i = lt_i;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '\n' or ch == '\r') return null;
        if (ch == '<') {
            depth += 1;
            continue;
        }
        if (ch == '>') {
            if (depth <= 0) return null;
            depth -= 1;
            if (depth == 0) return text[start_b .. i + 1];
        }
    }

    return null;
}

pub fn findLastTokenIndexBeforeOrAt(tokens: []const TokenLite, p: Position) ?usize {
    var last: ?usize = null;
    for (tokens, 0..) |t, i| {
        if (t.range.start.line > p.line) break;
        if (t.range.start.line == p.line and t.range.start.character > p.character) break;
        last = i;
    }
    return last;
}

pub fn rangeFromTokenPos(p: token.Pos) Range {
    const end_line_1b: u32 = if (p.end_line != 0) p.end_line else p.line;
    const end_char_excl: i64 = blk: {
        // Lexer columns are 1-based; `end_col` points just after the token.
        // Convert to 0-based, end-exclusive character index.
        if (p.end_col == 0) break :blk 0;
        break :blk @as(i64, @intCast(p.end_col)) - 1;
    };
    return .{
        .start = .{ .line = @as(i64, @intCast(p.line)) - 1, .character = @as(i64, @intCast(p.start_col)) - 1 },
        .end = .{ .line = @as(i64, @intCast(end_line_1b)) - 1, .character = end_char_excl },
    };
}

pub fn rangeStartLessOrEqual(a: Range, p: Position) bool {
    if (a.start.line < p.line) return true;
    if (a.start.line > p.line) return false;
    return a.start.character <= p.character;
}

pub fn rangeStartGreater(a: Range, b: Range) bool {
    if (a.start.line != b.start.line) return a.start.line > b.start.line;
    return a.start.character > b.start.character;
}

pub fn rangeStartEqual(a: Range, b: Range) bool {
    return a.start.line == b.start.line and a.start.character == b.start.character;
}

pub fn rangeEqual(a: Range, b: Range) bool {
    return a.start.line == b.start.line and a.start.character == b.start.character and
        a.end.line == b.end.line and a.end.character == b.end.character;
}

pub fn findEnclosingFunctionAsyncInsertPosFromTokens(tokens: []const TokenLite, target_line: i64) ?Position {
    const FnScope = struct {
        body_depth: i64,
        insert_pos: ?Position,
    };

    var scopes: [128]FnScope = undefined;
    var scopes_len: usize = 0;
    var depth: i64 = 0;

    var pending_fun_pos: ?Position = null;
    var pending_fun_is_async: bool = false;

    for (tokens, 0..) |t, i| {
        if (t.range.start.line > target_line) break;

        if (t.kind == .keyword and std.mem.eql(u8, t.text, "fun")) {
            var is_async = false;
            var j: isize = @as(isize, @intCast(i)) - 1;
            while (j >= 0) : (j -= 1) {
                const prev = tokens[@as(usize, @intCast(j))];
                if (prev.range.start.line < t.range.start.line) break;
                if (prev.kind == .keyword and std.mem.eql(u8, prev.text, "async")) {
                    is_async = true;
                    break;
                }
            }
            pending_fun_pos = t.range.start;
            pending_fun_is_async = is_async;
            continue;
        }

        if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, "{")) {
            depth += 1;
            if (pending_fun_pos) |fun_pos| {
                if (scopes_len < scopes.len) {
                    scopes[scopes_len] = .{
                        .body_depth = depth,
                        .insert_pos = if (pending_fun_is_async) null else fun_pos,
                    };
                    scopes_len += 1;
                }
                pending_fun_pos = null;
                pending_fun_is_async = false;
            }
            continue;
        }

        if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, "}")) {
            if (scopes_len != 0 and scopes[scopes_len - 1].body_depth == depth) {
                scopes_len -= 1;
            }
            if (depth > 0) depth -= 1;
            continue;
        }
    }

    if (scopes_len == 0) return null;
    return scopes[scopes_len - 1].insert_pos;
}

pub fn isBuiltinTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "void") or std.mem.eql(u8, name, "raw") or std.mem.eql(u8, name, "num") or
        std.mem.eql(u8, name, "dec") or std.mem.eql(u8, name, "str") or std.mem.eql(u8, name, "bin") or
        std.mem.eql(u8, name, "chr") or std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "f64") or
        std.mem.eql(u8, name, "i8") or std.mem.eql(u8, name, "i16") or std.mem.eql(u8, name, "i32") or
        std.mem.eql(u8, name, "i64") or std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "u16") or
        std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "u64");
}

pub fn isLetInferTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "__let_infer__");
}

/// Returns true for characters that can appear in a Fun type identifier.
fn isTypeIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_' or c == '.';
}

/// Appends every identifier-like token found in a type string to `out`.
/// Handles plain names (`Point`), generics (`Map<str, List<num>>` → Map, str,
/// List, num), pointers/arrays (`Foo*`, `Bar[]`), and qualified names
/// (`mod.Type`). Separators (`<>,[]* ` etc.) split identifiers. The returned
/// slices borrow from `type_str` (no allocation of the names themselves).
pub fn collectTypeNamesFromTypeString(out: *ArrayList([]const u8), type_str: []const u8) !void {
    var i: usize = 0;
    while (i < type_str.len) {
        if (!isTypeIdentChar(type_str[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < type_str.len and isTypeIdentChar(type_str[i])) : (i += 1) {}
        const name = type_str[start..i];
        // A bare number (e.g. an array size `Foo[64]`) is not a type name.
        if (name.len != 0 and !(name[0] >= '0' and name[0] <= '9')) {
            try out.append(name);
        }
    }
}

/// Extracts type names from a function signature detail string such as
/// `fun add(num a, Point p) Result`. Parameter declarations in Fun are
/// `Type name`, so the type is the first token of each comma-separated parameter
/// and the return type is whatever follows the closing paren. The `fun` keyword
/// and parameter *names* are skipped. Borrows slices from `detail`.
pub fn collectReturnAndParamTypeNames(out: *ArrayList([]const u8), detail: []const u8) !void {
    const open = std.mem.indexOfScalar(u8, detail, '(') orelse {
        // No parameter list: treat the whole thing as a single type reference.
        try collectTypeNamesFromTypeString(out, detail);
        return;
    };
    const close = std.mem.lastIndexOfScalar(u8, detail, ')') orelse return;
    if (close < open) return;

    // Parameters: split on top-level commas; the FIRST identifier of each is the type.
    const params = detail[open + 1 .. close];
    var depth: i32 = 0;
    var seg_start: usize = 0;
    var pi: usize = 0;
    while (pi <= params.len) : (pi += 1) {
        const at_end = pi == params.len;
        const c = if (at_end) ',' else params[pi];
        if (!at_end and (c == '<' or c == '[' or c == '(')) depth += 1;
        if (!at_end and (c == '>' or c == ']' or c == ')')) depth -= 1;
        if ((at_end or c == ',') and depth <= 0) {
            const seg = std.mem.trim(u8, params[seg_start..pi], " \t");
            if (seg.len != 0) {
                // The parameter type is everything up to the last space-separated
                // token (the name). If there is no space, the whole seg is a type.
                const last_sp = std.mem.lastIndexOfScalar(u8, seg, ' ');
                const type_part = if (last_sp) |sp| std.mem.trim(u8, seg[0..sp], " \t") else seg;
                try collectTypeNamesFromTypeString(out, type_part);
            }
            seg_start = pi + 1;
        }
    }

    // Return type: tokens after the closing paren.
    if (close + 1 < detail.len) {
        const rtype = std.mem.trim(u8, detail[close + 1 ..], " \t\r\n");
        if (rtype.len != 0) try collectTypeNamesFromTypeString(out, rtype);
    }
}

/// Escapes a string for use inside an LSP completion snippet (InsertTextFormat
/// = Snippet). `$`, `}`, and `\` are special in snippet syntax.
fn appendSnippetEscaped(out: *ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        if (c == '$' or c == '}' or c == '\\') try out.append('\\');
        try out.append(c);
    }
}

/// Builds a gopls-style call snippet from a function/method signature `detail`
/// such as `fun add(num a, Point p) num` → `add(${1:a}, ${2:p})$0`. Each
/// parameter becomes a numbered tab-stop placeholder holding the parameter
/// *name* (the last whitespace-separated token of the parameter declaration).
/// Returns an owned string, or null if the signature has no parameter list
/// (in which case the caller should fall back to plain insertion). A zero-arg
/// function returns `name()$0`.
pub fn buildCallSnippet(allocator: Allocator, name: []const u8, detail: []const u8) !?[]const u8 {
    const open = std.mem.indexOfScalar(u8, detail, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, detail, ')') orelse return null;
    if (close < open) return null;

    var out = ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try appendSnippetEscaped(&out, name);
    try out.append('(');

    const params = detail[open + 1 .. close];
    var depth: i32 = 0;
    var seg_start: usize = 0;
    var idx: usize = 0;
    var tab: usize = 0;
    var pi: usize = 0;
    while (pi <= params.len) : (pi += 1) {
        const at_end = pi == params.len;
        const c = if (at_end) ',' else params[pi];
        if (!at_end and (c == '<' or c == '[' or c == '(')) depth += 1;
        if (!at_end and (c == '>' or c == ']' or c == ')')) depth -= 1;
        if ((at_end or c == ',') and depth <= 0) {
            const seg = std.mem.trim(u8, params[seg_start..pi], " \t");
            if (seg.len != 0) {
                tab += 1;
                if (idx > 0) try out.appendSlice(", ");
                idx += 1;
                // Parameter name = last whitespace-separated token; fall back to
                // the whole segment (e.g. a bare `vargs`/variadic marker).
                const last_sp = std.mem.lastIndexOfScalar(u8, seg, ' ');
                const pname = if (last_sp) |sp| std.mem.trim(u8, seg[sp + 1 ..], " \t*") else seg;
                try out.print("${{{d}:", .{tab});
                try appendSnippetEscaped(&out, if (pname.len != 0) pname else seg);
                try out.append('}');
            }
            seg_start = pi + 1;
        }
    }

    try out.append(')');
    try out.appendSlice("$0");
    return try out.toOwnedSlice();
}

pub fn preferDetailedSymbol(a: SymbolLite, b: SymbolLite) bool {
    if (a.detail != null and b.detail == null) return true;
    if (a.detail != null and b.detail != null and a.detail.?.len > b.detail.?.len) return true;
    if (a.value_type != null and b.value_type == null) return true;
    if (a.value_type != null and b.value_type != null) {
        const av = a.value_type.?;
        const bv = b.value_type.?;
        if (!isBuiltinTypeName(av) and isBuiltinTypeName(bv)) return true;
    }
    return false;
}

pub fn hasNonBuiltinValueType(s: SymbolLite) bool {
    if (s.value_type == null) return false;
    const vt = s.value_type.?;
    if (isLetInferTypeName(vt)) return false;
    return !isBuiltinTypeName(vt);
}

pub fn numericBuiltinRank(name: []const u8) u8 {
    if (std.mem.eql(u8, name, "dec")) return 2;
    if (std.mem.eql(u8, name, "num")) return 1;
    return 0;
}

pub fn findBestDefinition(symbols: []const SymbolLite, name: []const u8, at: Position) ?SymbolLite {
    var best_local: ?SymbolLite = null;
    var best_global: ?SymbolLite = null;

    for (symbols) |s| {
        if (!std.mem.eql(u8, s.name, name)) continue;

        if (s.container_fn_range) |cr| {
            if (!posInRange(at, cr)) continue;
            if (!rangeStartLessOrEqual(s.selection_range, at)) continue;
            if (best_local == null or rangeStartGreater(s.selection_range, best_local.?.selection_range) or
                (rangeStartEqual(s.selection_range, best_local.?.selection_range) and preferDetailedSymbol(s, best_local.?)))
            {
                best_local = s;
            }
        } else {
            if (best_global == null) best_global = s;
        }
    }

    if (best_local) |bl| {
        var best = bl;
        var preferred_non_builtin: ?SymbolLite = null;

        for (symbols) |s| {
            if (!std.mem.eql(u8, s.name, name)) continue;
            if (s.container_fn_range) |cr| {
                if (!posInRange(at, cr)) continue;
            } else {
                continue;
            }
            if (!rangeStartLessOrEqual(s.selection_range, at)) continue;

            if (preferDetailedSymbol(s, best)) {
                best = s;
            }

            if (hasNonBuiltinValueType(s)) {
                if (preferred_non_builtin == null or preferDetailedSymbol(s, preferred_non_builtin.?)) {
                    preferred_non_builtin = s;
                }
            }
        }

        if (preferred_non_builtin) |p| {
            best_local = p;
        } else {
            best_local = best;
        }
    }

    return best_local orelse best_global;
}

pub fn findAnyGlobalDefinition(symbols: []const SymbolLite, name: []const u8) ?SymbolLite {
    for (symbols) |s| {
        if (s.container_fn_range != null) continue;
        if (s.container_type != null) continue;
        if (!std.mem.eql(u8, s.name, name)) continue;
        return s;
    }
    return null;
}

/// A UTF-8 lead byte's sequence length, i.e. how many bytes make up the
/// codepoint it starts. Falls back to 1 for a stray/invalid lead byte (a
/// continuation byte with no preceding lead, or a malformed encoding) so
/// callers always make forward progress instead of looping or reading out
/// of bounds on already-corrupt input.
fn utf8LeadByteLen(b0: u8) usize {
    return std.unicode.utf8ByteSequenceLength(b0) catch 1;
}

/// How many UTF-16 code units the codepoint starting at `text[i]` (a
/// `seq_len`-byte UTF-8 sequence) contributes to an LSP `character` offset.
/// Codepoints above the Basic Multilingual Plane (encoded as 4 UTF-8 bytes)
/// need a UTF-16 surrogate PAIR — 2 units — everything else needs 1.
fn utf16UnitsForSeqLen(seq_len: usize) i64 {
    return if (seq_len == 4) 2 else 1;
}

fn byteIndexForLineStart(text: []const u8, target_line: i64) usize {
    var line: i64 = 0;
    var i: usize = 0;
    while (i < text.len and line < target_line) {
        const ch = text[i];
        if (ch == '\n') {
            line += 1;
            i += 1;
            continue;
        }
        if (ch == '\r' and i + 1 < text.len and text[i + 1] == '\n') {
            line += 1;
            i += 2;
            continue;
        }
        i += 1;
    }
    return i;
}

pub fn byteIndexForPosition(text: []const u8, p: Position) usize {
    // LSP positions are UTF-16 code-unit offsets by spec (absent a
    // negotiated `positionEncoding: "utf-8"`, which this server does not
    // assume every client supports — see `clientSupportsUtf8PositionEncoding`
    // in server.zig). Fun source is mostly ASCII, but comments/strings can
    // still contain non-ASCII text (curly quotes, em dashes, emoji, ...), so
    // `character` must be walked as UTF-16 units over decoded codepoints, NOT
    // as a raw byte count — treating it as bytes silently desyncs every
    // position on a line once ANY multi-byte-UTF-8 character precedes the
    // target column. Callers that compare a client position directly against
    // an internal (byte-column) token/AST range instead of slicing `text`
    // should go through `normalizePositionToByteColumns` first — see there
    // for why a single conversion point matters.
    // We still need to be robust to:
    // - CRLF line endings on Windows
    // - positions that point past end-of-line (formatters can do this)
    const target_line: i64 = if (p.line < 0) 0 else p.line;
    const target_char: i64 = if (p.character < 0) 0 else p.character;

    var i: usize = byteIndexForLineStart(text, target_line);

    // Now `i` is at start of the target line (or end of text).
    var units: i64 = 0;
    while (i < text.len and units < target_char) {
        const ch = text[i];
        if (ch == '\n') break;
        if (ch == '\r') {
            // Treat CRLF as newline.
            if (i + 1 < text.len and text[i + 1] == '\n') break;
        }
        const seq_len = @min(utf8LeadByteLen(ch), text.len - i);
        i += seq_len;
        units += utf16UnitsForSeqLen(seq_len);
    }

    return i;
}

/// Convert a client-supplied (UTF-16 code-unit) `Position` into the
/// equivalent Position using BYTE columns — the convention every internal
/// token/AST `Range` already uses (they're built straight from the lexer's
/// own byte-based column tracking; re-deriving UTF-16 columns for every
/// token up front would mean re-scanning the whole file's text per token,
/// which is O(tokens × file size) and not worth paying on every keystroke).
/// Call this ONCE, right after resolving a request's `(uri, position)` and
/// the document text, and use the result for every subsequent comparison
/// against `TokenLite.range`/AST-node positions (`posInRange`,
/// `findTokenIndexAt`, `findLastTokenIndexBeforeOrAt`, ...). Do NOT also
/// route the result back through `byteIndexForPosition` — that function
/// expects genuine UTF-16 input and would double-convert.
pub fn normalizePositionToByteColumns(text: []const u8, p: Position) Position {
    const target_line: i64 = if (p.line < 0) 0 else p.line;
    const line_start = byteIndexForLineStart(text, target_line);
    const byte_i = byteIndexForPosition(text, p);
    const byte_col: i64 = @intCast(byte_i - line_start);
    return .{ .line = target_line, .character = byte_col };
}

pub fn guessIdentifierPrefix(text: []const u8, p: Position) []const u8 {
    const idx = byteIndexForPosition(text, p);
    var start = idx;
    while (start > 0) {
        const ch = text[start - 1];
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
        if (!ok) break;
        start -= 1;
    }
    return text[start..idx];
}

pub fn guessTypeFromTextFallback(text: []const u8, name: []const u8, at: Position) ?[]const u8 {
    if (name.len == 0) return null;
    var limit = byteIndexForPosition(text, at);
    if (limit < name.len and text.len >= name.len) {
        limit = text.len;
    }
    if (limit < name.len) return null;

    const is_ident_char = struct {
        fn call(ch: u8) bool {
            return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
        }
    }.call;

    var i: usize = limit;
    while (i >= name.len) : (i -= 1) {
        const start = i - name.len;
        if (!std.mem.eql(u8, text[start..i], name)) continue;

        // Ensure identifier boundaries.
        if (start > 0 and is_ident_char(text[start - 1])) continue;
        if (i < text.len and is_ident_char(text[i])) continue;

        // Walk left to find the type token.
        var j: usize = start;
        // Skip whitespace.
        while (j > 0) {
            const ch = text[j - 1];
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                j -= 1;
                continue;
            }
            break;
        }

        // Skip generic args if present: `Type<...> name`.
        if (j > 0 and text[j - 1] == '>') {
            var depth: i64 = 0;
            var k: isize = @as(isize, @intCast(j)) - 1;
            while (k >= 0) : (k -= 1) {
                const ch = text[@intCast(k)];
                if (ch == '>') depth += 1;
                if (ch == '<') {
                    depth -= 1;
                    if (depth == 0) {
                        j = @as(usize, @intCast(k));
                        break;
                    }
                }
            }
        }

        // Skip whitespace and pointer/ref markers.
        while (j > 0) {
            const ch = text[j - 1];
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == '*' or ch == '&') {
                j -= 1;
                continue;
            }
            break;
        }

        const end = j;
        while (j > 0 and is_ident_char(text[j - 1])) {
            j -= 1;
        }
        if (end == j) continue;

        return text[j..end];
    }

    return null;
}

/// A Fun language keyword that can never be the receiver of a `.member`
/// access. Used by the text-based receiver scanners so that a dot-shorthand
/// like `ret .Variant` or `= .Ok` is not misinterpreted as `ret.` / `=.`.
pub fn isReceiverStopKeyword(word: []const u8) bool {
    const kws = [_][]const u8{
        "imp",      "as",   "pub",   "async",    "fun",  "compound", "quirk",
        "impl",     "enum", "asm",   "volatile", "arch", "defer",    "await",
        "ret",      "if",   "elif",  "else",     "for",  "fit",      "break",
        "continue", "void", "raw",   "num",      "dec",  "str",      "bin",
        "chr",      "true", "false", "nil",      "fork", "allow",    "expect",
        "sizeof",
    };
    for (kws) |kw| {
        if (std.mem.eql(u8, kw, word)) return true;
    }
    return false;
}

pub fn guessReceiverNameBeforeCursor(text: []const u8, p: Position) ?[]const u8 {
    const idx = byteIndexForPosition(text, p);
    if (idx == 0) return null;

    var dot_i_opt: ?usize = null;
    var i: usize = idx;
    while (i > 0) {
        const ch = text[i - 1];
        if (ch == '\n' or ch == '\r') break;
        if (ch == '.') {
            dot_i_opt = i - 1;
            break;
        }
        i -= 1;
    }
    const dot_i = dot_i_opt orelse return null;

    // Scan left to find receiver identifier. The receiver must be adjacent to
    // the dot on the SAME line: only skip spaces/tabs, never newlines. This
    // prevents an identifier on a previous line (or a bare-dot shorthand) from
    // being mis-bound as the receiver.
    var j: usize = dot_i;
    while (j > 0) {
        const ch = text[j - 1];
        if (ch == ' ' or ch == '\t') {
            j -= 1;
            continue;
        }
        break;
    }
    var start: usize = j;
    while (start > 0) {
        const ch = text[start - 1];
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
        if (!ok) break;
        start -= 1;
    }
    if (start >= j) return null;
    const name = text[start..j];
    if (isReceiverStopKeyword(name)) return null;
    return name;
}

pub fn guessReceiverNameAtCursor(text: []const u8, p: Position) ?[]const u8 {
    const idx = byteIndexForPosition(text, p);
    if (idx == 0) return null;
    if (text[idx - 1] != '.') return null;

    // Receiver must be adjacent to the dot on the SAME line: skip only
    // spaces/tabs, never newlines.
    var j: usize = idx - 1;
    while (j > 0) {
        const ch = text[j - 1];
        if (ch == ' ' or ch == '\t') {
            j -= 1;
            continue;
        }
        break;
    }
    var start: usize = j;
    while (start > 0) {
        const ch = text[start - 1];
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
        if (!ok) break;
        start -= 1;
    }
    if (start >= j) return null;
    const name = text[start..j];
    if (isReceiverStopKeyword(name)) return null;
    return name;
}

pub const ReceiverGuess = struct {
    name: []const u8,
    indexed: bool,
};

pub fn guessReceiverAtCursorWithIndex(text: []const u8, p: Position) ?ReceiverGuess {
    const idx = byteIndexForPosition(text, p);
    if (idx == 0) return null;

    var dot_i_opt: ?usize = null;
    var i: usize = idx;
    while (i > 0) {
        const ch = text[i - 1];
        if (ch == '\n' or ch == '\r') break;
        if (ch == '.') {
            dot_i_opt = i - 1;
            break;
        }
        i -= 1;
    }
    const dot_i = dot_i_opt orelse return null;

    const is_ident_char = struct {
        fn call(ch: u8) bool {
            return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
        }
    }.call;

    // Receiver must be adjacent to the dot on the SAME line: skip only
    // spaces/tabs, never newlines.
    var j: usize = dot_i;
    while (j > 0) {
        const ch = text[j - 1];
        if (ch == ' ' or ch == '\t') {
            j -= 1;
            continue;
        }
        break;
    }

    var indexed = false;
    if (j > 0 and text[j - 1] == ']') {
        var depth: i64 = 0;
        var k: usize = j;
        var found = false;
        while (k > 0) {
            const ch = text[k - 1];
            if (ch == ']') depth += 1;
            if (ch == '[') {
                depth -= 1;
                if (depth == 0) {
                    j = k - 1;
                    found = true;
                    break;
                }
            }
            k -= 1;
        }
        if (!found) return null;
        indexed = true;

        while (j > 0) {
            const ch = text[j - 1];
            if (ch == ' ' or ch == '\t') {
                j -= 1;
                continue;
            }
            break;
        }
    }

    var start: usize = j;
    while (start > 0 and is_ident_char(text[start - 1])) {
        start -= 1;
    }
    if (start >= j) return null;
    const name = text[start..j];
    if (isReceiverStopKeyword(name)) return null;
    return .{ .name = name, .indexed = indexed };
}

test "fls: byteIndexForPosition handles CRLF" {
    const text = "a\r\nb\r\nc";

    try std.testing.expectEqual(@as(usize, 0), byteIndexForPosition(text, .{ .line = 0, .character = 0 }));
    try std.testing.expectEqual(@as(usize, 1), byteIndexForPosition(text, .{ .line = 0, .character = 1 }));

    // Start of line 1 is after "a\r\n".
    try std.testing.expectEqual(@as(usize, 3), byteIndexForPosition(text, .{ .line = 1, .character = 0 }));
    try std.testing.expectEqual(@as(usize, 4), byteIndexForPosition(text, .{ .line = 1, .character = 1 }));
}

test "fls: byteIndexForPosition clamps past end-of-line" {
    if (_skip_lsp_tests_in_ci) return;
    const text = "ab\r\ncd\nEF";
    // line 0 is "ab"; char past EOL should clamp to the CR (start of CRLF)
    try std.testing.expectEqual(@as(usize, 2), byteIndexForPosition(text, .{ .line = 0, .character = 999 }));
    // line 1 is "cd"; char past EOL clamps to '\n'
    try std.testing.expectEqual(@as(usize, 6), byteIndexForPosition(text, .{ .line = 1, .character = 999 }));
}

test "fls: byteIndexForPosition clamps past end-of-text" {
    if (_skip_lsp_tests_in_ci) return;
    const text = "x\n";
    try std.testing.expectEqual(text.len, byteIndexForPosition(text, .{ .line = 99, .character = 0 }));
    try std.testing.expectEqual(text.len, byteIndexForPosition(text, .{ .line = 99, .character = 99 }));
}

test "fls: concreteGenericTypeSliceAtPosition extracts generic usage" {
    if (_skip_lsp_tests_in_ci) return;
    const text =
        "imp std.channel;\n\n" ++
        "async fun main() num {\n" ++
        "  Channel<num> src = channel_new_cap(0, 1);\n" ++
        "}\n";

    const got = concreteGenericTypeSliceAtPosition(text, .{ .line = 3, .character = 4 }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Channel<num>", got);
}

test "fls: byteIndexForPosition reference bounds (table)" {
    const Case = struct { text: []const u8, pos: Position, expected: usize };

    const cases = [_]Case{
        .{ .text = "a\nb", .pos = .{ .line = -1, .character = -1 }, .expected = 0 },
        .{ .text = "a\nb", .pos = .{ .line = 0, .character = 0 }, .expected = 0 },
        .{ .text = "a\nb", .pos = .{ .line = 0, .character = 1 }, .expected = 1 },
        .{ .text = "a\nb", .pos = .{ .line = 0, .character = 99 }, .expected = 1 },
        .{ .text = "a\nb", .pos = .{ .line = 1, .character = 0 }, .expected = 2 },
        .{ .text = "a\nb", .pos = .{ .line = 1, .character = 1 }, .expected = 3 },
        .{ .text = "a\nb", .pos = .{ .line = 2, .character = 0 }, .expected = 3 },

        .{ .text = "a\r\nb\r\n", .pos = .{ .line = 0, .character = 0 }, .expected = 0 },
        .{ .text = "a\r\nb\r\n", .pos = .{ .line = 0, .character = 1 }, .expected = 1 },
        .{ .text = "a\r\nb\r\n", .pos = .{ .line = 0, .character = 99 }, .expected = 1 },
        .{ .text = "a\r\nb\r\n", .pos = .{ .line = 1, .character = 0 }, .expected = 3 },
        .{ .text = "a\r\nb\r\n", .pos = .{ .line = 1, .character = 1 }, .expected = 4 },
        .{ .text = "a\r\nb\r\n", .pos = .{ .line = 1, .character = 99 }, .expected = 4 },
        .{ .text = "a\r\nb\r\n", .pos = .{ .line = 2, .character = 0 }, .expected = 6 },

        .{ .text = "", .pos = .{ .line = 0, .character = 0 }, .expected = 0 },
        .{ .text = "", .pos = .{ .line = 10, .character = 10 }, .expected = 0 },
    };

    for (cases) |c| {
        const got = byteIndexForPosition(c.text, c.pos);
        try std.testing.expectEqual(c.expected, got);
        try std.testing.expect(got <= c.text.len);
    }
}

test "fls: buildCallSnippet produces numbered placeholders from a signature" {
    const a = std.testing.allocator;
    const snip = (try buildCallSnippet(a, "add", "fun add(num a, num b) num")).?;
    defer a.free(snip);
    try std.testing.expectEqualStrings("add(${1:a}, ${2:b})$0", snip);
}

test "fls: buildCallSnippet handles zero args and pointer params" {
    const a = std.testing.allocator;
    const z = (try buildCallSnippet(a, "now", "fun now() num")).?;
    defer a.free(z);
    try std.testing.expectEqualStrings("now()$0", z);

    const ptr = (try buildCallSnippet(a, "free", "fun free(raw* p) void")).?;
    defer a.free(ptr);
    try std.testing.expectEqualStrings("free(${1:p})$0", ptr);
}

test "fls: buildCallSnippet escapes snippet metacharacters in names" {
    const a = std.testing.allocator;
    // A pathological param name containing '$' and '}' must be escaped.
    const s = (try buildCallSnippet(a, "f", "fun f(num a$b}c) num")).?;
    defer a.free(s);
    try std.testing.expectEqualStrings("f(${1:a\\$b\\}c})$0", s);
}

test "fls: buildCallSnippet returns null when there is no parameter list" {
    const a = std.testing.allocator;
    try std.testing.expect((try buildCallSnippet(a, "x", "x")) == null);
}

test "fls: paramNameFromLabel extracts the name" {
    try std.testing.expectEqualStrings("a", paramNameFromLabel("num a"));
    try std.testing.expectEqualStrings("p", paramNameFromLabel("Point* p"));
    try std.testing.expectEqualStrings("names", paramNameFromLabel("str[] names"));
    try std.testing.expectEqualStrings("vargs", paramNameFromLabel("vargs"));
}

test "fls: collectTypeNamesFromTypeString splits generics and pointers" {
    const a = std.testing.allocator;
    var out = ArrayList([]const u8).init(a);
    defer out.deinit();
    try collectTypeNamesFromTypeString(&out, "Map<str, List<num>>*");
    // Map, str, List, num
    try std.testing.expectEqual(@as(usize, 4), out.items.len);
    try std.testing.expectEqualStrings("Map", out.items[0]);
    try std.testing.expectEqualStrings("str", out.items[1]);
    try std.testing.expectEqualStrings("List", out.items[2]);
    try std.testing.expectEqualStrings("num", out.items[3]);
}

test "fls: collectReturnAndParamTypeNames extracts param + return types" {
    const a = std.testing.allocator;
    var out = ArrayList([]const u8).init(a);
    defer out.deinit();
    try collectReturnAndParamTypeNames(&out, "fun midpoint(Point p, Point q) Line");
    // Point, Point, Line (param TYPES + return type; param names skipped)
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("Point", out.items[0]);
    try std.testing.expectEqualStrings("Point", out.items[1]);
    try std.testing.expectEqualStrings("Line", out.items[2]);
}

// Build a flat token stream from {kind, text} pairs with synthetic ranges
// (one token per column on line 0) for testing call-vs-declaration detection.
fn mkToks(buf: []TokenLite, specs: []const struct { k: TokenLiteKind, t: []const u8 }) []TokenLite {
    for (specs, 0..) |s, i| {
        buf[i] = .{
            .kind = s.k,
            .text = s.t,
            .range = .{
                .start = .{ .line = 0, .character = @intCast(i) },
                .end = .{ .line = 0, .character = @intCast(i + 1) },
            },
        };
    }
    return buf[0..specs.len];
}

test "fls: callParenIsDeclaration detects impl method declaration (pub name(...) {)" {
    var buf: [16]TokenLite = undefined;
    // pub copy_from ( T [ ] src , num len ) {
    const toks = mkToks(&buf, &.{
        .{ .k = .keyword, .t = "pub" }, // 0
        .{ .k = .identifier, .t = "copy_from" }, // 1 (name)
        .{ .k = .symbol, .t = "(" }, // 2 (lparen)
        .{ .k = .identifier, .t = "T" }, // 3
        .{ .k = .operator, .t = "[" }, // 4
        .{ .k = .operator, .t = "]" }, // 5
        .{ .k = .identifier, .t = "src" }, // 6
        .{ .k = .symbol, .t = "," }, // 7
        .{ .k = .keyword, .t = "num" }, // 8
        .{ .k = .identifier, .t = "len" }, // 9
        .{ .k = .symbol, .t = ")" }, // 10
        .{ .k = .symbol, .t = "{" }, // 11
    });
    try std.testing.expect(callParenIsDeclaration(toks, 1, 2));
}

test "fls: callParenIsDeclaration detects fun declaration with return type" {
    var buf: [16]TokenLite = undefined;
    // fun add ( num a , num b ) num {
    const toks = mkToks(&buf, &.{
        .{ .k = .keyword, .t = "fun" }, // 0
        .{ .k = .identifier, .t = "add" }, // 1
        .{ .k = .symbol, .t = "(" }, // 2
        .{ .k = .keyword, .t = "num" }, // 3
        .{ .k = .identifier, .t = "a" }, // 4
        .{ .k = .symbol, .t = "," }, // 5
        .{ .k = .keyword, .t = "num" }, // 6
        .{ .k = .identifier, .t = "b" }, // 7
        .{ .k = .symbol, .t = ")" }, // 8
        .{ .k = .keyword, .t = "num" }, // 9 (return type)
        .{ .k = .symbol, .t = "{" }, // 10
    });
    try std.testing.expect(callParenIsDeclaration(toks, 1, 2));
}

test "fls: callParenIsDeclaration treats a call as NOT a declaration" {
    var buf: [16]TokenLite = undefined;
    // add ( 1 , 2 ) ;
    const toks = mkToks(&buf, &.{
        .{ .k = .identifier, .t = "add" }, // 0
        .{ .k = .symbol, .t = "(" }, // 1
        .{ .k = .number, .t = "1" }, // 2
        .{ .k = .symbol, .t = "," }, // 3
        .{ .k = .number, .t = "2" }, // 4
        .{ .k = .symbol, .t = ")" }, // 5
        .{ .k = .symbol, .t = ";" }, // 6
    });
    try std.testing.expect(!callParenIsDeclaration(toks, 0, 1));
}

test "fls: callParenIsDeclaration treats a method call (recv.m(...)) as NOT a declaration" {
    var buf: [16]TokenLite = undefined;
    // b . set ( 3 , 4 ) ;
    const toks = mkToks(&buf, &.{
        .{ .k = .identifier, .t = "b" }, // 0
        .{ .k = .operator, .t = "." }, // 1
        .{ .k = .identifier, .t = "set" }, // 2 (name)
        .{ .k = .symbol, .t = "(" }, // 3 (lparen)
        .{ .k = .number, .t = "3" }, // 4
        .{ .k = .symbol, .t = "," }, // 5
        .{ .k = .number, .t = "4" }, // 6
        .{ .k = .symbol, .t = ")" }, // 7
        .{ .k = .symbol, .t = ";" }, // 8
    });
    try std.testing.expect(!callParenIsDeclaration(toks, 2, 3));
}

test "fls: callParenIsDeclaration treats a fit-subject call (fit f(x) {) as NOT a declaration" {
    var buf: [16]TokenLite = undefined;
    // fit parse ( src ) {  — the `)`-then-`{` looks like a decl, but `fit` before the
    // name makes it a call expression (the fit subject). Must NOT be a declaration,
    // otherwise inlay parameter hints are wrongly suppressed on the subject call.
    const toks = mkToks(&buf, &.{
        .{ .k = .keyword, .t = "fit" }, // 0
        .{ .k = .identifier, .t = "parse" }, // 1 (name)
        .{ .k = .symbol, .t = "(" }, // 2 (lparen)
        .{ .k = .identifier, .t = "src" }, // 3
        .{ .k = .symbol, .t = ")" }, // 4
        .{ .k = .symbol, .t = "{" }, // 5
    });
    try std.testing.expect(!callParenIsDeclaration(toks, 1, 2));
}
