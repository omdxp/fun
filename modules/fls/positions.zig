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

pub fn byteIndexForPosition(text: []const u8, p: Position) usize {
    // LSP positions are UTF-16 by spec.
    // Fun source is typically ASCII, but we still need to be robust to:
    // - CRLF line endings on Windows
    // - positions that point past end-of-line (formatters can do this)
    // We treat `character` as a byte offset within the line and clamp safely.
    const target_line: i64 = if (p.line < 0) 0 else p.line;
    const target_char: i64 = if (p.character < 0) 0 else p.character;

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

    // Now `i` is at start of the target line (or end of text).
    var col: i64 = 0;
    while (i < text.len and col < target_char) {
        const ch = text[i];
        if (ch == '\n') break;
        if (ch == '\r') {
            // Treat CRLF as newline.
            if (i + 1 < text.len and text[i + 1] == '\n') break;
        }
        i += 1;
        col += 1;
    }

    return i;
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

    // Scan left to find receiver identifier.
    var j: usize = dot_i;
    while (j > 0) {
        const ch = text[j - 1];
        if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
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
    return text[start..j];
}

pub fn guessReceiverNameAtCursor(text: []const u8, p: Position) ?[]const u8 {
    const idx = byteIndexForPosition(text, p);
    if (idx == 0) return null;
    if (text[idx - 1] != '.') return null;

    var j: usize = idx - 1;
    while (j > 0) {
        const ch = text[j - 1];
        if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
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
    return text[start..j];
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

    var j: usize = dot_i;
    while (j > 0) {
        const ch = text[j - 1];
        if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
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
            if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
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
    return .{ .name = text[start..j], .indexed = indexed };
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
