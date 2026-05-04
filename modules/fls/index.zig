const std = @import("std");
const ast = @import("ast");
const codegen = @import("codegen");
const parser = @import("parser");
const lexer = @import("lexer");
const utils = @import("utils");
const globals = @import("globals.zig");
const types = @import("types.zig");
const positions_mod = @import("positions.zig");
const token_idx = @import("token_index.zig");
const ast_idx = @import("ast_index.zig");

fn ArrayList(comptime T: type) type {
    return std.array_list.Managed(T);
}

const Allocator = std.mem.Allocator;

const globalIo = globals.globalIo;
const nowNs = globals.nowNs;

const Position = types.Position;
const Range = types.Range;
const TokenLite = types.TokenLite;
const SymbolLite = types.SymbolLite;
const TokenLiteKind = types.TokenLiteKind;
pub const Index = types.Index;

const rangeFromTokenPos = positions_mod.rangeFromTokenPos;
const findBestDefinition = positions_mod.findBestDefinition;
const collectSymbolsFromTokens = token_idx.collectSymbolsFromTokens;
const enrichSymbolsFromAst = ast_idx.enrichSymbolsFromAst;
const collectSymbolsFromTopLevel = ast_idx.collectSymbolsFromTopLevel;
const fixAstVariableRanges = ast_idx.fixAstVariableRanges;

var fls_temp_cleanup_done: bool = false;
var fls_temp_dir_warned: bool = false;
var fls_temp_dir_announced: bool = false;
var fls_temp_dir_cache_init_done: bool = false;
var fls_temp_dir_cache: ?FlsTempDir = null;

pub const FlsTempDir = struct {
    dir: std.Io.Dir,
    abs_path: []const u8,
};

pub fn tryOpenFlsTempDir(alloc: Allocator) !?FlsTempDir {
    const is_windows = @import("builtin").target.os.tag == .windows;

    const Try = struct {
        fn openSub(alloc_inner: Allocator, root_path: []const u8) !?FlsTempDir {
            const base_dir_opt = std.Io.Dir.openDirAbsolute(globalIo(), root_path, .{}) catch null;
            if (base_dir_opt) |bd| {
                var bd_mut = bd;
                defer bd_mut.close(globalIo());

                bd_mut.createDir(globalIo(), "fun-fls", .default_dir) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => return null,
                };

                const abs_path = try std.fs.path.join(alloc_inner, &.{ root_path, "fun-fls" });
                const d = std.Io.Dir.openDirAbsolute(globalIo(), abs_path, .{ .iterate = true }) catch return null;
                return .{ .dir = d, .abs_path = abs_path };
            }
            return null;
        }
    };

    const env_try = struct {
        fn get(alloc_inner: Allocator, comptime name: [:0]const u8) ?[]const u8 {
            const z = std.c.getenv(name) orelse return null;
            const s = std.mem.sliceTo(z, 0);
            return alloc_inner.dupe(u8, s) catch null;
        }
    };

    if (is_windows) {
        if (env_try.get(alloc, "TEMP")) |p| if (try Try.openSub(alloc, p)) |r| return r;
        if (env_try.get(alloc, "TMP")) |p| if (try Try.openSub(alloc, p)) |r| return r;
        if (env_try.get(alloc, "LOCALAPPDATA")) |lap| {
            const p = try std.fs.path.join(alloc, &.{ lap, "Temp" });
            if (try Try.openSub(alloc, p)) |r| return r;
        }
        if (env_try.get(alloc, "USERPROFILE")) |up| {
            const p = try std.fs.path.join(alloc, &.{ up, "AppData", "Local", "Temp" });
            if (try Try.openSub(alloc, p)) |r| return r;
        }
        if (env_try.get(alloc, "SystemRoot")) |sr| {
            const p = try std.fs.path.join(alloc, &.{ sr, "Temp" });
            if (try Try.openSub(alloc, p)) |r| return r;
        }

        // Last-resort Windows conventional temp path.
        if (try Try.openSub(alloc, "C:\\Windows\\Temp")) |r| return r;
    } else {
        if (env_try.get(alloc, "TMPDIR")) |p| if (try Try.openSub(alloc, p)) |r| return r;
        if (env_try.get(alloc, "TMP")) |p| if (try Try.openSub(alloc, p)) |r| return r;
        if (env_try.get(alloc, "TEMP")) |p| if (try Try.openSub(alloc, p)) |r| return r;

        // Last-resort POSIX conventional temp path.
        if (try Try.openSub(alloc, "/tmp")) |r| return r;
    }

    return null;
}

pub fn getOrInitFlsTempDirCached() ?FlsTempDir {
    if (fls_temp_dir_cache_init_done) return fls_temp_dir_cache;
    fls_temp_dir_cache_init_done = true;

    // Cache allocations live for the lifetime of the process.
    // This avoids reallocating/joining paths and reopening the directory on every keystroke.
    const cache_alloc = std.heap.page_allocator;
    fls_temp_dir_cache = tryOpenFlsTempDir(cache_alloc) catch null;

    const debug_on = blk: {
        const z = std.c.getenv("FUN_FLS_DEBUG") orelse break :blk false;
        const v = std.mem.sliceTo(z, 0);
        break :blk std.mem.eql(u8, v, "1");
    };

    if (fls_temp_dir_cache) |res| {
        if (debug_on and !fls_temp_dir_announced) {
            fls_temp_dir_announced = true;
            var _tmp_buf: [512]u8 = undefined;
            const _tmp_msg = std.fmt.bufPrint(&_tmp_buf, "[fls] temp dir: {s}\n", .{res.abs_path}) catch return fls_temp_dir_cache;
            std.Io.File.stderr().writeStreamingAll(globalIo(), _tmp_msg) catch {};
        }
        // One-time best-effort cleanup of stale leftovers.
        var d = res.dir;
        maybeCleanupFlsTempDir(&d);
    } else if (debug_on and !fls_temp_dir_warned) {
        fls_temp_dir_warned = true;
        std.Io.File.stderr().writeStreamingAll(globalIo(), "[fls] warning: could not open OS temp dir; using process CWD for temp files\n") catch {};
    }

    return fls_temp_dir_cache;
}

pub fn maybeCleanupFlsTempDir(dir: *std.Io.Dir) void {
    if (fls_temp_cleanup_done) return;
    fls_temp_cleanup_done = true;

    const now_ns: i128 = nowNs();
    // Delete only sufficiently old leftovers to avoid interfering with another running instance.
    // Files are normally deleted immediately; these are only meant to catch crash/kill residue.
    const max_age_ns: i128 = 30 * std.time.ns_per_min;

    var it = dir.iterate();
    while (it.next(globalIo()) catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;

        const prefix_idx = "_fls_idx_";
        const prefix_out = "__fls_unused__";

        var stamp_str: ?[]const u8 = null;
        if (std.mem.startsWith(u8, name, prefix_idx)) {
            const rest = name[prefix_idx.len..];
            if (std.mem.indexOfScalar(u8, rest, '_')) |pos| {
                stamp_str = rest[0..pos];
            }
        } else if (std.mem.startsWith(u8, name, prefix_out)) {
            const rest = name[prefix_out.len..];
            if (std.mem.indexOfScalar(u8, rest, '_')) |pos| {
                stamp_str = rest[0..pos];
            }
        } else {
            continue;
        }

        const s = stamp_str orelse continue;
        const stamp_ns = std.fmt.parseInt(i128, s, 10) catch continue;
        const age = now_ns - stamp_ns;
        if (age > max_age_ns) {
            dir.deleteFile(globalIo(), name) catch {};
        }
    }
}

pub fn buildIndexFromText(allocator: Allocator, text: []const u8) !*Index {
    return buildIndexFromTextAt(allocator, text, null, .open_document);
}

pub const IndexBuildScope = enum {
    open_document,
    background,
};

pub fn buildIndexFromTextAt(allocator: Allocator, text: []const u8, tmp_dir_path_opt: ?[]const u8, scope: IndexBuildScope) !*Index {
    // Parsing while typing regularly hits syntax errors.
    // Use an arena for the full compiler pipeline and for all index allocations.
    // This avoids per-token frees (which are brittle if anything is corrupted) and
    // keeps rebuildIndex O(1) cleanup.
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const tmp_alloc = arena.allocator();

    // NOTE: This function may run very frequently while typing.
    // If a directory path is provided, create the temp file in that directory so
    // relative imports resolve correctly. Otherwise, best-effort use OS temp.
    var tmp_dir = std.Io.Dir.cwd();
    var tmp_dir_path: ?[]const u8 = null;

    if (tmp_dir_path_opt) |p| {
        if (std.fs.path.isAbsolute(p)) {
            tmp_dir = try std.Io.Dir.openDirAbsolute(globalIo(), p, .{});
            defer tmp_dir.close(globalIo());
            tmp_dir_path = p;
        }
    } else if (getOrInitFlsTempDirCached()) |res| {
        tmp_dir = res.dir;
        tmp_dir_path = res.abs_path;
    }
    var tmp_name_buf: [96]u8 = undefined;
    var rng_buf: [8]u8 = undefined;
    globalIo().random(&rng_buf);
    const nonce = std.mem.readInt(u64, &rng_buf, .little);
    const S = struct {
        var uid: std.atomic.Value(u64) = .init(0);
    };
    const stamp = S.uid.fetchAdd(1, .monotonic);
    const tmp_name = try std.fmt.bufPrint(&tmp_name_buf, "_fls_idx_{d}_{x}.fn", .{ stamp, nonce });

    var out_name_buf: [96]u8 = undefined;
    const out_name = try std.fmt.bufPrint(&out_name_buf, "__fls_unused__{d}_{x}.c", .{ stamp, nonce });

    const tmp_path_for_codegen = if (tmp_dir_path) |p|
        (try std.fs.path.join(tmp_alloc, &.{ p, tmp_name }))
    else
        tmp_name;
    const out_path_for_codegen = if (tmp_dir_path) |p|
        (try std.fs.path.join(tmp_alloc, &.{ p, out_name }))
    else
        out_name;

    {
        const f = try tmp_dir.createFile(globalIo(), tmp_name, .{ .read = true, .truncate = true });
        defer f.close(globalIo());
        try f.writeStreamingAll(globalIo(), text);
    }
    defer tmp_dir.deleteFile(globalIo(), tmp_name) catch {};
    defer tmp_dir.deleteFile(globalIo(), out_name) catch {};

    // For LSP indexing, avoid preloading imports during parsing.
    // This prevents noisy "Import file not found" errors when indexing from a temp file path,
    // and also avoids touching the user's project directory.
    var tp = try codegen.TranspileProcess.init(
        tmp_alloc,
        tmp_path_for_codegen,
        out_path_for_codegen,
        .{ .exec = false, .outf = false, .ast = false, .preload_imports = false, .preload_std_imports = false, .emit_stderr = false },
    );
    defer tp.deinit();

    var lp = lexer.LexProcess.init(&tp);
    defer lp.deinit();
    try lp.lex();

    var tokens_out = ArrayList(TokenLite).init(tmp_alloc);
    for (tp.tokens.items()) |t| {
        if (t.type == .NewLine) continue;

        const kind: TokenLiteKind = switch (t.type) {
            .Identifier => .identifier,
            .Keyword => .keyword,
            .Number => .number,
            .String => .string,
            .Boolean => .boolean,
            .Comment => .comment,
            .Operator => .operator,
            .Symbol => .symbol,
            .NewLine => continue,
        };

        var text_copy: []u8 = undefined;
        switch (t.type) {
            .Symbol => {
                text_copy = try tmp_alloc.alloc(u8, 1);
                text_copy[0] = t.data.cval;
            },
            .Boolean => {
                const s = if (t.data.bval) "true" else "false";
                text_copy = try tmp_alloc.dupe(u8, s);
            },
            .Number => {
                var buf: [64]u8 = undefined;
                const s = switch (t.data) {
                    .inum => |v| try std.fmt.bufPrint(&buf, "{d}", .{v}),
                    .lnum => |v| try std.fmt.bufPrint(&buf, "{d}", .{v}),
                    .llnum => |v| try std.fmt.bufPrint(&buf, "{d}", .{v}),
                    .dnum => |v| try std.fmt.bufPrint(&buf, "{d}", .{v}),
                    .sval => |sv| sv.items,
                    else => "0",
                };
                text_copy = try tmp_alloc.dupe(u8, s);
            },
            else => {
                text_copy = switch (t.data) {
                    .sval => |sv| try tmp_alloc.dupe(u8, sv.items),
                    else => try tmp_alloc.dupe(u8, ""),
                };
            },
        }

        try tokens_out.append(.{ .kind = kind, .text = text_copy, .range = rangeFromTokenPos(t.pos) });
    }

    // Best-effort parse. Policy is scope-aware but opt-in by default for stability:
    // - open documents: disabled by default (token-only)
    // - background/workspace/import indexing: disabled by default (token-only)
    // Overrides:
    // - FLS_ENABLE_INPROC_PARSE=<truthy|falsey> forces on/off globally
    // - FLS_PARSE_SCOPE=none|open|all controls scoped parsing when the global override is unset
    const parse_enabled: bool = blk: {
        const isTruthy = struct {
            fn call(v: []const u8) bool {
                const s = std.mem.trim(u8, v, " \t\r\n");
                if (s.len == 0) return false;
                if (std.ascii.eqlIgnoreCase(s, "0")) return false;
                if (std.ascii.eqlIgnoreCase(s, "false")) return false;
                if (std.ascii.eqlIgnoreCase(s, "no")) return false;
                if (std.ascii.eqlIgnoreCase(s, "off")) return false;
                return true;
            }
        }.call;

        if (std.c.getenv("FLS_ENABLE_INPROC_PARSE")) |z| {
            const raw_global = std.mem.sliceTo(z, 0);
            break :blk isTruthy(raw_global);
        }

        if (std.c.getenv("FLS_PARSE_SCOPE")) |z| {
            const raw_scope = std.mem.sliceTo(z, 0);
            const s = std.mem.trim(u8, raw_scope, " \t\r\n");
            if (s.len == 0) break :blk false;
            if (std.ascii.eqlIgnoreCase(s, "none")) break :blk false;
            if (std.ascii.eqlIgnoreCase(s, "all")) break :blk true;
            if (std.ascii.eqlIgnoreCase(s, "open")) break :blk scope == .open_document;
        }

        // Default to token-only indexing unless explicitly opted into parser-backed indexing.
        break :blk false;
    };

    var parse_ok: bool = false;
    if (parse_enabled) {
        parse_ok = true;
        var pp = parser.ParseProcess.init(&tp);
        pp.parse() catch {
            parse_ok = false;
        };
        if (parse_ok) {
            // Let inference updates AST variable types so LSP can expose concrete types.
            tp.infer_let_types_best_effort();
        }
    }

    var symbols_out = ArrayList(SymbolLite).init(tmp_alloc);

    // Always do lexer-driven indexing first (robust while typing), then optionally
    // overlay/replace globals+locals with AST-backed symbols.
    var symbols_token = ArrayList(SymbolLite).init(tmp_alloc);
    try collectSymbolsFromTokens(tmp_alloc, &symbols_token, tp.tokens.items());

    if (parse_ok) {
        // Keep member/field symbols from the lexer scan (AST lacks positions for some of these).
        // Also keep lexer-derived enums/variants (AST-backed symbol collection currently doesn't include them).
        // Also keep token-derived locals (including implicit `self` and params inside `impl` methods),
        // because the current AST-backed collection does not cover all method-body locals.
        for (symbols_token.items) |s| {
            switch (s.kind) {
                .field, .property, .method => try symbols_out.append(s),
                .enum_, .enumMember => try symbols_out.append(s),
                .struct_, .interface => try symbols_out.append(s),
                .variable => {
                    if (s.container_fn_range != null) try symbols_out.append(s);
                },
                else => {},
            }
        }

        // Add AST-backed globals/locals/types.
        for (tp.nodes.items()) |n| {
            try collectSymbolsFromTopLevel(tmp_alloc, &symbols_out, n);
        }

        // If the AST missed pub flags, fall back to token-derived visibility for top-level symbols.
        var token_public = std.StringHashMap(bool).init(tmp_alloc);
        defer token_public.deinit();
        for (symbols_token.items) |s| {
            if (s.container_type != null) continue;
            if (s.container_fn_range != null) continue;
            if (!token_public.contains(s.name)) {
                try token_public.put(s.name, s.is_public);
            } else if (s.is_public) {
                // Preserve any public signal from tokens.
                try token_public.put(s.name, true);
            }
        }
        for (symbols_out.items) |*s| {
            if (s.container_type != null) continue;
            if (s.container_fn_range != null) continue;
            if (s.is_public) continue;
            if (token_public.get(s.name)) |pub_flag| {
                if (pub_flag) s.is_public = true;
            }
        }
    } else {
        // Fallback: token-only symbol index.
        symbols_out = symbols_token;
    }

    if (parse_ok) {
        fixAstVariableRanges(tokens_out.items, &symbols_out);
    }

    // If we successfully parsed in-process, enrich token-derived member symbols with
    // AST types/signatures (best-effort; ignore failures).
    if (parse_ok) {
        enrichSymbolsFromAst(tmp_alloc, &symbols_out, &tp) catch {};
    }

    const idx = try allocator.create(Index);
    idx.* = .{
        .allocator = allocator,
        .arena = arena,
        .tokens = try tokens_out.toOwnedSlice(),
        .symbols = try symbols_out.toOwnedSlice(),
    };
    return idx;
}

pub const GuessedCallSignature = struct {
    label: []const u8,
    active_param: i64,
    callee_i: ?usize = null,
    lparen_i: ?usize = null,
    cursor_tok_i: ?usize = null,
    explicit_generic_start_i: ?usize = null,
};

pub fn guessCallSignature(idx: *const Index, p: Position) ?GuessedCallSignature {
    // Find the closest '(' before cursor, then get identifier before it.
    var tok_index: ?usize = null;
    for (idx.tokens, 0..) |t, i| {
        if (t.range.start.line > p.line) break;
        if (t.range.start.line == p.line and t.range.start.character > p.character) break;
        tok_index = i;
    }
    if (tok_index == null) return null;

    var i: isize = @intCast(tok_index.?);
    var paren_depth: i64 = 0;
    var active_param: i64 = 0;
    while (i >= 0) : (i -= 1) {
        const t = idx.tokens[@intCast(i)];
        if (t.kind == .symbol or t.kind == .operator) {
            if (std.mem.eql(u8, t.text, ")")) {
                paren_depth += 1;
            } else if (std.mem.eql(u8, t.text, "(")) {
                if (paren_depth == 0) {
                    // function name is previous identifier
                    if (i - 1 >= 0) {
                        const prev = idx.tokens[@intCast(i - 1)];
                        if (prev.kind == .identifier) {
                            const fn_name = prev.text;
                            const def = findBestDefinition(idx.symbols, fn_name, p) orelse null;
                            const label = if (def != null and def.?.detail != null) def.?.detail.? else fn_name;
                            return .{ .label = label, .active_param = active_param };
                        }
                    }
                    return null;
                }
                paren_depth -= 1;
            } else if (paren_depth == 0 and std.mem.eql(u8, t.text, ",")) {
                active_param += 1;
            }
        }
    }
    return null;
}

pub fn classifyIdentifierTokenType(idx: *const Index, name: []const u8) u32 {
    // Built-in/C typedef-like type names that don't appear in the current file's symbol table.
    if (utils.keyword_is_datatype(name)) return 7;
    if (utils.get_c_typedef_alias_datatype_type(name) != null) return 7;

    for (idx.symbols) |s| {
        if (!std.mem.eql(u8, s.name, name)) continue;
        return switch (s.kind) {
            .function, .method => 5,
            .struct_, .interface, .enum_, .class, .typeParameter => 7,
            .enumMember => 8,
            .variable => 6,
            .field, .property, .constant => 6,
            else => 6,
        };
    }
    return 6;
}

pub fn isAllUpperTypeLikeName(name: []const u8) bool {
    var saw_alpha = false;
    for (name) |c| {
        if (std.ascii.isAlphabetic(c)) {
            saw_alpha = true;
            if (std.ascii.isLower(c)) return false;
            continue;
        }
        if (std.ascii.isDigit(c) or c == '_') continue;
        return false;
    }
    return saw_alpha;
}

pub fn isDefaultLibraryTypeName(name: []const u8) bool {
    if (utils.keyword_is_datatype(name)) return true;
    if (utils.get_c_typedef_alias_datatype_type(name) != null) {
        // Keep all-caps C object-like types (for example FILE) on custom-type color.
        if (isAllUpperTypeLikeName(name)) return false;
        return true;
    }
    return false;
}

pub fn buildSemanticTokens(allocator: Allocator, idx: *const Index) ![]u32 {
    var data = ArrayList(u32).init(allocator);
    errdefer data.deinit();

    var last_line: i64 = 0;
    var last_start: i64 = 0;
    var have_last = false;

    for (idx.tokens, 0..) |t, ti| {
        const start_line = t.range.start.line;
        const start_char = t.range.start.character;
        const len_i64 = t.range.end.character - t.range.start.character;
        if (len_i64 <= 0) continue;

        const delta_line: u32 = if (!have_last) @intCast(start_line) else @intCast(start_line - last_line);
        const delta_start: u32 = if (!have_last or start_line != last_line) @intCast(start_char) else @intCast(start_char - last_start);
        const length: u32 = @intCast(len_i64);

        const token_type: u32 = switch (t.kind) {
            .keyword => if (utils.keyword_is_datatype(t.text)) 7 else 0,
            .comment => 1,
            .string => 2,
            .number => 3,
            .boolean => 9,
            .operator, .symbol => 4,
            .identifier => blk: {
                const prev_non_comment: ?usize = blk_prev: {
                    var p = ti;
                    while (p > 0) {
                        p -= 1;
                        if (idx.tokens[p].kind != .comment) break :blk_prev p;
                    }
                    break :blk_prev null;
                };
                const next_non_comment: ?usize = blk_next: {
                    var n = ti + 1;
                    while (n < idx.tokens.len) : (n += 1) {
                        if (idx.tokens[n].kind != .comment) break :blk_next n;
                    }
                    break :blk_next null;
                };

                // Function declaration name: `fun name(...)` and `fun name<T>(...)`.
                if (prev_non_comment) |pi| {
                    const pt = idx.tokens[pi];
                    if (pt.kind == .keyword and std.mem.eql(u8, pt.text, "fun")) {
                        break :blk 5;
                    }
                }

                // Generic parameter slots: `<T>`, `<T, U>`.
                const looks_type_like_ident = t.text.len != 0 and std.ascii.isUpper(t.text[0]);

                // Type slots in impl clauses: `impl Type as Quirk`.
                if (looks_type_like_ident) {
                    if (prev_non_comment) |pi| {
                        const pt = idx.tokens[pi];
                        if (pt.kind == .keyword and std.mem.eql(u8, pt.text, "as")) {
                            break :blk 7;
                        }
                        if (pt.kind == .keyword and std.mem.eql(u8, pt.text, "impl")) {
                            if (next_non_comment) |ni| {
                                const nt = idx.tokens[ni];
                                if (nt.kind == .keyword and std.mem.eql(u8, nt.text, "as")) {
                                    break :blk 7;
                                }
                            }
                        }
                    }
                }

                const in_generic_parameter_list = blk_generic: {
                    if (!looks_type_like_ident) break :blk_generic false;

                    var depth: i64 = 0;
                    var p = ti;
                    while (p > 0) {
                        p -= 1;
                        const bt = idx.tokens[p];
                        if (bt.kind == .comment) continue;
                        if (!(bt.kind == .symbol or bt.kind == .operator)) continue;

                        if (std.mem.eql(u8, bt.text, ">")) {
                            depth += 1;
                            continue;
                        }
                        if (std.mem.eql(u8, bt.text, "<")) {
                            if (depth == 0) break :blk_generic true;
                            depth -= 1;
                            continue;
                        }

                        if (depth == 0 and
                            (std.mem.eql(u8, bt.text, "{") or
                                std.mem.eql(u8, bt.text, "}") or
                                std.mem.eql(u8, bt.text, "(") or
                                std.mem.eql(u8, bt.text, ")") or
                                std.mem.eql(u8, bt.text, ";") or
                                std.mem.eql(u8, bt.text, "=")))
                        {
                            break :blk_generic false;
                        }
                    }
                    break :blk_generic false;
                };
                if (in_generic_parameter_list) {
                    if (next_non_comment) |ni| {
                        const nt = idx.tokens[ni];
                        if ((nt.kind == .symbol or nt.kind == .operator) and
                            (std.mem.eql(u8, nt.text, ",") or std.mem.eql(u8, nt.text, ">")))
                        {
                            break :blk 7;
                        }
                    }
                }

                // Return type slot: `fun name(...) T {` and quirk signatures `name(...) T;`.
                if (prev_non_comment) |pi| {
                    const pt = idx.tokens[pi];
                    if ((pt.kind == .symbol or pt.kind == .operator) and std.mem.eql(u8, pt.text, ")")) {
                        var ri: usize = ti + 1;
                        while (ri < idx.tokens.len and idx.tokens[ri].kind == .comment) : (ri += 1) {}
                        while (ri < idx.tokens.len and (idx.tokens[ri].kind == .symbol or idx.tokens[ri].kind == .operator) and std.mem.eql(u8, idx.tokens[ri].text, "*")) : (ri += 1) {
                            while (ri < idx.tokens.len and idx.tokens[ri].kind == .comment) : (ri += 1) {}
                        }
                        if (ri < idx.tokens.len) {
                            const rt = idx.tokens[ri];
                            if ((rt.kind == .symbol or rt.kind == .operator) and
                                (std.mem.eql(u8, rt.text, "{") or std.mem.eql(u8, rt.text, ";")))
                            {
                                break :blk 7;
                            }
                        }
                    }
                }

                // Heuristic: treat `Type name;` / `Type name =` / `Type name,` as a type position,
                // even if the type name isn't in this document's symbol table.
                var j0: usize = ti + 1;
                while (j0 < idx.tokens.len and idx.tokens[j0].kind == .comment) : (j0 += 1) {}
                var decl_name_i_opt: ?usize = null;
                if (j0 < idx.tokens.len) {
                    var probe = j0;

                    // Support generic declarations like `Vec<num> v;`.
                    if ((idx.tokens[probe].kind == .symbol or idx.tokens[probe].kind == .operator) and std.mem.eql(u8, idx.tokens[probe].text, "<")) {
                        var depth: i64 = 0;
                        var p = probe;
                        while (p < idx.tokens.len) : (p += 1) {
                            const pt = idx.tokens[p];
                            if (pt.kind == .comment) continue;
                            if (!(pt.kind == .symbol or pt.kind == .operator)) continue;
                            if (std.mem.eql(u8, pt.text, "<")) {
                                depth += 1;
                            } else if (std.mem.eql(u8, pt.text, ">")) {
                                depth -= 1;
                                if (depth == 0) {
                                    probe = p + 1;
                                    break;
                                }
                            }
                        }
                        while (probe < idx.tokens.len and idx.tokens[probe].kind == .comment) : (probe += 1) {}
                    }

                    // Allow suffixes in declarations like `Type* name`, `Type[] name`, `Type[16] name`.
                    var scanning_suffix = true;
                    while (scanning_suffix and probe < idx.tokens.len) {
                        scanning_suffix = false;

                        while (probe < idx.tokens.len and (idx.tokens[probe].kind == .symbol or idx.tokens[probe].kind == .operator) and std.mem.eql(u8, idx.tokens[probe].text, "*")) : (probe += 1) {
                            while (probe < idx.tokens.len and idx.tokens[probe].kind == .comment) : (probe += 1) {}
                            scanning_suffix = true;
                        }

                        if (probe < idx.tokens.len and (idx.tokens[probe].kind == .symbol or idx.tokens[probe].kind == .operator) and std.mem.eql(u8, idx.tokens[probe].text, "[")) {
                            var depth: i64 = 0;
                            while (probe < idx.tokens.len) : (probe += 1) {
                                const at = idx.tokens[probe];
                                if (at.kind == .comment) continue;
                                if (!(at.kind == .symbol or at.kind == .operator)) continue;
                                if (std.mem.eql(u8, at.text, "[")) {
                                    depth += 1;
                                } else if (std.mem.eql(u8, at.text, "]")) {
                                    depth -= 1;
                                    if (depth == 0) {
                                        probe += 1;
                                        while (probe < idx.tokens.len and idx.tokens[probe].kind == .comment) : (probe += 1) {}
                                        break;
                                    }
                                }
                            }
                            scanning_suffix = true;
                        }
                    }

                    if (probe < idx.tokens.len and idx.tokens[probe].kind == .identifier) {
                        decl_name_i_opt = probe;
                    }
                }

                if (decl_name_i_opt) |decl_name_i| {
                    var k0: usize = decl_name_i + 1;
                    while (k0 < idx.tokens.len and idx.tokens[k0].kind == .comment) : (k0 += 1) {}
                    if (k0 < idx.tokens.len) {
                        const nt0 = idx.tokens[k0];
                        if ((nt0.kind == .symbol or nt0.kind == .operator) and
                            (std.mem.eql(u8, nt0.text, ";") or std.mem.eql(u8, nt0.text, "=") or std.mem.eql(u8, nt0.text, ",") or std.mem.eql(u8, nt0.text, ")")))
                        {
                            const type_by_symbol = classifyIdentifierTokenType(idx, t.text);
                            const type_by_shape = looks_type_like_ident or utils.get_c_typedef_alias_datatype_type(t.text) != null;
                            if (type_by_symbol == 7 or type_by_shape) {
                                break :blk 7; // type
                            }
                        }
                    }
                }

                // Prefer symbol-table classification.
                const by_symbol = classifyIdentifierTokenType(idx, t.text);
                if (by_symbol == 5 or by_symbol == 7 or by_symbol == 8) break :blk by_symbol;

                // Heuristic for call-sites: identifier followed by '(' => function.
                var j: usize = ti + 1;
                while (j < idx.tokens.len and idx.tokens[j].kind == .comment) : (j += 1) {}
                if (j < idx.tokens.len) {
                    const nt = idx.tokens[j];
                    if ((nt.kind == .symbol or nt.kind == .operator) and std.mem.eql(u8, nt.text, "(")) {
                        break :blk 5;
                    }
                }

                break :blk by_symbol;
            },
        };
        const default_library_modifier: u32 = 1 << 0;
        const modifiers: u32 = if (token_type == 7 and isDefaultLibraryTypeName(t.text))
            default_library_modifier
        else
            0;

        try data.appendSlice(&[_]u32{ delta_line, delta_start, length, token_type, modifiers });
        last_line = start_line;
        last_start = start_char;
        have_last = true;
    }

    return data.toOwnedSlice();
}
test "fls index: locals are indexed inside fun bodies" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        "compound Point {\n" ++
        "  num x;\n" ++
        "  num y;\n" ++
        "}\n\n" ++
        "impl Point {\n" ++
        "  translate(num dx, num dy) {\n" ++
        "    self.x += dx;\n" ++
        "    self.y += dy;\n" ++
        "  }\n" ++
        "}\n\n" ++
        "fun main() {\n" ++
        "  Point p;\n" ++
        "  p.x = 1;\n" ++
        "}\n";

    const idx = try buildIndexFromText(allocator, text);
    defer idx.deinit();

    var found_p = false;
    for (idx.symbols) |s| {
        if (s.kind == .variable and std.mem.eql(u8, s.name, "p")) {
            found_p = true;
            break;
        }
    }
    try std.testing.expect(found_p);
}

test "fls index: generic locals are indexed" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        "imp std.vec;\n\n" ++
        "fun main() {\n" ++
        "  Vec<num> nums;\n" ++
        "  nums.clear();\n" ++
        "}\n";

    const idx = try buildIndexFromText(allocator, text);
    defer idx.deinit();

    var found = false;
    for (idx.symbols) |s| {
        if (s.kind != .variable) continue;
        if (!std.mem.eql(u8, s.name, "nums")) continue;
        found = true;
        if (s.value_type) |vt| {
            try std.testing.expect(std.mem.startsWith(u8, vt, "Vec"));
        }
        break;
    }
    try std.testing.expect(found);
}

test "fls index: let locals infer types" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        "fun main() {\n" ++
        "  let x = 1;\n" ++
        "  let s = \"hi\";\n" ++
        "  x = x + 1;\n" ++
        "}\n";

    const idx = try buildIndexFromText(allocator, text);
    defer idx.deinit();

    var found_x = false;
    var found_s = false;

    for (idx.symbols) |s| {
        if (s.kind != .variable) continue;
        if (std.mem.eql(u8, s.name, "x")) {
            found_x = true;
            try std.testing.expect(s.value_type != null);
            try std.testing.expect(std.mem.eql(u8, s.value_type.?, "num"));
        }
        if (std.mem.eql(u8, s.name, "s")) {
            found_s = true;
            try std.testing.expect(s.value_type != null);
            try std.testing.expect(std.mem.eql(u8, s.value_type.?, "str"));
        }
    }

    try std.testing.expect(found_x);
    try std.testing.expect(found_s);
}

test "fls index: let locals inferred in token-only index" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Missing closing brace forces parser failure; token indexing should still pick up let types.
    const text =
        "fun main() {\n" ++
        "  let x = 1;\n" ++
        "  let s = \"hi\";\n";

    const idx = try buildIndexFromText(allocator, text);
    defer idx.deinit();

    var found_x = false;
    var found_s = false;

    for (idx.symbols) |s| {
        if (s.kind != .variable) continue;
        if (std.mem.eql(u8, s.name, "x")) {
            found_x = true;
            try std.testing.expect(s.value_type != null);
            try std.testing.expect(std.mem.eql(u8, s.value_type.?, "num"));
        }
        if (std.mem.eql(u8, s.name, "s")) {
            found_s = true;
            try std.testing.expect(s.value_type != null);
            try std.testing.expect(std.mem.eql(u8, s.value_type.?, "str"));
        }
    }

    try std.testing.expect(found_x);
    try std.testing.expect(found_s);
}

test "fls index: let uses prior let in expression" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        "fun main() {\n" ++
        "  let a = 1;\n" ++
        "  let b = a + 2;\n" ++
        "}\n";

    const idx = try buildIndexFromText(allocator, text);
    defer idx.deinit();

    var found_b = false;
    for (idx.symbols) |s| {
        if (s.kind != .variable) continue;
        if (!std.mem.eql(u8, s.name, "b")) continue;
        found_b = true;
        try std.testing.expect(s.value_type != null);
        try std.testing.expect(std.mem.eql(u8, s.value_type.?, "num"));
    }
    try std.testing.expect(found_b);
}

test "fls index: let from member access" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        "compound User {\n" ++
        "  num age;\n" ++
        "}\n" ++
        "fun main() {\n" ++
        "  User u;\n" ++
        "  let a = u.age;\n" ++
        "}\n";

    const idx = try buildIndexFromText(allocator, text);
    defer idx.deinit();

    var found_a = false;
    for (idx.symbols) |s| {
        if (s.kind != .variable) continue;
        if (!std.mem.eql(u8, s.name, "a")) continue;
        found_a = true;
        try std.testing.expect(s.value_type != null);
        try std.testing.expect(std.mem.eql(u8, s.value_type.?, "num"));
    }
    try std.testing.expect(found_a);
}

test "fls index: generic function signature includes params" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        "fun id<T>(T x) T { ret x; }\n" ++
        "fun main() { num v = id(1); }\n";

    const idx = try buildIndexFromText(allocator, text);
    defer idx.deinit();

    var found = false;
    for (idx.symbols) |s| {
        if (s.kind != .function) continue;
        if (!std.mem.eql(u8, s.name, "id")) continue;
        found = true;
        try std.testing.expect(s.detail != null);
        try std.testing.expect(std.mem.indexOf(u8, s.detail.?, "id<T>") != null);
        break;
    }
    try std.testing.expect(found);
}

test "fls index: variadic function signature includes ellipsis" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        "fun log(str fmt, ...) num { ret 0; }\n";

    const idx = try buildIndexFromText(allocator, text);
    defer idx.deinit();

    var found = false;
    for (idx.symbols) |s| {
        if (s.kind != .function) continue;
        if (!std.mem.eql(u8, s.name, "log")) continue;
        found = true;
        try std.testing.expect(s.detail != null);
        try std.testing.expect(std.mem.indexOf(u8, s.detail.?, "(str fmt, ...)") != null);
        break;
    }
    try std.testing.expect(found);
}

test "fls index: impl methods include self, params, locals" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        "compound Point {\n" ++
        "  num x;\n" ++
        "}\n\n" ++
        "impl Point {\n" ++
        "  translate(num dx, num dy) {\n" ++
        "    num tmp = 1;\n" ++
        "    self.x += dx;\n" ++
        "  }\n" ++
        "}\n";

    const idx = try buildIndexFromText(allocator, text);
    defer idx.deinit();

    var found_self = false;
    var found_dx = false;
    var found_dy = false;
    var found_tmp = false;

    for (idx.symbols) |s| {
        if (s.kind != .variable) continue;
        if (s.container_fn_range == null) continue;
        if (std.mem.eql(u8, s.name, "self")) found_self = true;
        if (std.mem.eql(u8, s.name, "dx")) found_dx = true;
        if (std.mem.eql(u8, s.name, "dy")) found_dy = true;
        if (std.mem.eql(u8, s.name, "tmp")) found_tmp = true;
    }

    try std.testing.expect(found_self);
    try std.testing.expect(found_dx);
    try std.testing.expect(found_dy);
    try std.testing.expect(found_tmp);
}

test "fls hover: signatures include custom return types" {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const text =
        "compound User {\n" ++
        "  num age;\n" ++
        "}\n\n" ++
        "fun make_user() User* {\n" ++
        "  User u;\n" ++
        "  ret &u;\n" ++
        "}\n";

    const idx = try buildIndexFromText(allocator, text);
    defer idx.deinit();

    var found: bool = false;
    for (idx.symbols) |s| {
        if (s.kind != .function) continue;
        if (!std.mem.eql(u8, s.name, "make_user")) continue;
        try std.testing.expect(s.detail != null);
        const det = s.detail.?;
        const rparen = std.mem.lastIndexOfScalar(u8, det, ')') orelse 0;
        try std.testing.expect(std.mem.indexOf(u8, det[rparen..], "User") != null);
        found = true;
    }
    try std.testing.expect(found);
}
