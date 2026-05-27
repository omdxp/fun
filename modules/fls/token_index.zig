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
const SymbolKind = types.SymbolKind;

const positions_mod = @import("positions.zig");
const byteIndexForPosition = positions_mod.byteIndexForPosition;
const rangeFromTokenPos = positions_mod.rangeFromTokenPos;
const isLetInferTypeName = positions_mod.isLetInferTypeName;
const isBuiltinTypeName = positions_mod.isBuiltinTypeName;

pub fn trimLeftSpace(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    return s[i..];
}

pub fn trimRightCR(s: []const u8) []const u8 {
    if (s.len != 0 and s[s.len - 1] == '\r') return s[0 .. s.len - 1];
    return s;
}

pub fn appendDocCommentAboveLine(allocator: Allocator, out: *ArrayList(u8), text: []const u8, decl_line: i64) !bool {
    // Collect contiguous `//...` lines immediately above `decl_line`.
    // Stop on the first blank or non-comment line.
    if (decl_line <= 0) return false;

    const decl_start = byteIndexForPosition(text, .{ .line = decl_line, .character = 0 });
    var cur_start: usize = decl_start;
    if (cur_start == 0) return false;

    var lines = ArrayList([]const u8).init(allocator);
    defer lines.deinit();

    while (cur_start > 0) {
        var prev_end: usize = cur_start - 1;

        // If we're sitting right after a newline, step back over it.
        if (text[prev_end] == '\n' and prev_end > 0) prev_end -= 1;

        // Find start of previous line.
        var prev_start: usize = prev_end;
        while (prev_start > 0 and text[prev_start - 1] != '\n') : (prev_start -= 1) {}

        var line = text[prev_start .. prev_end + 1];
        line = trimRightCR(line);
        const trimmed = trimLeftSpace(line);

        if (trimmed.len == 0) break;
        if (!std.mem.startsWith(u8, trimmed, "//")) break;

        var content = trimmed[2..];
        content = trimLeftSpace(content);
        try lines.append(content);

        cur_start = prev_start;
    }

    if (lines.items.len == 0) return false;

    // Render top-to-bottom.
    var i: isize = @intCast(lines.items.len);
    while (i > 0) : (i -= 1) {
        const l = lines.items[@intCast(i - 1)];
        try out.print("{s}\n", .{l});
    }
    try out.appendSlice("\n");
    return true;
}

pub fn tokenString(t: token.Token) []const u8 {
    return switch (t.data) {
        .sval => |sv| sv.items,
        else => "",
    };
}

pub fn isKeyword(t: token.Token, kw: []const u8) bool {
    return t.type == .Keyword and std.mem.eql(u8, tokenString(t), kw);
}

pub fn isIdent(t: token.Token) bool {
    return t.type == .Identifier;
}

pub fn isSymbolChar(t: token.Token, c: u8) bool {
    return t.type == .Symbol and t.data == .cval and t.data.cval == c;
}

pub fn isPunctChar(t: token.Token, c: u8) bool {
    switch (t.type) {
        .Symbol => return switch (t.data) {
            .cval => |v| v == c,
            else => false,
        },
        .Operator => return switch (t.data) {
            .sval => |sv| sv.items.len == 1 and sv.items[0] == c,
            else => false,
        },
        else => return false,
    }
}

pub fn isPrimitiveTypeKeywordName(s: []const u8) bool {
    // Fun primitive datatypes.
    return std.mem.eql(u8, s, "void") or std.mem.eql(u8, s, "raw") or std.mem.eql(u8, s, "num") or std.mem.eql(u8, s, "dec") or
        std.mem.eql(u8, s, "str") or std.mem.eql(u8, s, "bin") or std.mem.eql(u8, s, "chr");
}

pub fn isArrayTypeName(name: []const u8) bool {
    return name.len >= 2 and name[name.len - 2] == '[' and name[name.len - 1] == ']';
}

pub fn isTypeToken(t: token.Token) bool {
    if (t.type == .Identifier) return true;
    if (t.type == .Keyword and isPrimitiveTypeKeywordName(tokenString(t))) return true;
    return false;
}

pub fn nextNonTrivialToken(tokens: []const token.Token, start_index: usize) ?usize {
    var i = start_index;
    while (i < tokens.len) : (i += 1) {
        const t = tokens[i];
        if (t.type == .NewLine or t.type == .Comment) continue;
        return i;
    }
    return null;
}

pub fn prevNonTrivialToken(tokens: []const token.Token, start_index: usize) ?usize {
    if (start_index == 0) return null;
    var i: isize = @intCast(start_index);
    while (i > 0) : (i -= 1) {
        const t = tokens[@intCast(i - 1)];
        if (t.type == .NewLine or t.type == .Comment) continue;
        return @intCast(i - 1);
    }
    return null;
}

pub fn skipGenericArgsForward(tokens: []const token.Token, start_index: usize) usize {
    if (start_index >= tokens.len) return start_index;
    const start_text = tokenString(tokens[start_index]);
    if (std.mem.indexOfScalar(u8, start_text, '<') == null) return start_index;
    var depth: i64 = 0;
    var i: usize = start_index;
    while (i < tokens.len) : (i += 1) {
        const t = tokens[i];
        if (t.type == .NewLine or t.type == .Comment) continue;

        const ts = tokenString(t);
        var j: usize = 0;
        while (j < ts.len) : (j += 1) {
            const ch = ts[j];
            if (ch == '<') {
                depth += 1;
                continue;
            }
            if (ch == '>') {
                depth -= 1;
                if (depth == 0) return nextNonTrivialToken(tokens, i + 1) orelse (i + 1);
            }
        }
    }
    return i;
}

pub fn rangeFromTokenSpan(start_t: token.Token, end_t: token.Token) Range {
    const sr = rangeFromTokenPos(start_t.pos);
    const er = rangeFromTokenPos(end_t.pos);
    return .{ .start = sr.start, .end = er.end };
}

pub fn buildSignatureFromTokens(
    allocator: Allocator,
    tokens: []const token.Token,
    name_i: usize,
    include_fun_prefix: bool,
) !struct { detail: ?[]u8, return_type: ?[]u8 } {
    if (name_i >= tokens.len) return .{ .detail = null, .return_type = null };
    if (!isIdent(tokens[name_i])) return .{ .detail = null, .return_type = null };

    var after_name_i = nextNonTrivialToken(tokens, name_i + 1) orelse return .{ .detail = null, .return_type = null };

    var name_buf = ArrayList(u8).init(allocator);
    errdefer name_buf.deinit();
    try name_buf.appendSlice(tokenString(tokens[name_i]));

    // Optional generic params between name and '(' (e.g., `fun id<T>(...)`).
    if (isPunctChar(tokens[after_name_i], '<')) {
        var depth: i64 = 0;
        var i: usize = after_name_i;
        var first_param = true;
        var params_buf = ArrayList(u8).init(allocator);
        defer params_buf.deinit();

        while (i < tokens.len) : (i += 1) {
            const t = tokens[i];
            if (t.type == .NewLine or t.type == .Comment) continue;
            if (isPunctChar(t, '<')) {
                depth += 1;
                continue;
            }
            if (isPunctChar(t, '>')) {
                depth -= 1;
                if (depth == 0) break;
                continue;
            }
            if (depth == 1 and isIdent(t)) {
                if (!first_param) try params_buf.appendSlice(", ");
                first_param = false;
                try params_buf.appendSlice(tokenString(t));
            }
        }

        if (params_buf.items.len != 0) {
            try name_buf.append('<');
            try name_buf.appendSlice(params_buf.items);
            try name_buf.append('>');
        }

        after_name_i = skipGenericArgsForward(tokens, after_name_i);
    }

    if (!isPunctChar(tokens[after_name_i], '(')) return .{ .detail = null, .return_type = null };

    // Find matching ')'
    var depth: i64 = 0;
    var rparen_i: ?usize = null;
    var k: usize = after_name_i;
    while (k < tokens.len) : (k += 1) {
        const tk = tokens[k];
        if (isPunctChar(tk, '(')) depth += 1;
        if (isPunctChar(tk, ')')) {
            depth -= 1;
            if (depth == 0) {
                rparen_i = k;
                break;
            }
        }
    }
    if (rparen_i == null) return .{ .detail = null, .return_type = null };

    var buf = ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    const is_async_decl = blk: {
        const prev_i = prevNonTrivialToken(tokens, name_i) orelse break :blk false;
        if (isKeyword(tokens[prev_i], "async")) break :blk true;
        if (include_fun_prefix and isKeyword(tokens[prev_i], "fun")) {
            const prev2_i = prevNonTrivialToken(tokens, prev_i) orelse break :blk false;
            if (isKeyword(tokens[prev2_i], "async")) break :blk true;
        }
        break :blk false;
    };

    if (is_async_decl) {
        try buf.appendSlice("async ");
    }

    if (include_fun_prefix) {
        try buf.print("fun {s}(", .{name_buf.items});
    } else {
        try buf.print("{s}(", .{name_buf.items});
    }

    const parsed = struct {
        fn isStarToken(t: token.Token) bool {
            if (t.type == .Operator and t.data == .sval and std.mem.eql(u8, t.data.sval.items, "*")) return true;
            if (t.type == .Symbol and t.data == .cval and t.data.cval == '*') return true;
            return false;
        }

        fn appendGenericSuffix(out_buf: *ArrayList(u8), all_tokens: []const token.Token, start_i: usize) !usize {
            if (start_i >= all_tokens.len) return start_i;
            if (!isPunctChar(all_tokens[start_i], '<')) return start_i;

            var generic_depth: i64 = 0;
            var i = start_i;
            while (i < all_tokens.len) : (i += 1) {
                const tk = all_tokens[i];
                if (tk.type == .NewLine or tk.type == .Comment) continue;

                if (isPunctChar(tk, '<')) {
                    generic_depth += 1;
                    try out_buf.append('<');
                    continue;
                }

                if (isPunctChar(tk, '>')) {
                    generic_depth -= 1;
                    try out_buf.append('>');
                    if (generic_depth == 0) {
                        return nextNonTrivialToken(all_tokens, i + 1) orelse (i + 1);
                    }
                    continue;
                }

                if (generic_depth <= 0) break;

                if (isPunctChar(tk, ',')) {
                    try out_buf.appendSlice(", ");
                    continue;
                }

                const ts = tokenString(tk);
                if (ts.len == 0) continue;
                try out_buf.appendSlice(ts);
            }

            return i;
        }

        fn appendPointerSuffix(out_buf: *ArrayList(u8), all_tokens: []const token.Token, start_i: usize) !usize {
            var i = start_i;
            while (i < all_tokens.len and isStarToken(all_tokens[i])) : (i += 1) {
                try out_buf.append('*');
            }
            return i;
        }

        fn appendArraySuffix(out_buf: *ArrayList(u8), all_tokens: []const token.Token, start_i: usize) !usize {
            var i = start_i;
            while (i < all_tokens.len) {
                const tk = all_tokens[i];
                if (!isPunctChar(tk, '[')) break;

                try out_buf.appendSlice("[]");

                var bracket_depth: i64 = 0;
                while (i < all_tokens.len) : (i += 1) {
                    const at = all_tokens[i];
                    if (at.type == .NewLine or at.type == .Comment) continue;
                    if (isPunctChar(at, '[')) {
                        bracket_depth += 1;
                        continue;
                    }
                    if (isPunctChar(at, ']')) {
                        bracket_depth -= 1;
                        if (bracket_depth == 0) {
                            i = nextNonTrivialToken(all_tokens, i + 1) orelse (i + 1);
                            break;
                        }
                    }
                }
            }
            return i;
        }
    };

    // Parse params as `Type[*...] name` pairs.
    var first: bool = true;
    var pi: usize = after_name_i + 1;
    while (pi < rparen_i.?) {
        const pt = tokens[pi];
        if (pt.type == .NewLine or pt.type == .Comment) {
            pi += 1;
            continue;
        }
        if (isPunctChar(pt, ',')) {
            pi += 1;
            continue;
        }

        if (pt.type == .Operator and std.mem.eql(u8, tokenString(pt), "...")) {
            if (!first) try buf.appendSlice(", ");
            first = false;
            try buf.appendSlice("...");
            break;
        }

        if (!isTypeToken(pt)) {
            pi += 1;
            continue;
        }
        const ptype_raw = tokenString(pt);
        const ptype = allocator.dupe(u8, ptype_raw) catch ptype_raw;
        var ptype_buf = ArrayList(u8).init(allocator);
        defer ptype_buf.deinit();
        try ptype_buf.appendSlice(ptype);
        var after_type_i = nextNonTrivialToken(tokens, pi + 1) orelse break;
        after_type_i = try parsed.appendGenericSuffix(&ptype_buf, tokens, after_type_i);
        const after_ptr_i = try parsed.appendPointerSuffix(&ptype_buf, tokens, after_type_i);
        const after_array_i = try parsed.appendArraySuffix(&ptype_buf, tokens, after_ptr_i);

        const pname_i = nextNonTrivialToken(tokens, after_array_i) orelse break;
        if (!isIdent(tokens[pname_i])) {
            pi += 1;
            continue;
        }
        const pname_raw = tokenString(tokens[pname_i]);
        const pname = allocator.dupe(u8, pname_raw) catch pname_raw;
        if (!first) try buf.appendSlice(", ");
        first = false;
        try buf.print("{s} {s}", .{ ptype_buf.items, pname });
        pi = pname_i + 1;
    }

    try buf.append(')');

    // Optional return type: `<type>[*...]` before `{` or `;`.
    var rtype_owned: ?[]u8 = null;
    const after_rparen_i = nextNonTrivialToken(tokens, rparen_i.? + 1);
    if (after_rparen_i) |ri| {
        const rt = tokens[ri];
        if (isTypeToken(rt)) {
            const rts_raw = tokenString(rt);
            const rts = allocator.dupe(u8, rts_raw) catch rts_raw;

            var rt_buf = ArrayList(u8).init(allocator);
            errdefer rt_buf.deinit();
            try rt_buf.appendSlice(rts);

            var after_type_i = nextNonTrivialToken(tokens, ri + 1) orelse (ri + 1);
            after_type_i = try parsed.appendGenericSuffix(&rt_buf, tokens, after_type_i);

            const after_ptr_i = try parsed.appendPointerSuffix(&rt_buf, tokens, after_type_i);
            _ = try parsed.appendArraySuffix(&rt_buf, tokens, after_ptr_i);
            rtype_owned = try rt_buf.toOwnedSlice();
            try buf.print(" {s}", .{rtype_owned.?});
        }
    }

    return .{ .detail = try buf.toOwnedSlice(), .return_type = rtype_owned };
}

pub fn collectSymbolsFromTokens(allocator: Allocator, out: *ArrayList(SymbolLite), tokens: []const token.Token) !void {
    var brace_depth: i64 = 0;
    var paren_depth: i64 = 0;

    const ParamLite = struct {
        name: []const u8,
        dtype_base: []const u8,
        dtype_display: []const u8,
    };

    // Track when we're inside any function-ish body so we can index locals.
    // This includes:
    // - `fun name(...) { ... }`
    // - `impl Type { method(...) { ... } }`
    const PendingBodyKind = enum { none, fun_decl, impl_method };

    var pending_body: PendingBodyKind = .none;
    var pending_params = ArrayList(ParamLite).init(allocator);
    defer pending_params.deinit();
    var pending_impl_owner: ?[]const u8 = null;
    var pending_is_variadic: bool = false;

    var in_body: bool = false;
    var body_brace_depth: i64 = 0;
    var body_range: ?Range = null;
    var body_symbol_start: usize = 0;

    // Track `impl Type { ... }` so we can recognize method declarations.
    var pending_impl_block: bool = false;
    var in_impl_block: bool = false;
    var impl_brace_depth: i64 = 0;
    var impl_owner_name: ?[]const u8 = null;

    var locals_type_map = std.StringHashMap([]const u8).init(allocator);
    defer locals_type_map.deinit();
    var globals_type_map = std.StringHashMap([]const u8).init(allocator);
    defer globals_type_map.deinit();

    const putType = struct {
        fn call(map: *std.StringHashMap([]const u8), name: []const u8, tname: ?[]const u8, allocator_: Allocator) void {
            if (tname == null) return;
            const key = allocator_.dupe(u8, name) catch name;
            const val = allocator_.dupe(u8, tname.?) catch tname.?;
            map.put(key, val) catch {};
        }
    }.call;

    const resetPendingBody = struct {
        fn call(kind: *PendingBodyKind, params: *ArrayList(ParamLite), owner: *?[]const u8, is_variadic: *bool) void {
            kind.* = .none;
            params.clearRetainingCapacity();
            owner.* = null;
            is_variadic.* = false;
        }
    }.call;

    const isEllipsisToken = struct {
        fn call(t: token.Token) bool {
            return t.type == .Operator and std.mem.eql(u8, tokenString(t), "...");
        }
    }.call;

    const isLetToken = struct {
        fn call(t: token.Token) bool {
            return t.type == .Keyword and std.mem.eql(u8, tokenString(t), "let");
        }
    }.call;

    const isDotTokenAny = struct {
        fn call(t: token.Token) bool {
            if (t.type == .Symbol and t.data == .cval and t.data.cval == '.') return true;
            if (t.type == .Operator and t.data == .sval and std.mem.eql(u8, t.data.sval.items, ".")) return true;
            return false;
        }
    }.call;

    const inferExprTypeFromTokens = struct {
        fn call(
            allocator_: Allocator,
            tokens_: []const token.Token,
            start_i: usize,
            end_i: usize,
            locals_map: *const std.StringHashMap([]const u8),
            globals_map: *const std.StringHashMap([]const u8),
            symbols: []const SymbolLite,
        ) ?[]const u8 {
            const findFunctionReturnType = struct {
                fn callSyms(name: []const u8, syms: []const SymbolLite) ?[]const u8 {
                    for (syms) |s| {
                        if (s.kind != .function) continue;
                        if (!std.mem.eql(u8, s.name, name)) continue;
                        return s.value_type orelse null;
                    }
                    return null;
                }
            }.callSyms;

            const extractFirstGenericArg = struct {
                fn callType(type_name: []const u8) ?[]const u8 {
                    const lt = std.mem.indexOfScalar(u8, type_name, '<') orelse return null;
                    var depth: i64 = 0;
                    const start = lt + 1;
                    var i = start;
                    while (i < type_name.len) : (i += 1) {
                        const ch = type_name[i];
                        if (ch == '<') {
                            depth += 1;
                            continue;
                        }
                        if (ch == '>') {
                            if (depth == 0) {
                                const seg = std.mem.trim(u8, type_name[start..i], " \t\r\n");
                                if (seg.len == 0) return null;
                                return seg;
                            }
                            depth -= 1;
                            continue;
                        }
                        if (ch == ',' and depth == 0) {
                            const seg = std.mem.trim(u8, type_name[start..i], " \t\r\n");
                            if (seg.len == 0) return null;
                            return seg;
                        }
                    }
                    return null;
                }
            }.callType;

            const substituteGenericTypeParam = struct {
                fn genericInner(type_name: []const u8) ?[]const u8 {
                    const lt = std.mem.indexOfScalar(u8, type_name, '<') orelse return null;
                    var depth: i64 = 0;
                    var i = lt;
                    while (i < type_name.len) : (i += 1) {
                        const ch = type_name[i];
                        if (ch == '<') {
                            depth += 1;
                            continue;
                        }
                        if (ch == '>') {
                            depth -= 1;
                            if (depth == 0 and i > lt + 1) {
                                return type_name[lt + 1 .. i];
                            }
                            continue;
                        }
                    }
                    return null;
                }

                fn nextTopLevelSegment(inner: []const u8, idx: *usize) ?[]const u8 {
                    while (idx.* < inner.len) {
                        var depth: i64 = 0;
                        const start = idx.*;
                        var i = start;
                        while (i < inner.len) : (i += 1) {
                            const ch = inner[i];
                            if (ch == '<') {
                                depth += 1;
                                continue;
                            }
                            if (ch == '>') {
                                if (depth > 0) depth -= 1;
                                continue;
                            }
                            if (ch == ',' and depth == 0) break;
                        }

                        idx.* = if (i < inner.len) i + 1 else inner.len;
                        const seg = std.mem.trim(u8, inner[start..i], " \t\r\n");
                        if (seg.len != 0) return seg;
                    }
                    return null;
                }

                fn mapContainerGeneric(container_type: []const u8, receiver_type: []const u8, param_name: []const u8) ?[]const u8 {
                    const c_inner = genericInner(container_type) orelse return null;
                    const r_inner = genericInner(receiver_type) orelse return null;

                    var ci: usize = 0;
                    var ri: usize = 0;
                    while (true) {
                        const cseg = nextTopLevelSegment(c_inner, &ci) orelse break;
                        const rseg = nextTopLevelSegment(r_inner, &ri) orelse break;
                        if (std.mem.eql(u8, cseg, param_name)) {
                            return rseg;
                        }
                    }
                    return null;
                }

                fn callType(container_type: []const u8, receiver_type: []const u8, member_type: []const u8) []const u8 {
                    const mt = std.mem.trim(u8, member_type, " \t\r\n");
                    if (mapContainerGeneric(container_type, receiver_type, mt)) |mapped| {
                        return mapped;
                    }
                    if (mt.len == 1 and std.ascii.isUpper(mt[0])) {
                        if (extractFirstGenericArg(receiver_type)) |arg| return arg;
                    }
                    return member_type;
                }
            }.callType;

            const localBaseTypeName = struct {
                fn callName(name: []const u8) []const u8 {
                    var base = if (std.mem.indexOfScalar(u8, name, '<')) |idx| name[0..idx] else name;
                    base = std.mem.trim(u8, base, " \t\r\n");
                    while (base.len >= 2 and std.mem.eql(u8, base[base.len - 2 ..], "[]")) {
                        base = std.mem.trim(u8, base[0 .. base.len - 2], " \t\r\n");
                    }
                    while (base.len != 0) {
                        const ch = base[base.len - 1];
                        if (ch == '*' or ch == '&') {
                            base = std.mem.trim(u8, base[0 .. base.len - 1], " \t\r\n");
                            continue;
                        }
                        break;
                    }
                    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
                        base = base[dot + 1 ..];
                    }
                    return base;
                }
            }.callName;

            const findMemberReturnType = struct {
                fn callSyms(receiver_type: []const u8, member: []const u8, syms: []const SymbolLite) ?[]const u8 {
                    const want_base = localBaseTypeName(receiver_type);
                    for (syms) |s| {
                        if (s.container_type == null) continue;
                        if (!std.mem.eql(u8, localBaseTypeName(s.container_type.?), want_base)) continue;
                        if (!std.mem.eql(u8, s.name, member)) continue;
                        if (s.kind != .method and s.kind != .function) continue;
                        const rt = s.value_type orelse return null;
                        return substituteGenericTypeParam(s.container_type.?, receiver_type, rt);
                    }
                    return null;
                }
            }.callSyms;

            const findMemberFieldType = struct {
                fn callSyms(receiver_type: []const u8, member: []const u8, syms: []const SymbolLite) ?[]const u8 {
                    const want_base = localBaseTypeName(receiver_type);
                    for (syms) |s| {
                        if (s.container_type == null) continue;
                        if (!std.mem.eql(u8, localBaseTypeName(s.container_type.?), want_base)) continue;
                        if (!std.mem.eql(u8, s.name, member)) continue;
                        if (s.kind != .field and s.kind != .property) continue;
                        const ft = s.value_type orelse return null;
                        return substituteGenericTypeParam(s.container_type.?, receiver_type, ft);
                    }
                    return null;
                }
            }.callSyms;

            const findEnumMemberType = struct {
                fn callSyms(container_type: []const u8, member: []const u8, syms: []const SymbolLite) ?[]const u8 {
                    const want_base = localBaseTypeName(container_type);
                    for (syms) |s| {
                        if (s.container_type == null) continue;
                        if (!std.mem.eql(u8, localBaseTypeName(s.container_type.?), want_base)) continue;
                        if (!std.mem.eql(u8, s.name, member)) continue;
                        if (s.kind != .enumMember) continue;
                        return s.container_type orelse container_type;
                    }
                    return null;
                }
            }.callSyms;

            const findTypeName = struct {
                fn callSyms(name: []const u8, syms: []const SymbolLite) ?[]const u8 {
                    for (syms) |s| {
                        if (!std.mem.eql(u8, s.name, name)) continue;
                        if (s.kind == .struct_ or s.kind == .enum_ or s.kind == .interface) {
                            return s.name;
                        }
                    }
                    return null;
                }
            }.callSyms;

            const resolveIdentType = struct {
                fn callSyms(name: []const u8, lt: *const std.StringHashMap([]const u8), gt: *const std.StringHashMap([]const u8)) ?[]const u8 {
                    if (lt.get(name)) |t| return t;
                    if (gt.get(name)) |t| return t;
                    return null;
                }
            }.callSyms;

            var saw_str = false;
            var saw_bin = false;
            var saw_chr = false;
            var saw_dec = false;
            var saw_num = false;
            var array_literal_depth: usize = 0;
            var candidate: ?[]const u8 = null;
            var candidate_rank: u8 = 0;

            const arrayElementType = struct {
                fn call(name: []const u8) []const u8 {
                    if (isArrayTypeName(name)) return name[0 .. name.len - 2];
                    return name;
                }
            }.call;

            const rankType = struct {
                fn call(name: []const u8) u8 {
                    if (isLetInferTypeName(name)) return 0;
                    if (!isBuiltinTypeName(name)) return 3;
                    if (std.mem.eql(u8, name, "str") or std.mem.eql(u8, name, "bin")) return 2;
                    if (std.mem.eql(u8, name, "dec")) return 2;
                    if (std.mem.eql(u8, name, "num")) return 1;
                    return 1;
                }
            }.call;

            const updateCandidate = struct {
                fn call(best: *?[]const u8, best_rank: *u8, name: []const u8) void {
                    const rank = rankType(name);
                    if (rank == 0) return;
                    if (best.* == null or rank > best_rank.*) {
                        best.* = name;
                        best_rank.* = rank;
                    }
                }
            }.call;

            const isLikelyTypeIdentifier = struct {
                fn call(name: []const u8) bool {
                    if (name.len == 0) return false;
                    return std.ascii.isUpper(name[0]);
                }
            }.call;

            const inferExactTerminalType = struct {
                const Bounds = struct { start: usize, end: usize };

                fn trimBounds(tokens_a: []const token.Token, start: usize, end: usize) ?Bounds {
                    var s = start;
                    var e = end;
                    while (s < e and (tokens_a[s].type == .NewLine or tokens_a[s].type == .Comment)) : (s += 1) {}
                    while (e > s and (tokens_a[e - 1].type == .NewLine or tokens_a[e - 1].type == .Comment)) : (e -= 1) {}
                    if (s >= e) return null;
                    return .{ .start = s, .end = e };
                }

                fn onlyTrivial(tokens_a: []const token.Token, start: usize, end: usize) bool {
                    var i = start;
                    while (i < end) : (i += 1) {
                        const t = tokens_a[i];
                        if (t.type == .NewLine or t.type == .Comment) continue;
                        return false;
                    }
                    return true;
                }

                fn findMatchingParen(tokens_a: []const token.Token, lparen_i: usize, end: usize) ?usize {
                    var depth: i64 = 0;
                    var i = lparen_i;
                    while (i < end) : (i += 1) {
                        const t = tokens_a[i];
                        if (t.type == .NewLine or t.type == .Comment) continue;
                        if (isPunctChar(t, '(')) depth += 1;
                        if (isPunctChar(t, ')')) {
                            depth -= 1;
                            if (depth == 0) return i;
                        }
                    }
                    return null;
                }

                fn findMatchingBracket(tokens_a: []const token.Token, lbr_i: usize, end: usize) ?usize {
                    var depth: i64 = 0;
                    var i = lbr_i;
                    while (i < end) : (i += 1) {
                        const t = tokens_a[i];
                        if (t.type == .NewLine or t.type == .Comment) continue;
                        if (isPunctChar(t, '[')) depth += 1;
                        if (isPunctChar(t, ']')) {
                            depth -= 1;
                            if (depth == 0) return i;
                        }
                    }
                    return null;
                }

                fn findMatchingBrace(tokens_a: []const token.Token, lbrace_i: usize, end: usize) ?usize {
                    var depth: i64 = 0;
                    var i = lbrace_i;
                    while (i < end) : (i += 1) {
                        const t = tokens_a[i];
                        if (t.type == .NewLine or t.type == .Comment) continue;
                        if (isSymbolChar(t, '{')) depth += 1;
                        if (isSymbolChar(t, '}')) {
                            depth -= 1;
                            if (depth == 0) return i;
                        }
                    }
                    return null;
                }

                fn findTopLevelDot(tokens_a: []const token.Token, start: usize, end: usize) ?usize {
                    var p_depth: i64 = 0;
                    var b_depth: i64 = 0;
                    var c_depth: i64 = 0;
                    var i = start;
                    while (i < end) : (i += 1) {
                        const t = tokens_a[i];
                        if (t.type == .NewLine or t.type == .Comment) continue;

                        if (isPunctChar(t, '(')) {
                            p_depth += 1;
                            continue;
                        }
                        if (isPunctChar(t, ')')) {
                            if (p_depth > 0) p_depth -= 1;
                            continue;
                        }
                        if (isPunctChar(t, '[')) {
                            b_depth += 1;
                            continue;
                        }
                        if (isPunctChar(t, ']')) {
                            if (b_depth > 0) b_depth -= 1;
                            continue;
                        }
                        if (isSymbolChar(t, '{')) {
                            c_depth += 1;
                            continue;
                        }
                        if (isSymbolChar(t, '}')) {
                            if (c_depth > 0) c_depth -= 1;
                            continue;
                        }

                        if (p_depth == 0 and b_depth == 0 and c_depth == 0 and isDotTokenAny(t)) {
                            return i;
                        }
                    }
                    return null;
                }

                fn stripOuterParens(tokens_a: []const token.Token, start: usize, end: usize) ?Bounds {
                    var b = trimBounds(tokens_a, start, end) orelse return null;
                    while (true) {
                        if (!isPunctChar(tokens_a[b.start], '(')) break;
                        if (!isPunctChar(tokens_a[b.end - 1], ')')) break;
                        const rp = findMatchingParen(tokens_a, b.start, b.end) orelse break;
                        if (rp != b.end - 1) break;
                        b = trimBounds(tokens_a, b.start + 1, b.end - 1) orelse return null;
                    }
                    return b;
                }

                fn stripPointerLevels(type_name: []const u8, levels: usize) ?[]const u8 {
                    var trimmed = std.mem.trim(u8, type_name, " \t\r\n");
                    var n = levels;
                    while (n > 0) : (n -= 1) {
                        trimmed = std.mem.trimEnd(u8, trimmed, " \t\r\n");
                        if (trimmed.len == 0 or trimmed[trimmed.len - 1] != '*') return null;
                        trimmed = trimmed[0 .. trimmed.len - 1];
                    }
                    trimmed = std.mem.trimEnd(u8, trimmed, " \t\r\n");
                    if (trimmed.len == 0) return null;
                    return trimmed;
                }

                const GenericTypeCore = struct {
                    base: []const u8,
                    inner: []const u8,
                };

                const CallArgRange = struct {
                    start: usize,
                    end: usize,
                };

                const NamedInitArg = struct {
                    field_name: []const u8,
                    expr_range: CallArgRange,
                };

                const CompoundFieldInfo = struct {
                    name: []const u8,
                    value_type: []const u8,
                };

                fn isIdentStartChar(ch: u8) bool {
                    return std.ascii.isAlphabetic(ch) or ch == '_';
                }

                fn isIdentChar(ch: u8) bool {
                    return std.ascii.isAlphanumeric(ch) or ch == '_';
                }

                fn splitTopLevelCsv(allocator_a: Allocator, text: []const u8, out_list: *ArrayList([]const u8)) void {
                    var csv_angle_depth: i64 = 0;
                    var csv_paren_depth: i64 = 0;
                    var csv_brack_depth: i64 = 0;
                    var csv_brace_depth: i64 = 0;
                    var start: usize = 0;

                    var i: usize = 0;
                    while (i < text.len) : (i += 1) {
                        const ch = text[i];
                        switch (ch) {
                            '<' => csv_angle_depth += 1,
                            '>' => {
                                if (csv_angle_depth > 0) csv_angle_depth -= 1;
                            },
                            '(' => csv_paren_depth += 1,
                            ')' => {
                                if (csv_paren_depth > 0) csv_paren_depth -= 1;
                            },
                            '[' => csv_brack_depth += 1,
                            ']' => {
                                if (csv_brack_depth > 0) csv_brack_depth -= 1;
                            },
                            '{' => csv_brace_depth += 1,
                            '}' => {
                                if (csv_brace_depth > 0) csv_brace_depth -= 1;
                            },
                            ',' => {
                                if (csv_angle_depth == 0 and csv_paren_depth == 0 and csv_brack_depth == 0 and csv_brace_depth == 0) {
                                    const seg = std.mem.trim(u8, text[start..i], " \t\r\n");
                                    if (seg.len != 0) {
                                        out_list.append(allocator_a.dupe(u8, seg) catch seg) catch {};
                                    }
                                    start = i + 1;
                                }
                            },
                            else => {},
                        }
                    }

                    const tail = std.mem.trim(u8, text[start..], " \t\r\n");
                    if (tail.len != 0) {
                        out_list.append(allocator_a.dupe(u8, tail) catch tail) catch {};
                    }
                }

                fn parseFunctionGenericParams(allocator_a: Allocator, detail: []const u8, out_params: *ArrayList([]const u8)) void {
                    const lparen = std.mem.indexOfScalar(u8, detail, '(') orelse return;

                    var depth: i64 = 0;
                    var lt_i: ?usize = null;
                    var gt_i: ?usize = null;
                    var i: usize = 0;
                    while (i < lparen) : (i += 1) {
                        const ch = detail[i];
                        if (ch == '<') {
                            if (depth == 0) lt_i = i;
                            depth += 1;
                            continue;
                        }
                        if (ch == '>') {
                            if (depth > 0) {
                                depth -= 1;
                                if (depth == 0) gt_i = i;
                            }
                            continue;
                        }
                    }
                    if (lt_i == null or gt_i == null or gt_i.? <= lt_i.?) return;

                    var raw_params = ArrayList([]const u8).init(allocator_a);
                    defer raw_params.deinit();
                    splitTopLevelCsv(allocator_a, detail[lt_i.? + 1 .. gt_i.?], &raw_params);
                    for (raw_params.items) |rp| {
                        var p = std.mem.trim(u8, rp, " \t\r\n");
                        if (p.len == 0) continue;
                        var cut = p.len;
                        var j: usize = 0;
                        while (j < p.len) : (j += 1) {
                            const ch = p[j];
                            if (ch == ':' or ch == '=' or ch == ' ' or ch == '\t') {
                                cut = j;
                                break;
                            }
                        }
                        p = std.mem.trim(u8, p[0..cut], " \t\r\n");
                        if (p.len == 0) continue;
                        out_params.append(allocator_a.dupe(u8, p) catch p) catch {};
                    }
                }

                fn parseFunctionParamTypes(allocator_a: Allocator, detail: []const u8, out_types: *ArrayList([]const u8)) void {
                    const lparen = std.mem.indexOfScalar(u8, detail, '(') orelse return;
                    var depth: i64 = 0;
                    var rparen: ?usize = null;
                    var i = lparen;
                    while (i < detail.len) : (i += 1) {
                        const ch = detail[i];
                        if (ch == '(') depth += 1;
                        if (ch == ')') {
                            depth -= 1;
                            if (depth == 0) {
                                rparen = i;
                                break;
                            }
                        }
                    }
                    if (rparen == null or rparen.? <= lparen) return;

                    var raw_params = ArrayList([]const u8).init(allocator_a);
                    defer raw_params.deinit();
                    splitTopLevelCsv(allocator_a, detail[lparen + 1 .. rparen.?], &raw_params);

                    for (raw_params.items) |rp| {
                        var seg = std.mem.trim(u8, rp, " \t\r\n");
                        if (seg.len == 0) continue;
                        if (std.mem.eql(u8, seg, "...")) continue;

                        var split_at: ?usize = null;
                        var j = seg.len;
                        while (j > 0) : (j -= 1) {
                            const ch = seg[j - 1];
                            if (ch == ' ' or ch == '\t') {
                                split_at = j - 1;
                                break;
                            }
                        }

                        var tname = seg;
                        if (split_at) |s| {
                            const maybe_type = std.mem.trim(u8, seg[0..s], " \t\r\n");
                            if (maybe_type.len != 0) tname = maybe_type;
                        }

                        out_types.append(allocator_a.dupe(u8, tname) catch tname) catch {};
                    }
                }

                fn parseCallExplicitTypeArgs(allocator_a: Allocator, tokens_a: []const token.Token, l_angle_i: usize, out_args: *ArrayList([]const u8)) void {
                    var depth: i64 = 0;
                    var cur = ArrayList(u8).init(allocator_a);
                    defer cur.deinit();

                    const flush = struct {
                        fn call(allocator_b: Allocator, cur_buf: *ArrayList(u8), out_buf: *ArrayList([]const u8)) void {
                            const seg = std.mem.trim(u8, cur_buf.items, " \t\r\n");
                            if (seg.len != 0) {
                                out_buf.append(allocator_b.dupe(u8, seg) catch seg) catch {};
                            }
                            cur_buf.clearRetainingCapacity();
                        }
                    }.call;

                    var i = l_angle_i;
                    while (i < tokens_a.len) : (i += 1) {
                        const t = tokens_a[i];
                        if (t.type == .NewLine or t.type == .Comment) continue;
                        const ts = tokenString(t);
                        if (ts.len == 0) continue;

                        var j: usize = 0;
                        while (j < ts.len) : (j += 1) {
                            const ch = ts[j];
                            if (ch == '<') {
                                depth += 1;
                                if (depth == 1) continue;
                                cur.append('<') catch {};
                                continue;
                            }
                            if (ch == '>') {
                                if (depth > 0) depth -= 1;
                                if (depth == 0) {
                                    flush(allocator_a, &cur, out_args);
                                    return;
                                }
                                cur.append('>') catch {};
                                continue;
                            }
                            if (depth <= 0) return;

                            if (ch == ',' and depth == 1) {
                                flush(allocator_a, &cur, out_args);
                                continue;
                            }

                            cur.append(ch) catch {};
                        }
                    }
                }

                fn trimTokenRange(tokens_a: []const token.Token, start: usize, end: usize) ?CallArgRange {
                    var s = start;
                    var e = end;
                    while (s < e and (tokens_a[s].type == .NewLine or tokens_a[s].type == .Comment)) : (s += 1) {}
                    while (e > s and (tokens_a[e - 1].type == .NewLine or tokens_a[e - 1].type == .Comment)) : (e -= 1) {}
                    if (s >= e) return null;
                    return .{ .start = s, .end = e };
                }

                fn collectCallArgRanges(tokens_a: []const token.Token, lparen_i: usize, rparen_i: usize, out_ranges: *ArrayList(CallArgRange)) void {
                    var seg_start = nextNonTrivialToken(tokens_a, lparen_i + 1) orelse return;

                    var p_depth: i64 = 0;
                    var b_depth: i64 = 0;
                    var c_depth: i64 = 0;
                    var g_depth: i64 = 0;

                    var i = lparen_i + 1;
                    while (i < rparen_i) : (i += 1) {
                        const t = tokens_a[i];
                        if (t.type == .NewLine or t.type == .Comment) continue;

                        if (isPunctChar(t, '(')) {
                            p_depth += 1;
                            continue;
                        }
                        if (isPunctChar(t, ')')) {
                            if (p_depth > 0) p_depth -= 1;
                            continue;
                        }
                        if (isPunctChar(t, '[')) {
                            b_depth += 1;
                            continue;
                        }
                        if (isPunctChar(t, ']')) {
                            if (b_depth > 0) b_depth -= 1;
                            continue;
                        }
                        if (isSymbolChar(t, '{')) {
                            c_depth += 1;
                            continue;
                        }
                        if (isSymbolChar(t, '}')) {
                            if (c_depth > 0) c_depth -= 1;
                            continue;
                        }
                        if (isPunctChar(t, '<')) {
                            g_depth += 1;
                            continue;
                        }
                        if (isPunctChar(t, '>')) {
                            if (g_depth > 0) g_depth -= 1;
                            continue;
                        }

                        if (isPunctChar(t, ',') and p_depth == 0 and b_depth == 0 and c_depth == 0 and g_depth == 0) {
                            if (trimTokenRange(tokens_a, seg_start, i)) |rg| {
                                out_ranges.append(rg) catch {};
                            }
                            seg_start = nextNonTrivialToken(tokens_a, i + 1) orelse rparen_i;
                        }
                    }

                    if (seg_start < rparen_i) {
                        if (trimTokenRange(tokens_a, seg_start, rparen_i)) |rg| {
                            out_ranges.append(rg) catch {};
                        }
                    }
                }

                fn collectInitArgRanges(tokens_a: []const token.Token, lbrace_i: usize, rbrace_i: usize, out_ranges: *ArrayList(CallArgRange)) void {
                    var seg_start = nextNonTrivialToken(tokens_a, lbrace_i + 1) orelse return;

                    var p_depth: i64 = 0;
                    var b_depth: i64 = 0;
                    var c_depth: i64 = 0;
                    var g_depth: i64 = 0;

                    var i = lbrace_i + 1;
                    while (i < rbrace_i) : (i += 1) {
                        const t = tokens_a[i];
                        if (t.type == .NewLine or t.type == .Comment) continue;

                        if (isPunctChar(t, '(')) {
                            p_depth += 1;
                            continue;
                        }
                        if (isPunctChar(t, ')')) {
                            if (p_depth > 0) p_depth -= 1;
                            continue;
                        }
                        if (isPunctChar(t, '[')) {
                            b_depth += 1;
                            continue;
                        }
                        if (isPunctChar(t, ']')) {
                            if (b_depth > 0) b_depth -= 1;
                            continue;
                        }
                        if (isSymbolChar(t, '{')) {
                            c_depth += 1;
                            continue;
                        }
                        if (isSymbolChar(t, '}')) {
                            if (c_depth > 0) c_depth -= 1;
                            continue;
                        }
                        if (isPunctChar(t, '<')) {
                            g_depth += 1;
                            continue;
                        }
                        if (isPunctChar(t, '>')) {
                            if (g_depth > 0) g_depth -= 1;
                            continue;
                        }

                        if (isPunctChar(t, ',') and p_depth == 0 and b_depth == 0 and c_depth == 0 and g_depth == 0) {
                            if (trimTokenRange(tokens_a, seg_start, i)) |rg| {
                                out_ranges.append(rg) catch {};
                            }
                            seg_start = nextNonTrivialToken(tokens_a, i + 1) orelse rbrace_i;
                        }
                    }

                    if (seg_start < rbrace_i) {
                        if (trimTokenRange(tokens_a, seg_start, rbrace_i)) |rg| {
                            out_ranges.append(rg) catch {};
                        }
                    }
                }

                fn isGenericParamName(name: []const u8, generic_params: []const []const u8) bool {
                    for (generic_params) |gp| {
                        if (std.mem.eql(u8, gp, name)) return true;
                    }
                    return false;
                }

                fn bindGenericParam(allocator_a: Allocator, map: *std.StringHashMap([]const u8), param: []const u8, arg_t: []const u8) void {
                    if (map.get(param) != null) return;
                    const k = allocator_a.dupe(u8, param) catch param;
                    const v = allocator_a.dupe(u8, std.mem.trim(u8, arg_t, " \t\r\n")) catch arg_t;
                    map.put(k, v) catch {};
                }

                fn countPtrRefSuffix(type_name_raw: []const u8) usize {
                    var tname = std.mem.trimEnd(u8, type_name_raw, " \t\r\n");
                    var n: usize = 0;
                    while (tname.len != 0) {
                        const ch = tname[tname.len - 1];
                        if (ch == '*' or ch == '&') {
                            n += 1;
                            tname = std.mem.trimEnd(u8, tname[0 .. tname.len - 1], " \t\r\n");
                            continue;
                        }
                        break;
                    }
                    return n;
                }

                fn parseGenericCore(type_name_raw: []const u8) ?GenericTypeCore {
                    const tname = std.mem.trim(u8, type_name_raw, " \t\r\n");
                    const lt = std.mem.indexOfScalar(u8, tname, '<') orelse return null;

                    var depth: i64 = 0;
                    var gt: ?usize = null;
                    var i = lt;
                    while (i < tname.len) : (i += 1) {
                        const ch = tname[i];
                        if (ch == '<') {
                            depth += 1;
                            continue;
                        }
                        if (ch == '>') {
                            depth -= 1;
                            if (depth == 0) {
                                gt = i;
                                break;
                            }
                            continue;
                        }
                    }
                    if (gt == null or gt.? <= lt) return null;
                    if (std.mem.trim(u8, tname[gt.? + 1 ..], " \t\r\n").len != 0) return null;

                    return .{
                        .base = std.mem.trim(u8, tname[0..lt], " \t\r\n"),
                        .inner = tname[lt + 1 .. gt.?],
                    };
                }

                fn inferGenericBindings(
                    allocator_a: Allocator,
                    param_type_raw: []const u8,
                    arg_type_raw: []const u8,
                    generic_params: []const []const u8,
                    map: *std.StringHashMap([]const u8),
                ) void {
                    const param_type = std.mem.trim(u8, param_type_raw, " \t\r\n");
                    const arg_type = std.mem.trim(u8, arg_type_raw, " \t\r\n");
                    if (param_type.len == 0 or arg_type.len == 0) return;

                    if (isGenericParamName(param_type, generic_params)) {
                        bindGenericParam(allocator_a, map, param_type, arg_type);
                        return;
                    }

                    if (std.mem.endsWith(u8, param_type, "[]") and std.mem.endsWith(u8, arg_type, "[]")) {
                        inferGenericBindings(allocator_a, param_type[0 .. param_type.len - 2], arg_type[0 .. arg_type.len - 2], generic_params, map);
                        return;
                    }

                    const p_ptr = countPtrRefSuffix(param_type);
                    if (p_ptr != 0) {
                        const a_ptr = countPtrRefSuffix(arg_type);
                        if (a_ptr >= p_ptr and arg_type.len >= p_ptr and param_type.len >= p_ptr) {
                            const p_core = std.mem.trimEnd(u8, param_type[0 .. param_type.len - p_ptr], " \t\r\n");
                            const a_core = std.mem.trimEnd(u8, arg_type[0 .. arg_type.len - p_ptr], " \t\r\n");
                            inferGenericBindings(allocator_a, p_core, a_core, generic_params, map);
                            return;
                        }
                    }

                    if (parseGenericCore(param_type)) |pg| {
                        if (parseGenericCore(arg_type)) |ag| {
                            if (!std.mem.eql(u8, pg.base, ag.base)) return;

                            var p_args = ArrayList([]const u8).init(allocator_a);
                            defer p_args.deinit();
                            var a_args = ArrayList([]const u8).init(allocator_a);
                            defer a_args.deinit();

                            splitTopLevelCsv(allocator_a, pg.inner, &p_args);
                            splitTopLevelCsv(allocator_a, ag.inner, &a_args);

                            const n = @min(p_args.items.len, a_args.items.len);
                            var idx: usize = 0;
                            while (idx < n) : (idx += 1) {
                                inferGenericBindings(allocator_a, p_args.items[idx], a_args.items[idx], generic_params, map);
                            }
                        }
                    }
                }

                fn inferLiteralArgType(tokens_a: []const token.Token, start: usize, end: usize) ?[]const u8 {
                    const b = trimTokenRange(tokens_a, start, end) orelse return null;
                    if (!onlyTrivial(tokens_a, b.start + 1, b.end)) return null;

                    const t = tokens_a[b.start];
                    switch (t.type) {
                        .String => return "str",
                        .Boolean => return "bin",
                        .Number => {
                            if (t.num == null and t.data == .cval) return "chr";
                            return switch (t.data) {
                                .dnum => "dec",
                                else => "num",
                            };
                        },
                        else => return null,
                    }
                }

                fn parseNamedInitArg(tokens_a: []const token.Token, start: usize, end: usize) ?NamedInitArg {
                    const b = trimTokenRange(tokens_a, start, end) orelse return null;

                    var p_depth: i64 = 0;
                    var b_depth: i64 = 0;
                    var c_depth: i64 = 0;
                    var g_depth: i64 = 0;
                    var eq_i: ?usize = null;

                    var i = b.start;
                    while (i < b.end) : (i += 1) {
                        const t = tokens_a[i];
                        if (t.type == .NewLine or t.type == .Comment) continue;

                        if (isPunctChar(t, '(')) {
                            p_depth += 1;
                            continue;
                        }
                        if (isPunctChar(t, ')')) {
                            if (p_depth > 0) p_depth -= 1;
                            continue;
                        }
                        if (isPunctChar(t, '[')) {
                            b_depth += 1;
                            continue;
                        }
                        if (isPunctChar(t, ']')) {
                            if (b_depth > 0) b_depth -= 1;
                            continue;
                        }
                        if (isSymbolChar(t, '{')) {
                            c_depth += 1;
                            continue;
                        }
                        if (isSymbolChar(t, '}')) {
                            if (c_depth > 0) c_depth -= 1;
                            continue;
                        }
                        if (isPunctChar(t, '<')) {
                            g_depth += 1;
                            continue;
                        }
                        if (isPunctChar(t, '>')) {
                            if (g_depth > 0) g_depth -= 1;
                            continue;
                        }

                        if (isPunctChar(t, '=') and p_depth == 0 and b_depth == 0 and c_depth == 0 and g_depth == 0) {
                            eq_i = i;
                            break;
                        }
                    }

                    if (eq_i == null) return null;
                    const lhs = trimTokenRange(tokens_a, b.start, eq_i.?) orelse return null;
                    if (lhs.end != lhs.start + 1 or !isIdent(tokens_a[lhs.start])) return null;
                    const rhs = trimTokenRange(tokens_a, eq_i.? + 1, b.end) orelse return null;

                    return .{
                        .field_name = tokenString(tokens_a[lhs.start]),
                        .expr_range = rhs,
                    };
                }

                fn buildSpecializedTypeName(allocator_a: Allocator, base_name: []const u8, args: []const []const u8) []const u8 {
                    if (args.len == 0) return allocator_a.dupe(u8, base_name) catch base_name;

                    var out_buf = ArrayList(u8).init(allocator_a);
                    defer out_buf.deinit();

                    out_buf.appendSlice(base_name) catch return allocator_a.dupe(u8, base_name) catch base_name;
                    out_buf.append('<') catch return allocator_a.dupe(u8, base_name) catch base_name;
                    var i: usize = 0;
                    while (i < args.len) : (i += 1) {
                        if (i != 0) out_buf.appendSlice(", ") catch {};
                        out_buf.appendSlice(std.mem.trim(u8, args[i], " \t\r\n")) catch {};
                    }
                    out_buf.append('>') catch {};
                    return out_buf.toOwnedSlice() catch (allocator_a.dupe(u8, base_name) catch base_name);
                }

                fn findFieldTypeByName(fields: []const CompoundFieldInfo, field_name: []const u8) ?[]const u8 {
                    for (fields) |f| {
                        if (std.mem.eql(u8, f.name, field_name)) return f.value_type;
                    }
                    return null;
                }

                fn inferCompoundInitType(
                    allocator_a: Allocator,
                    tokens_a: []const token.Token,
                    ident_name: []const u8,
                    explicit_generic_start_i: ?usize,
                    lbrace_i: usize,
                    rbrace_i: usize,
                    lt: *const std.StringHashMap([]const u8),
                    gt: *const std.StringHashMap([]const u8),
                    syms: []const SymbolLite,
                ) ?[]const u8 {
                    if (explicit_generic_start_i) |gi| {
                        var explicit_args = ArrayList([]const u8).init(allocator_a);
                        defer explicit_args.deinit();
                        parseCallExplicitTypeArgs(allocator_a, tokens_a, gi, &explicit_args);
                        if (explicit_args.items.len == 0) return allocator_a.dupe(u8, ident_name) catch ident_name;
                        return buildSpecializedTypeName(allocator_a, ident_name, explicit_args.items);
                    }

                    var fields = ArrayList(CompoundFieldInfo).init(allocator_a);
                    defer fields.deinit();

                    var owner_template: ?[]const u8 = null;
                    const want_base = localBaseTypeName(ident_name);
                    for (syms) |s| {
                        if (s.kind != .field and s.kind != .property) continue;
                        if (s.container_type == null) continue;
                        if (!std.mem.eql(u8, localBaseTypeName(s.container_type.?), want_base)) continue;

                        if (owner_template == null) owner_template = s.container_type.?;
                        if (s.value_type == null) continue;

                        var seen = false;
                        for (fields.items) |f| {
                            if (std.mem.eql(u8, f.name, s.name)) {
                                seen = true;
                                break;
                            }
                        }
                        if (seen) continue;

                        fields.append(.{ .name = s.name, .value_type = s.value_type.? }) catch {};
                    }

                    if (owner_template == null) return allocator_a.dupe(u8, ident_name) catch ident_name;
                    const generic_core = parseGenericCore(owner_template.?) orelse return allocator_a.dupe(u8, ident_name) catch ident_name;

                    var generic_params = ArrayList([]const u8).init(allocator_a);
                    defer generic_params.deinit();
                    splitTopLevelCsv(allocator_a, generic_core.inner, &generic_params);
                    if (generic_params.items.len == 0) return allocator_a.dupe(u8, ident_name) catch ident_name;

                    var bindings = std.StringHashMap([]const u8).init(allocator_a);
                    defer bindings.deinit();

                    var arg_ranges = ArrayList(CallArgRange).init(allocator_a);
                    defer arg_ranges.deinit();
                    collectInitArgRanges(tokens_a, lbrace_i, rbrace_i, &arg_ranges);

                    var positional_i: usize = 0;
                    for (arg_ranges.items) |ar| {
                        var target_field_type: ?[]const u8 = null;
                        var expr_range = ar;

                        if (parseNamedInitArg(tokens_a, ar.start, ar.end)) |named| {
                            target_field_type = findFieldTypeByName(fields.items, named.field_name);
                            expr_range = named.expr_range;
                        } else {
                            if (positional_i < fields.items.len) {
                                target_field_type = fields.items[positional_i].value_type;
                                positional_i += 1;
                            }
                        }

                        if (target_field_type == null) continue;
                        const arg_t = inferExpr(allocator_a, tokens_a, expr_range.start, expr_range.end, lt, gt, syms) orelse inferLiteralArgType(tokens_a, expr_range.start, expr_range.end) orelse continue;
                        inferGenericBindings(allocator_a, target_field_type.?, arg_t, generic_params.items, &bindings);
                    }

                    var specialized_args = ArrayList([]const u8).init(allocator_a);
                    defer specialized_args.deinit();

                    var resolved_any = false;
                    for (generic_params.items) |gp| {
                        if (bindings.get(gp)) |bound| {
                            specialized_args.append(bound) catch {};
                            resolved_any = true;
                        } else {
                            specialized_args.append(gp) catch {};
                        }
                    }

                    if (!resolved_any) return allocator_a.dupe(u8, ident_name) catch ident_name;
                    return buildSpecializedTypeName(allocator_a, ident_name, specialized_args.items);
                }

                fn substituteTypeParams(allocator_a: Allocator, type_name: []const u8, map: *const std.StringHashMap([]const u8)) []const u8 {
                    var out_buf = ArrayList(u8).init(allocator_a);
                    defer out_buf.deinit();

                    var changed = false;
                    var i: usize = 0;
                    while (i < type_name.len) {
                        const ch = type_name[i];
                        if (!isIdentStartChar(ch)) {
                            out_buf.append(ch) catch return type_name;
                            i += 1;
                            continue;
                        }

                        const start = i;
                        i += 1;
                        while (i < type_name.len and isIdentChar(type_name[i])) : (i += 1) {}
                        const ident = type_name[start..i];
                        if (map.get(ident)) |resolved| {
                            out_buf.appendSlice(resolved) catch return type_name;
                            changed = true;
                        } else {
                            out_buf.appendSlice(ident) catch return type_name;
                        }
                    }

                    if (!changed) return type_name;
                    return out_buf.toOwnedSlice() catch type_name;
                }

                fn findFunctionSymbol(name: []const u8, syms: []const SymbolLite) ?SymbolLite {
                    for (syms) |s| {
                        if (s.kind != .function) continue;
                        if (!std.mem.eql(u8, s.name, name)) continue;
                        return s;
                    }
                    return null;
                }

                fn inferFunctionCallReturnType(
                    allocator_a: Allocator,
                    tokens_a: []const token.Token,
                    ident_name: []const u8,
                    explicit_generic_start_i: ?usize,
                    lparen_i: usize,
                    rparen_i: usize,
                    lt: *const std.StringHashMap([]const u8),
                    gt: *const std.StringHashMap([]const u8),
                    syms: []const SymbolLite,
                ) ?[]const u8 {
                    const fn_sym = findFunctionSymbol(ident_name, syms) orelse return null;
                    const base_rt = fn_sym.value_type orelse return null;
                    const sig_detail = fn_sym.detail orelse return base_rt;

                    var generic_params = ArrayList([]const u8).init(allocator_a);
                    defer generic_params.deinit();
                    parseFunctionGenericParams(allocator_a, sig_detail, &generic_params);
                    if (generic_params.items.len == 0) return base_rt;

                    var bindings = std.StringHashMap([]const u8).init(allocator_a);
                    defer bindings.deinit();

                    if (explicit_generic_start_i) |gi| {
                        var explicit_args = ArrayList([]const u8).init(allocator_a);
                        defer explicit_args.deinit();
                        parseCallExplicitTypeArgs(allocator_a, tokens_a, gi, &explicit_args);
                        const map_n = @min(explicit_args.items.len, generic_params.items.len);
                        var idx: usize = 0;
                        while (idx < map_n) : (idx += 1) {
                            bindGenericParam(allocator_a, &bindings, generic_params.items[idx], explicit_args.items[idx]);
                        }
                    }

                    var param_types = ArrayList([]const u8).init(allocator_a);
                    defer param_types.deinit();
                    parseFunctionParamTypes(allocator_a, sig_detail, &param_types);

                    var arg_ranges = ArrayList(CallArgRange).init(allocator_a);
                    defer arg_ranges.deinit();
                    collectCallArgRanges(tokens_a, lparen_i, rparen_i, &arg_ranges);

                    const pair_n = @min(param_types.items.len, arg_ranges.items.len);
                    var ai: usize = 0;
                    while (ai < pair_n) : (ai += 1) {
                        const ar = arg_ranges.items[ai];
                        const arg_t = inferExpr(allocator_a, tokens_a, ar.start, ar.end, lt, gt, syms) orelse inferLiteralArgType(tokens_a, ar.start, ar.end) orelse continue;
                        inferGenericBindings(allocator_a, param_types.items[ai], arg_t, generic_params.items, &bindings);
                    }

                    return substituteTypeParams(allocator_a, base_rt, &bindings);
                }

                fn inferDotChain(
                    allocator_a: Allocator,
                    tokens_a: []const token.Token,
                    start: usize,
                    end: usize,
                    lt: *const std.StringHashMap([]const u8),
                    gt: *const std.StringHashMap([]const u8),
                    syms: []const SymbolLite,
                ) ?[]const u8 {
                    const b = stripOuterParens(tokens_a, start, end) orelse return null;
                    const first_dot = findTopLevelDot(tokens_a, b.start, b.end) orelse return null;

                    var recv_type = inferExpr(allocator_a, tokens_a, b.start, first_dot, lt, gt, syms) orelse return null;
                    var dot_i = first_dot;
                    while (dot_i < b.end) {
                        const member_i = nextNonTrivialToken(tokens_a, dot_i + 1) orelse return null;
                        if (member_i >= b.end or !isIdent(tokens_a[member_i])) return null;
                        const member_name = tokenString(tokens_a[member_i]);

                        var after_member = nextNonTrivialToken(tokens_a, member_i + 1) orelse b.end;
                        if (after_member < b.end and isPunctChar(tokens_a[after_member], '(')) {
                            const rp = findMatchingParen(tokens_a, after_member, b.end) orelse return null;
                            recv_type = findMemberReturnType(recv_type, member_name, syms) orelse return null;
                            after_member = nextNonTrivialToken(tokens_a, rp + 1) orelse b.end;
                        } else {
                            if (findMemberFieldType(recv_type, member_name, syms)) |ft| {
                                recv_type = ft;
                            } else if (findEnumMemberType(recv_type, member_name, syms)) |et| {
                                recv_type = et;
                            } else {
                                return null;
                            }
                        }

                        if (after_member >= b.end) return recv_type;
                        if (!isDotTokenAny(tokens_a[after_member])) return null;
                        dot_i = after_member;
                    }

                    return null;
                }

                fn inferExpr(
                    allocator_a: Allocator,
                    tokens_a: []const token.Token,
                    start: usize,
                    end: usize,
                    lt: *const std.StringHashMap([]const u8),
                    gt: *const std.StringHashMap([]const u8),
                    syms: []const SymbolLite,
                ) ?[]const u8 {
                    const b = stripOuterParens(tokens_a, start, end) orelse return null;
                    const first_i = nextNonTrivialToken(tokens_a, b.start) orelse return null;

                    if (isKeyword(tokens_a[first_i], "await")) {
                        const after_await = nextNonTrivialToken(tokens_a, first_i + 1) orelse return null;
                        return inferExpr(allocator_a, tokens_a, after_await, b.end, lt, gt, syms);
                    }

                    var deref_count: usize = 0;
                    var addr_count: usize = 0;
                    var cur_i = first_i;
                    while (cur_i < b.end) {
                        const tk = tokens_a[cur_i];
                        if (isPunctChar(tk, '*')) {
                            deref_count += 1;
                            cur_i = nextNonTrivialToken(tokens_a, cur_i + 1) orelse return null;
                            continue;
                        }
                        if (isPunctChar(tk, '&')) {
                            addr_count += 1;
                            cur_i = nextNonTrivialToken(tokens_a, cur_i + 1) orelse return null;
                            continue;
                        }
                        break;
                    }

                    var core_type: ?[]const u8 = inferDotChain(allocator_a, tokens_a, cur_i, b.end, lt, gt, syms);
                    if (core_type == null) {
                        const id_i = nextNonTrivialToken(tokens_a, cur_i) orelse return null;
                        if (id_i >= b.end or !isIdent(tokens_a[id_i])) return null;

                        const ident_name = tokenString(tokens_a[id_i]);
                        const after_ident = nextNonTrivialToken(tokens_a, id_i + 1) orelse b.end;
                        var probe_i = after_ident;
                        var explicit_generic_start_i: ?usize = null;
                        if (probe_i < b.end and isPunctChar(tokens_a[probe_i], '<')) {
                            explicit_generic_start_i = probe_i;
                            probe_i = skipGenericArgsForward(tokens_a, probe_i);
                        }

                        if (probe_i < b.end and isPunctChar(tokens_a[probe_i], '(')) {
                            const rp = findMatchingParen(tokens_a, probe_i, b.end) orelse return null;
                            if (!onlyTrivial(tokens_a, rp + 1, b.end)) return null;
                            core_type = inferFunctionCallReturnType(allocator_a, tokens_a, ident_name, explicit_generic_start_i, probe_i, rp, lt, gt, syms);
                            if (core_type == null) {
                                core_type = findFunctionReturnType(ident_name, syms);
                            }
                            if (core_type == null) return null;
                        } else if (probe_i < b.end and isSymbolChar(tokens_a[probe_i], '{')) {
                            const rb = findMatchingBrace(tokens_a, probe_i, b.end) orelse return null;
                            if (!onlyTrivial(tokens_a, rb + 1, b.end)) return null;
                            core_type = inferCompoundInitType(allocator_a, tokens_a, ident_name, explicit_generic_start_i, probe_i, rb, lt, gt, syms);
                            if (core_type == null) return null;
                        } else if (probe_i < b.end and isPunctChar(tokens_a[probe_i], '[')) {
                            const rb = findMatchingBracket(tokens_a, probe_i, b.end) orelse return null;
                            if (!onlyTrivial(tokens_a, rb + 1, b.end)) return null;
                            if (resolveIdentType(ident_name, lt, gt)) |it| {
                                core_type = arrayElementType(it);
                            } else {
                                return null;
                            }
                        } else {
                            if (!onlyTrivial(tokens_a, after_ident, b.end)) return null;
                            core_type = resolveIdentType(ident_name, lt, gt) orelse findTypeName(ident_name, syms);
                        }
                    }

                    if (core_type == null) return null;
                    var out_type = core_type.?;

                    if (deref_count != 0) {
                        out_type = stripPointerLevels(out_type, deref_count) orelse return null;
                    }

                    if (addr_count != 0) return null;

                    return out_type;
                }

                fn callType(
                    allocator_a: Allocator,
                    tokens_a: []const token.Token,
                    start: usize,
                    end: usize,
                    lt: *const std.StringHashMap([]const u8),
                    gt: *const std.StringHashMap([]const u8),
                    syms: []const SymbolLite,
                ) ?[]const u8 {
                    return inferExpr(allocator_a, tokens_a, start, end, lt, gt, syms);
                }
            }.callType;

            const first_i_opt = nextNonTrivialToken(tokens_, start_i);
            if (first_i_opt) |fi| {
                // Count how deeply nested the opening brackets are for multi-dim arrays.
                // `[1,2]` → depth 1, `[[1,2],[3,4]]` → depth 2, etc.
                var bracket_scan_i: usize = fi;
                while (bracket_scan_i < end_i) {
                    const bt = tokens_[bracket_scan_i];
                    if (bt.type == .NewLine or bt.type == .Comment) {
                        bracket_scan_i += 1;
                        continue;
                    }
                    if (isPunctChar(bt, '(')) {
                        // Wrapped in parens — check inside.
                        bracket_scan_i += 1;
                        continue;
                    }
                    if (isPunctChar(bt, '[')) {
                        array_literal_depth += 1;
                        // Peek at next non-trivial token; if it's also '[', recurse into it.
                        const next_b = nextNonTrivialToken(tokens_, bracket_scan_i + 1) orelse break;
                        if (isPunctChar(tokens_[next_b], '[')) {
                            bracket_scan_i = next_b;
                            continue;
                        }
                    }
                    break;
                }
            }
            const saw_array_literal = array_literal_depth > 0;

            const exact_terminal_type = inferExactTerminalType(allocator_, tokens_, start_i, end_i, locals_map, globals_map, symbols);

            var i: usize = start_i;
            while (i < end_i) : (i += 1) {
                const t = tokens_[i];
                if (t.type == .NewLine or t.type == .Comment) continue;
                switch (t.type) {
                    .String => {
                        saw_str = true;
                        continue;
                    },
                    .Boolean => {
                        saw_bin = true;
                        continue;
                    },
                    .Number => {
                        if (t.num == null and t.data == .cval) {
                            saw_chr = true;
                            continue;
                        }
                        switch (t.data) {
                            .dnum => saw_dec = true,
                            .cval => saw_chr = true,
                            else => saw_num = true,
                        }
                        continue;
                    },
                    .Identifier => {
                        const name = tokenString(t);
                        if (prevNonTrivialToken(tokens_, i)) |prev_i| {
                            if (prev_i >= start_i and isDotTokenAny(tokens_[prev_i])) {
                                continue;
                            }
                        }
                        const next_i_opt = nextNonTrivialToken(tokens_, i + 1);
                        if (next_i_opt == null) {
                            if (resolveIdentType(name, locals_map, globals_map)) |tname| {
                                updateCandidate(&candidate, &candidate_rank, tname);
                            }
                            continue;
                        }
                        var next_i = next_i_opt.?;

                        // Unary address-of root expression: `&name` -> `Type*`.
                        // Avoid applying this to nested call arguments like `foo(&x, ...)`.
                        if (i > start_i) {
                            const prev_i = prevNonTrivialToken(tokens_, i) orelse null;
                            if (prev_i != null and isPunctChar(tokens_[prev_i.?], '&')) {
                                const before_addr_i = prevNonTrivialToken(tokens_, prev_i.?);
                                if (before_addr_i == null or before_addr_i.? < start_i) {
                                    if (resolveIdentType(name, locals_map, globals_map)) |tname| {
                                        if (!isArrayTypeName(tname)) {
                                            const ptr_name = std.mem.concat(allocator_, u8, &[_][]const u8{ tname, "*" }) catch tname;
                                            updateCandidate(&candidate, &candidate_rank, ptr_name);
                                        }
                                    }
                                    continue;
                                }
                            }
                        }

                        // Indexing: `arr[i]` -> element type if array.
                        // If followed by `.member`, resolve member type on the element.
                        if (isPunctChar(tokens_[next_i], '[')) {
                            if (resolveIdentType(name, locals_map, globals_map)) |tname| {
                                const elem = arrayElementType(tname);
                                var member_resolved = false;
                                var saw_member_access = false;

                                var depth: i64 = 0;
                                var j: usize = next_i;
                                while (j < end_i) : (j += 1) {
                                    const tj = tokens_[j];
                                    if (tj.type == .NewLine or tj.type == .Comment) continue;
                                    if (isPunctChar(tj, '[')) depth += 1;
                                    if (isPunctChar(tj, ']')) {
                                        depth -= 1;
                                        if (depth == 0) {
                                            const after_idx = nextNonTrivialToken(tokens_, j + 1) orelse end_i;
                                            if (after_idx < end_i and isDotTokenAny(tokens_[after_idx])) {
                                                saw_member_access = true;
                                                const member_i = nextNonTrivialToken(tokens_, after_idx + 1) orelse end_i;
                                                if (member_i < end_i and isIdent(tokens_[member_i])) {
                                                    const member_name = tokenString(tokens_[member_i]);
                                                    const after_member = nextNonTrivialToken(tokens_, member_i + 1) orelse end_i;
                                                    if (after_member < end_i and isPunctChar(tokens_[after_member], '(')) {
                                                        if (findMemberReturnType(elem, member_name, symbols)) |rt| {
                                                            updateCandidate(&candidate, &candidate_rank, rt);
                                                            member_resolved = true;
                                                            break;
                                                        }
                                                    }
                                                    if (findMemberFieldType(elem, member_name, symbols)) |ft| {
                                                        updateCandidate(&candidate, &candidate_rank, ft);
                                                        member_resolved = true;
                                                        break;
                                                    }
                                                    if (findEnumMemberType(elem, member_name, symbols)) |et| {
                                                        updateCandidate(&candidate, &candidate_rank, et);
                                                        member_resolved = true;
                                                        break;
                                                    }
                                                }
                                            }
                                            break;
                                        }
                                    }
                                }

                                if (!member_resolved and !saw_member_access) {
                                    updateCandidate(&candidate, &candidate_rank, elem);
                                }
                            }
                            continue;
                        }

                        // Compound init: `Type{...}` or `Type<...>{...}`
                        if (isPunctChar(tokens_[next_i], '<')) {
                            next_i = skipGenericArgsForward(tokens_, next_i);
                        }
                        if (next_i >= end_i or next_i >= tokens_.len) {
                            if (resolveIdentType(name, locals_map, globals_map)) |tname| {
                                updateCandidate(&candidate, &candidate_rank, tname);
                            }
                            continue;
                        }
                        if (next_i < end_i and isSymbolChar(tokens_[next_i], '{')) {
                            updateCandidate(&candidate, &candidate_rank, allocator_.dupe(u8, name) catch name);
                            continue;
                        }

                        // Function call: `name(...)`
                        if (isPunctChar(tokens_[next_i], '(')) {
                            if (findFunctionReturnType(name, symbols)) |rt| {
                                updateCandidate(&candidate, &candidate_rank, rt);
                            }
                            continue;
                        }

                        // Member access chain.
                        if (isDotTokenAny(tokens_[next_i])) {
                            var recv_type = resolveIdentType(name, locals_map, globals_map);
                            var recv_type_is_heuristic = false;
                            if (recv_type == null) {
                                recv_type = findTypeName(name, symbols);
                            }
                            if (recv_type == null and isLikelyTypeIdentifier(name)) {
                                recv_type = name;
                                recv_type_is_heuristic = true;
                            }
                            var j = next_i;
                            while (recv_type != null and j < end_i and isDotTokenAny(tokens_[j])) {
                                const member_i = nextNonTrivialToken(tokens_, j + 1) orelse break;
                                if (!isIdent(tokens_[member_i])) break;
                                const member_name = tokenString(tokens_[member_i]);
                                const after_member = nextNonTrivialToken(tokens_, member_i + 1) orelse end_i;
                                if (after_member < end_i and isPunctChar(tokens_[after_member], '(')) {
                                    recv_type = findMemberReturnType(recv_type.?, member_name, symbols);
                                    break;
                                }
                                if (findMemberFieldType(recv_type.?, member_name, symbols)) |ft| {
                                    recv_type = ft;
                                } else if (findEnumMemberType(recv_type.?, member_name, symbols)) |et| {
                                    recv_type = et;
                                } else if (recv_type_is_heuristic) {
                                    // For imported enum members, token-only indexing may not include enum metadata.
                                    // Keep the receiver type for terminal qualified constants like `Direction.SOUTH`.
                                    const next_dot = nextNonTrivialToken(tokens_, after_member) orelse end_i;
                                    if (next_dot < end_i and isDotTokenAny(tokens_[next_dot])) {
                                        recv_type = null;
                                    }
                                } else {
                                    recv_type = null;
                                }
                                j = after_member;
                            }
                            if (recv_type) |rt| {
                                updateCandidate(&candidate, &candidate_rank, rt);
                            }
                            continue;
                        }

                        if (resolveIdentType(name, locals_map, globals_map)) |tname| {
                            updateCandidate(&candidate, &candidate_rank, tname);
                        }
                        continue;
                    },
                    else => continue,
                }
            }

            // Build a type string with the correct number of `[]` suffixes for the
            // detected array nesting depth (e.g. depth=2 → "num[][]").
            const appendArraySuffix = struct {
                fn call(a: Allocator, base: []const u8, depth: usize) []const u8 {
                    if (depth == 0) return a.dupe(u8, base) catch base;
                    var buf = ArrayList(u8).init(a);
                    buf.appendSlice(base) catch return base;
                    var d: usize = 0;
                    while (d < depth) : (d += 1) buf.appendSlice("[]") catch return base;
                    return buf.toOwnedSlice() catch base;
                }
            }.call;

            if (exact_terminal_type) |et| {
                if (!isLetInferTypeName(et)) {
                    return allocator_.dupe(u8, et) catch et;
                }
            }

            if (candidate) |cand| {
                if (!isLetInferTypeName(cand) and !isBuiltinTypeName(cand)) {
                    if (saw_array_literal and !isArrayTypeName(cand)) {
                        return appendArraySuffix(allocator_, cand, array_literal_depth);
                    }
                    return allocator_.dupe(u8, cand) catch cand;
                }
            }
            if (saw_str) {
                const base = "str";
                if (saw_array_literal) return appendArraySuffix(allocator_, base, array_literal_depth);
                return allocator_.dupe(u8, base) catch base;
            }
            if (saw_bin) {
                const base = "bin";
                if (saw_array_literal) return appendArraySuffix(allocator_, base, array_literal_depth);
                return allocator_.dupe(u8, base) catch base;
            }
            if (saw_chr) {
                const base = "chr";
                if (saw_array_literal) return appendArraySuffix(allocator_, base, array_literal_depth);
                return allocator_.dupe(u8, base) catch base;
            }
            if (saw_dec or (candidate != null and std.mem.eql(u8, candidate.?, "dec"))) {
                const base = "dec";
                if (saw_array_literal) return appendArraySuffix(allocator_, base, array_literal_depth);
                return allocator_.dupe(u8, base) catch base;
            }
            if (saw_num or (candidate != null and std.mem.eql(u8, candidate.?, "num"))) {
                const base = "num";
                if (saw_array_literal) return appendArraySuffix(allocator_, base, array_literal_depth);
                return allocator_.dupe(u8, base) catch base;
            }
            if (candidate) |cand2| {
                if (!isLetInferTypeName(cand2)) {
                    if (saw_array_literal and !isArrayTypeName(cand2)) {
                        return appendArraySuffix(allocator_, cand2, array_literal_depth);
                    }
                    return allocator_.dupe(u8, cand2) catch cand2;
                }
            }
            return null;
        }
    }.call;

    const isPubToken = struct {
        fn call(t: token.Token) bool {
            if (t.type != .Keyword and t.type != .Identifier) return false;
            return std.mem.eql(u8, tokenString(t), "pub");
        }
    }.call;

    const isAsyncToken = struct {
        fn call(t: token.Token) bool {
            if (t.type != .Keyword and t.type != .Identifier) return false;
            return std.mem.eql(u8, tokenString(t), "async");
        }
    }.call;

    const hasPubModifierBefore = struct {
        fn call(tokens_: []const token.Token, start_index: usize) bool {
            const prev_i = prevNonTrivialToken(tokens_, start_index) orelse return false;
            if (isPubToken(tokens_[prev_i])) return true;

            // Allow `pub async ...` declarations where the anchor token is
            // either `fun` (top-level) or the method name (impl methods).
            if (isAsyncToken(tokens_[prev_i])) {
                const prev2_i = prevNonTrivialToken(tokens_, prev_i) orelse return false;
                if (isPubToken(tokens_[prev2_i])) return true;
            }

            return false;
        }
    }.call;

    const parseParamsAfterLParen = struct {
        fn call(allocator_: Allocator, tokens_: []const token.Token, lparen_i: usize, params: *ArrayList(ParamLite), is_variadic: *bool) void {
            // Parse `Type name` pairs until the matching ')'. Best-effort; ignore failures.
            var depth: i64 = 0;
            var rparen_i: ?usize = null;
            var k: usize = lparen_i;
            while (k < tokens_.len) : (k += 1) {
                const tk = tokens_[k];
                if (isPunctChar(tk, '(')) depth += 1;
                if (isPunctChar(tk, ')')) {
                    depth -= 1;
                    if (depth == 0) {
                        rparen_i = k;
                        break;
                    }
                }
            }
            if (rparen_i == null) return;

            var pi: usize = lparen_i + 1;
            while (pi < rparen_i.?) {
                const pt = tokens_[pi];
                if (pt.type == .NewLine or pt.type == .Comment) {
                    pi += 1;
                    continue;
                }
                if (isEllipsisToken(pt)) {
                    is_variadic.* = true;
                    break;
                }
                if (isPunctChar(pt, ',')) {
                    pi += 1;
                    continue;
                }
                if (!isTypeToken(pt)) {
                    pi += 1;
                    continue;
                }
                const ptype_base = tokenString(pt);

                var ptype_buf = ArrayList(u8).init(allocator_);
                defer ptype_buf.deinit();
                ptype_buf.appendSlice(ptype_base) catch {};

                // Preserve generic suffix in parameter types (e.g. `Box<T>`).
                var name_i = nextNonTrivialToken(tokens_, pi + 1) orelse break;
                if (name_i < tokens_.len and isPunctChar(tokens_[name_i], '<')) {
                    var gdepth: i64 = 0;
                    var gi = name_i;
                    while (gi < tokens_.len) : (gi += 1) {
                        const gtok = tokens_[gi];
                        if (gtok.type == .NewLine or gtok.type == .Comment) continue;
                        if (isPunctChar(gtok, '<')) {
                            gdepth += 1;
                            ptype_buf.append('<') catch {};
                            continue;
                        }
                        if (isPunctChar(gtok, '>')) {
                            gdepth -= 1;
                            ptype_buf.append('>') catch {};
                            if (gdepth == 0) {
                                name_i = nextNonTrivialToken(tokens_, gi + 1) orelse break;
                                break;
                            }
                            continue;
                        }
                        if (gdepth <= 0) break;
                        if (isPunctChar(gtok, ',')) {
                            ptype_buf.appendSlice(", ") catch {};
                            continue;
                        }
                        const ts = tokenString(gtok);
                        if (ts.len != 0) ptype_buf.appendSlice(ts) catch {};
                    }
                }

                while (name_i < tokens_.len and isPunctChar(tokens_[name_i], '[')) {
                    ptype_buf.appendSlice("[]") catch {};

                    var bracket_depth: i64 = 0;
                    var bi = name_i;
                    while (bi < tokens_.len) : (bi += 1) {
                        const bt = tokens_[bi];
                        if (bt.type == .NewLine or bt.type == .Comment) continue;
                        if (isPunctChar(bt, '[')) {
                            bracket_depth += 1;
                            continue;
                        }
                        if (isPunctChar(bt, ']')) {
                            bracket_depth -= 1;
                            if (bracket_depth == 0) {
                                name_i = nextNonTrivialToken(tokens_, bi + 1) orelse break;
                                break;
                            }
                        }
                    }
                    if (name_i >= tokens_.len) break;
                }

                // Allow pointer/reference markers between type and name: `Type* name` / `Type & name`.
                var markers = ArrayList(u8).init(allocator_);
                defer markers.deinit();
                while (name_i < tokens_.len and (isPunctChar(tokens_[name_i], '*') or isPunctChar(tokens_[name_i], '&'))) {
                    if (isPunctChar(tokens_[name_i], '*')) markers.append('*') catch {};
                    if (isPunctChar(tokens_[name_i], '&')) markers.append('&') catch {};
                    name_i = nextNonTrivialToken(tokens_, name_i + 1) orelse break;
                }
                if (name_i >= tokens_.len or !isIdent(tokens_[name_i])) {
                    pi += 1;
                    continue;
                }

                const pname = tokenString(tokens_[name_i]);
                const pname_owned = allocator_.dupe(u8, pname) catch pname;
                const ptype_core = allocator_.dupe(u8, ptype_buf.items) catch ptype_base;
                const dtype_display = if (markers.items.len == 0)
                    ptype_core
                else
                    (std.mem.concat(allocator_, u8, &[_][]const u8{ ptype_core, markers.items }) catch ptype_core);

                params.append(.{ .name = pname_owned, .dtype_base = dtype_display, .dtype_display = dtype_display }) catch {};
                pi = name_i + 1;
            }
        }
    }.call;

    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const t = tokens[i];

        if (isSymbolChar(t, '{')) brace_depth += 1;
        if (isSymbolChar(t, '}')) brace_depth -= 1;
        if (isPunctChar(t, '(')) paren_depth += 1;
        if (isPunctChar(t, ')')) paren_depth -= 1;

        // Enter/exit impl blocks.
        if (pending_impl_block and isSymbolChar(t, '{')) {
            pending_impl_block = false;
            in_impl_block = true;
            impl_brace_depth = brace_depth;
        }
        if (pending_impl_block and isSymbolChar(t, ';')) {
            pending_impl_block = false;
            impl_owner_name = null;
        }
        if (in_impl_block and isSymbolChar(t, '}') and brace_depth < impl_brace_depth) {
            in_impl_block = false;
            impl_owner_name = null;
        }

        // Enter/exit function-ish bodies.
        if (pending_body != .none and isSymbolChar(t, '{')) {
            in_body = true;
            body_brace_depth = brace_depth;
            const br = rangeFromTokenPos(t.pos);
            body_range = .{
                .start = br.start,
                .end = .{ .line = std.math.maxInt(i64), .character = std.math.maxInt(i64) },
            };
            body_symbol_start = out.items.len;
            locals_type_map.clearRetainingCapacity();

            // Add implicit `self` inside impl method bodies.
            if (pending_body == .impl_method) {
                if (pending_impl_owner) |owner| {
                    try out.append(.{
                        .name = try allocator.dupe(u8, "self"),
                        .kind = .variable,
                        .decl_range = br,
                        .selection_range = br,
                        .container_fn_range = body_range.?,
                        .container_type = null,
                        .value_type = try allocator.dupe(u8, owner),
                        .detail = try allocator.dupe(u8, owner),
                    });
                    putType(&locals_type_map, "self", owner, allocator);
                }
            }

            // Add implicit `vargs` for variadic functions.
            if (pending_is_variadic) {
                try out.append(.{
                    .name = try allocator.dupe(u8, "vargs"),
                    .kind = .variable,
                    .decl_range = br,
                    .selection_range = br,
                    .container_fn_range = body_range.?,
                    .container_type = null,
                    .value_type = try allocator.dupe(u8, "Vec<str>"),
                    .detail = try allocator.dupe(u8, "Vec<str> vargs"),
                });
                putType(&locals_type_map, "vargs", "Vec<str>", allocator);
            }

            // Add params as locals within the body.
            for (pending_params.items) |pinfo| {
                try out.append(.{
                    .name = try allocator.dupe(u8, pinfo.name),
                    .kind = .variable,
                    .decl_range = br,
                    .selection_range = br,
                    .container_fn_range = body_range.?,
                    .container_type = null,
                    .value_type = try allocator.dupe(u8, pinfo.dtype_display),
                    .detail = blk: {
                        var det_buf = ArrayList(u8).init(allocator);
                        defer det_buf.deinit();
                        try det_buf.print("{s} {s}", .{ pinfo.dtype_display, pinfo.name });
                        break :blk try allocator.dupe(u8, det_buf.items);
                    },
                });
                putType(&locals_type_map, pinfo.name, pinfo.dtype_display, allocator);
            }

            resetPendingBody(&pending_body, &pending_params, &pending_impl_owner, &pending_is_variadic);
        }
        if (pending_body != .none and isSymbolChar(t, ';')) {
            // Prototype/no-body.
            resetPendingBody(&pending_body, &pending_params, &pending_impl_owner, &pending_is_variadic);
        }
        if (in_body and isSymbolChar(t, '}') and brace_depth < body_brace_depth) {
            const end_range = rangeFromTokenPos(t.pos);
            if (body_range) |br| {
                const fixed_range = Range{ .start = br.start, .end = end_range.end };
                for (out.items[body_symbol_start..]) |*sym| {
                    if (sym.container_fn_range) |cr| {
                        if (cr.start.line == br.start.line and cr.start.character == br.start.character and
                            cr.end.line == std.math.maxInt(i64))
                        {
                            sym.container_fn_range = fixed_range;
                        }
                    }
                }
            }
            in_body = false;
            body_range = null;
            locals_type_map.clearRetainingCapacity();
        }

        if (isKeyword(t, "fun")) {
            resetPendingBody(&pending_body, &pending_params, &pending_impl_owner, &pending_is_variadic);
            pending_body = .fun_decl;
            const is_public = hasPubModifierBefore(tokens, i);
            const name_i = nextNonTrivialToken(tokens, i + 1) orelse continue;
            if (!isIdent(tokens[name_i])) continue;
            const name = tokenString(tokens[name_i]);
            const r = rangeFromTokenPos(tokens[name_i].pos);

            // Capture params so we can offer them as locals inside the body.
            const after_name_i = nextNonTrivialToken(tokens, name_i + 1) orelse {
                // Still index the function symbol; params are just best-effort.
                const sig = try buildSignatureFromTokens(allocator, tokens, name_i, true);
                try out.append(.{
                    .name = try allocator.dupe(u8, name),
                    .kind = .function,
                    .decl_range = r,
                    .selection_range = r,
                    .is_public = is_public,
                    .container_type = null,
                    .value_type = sig.return_type,
                    .detail = sig.detail,
                });
                continue;
            };
            if (isPunctChar(tokens[after_name_i], '(')) {
                parseParamsAfterLParen(allocator, tokens, after_name_i, &pending_params, &pending_is_variadic);
            }

            const sig = try buildSignatureFromTokens(allocator, tokens, name_i, true);
            try out.append(.{
                .name = try allocator.dupe(u8, name),
                .kind = .function,
                .decl_range = r,
                .selection_range = r,
                .is_public = is_public,
                .container_type = null,
                .value_type = sig.return_type,
                .detail = sig.detail,
            });
            continue;
        }

        if (isKeyword(t, "compound")) {
            const is_public = blk: {
                const prev = prevNonTrivialToken(tokens, i) orelse break :blk false;
                break :blk isPubToken(tokens[prev]);
            };
            const name_i = nextNonTrivialToken(tokens, i + 1) orelse continue;
            if (!isIdent(tokens[name_i])) continue;
            const name = tokenString(tokens[name_i]);
            const r = rangeFromTokenPos(tokens[name_i].pos);
            try out.append(.{
                .name = try allocator.dupe(u8, name),
                .kind = .struct_,
                .decl_range = r,
                .selection_range = r,
                .is_public = is_public,
                .container_type = null,
                .value_type = null,
                .detail = null,
            });

            // Best-effort field indexing inside `compound Name { Type field; ... }`.
            // This is lexer-driven to stay robust while typing.
            var owner_name_buf = ArrayList(u8).init(allocator);
            defer owner_name_buf.deinit();
            owner_name_buf.appendSlice(name) catch {};

            var after_compound_name_i = nextNonTrivialToken(tokens, name_i + 1) orelse tokens.len;
            if (after_compound_name_i < tokens.len and isPunctChar(tokens[after_compound_name_i], '<')) {
                var gdepth: i64 = 0;
                var gi = after_compound_name_i;
                while (gi < tokens.len) : (gi += 1) {
                    const gtok = tokens[gi];
                    if (gtok.type == .NewLine or gtok.type == .Comment) continue;
                    if (isPunctChar(gtok, '<')) {
                        gdepth += 1;
                        owner_name_buf.append('<') catch {};
                        continue;
                    }
                    if (isPunctChar(gtok, '>')) {
                        gdepth -= 1;
                        owner_name_buf.append('>') catch {};
                        if (gdepth == 0) {
                            after_compound_name_i = nextNonTrivialToken(tokens, gi + 1) orelse tokens.len;
                            break;
                        }
                        continue;
                    }
                    if (gdepth <= 0) break;
                    if (isPunctChar(gtok, ',')) {
                        owner_name_buf.appendSlice(", ") catch {};
                        continue;
                    }
                    const ts = tokenString(gtok);
                    if (ts.len != 0) owner_name_buf.appendSlice(ts) catch {};
                }
            }

            const owner_name = allocator.dupe(u8, owner_name_buf.items) catch name;
            // Find opening '{'
            var j_opt = nextNonTrivialToken(tokens, after_compound_name_i);
            while (j_opt) |j| {
                if (isSymbolChar(tokens[j], '{')) {
                    var depth: i64 = 1;
                    var k: usize = j + 1;
                    while (k < tokens.len and depth > 0) : (k += 1) {
                        const tk = tokens[k];
                        if (isSymbolChar(tk, '{')) depth += 1;
                        if (isSymbolChar(tk, '}')) depth -= 1;
                        if (depth != 1) continue;

                        if (!isTypeToken(tk)) continue;

                        const ftype_raw = tokenString(tk);
                        var ftype_buf = ArrayList(u8).init(allocator);
                        defer ftype_buf.deinit();
                        ftype_buf.appendSlice(ftype_raw) catch {};

                        var field_name_i = nextNonTrivialToken(tokens, k + 1) orelse continue;
                        if (field_name_i < tokens.len and isPunctChar(tokens[field_name_i], '<')) {
                            var gdepth: i64 = 0;
                            var gi = field_name_i;
                            while (gi < tokens.len) : (gi += 1) {
                                const gtok = tokens[gi];
                                if (gtok.type == .NewLine or gtok.type == .Comment) continue;
                                if (isPunctChar(gtok, '<')) {
                                    gdepth += 1;
                                    ftype_buf.append('<') catch {};
                                    continue;
                                }
                                if (isPunctChar(gtok, '>')) {
                                    gdepth -= 1;
                                    ftype_buf.append('>') catch {};
                                    if (gdepth == 0) {
                                        field_name_i = nextNonTrivialToken(tokens, gi + 1) orelse continue;
                                        break;
                                    }
                                    continue;
                                }
                                if (gdepth <= 0) break;
                                if (isPunctChar(gtok, ',')) {
                                    ftype_buf.appendSlice(", ") catch {};
                                    continue;
                                }
                                const ts = tokenString(gtok);
                                if (ts.len != 0) ftype_buf.appendSlice(ts) catch {};
                            }
                        }

                        // Consume array dimension brackets that are part of the field type,
                        // e.g. `T[] data;` or `num[][] grid;`.
                        while (field_name_i < tokens.len and isPunctChar(tokens[field_name_i], '[')) {
                            const rbr_i = nextNonTrivialToken(tokens, field_name_i + 1) orelse break;
                            if (rbr_i < tokens.len and isPunctChar(tokens[rbr_i], ']')) {
                                ftype_buf.appendSlice("[]") catch {};
                                field_name_i = nextNonTrivialToken(tokens, rbr_i + 1) orelse break;
                            } else break;
                        }

                        var markers = ArrayList(u8).init(allocator);
                        defer markers.deinit();
                        while (field_name_i < tokens.len and (isPunctChar(tokens[field_name_i], '*') or isPunctChar(tokens[field_name_i], '&'))) {
                            if (isPunctChar(tokens[field_name_i], '*')) try markers.append('*');
                            if (isPunctChar(tokens[field_name_i], '&')) try markers.append('&');
                            field_name_i = nextNonTrivialToken(tokens, field_name_i + 1) orelse break;
                        }

                        if (!isIdent(tokens[field_name_i])) continue;

                        const after_name_i = nextNonTrivialToken(tokens, field_name_i + 1) orelse continue;
                        if (!isSymbolChar(tokens[after_name_i], ';')) continue;

                        const ftype = if (markers.items.len == 0)
                            (allocator.dupe(u8, ftype_buf.items) catch ftype_raw)
                        else
                            (std.mem.concat(allocator, u8, &[_][]const u8{ ftype_buf.items, markers.items }) catch ftype_raw);
                        const fname = tokenString(tokens[field_name_i]);
                        const fr = rangeFromTokenPos(tokens[field_name_i].pos);
                        try out.append(.{
                            .name = try allocator.dupe(u8, fname),
                            .kind = .field,
                            .decl_range = fr,
                            .selection_range = fr,
                            .is_public = is_public,
                            .container_type = try allocator.dupe(u8, owner_name),
                            .value_type = try allocator.dupe(u8, ftype),
                            .detail = null,
                        });

                        // Skip past `Type name ;` to avoid re-processing.
                        k = after_name_i;
                    }
                    break;
                }
                j_opt = nextNonTrivialToken(tokens, j + 1);
            }
            continue;
        }

        if (isKeyword(t, "enum")) {
            const is_public = blk: {
                const prev = prevNonTrivialToken(tokens, i) orelse break :blk false;
                break :blk isPubToken(tokens[prev]);
            };
            const name_i = nextNonTrivialToken(tokens, i + 1) orelse continue;
            if (!isIdent(tokens[name_i])) continue;
            const name = tokenString(tokens[name_i]);
            const r = rangeFromTokenPos(tokens[name_i].pos);
            try out.append(.{
                .name = try allocator.dupe(u8, name),
                .kind = .enum_,
                .decl_range = r,
                .selection_range = r,
                .is_public = is_public,
                .container_type = null,
                .value_type = null,
                .detail = null,
            });

            // Best-effort enum variant indexing inside `enum Name { Variant; Variant2 = 3; ... }`.
            const owner_name = name;
            var j_opt = nextNonTrivialToken(tokens, name_i + 1);
            while (j_opt) |j| {
                if (isSymbolChar(tokens[j], '{')) {
                    var depth: i64 = 1;
                    var k: usize = j + 1;
                    while (k < tokens.len and depth > 0) : (k += 1) {
                        const tk = tokens[k];
                        if (isSymbolChar(tk, '{')) depth += 1;
                        if (isSymbolChar(tk, '}')) depth -= 1;
                        if (depth != 1) continue;

                        if (!isIdent(tk)) continue;
                        const after_name_i = nextNonTrivialToken(tokens, k + 1) orelse continue;

                        // `Variant,` / `Variant;` / `Variant}`
                        if (isPunctChar(tokens[after_name_i], ',') or isSymbolChar(tokens[after_name_i], ';') or isSymbolChar(tokens[after_name_i], '}')) {
                            const vname = tokenString(tk);
                            const vr = rangeFromTokenPos(tk.pos);
                            try out.append(.{
                                .name = try allocator.dupe(u8, vname),
                                .kind = .enumMember,
                                .decl_range = vr,
                                .selection_range = vr,
                                .is_public = is_public,
                                .container_type = try allocator.dupe(u8, owner_name),
                                .value_type = try allocator.dupe(u8, owner_name),
                                .detail = null,
                            });
                            k = after_name_i;
                            continue;
                        }

                        // `Variant = 3,` / `Variant = 3;` / `Variant = 3}`
                        if (isPunctChar(tokens[after_name_i], '=')) {
                            const semi_i = nextNonTrivialToken(tokens, after_name_i + 1) orelse continue;
                            // Scan forward to ',' / ';' / '}'
                            var m: usize = semi_i;
                            while (m < tokens.len) : (m += 1) {
                                if (isPunctChar(tokens[m], ',') or isSymbolChar(tokens[m], ';') or isSymbolChar(tokens[m], '}')) break;
                                if (isSymbolChar(tokens[m], '{')) break;
                            }
                            if (m < tokens.len and (isPunctChar(tokens[m], ',') or isSymbolChar(tokens[m], ';') or isSymbolChar(tokens[m], '}'))) {
                                const vname = tokenString(tk);
                                const vr = rangeFromTokenPos(tk.pos);
                                try out.append(.{
                                    .name = try allocator.dupe(u8, vname),
                                    .kind = .enumMember,
                                    .decl_range = vr,
                                    .selection_range = vr,
                                    .is_public = is_public,
                                    .container_type = try allocator.dupe(u8, owner_name),
                                    .value_type = try allocator.dupe(u8, owner_name),
                                    .detail = null,
                                });
                                k = m;
                            }
                        }
                    }
                    break;
                }
                j_opt = nextNonTrivialToken(tokens, j + 1);
            }

            continue;
        }

        if (isKeyword(t, "quirk")) {
            const is_public = blk: {
                const prev = prevNonTrivialToken(tokens, i) orelse break :blk false;
                break :blk isPubToken(tokens[prev]);
            };
            const name_i = nextNonTrivialToken(tokens, i + 1) orelse continue;
            if (!isIdent(tokens[name_i])) continue;
            const name = tokenString(tokens[name_i]);
            const r = rangeFromTokenPos(tokens[name_i].pos);
            try out.append(.{
                .name = try allocator.dupe(u8, name),
                .kind = .interface,
                .decl_range = r,
                .selection_range = r,
                .is_public = is_public,
                .container_type = null,
                .value_type = null,
                .detail = null,
            });

            // Best-effort quirk method prototypes: `name(args...) type;`.
            const owner_name = name;
            var j_opt = nextNonTrivialToken(tokens, name_i + 1);
            while (j_opt) |j| {
                if (isSymbolChar(tokens[j], '{')) {
                    var depth: i64 = 1;
                    var k: usize = j + 1;
                    while (k < tokens.len and depth > 0) : (k += 1) {
                        const tk = tokens[k];
                        if (isSymbolChar(tk, '{')) depth += 1;
                        if (isSymbolChar(tk, '}')) depth -= 1;
                        if (depth != 1) continue;

                        if (!isIdent(tk)) continue;
                        const after_name_i = nextNonTrivialToken(tokens, k + 1) orelse continue;
                        if (!isPunctChar(tokens[after_name_i], '(')) continue;

                        const sig = try buildSignatureFromTokens(allocator, tokens, k, false);

                        const mname = tokenString(tk);
                        const mr = rangeFromTokenPos(tk.pos);
                        try out.append(.{
                            .name = try allocator.dupe(u8, mname),
                            .kind = .method,
                            .decl_range = mr,
                            .selection_range = mr,
                            .is_public = is_public,
                            .container_type = try allocator.dupe(u8, owner_name),
                            .value_type = sig.return_type,
                            .detail = sig.detail,
                        });
                    }
                    break;
                }
                j_opt = nextNonTrivialToken(tokens, j + 1);
            }
            continue;
        }

        if (isKeyword(t, "impl")) {
            // Enter impl block tracking so we can index locals/self inside methods.
            pending_impl_block = true;
            const type_i = nextNonTrivialToken(tokens, i + 1) orelse {
                impl_owner_name = null;
                continue;
            };
            if (!isIdent(tokens[type_i])) {
                impl_owner_name = null;
                continue;
            }

            const owner_base = tokenString(tokens[type_i]);
            var owner_buf = ArrayList(u8).init(allocator);
            defer owner_buf.deinit();
            owner_buf.appendSlice(owner_base) catch {};

            var after_type_i = nextNonTrivialToken(tokens, type_i + 1) orelse tokens.len;
            if (after_type_i < tokens.len and isPunctChar(tokens[after_type_i], '<')) {
                var gdepth: i64 = 0;
                var gi = after_type_i;
                while (gi < tokens.len) : (gi += 1) {
                    const gtok = tokens[gi];
                    if (gtok.type == .NewLine or gtok.type == .Comment) continue;
                    if (isPunctChar(gtok, '<')) {
                        gdepth += 1;
                        owner_buf.append('<') catch {};
                        continue;
                    }
                    if (isPunctChar(gtok, '>')) {
                        gdepth -= 1;
                        owner_buf.append('>') catch {};
                        if (gdepth == 0) {
                            after_type_i = nextNonTrivialToken(tokens, gi + 1) orelse tokens.len;
                            break;
                        }
                        continue;
                    }
                    if (gdepth <= 0) break;
                    if (isPunctChar(gtok, ',')) {
                        owner_buf.appendSlice(", ") catch {};
                        continue;
                    }
                    const ts = tokenString(gtok);
                    if (ts.len != 0) owner_buf.appendSlice(ts) catch {};
                }
            }

            const owner_name = allocator.dupe(u8, owner_buf.items) catch owner_base;
            impl_owner_name = owner_name;

            // impl <Type> [<Quirk>] { ... }
            // Find opening '{'
            var j_opt = nextNonTrivialToken(tokens, after_type_i);
            while (j_opt) |j| {
                if (isSymbolChar(tokens[j], '{')) {
                    // Scan methods: look for `<ident>(` until matching '}'
                    var depth: i64 = 1;
                    var k: usize = j + 1;
                    while (k < tokens.len and depth > 0) : (k += 1) {
                        const tk = tokens[k];
                        if (isSymbolChar(tk, '{')) depth += 1;
                        if (isSymbolChar(tk, '}')) depth -= 1;

                        if (depth != 1) continue;
                        if (!isIdent(tk)) continue;

                        const after_name_i = nextNonTrivialToken(tokens, k + 1) orelse continue;
                        if (!isPunctChar(tokens[after_name_i], '(')) continue;

                        const sig = try buildSignatureFromTokens(allocator, tokens, k, false);

                        const is_public = hasPubModifierBefore(tokens, k);

                        const mname = tokenString(tk);
                        const r = rangeFromTokenPos(tk.pos);
                        try out.append(.{
                            .name = try allocator.dupe(u8, mname),
                            .kind = .method,
                            .decl_range = r,
                            .selection_range = r,
                            .is_public = is_public,
                            .container_type = try allocator.dupe(u8, owner_name),
                            .value_type = sig.return_type,
                            .detail = sig.detail,
                        });
                    }
                    break;
                }
                j_opt = nextNonTrivialToken(tokens, j + 1);
            }
            continue;
        }

        // Recognize impl method declarations at the top-level of an impl block so we can index
        // `self`, params, and locals within the method body.
        if (in_impl_block and brace_depth == impl_brace_depth and t.type == .Identifier) {
            const after_name_i = nextNonTrivialToken(tokens, i + 1) orelse null;
            if (after_name_i != null and isPunctChar(tokens[after_name_i.?], '(')) {
                // Avoid clobbering a pending `fun` body if the user is mid-edit.
                resetPendingBody(&pending_body, &pending_params, &pending_impl_owner, &pending_is_variadic);
                pending_body = .impl_method;
                pending_impl_owner = impl_owner_name;
                parseParamsAfterLParen(allocator, tokens, after_name_i.?, &pending_params, &pending_is_variadic);
            }
        }

        // Best-effort for-range local indexing:
        // - `for item : iterable { ... }`
        // - `for index, item :: iterable { ... }`
        if (in_body and isKeyword(t, "for")) {
            const first_i = nextNonTrivialToken(tokens, i + 1) orelse continue;
            if (!isIdent(tokens[first_i])) continue;

            var index_name_i: ?usize = null;
            var item_name_i: usize = first_i;
            var expr_start_i: ?usize = null;

            const after_first_i = nextNonTrivialToken(tokens, first_i + 1) orelse continue;

            if (isPunctChar(tokens[after_first_i], ',')) {
                // `for index, item :: expr`
                const second_i = nextNonTrivialToken(tokens, after_first_i + 1) orelse continue;
                if (!isIdent(tokens[second_i])) continue;
                index_name_i = first_i;
                item_name_i = second_i;

                const delim_i = nextNonTrivialToken(tokens, second_i + 1) orelse continue;
                if (tokens[delim_i].type == .Operator and std.mem.eql(u8, tokenString(tokens[delim_i]), "::")) {
                    expr_start_i = nextNonTrivialToken(tokens, delim_i + 1);
                } else if (isPunctChar(tokens[delim_i], ':')) {
                    const delim2_i = nextNonTrivialToken(tokens, delim_i + 1) orelse continue;
                    if (!isPunctChar(tokens[delim2_i], ':')) continue;
                    expr_start_i = nextNonTrivialToken(tokens, delim2_i + 1);
                } else {
                    continue;
                }
            } else if (isPunctChar(tokens[after_first_i], ':')) {
                // `for item : expr`
                item_name_i = first_i;
                expr_start_i = nextNonTrivialToken(tokens, after_first_i + 1);
            } else {
                continue;
            }

            if (expr_start_i == null) continue;

            // Find a conservative end bound for iterable expression (before loop body `{`).
            var expr_end_i: usize = expr_start_i.?;
            var p_depth: i64 = 0;
            var b_depth: i64 = 0;
            var c_depth: i64 = 0;
            while (expr_end_i < tokens.len) : (expr_end_i += 1) {
                const ek = tokens[expr_end_i];
                if (ek.type == .NewLine or ek.type == .Comment) continue;
                if (isPunctChar(ek, '(')) p_depth += 1;
                if (isPunctChar(ek, ')')) p_depth -= 1;
                if (isPunctChar(ek, '[')) b_depth += 1;
                if (isPunctChar(ek, ']')) b_depth -= 1;
                if (isSymbolChar(ek, '{')) {
                    if (p_depth <= 0 and b_depth <= 0 and c_depth <= 0) break;
                    c_depth += 1;
                    continue;
                }
                if (isSymbolChar(ek, '}')) {
                    if (c_depth > 0) c_depth -= 1;
                    continue;
                }
            }

            const iterable_type = inferExprTypeFromTokens(allocator, tokens, expr_start_i.?, expr_end_i, &locals_type_map, &globals_type_map, out.items);
            const item_type = if (iterable_type) |it|
                (if (isArrayTypeName(it)) it[0 .. it.len - 2] else it)
            else
                null;

            // Indexed loop counter is always numeric.
            if (index_name_i) |idx_i| {
                const idx_name_raw = tokenString(tokens[idx_i]);
                const idx_name = allocator.dupe(u8, idx_name_raw) catch idx_name_raw;
                const idx_r = rangeFromTokenPos(tokens[idx_i].pos);
                try out.append(.{
                    .name = try allocator.dupe(u8, idx_name),
                    .kind = .variable,
                    .decl_range = idx_r,
                    .selection_range = idx_r,
                    .container_fn_range = body_range.?,
                    .container_type = null,
                    .value_type = try allocator.dupe(u8, "num"),
                    .detail = blk: {
                        var det_buf = ArrayList(u8).init(allocator);
                        defer det_buf.deinit();
                        try det_buf.print("num {s}", .{idx_name});
                        break :blk try allocator.dupe(u8, det_buf.items);
                    },
                });
                putType(&locals_type_map, idx_name, "num", allocator);
            }

            const item_name_raw = tokenString(tokens[item_name_i]);
            const item_name = allocator.dupe(u8, item_name_raw) catch item_name_raw;
            const item_r = rangeFromTokenPos(tokens[item_name_i].pos);
            const item_vt = if (item_type) |it| (allocator.dupe(u8, it) catch it) else null;
            const item_detail = if (item_type) |it| blk: {
                var det_buf = ArrayList(u8).init(allocator);
                defer det_buf.deinit();
                try det_buf.print("{s} {s}", .{ it, item_name });
                break :blk try allocator.dupe(u8, det_buf.items);
            } else null;

            try out.append(.{
                .name = try allocator.dupe(u8, item_name),
                .kind = .variable,
                .decl_range = item_r,
                .selection_range = item_r,
                .container_fn_range = body_range.?,
                .container_type = null,
                .value_type = item_vt,
                .detail = item_detail,
            });
            putType(&locals_type_map, item_name, item_type, allocator);
            continue;
        }

        // Best-effort local variable indexing (token-based):
        // - `let name = <expr>;` (expression-based inference)
        // - `Type name;` / `Type name = ...;`
        // - `Type* name;` / `Type * name = ...;`
        // - `Type& name;` / `Type & name = ...;`
        // Attach locals to the enclosing `fun { ... }` body.
        if (in_body and isLetToken(t)) {
            const name_i = nextNonTrivialToken(tokens, i + 1) orelse continue;
            if (!isIdent(tokens[name_i])) continue;

            const after_name_i = nextNonTrivialToken(tokens, name_i + 1) orelse continue;
            if (!isPunctChar(tokens[after_name_i], '=')) continue;

            var end_i = after_name_i + 1;
            var depth: i64 = 0;
            var generic_depth: i64 = 0;
            while (end_i < tokens.len) : (end_i += 1) {
                const tk = tokens[end_i];
                if (tk.type == .NewLine or tk.type == .Comment) continue;
                if (isPunctChar(tk, '(') or isPunctChar(tk, '[') or isSymbolChar(tk, '{')) depth += 1;
                if (isPunctChar(tk, ')') or isPunctChar(tk, ']') or isSymbolChar(tk, '}')) depth -= 1;
                if (isPunctChar(tk, '<')) generic_depth += 1;
                if (isPunctChar(tk, '>') and generic_depth > 0) generic_depth -= 1;
                if (depth <= 0 and isPunctChar(tk, ';')) break;
                if (depth <= 0 and generic_depth <= 0 and isPunctChar(tk, ',')) break;
            }

            const vname_raw = tokenString(tokens[name_i]);
            const vname = allocator.dupe(u8, vname_raw) catch vname_raw;
            const r = rangeFromTokenPos(tokens[name_i].pos);

            const inferred = inferExprTypeFromTokens(allocator, tokens, after_name_i + 1, end_i, &locals_type_map, &globals_type_map, out.items);
            const value_type = if (inferred) |tname| (allocator.dupe(u8, tname) catch tname) else null;
            const detail = if (inferred) |tname| blk: {
                var det_buf = ArrayList(u8).init(allocator);
                defer det_buf.deinit();
                try det_buf.print("{s} {s}", .{ tname, vname });
                break :blk try allocator.dupe(u8, det_buf.items);
            } else null;

            try out.append(.{
                .name = try allocator.dupe(u8, vname),
                .kind = .variable,
                .decl_range = r,
                .selection_range = r,
                .container_fn_range = body_range.?,
                .container_type = null,
                .value_type = value_type,
                .detail = detail,
            });
            putType(&locals_type_map, vname, value_type, allocator);
            continue;
        }
        if (in_body and isTypeToken(t)) {
            // Avoid `compound X`, `quirk X`, `impl X`, `fun name`.
            if (i > 0 and tokens[i - 1].type == .Keyword) {
                const kw = tokenString(tokens[i - 1]);
                if (std.mem.eql(u8, kw, "compound") or std.mem.eql(u8, kw, "quirk") or std.mem.eql(u8, kw, "impl") or std.mem.eql(u8, kw, "enum") or std.mem.eql(u8, kw, "fun")) {
                    continue;
                }
            }

            const vtype_base_raw = tokenString(t);
            var vtype_buf = ArrayList(u8).init(allocator);
            defer vtype_buf.deinit();
            vtype_buf.appendSlice(vtype_base_raw) catch {};

            var name_i = nextNonTrivialToken(tokens, i + 1) orelse continue;
            if (name_i < tokens.len and isPunctChar(tokens[name_i], '<')) {
                var gdepth: i64 = 0;
                var gi = name_i;
                while (gi < tokens.len) : (gi += 1) {
                    const gtok = tokens[gi];
                    if (gtok.type == .NewLine or gtok.type == .Comment) continue;
                    if (isPunctChar(gtok, '<')) {
                        gdepth += 1;
                        vtype_buf.append('<') catch {};
                        continue;
                    }
                    if (isPunctChar(gtok, '>')) {
                        gdepth -= 1;
                        vtype_buf.append('>') catch {};
                        if (gdepth == 0) {
                            name_i = nextNonTrivialToken(tokens, gi + 1) orelse continue;
                            break;
                        }
                        continue;
                    }
                    if (gdepth <= 0) break;
                    if (isPunctChar(gtok, ',')) {
                        vtype_buf.appendSlice(", ") catch {};
                        continue;
                    }
                    const ts = tokenString(gtok);
                    if (ts.len != 0) vtype_buf.appendSlice(ts) catch {};
                }
            }
            // Consume array dimension brackets `[][]...` that are part of the type.
            while (name_i < tokens.len and isPunctChar(tokens[name_i], '[')) {
                const rbr_i = nextNonTrivialToken(tokens, name_i + 1) orelse break;
                if (rbr_i < tokens.len and isPunctChar(tokens[rbr_i], ']')) {
                    vtype_buf.appendSlice("[]") catch {};
                    name_i = nextNonTrivialToken(tokens, rbr_i + 1) orelse break;
                } else break;
            }

            var markers = ArrayList(u8).init(allocator);
            defer markers.deinit();
            while (name_i < tokens.len and (isPunctChar(tokens[name_i], '*') or isPunctChar(tokens[name_i], '&'))) {
                if (isPunctChar(tokens[name_i], '*')) try markers.append('*');
                if (isPunctChar(tokens[name_i], '&')) try markers.append('&');
                name_i = nextNonTrivialToken(tokens, name_i + 1) orelse break;
            }
            if (name_i >= tokens.len or !isIdent(tokens[name_i])) continue;

            // Avoid pairing across lines (e.g. `p` then next-line `p.x...`) which would
            // create bogus locals like `p p`.
            if (tokens[i].pos.line != tokens[name_i].pos.line) continue;

            // Require declaration terminator after the name.
            const first_after_i = nextNonTrivialToken(tokens, name_i + 1) orelse continue;
            if (!(isPunctChar(tokens[first_after_i], ';') or isPunctChar(tokens[first_after_i], '=') or isPunctChar(tokens[first_after_i], ','))) continue;

            const vtype_display = if (markers.items.len == 0)
                (allocator.dupe(u8, vtype_buf.items) catch vtype_base_raw)
            else
                (try std.mem.concat(allocator, u8, &[_][]const u8{ vtype_buf.items, markers.items }));

            // Support `Type a, b, c;` by walking commas until a terminator.
            var cur_name_i: usize = name_i;
            while (true) {
                const vname_raw = tokenString(tokens[cur_name_i]);
                const vname = allocator.dupe(u8, vname_raw) catch vname_raw;
                const r = rangeFromTokenPos(tokens[cur_name_i].pos);

                var det_buf = ArrayList(u8).init(allocator);
                defer det_buf.deinit();
                try det_buf.print("{s} {s}", .{ vtype_display, vname });

                try out.append(.{
                    .name = try allocator.dupe(u8, vname),
                    .kind = .variable,
                    .decl_range = r,
                    .selection_range = r,
                    .container_fn_range = body_range.?,
                    .container_type = null,
                    .value_type = try allocator.dupe(u8, vtype_display),
                    .detail = try allocator.dupe(u8, det_buf.items),
                });

                putType(&locals_type_map, vname, vtype_display, allocator);

                const after_i = nextNonTrivialToken(tokens, cur_name_i + 1) orelse break;
                if (isPunctChar(tokens[after_i], ',')) {
                    const next_name_i = nextNonTrivialToken(tokens, after_i + 1) orelse break;
                    if (!isIdent(tokens[next_name_i])) break;
                    if (tokens[cur_name_i].pos.line != tokens[next_name_i].pos.line) break;
                    cur_name_i = next_name_i;
                    continue;
                }
                // End of declaration.
                break;
            }
            continue;
        }

        // Best-effort top-level global variable indexing: `Type name;` or `Type name = ...;`
        // Only at top-level (brace_depth==0) and not in parameter lists (paren_depth==0).
        if (brace_depth == 0 and paren_depth == 0 and isTypeToken(t)) {
            // Avoid `compound X`, `quirk X`, `impl X`, `fun name`.
            if (i > 0 and tokens[i - 1].type == .Keyword) {
                const kw = tokenString(tokens[i - 1]);
                if (std.mem.eql(u8, kw, "compound") or std.mem.eql(u8, kw, "quirk") or std.mem.eql(u8, kw, "impl") or std.mem.eql(u8, kw, "fun")) {
                    continue;
                }
            }

            const vtype_raw = tokenString(t);
            var vtype_buf = ArrayList(u8).init(allocator);
            defer vtype_buf.deinit();
            vtype_buf.appendSlice(vtype_raw) catch {};

            var name_i = nextNonTrivialToken(tokens, i + 1) orelse continue;
            if (name_i < tokens.len and isPunctChar(tokens[name_i], '<')) {
                var gdepth: i64 = 0;
                var gi = name_i;
                while (gi < tokens.len) : (gi += 1) {
                    const gtok = tokens[gi];
                    if (gtok.type == .NewLine or gtok.type == .Comment) continue;
                    if (isPunctChar(gtok, '<')) {
                        gdepth += 1;
                        vtype_buf.append('<') catch {};
                        continue;
                    }
                    if (isPunctChar(gtok, '>')) {
                        gdepth -= 1;
                        vtype_buf.append('>') catch {};
                        if (gdepth == 0) {
                            name_i = nextNonTrivialToken(tokens, gi + 1) orelse continue;
                            break;
                        }
                        continue;
                    }
                    if (gdepth <= 0) break;
                    if (isPunctChar(gtok, ',')) {
                        vtype_buf.appendSlice(", ") catch {};
                        continue;
                    }
                    const ts = tokenString(gtok);
                    if (ts.len != 0) vtype_buf.appendSlice(ts) catch {};
                }
            }

            // Consume array dimension brackets `[][]...` that follow the base type (or generic).
            while (name_i < tokens.len and isPunctChar(tokens[name_i], '[')) {
                const rbr_i = nextNonTrivialToken(tokens, name_i + 1) orelse break;
                if (rbr_i < tokens.len and isPunctChar(tokens[rbr_i], ']')) {
                    vtype_buf.appendSlice("[]") catch {};
                    name_i = nextNonTrivialToken(tokens, rbr_i + 1) orelse break;
                } else break;
            }

            var markers = ArrayList(u8).init(allocator);
            defer markers.deinit();
            while (name_i < tokens.len and (isPunctChar(tokens[name_i], '*') or isPunctChar(tokens[name_i], '&'))) {
                if (isPunctChar(tokens[name_i], '*')) try markers.append('*');
                if (isPunctChar(tokens[name_i], '&')) try markers.append('&');
                name_i = nextNonTrivialToken(tokens, name_i + 1) orelse break;
            }
            if (!isIdent(tokens[name_i])) continue;
            const after_i = nextNonTrivialToken(tokens, name_i + 1) orelse continue;
            const after = tokens[after_i];
            if (!(isPunctChar(after, ';') or isPunctChar(after, '=') or isPunctChar(after, ','))) continue;

            const vtype = if (markers.items.len == 0)
                (allocator.dupe(u8, vtype_buf.items) catch vtype_raw)
            else
                (std.mem.concat(allocator, u8, &[_][]const u8{ vtype_buf.items, markers.items }) catch vtype_raw);
            const vname_raw = tokenString(tokens[name_i]);
            const vname = allocator.dupe(u8, vname_raw) catch vname_raw;
            const r = rangeFromTokenPos(tokens[name_i].pos);

            var det_buf = ArrayList(u8).init(allocator);
            defer det_buf.deinit();
            try det_buf.print("{s} {s}", .{ vtype, vname });

            try out.append(.{
                .name = try allocator.dupe(u8, vname),
                .kind = .variable,
                .decl_range = r,
                .selection_range = r,
                .container_type = null,
                .value_type = try allocator.dupe(u8, vtype),
                .detail = try allocator.dupe(u8, det_buf.items),
                .is_public = blk: {
                    const prev = prevNonTrivialToken(tokens, i) orelse break :blk false;
                    break :blk isPubToken(tokens[prev]);
                },
            });
            putType(&globals_type_map, vname, vtype, allocator);
            continue;
        }
    }
}
