const std = @import("std");
const builtin = @import("builtin");

// Set an environment variable in THIS process so EVERY child compiler subprocess
// (diagnostics, etc.) inherits a deterministic `FUN_STDLIB_DIR` instead of relying
// on its own best-effort discovery. Cross-platform: POSIX libc has `setenv`, but the
// Windows CRT does not export it (lld-link: "undefined symbol: setenv") — the MSVCRT
// equivalent is `_putenv_s(name, value)`, which always overwrites. Best-effort; the
// caller ignores failure. Returns 0 on success to mirror both CRT functions.
const setEnvVar = if (builtin.os.tag == .windows) struct {
    extern "c" fn _putenv_s(name: [*:0]const u8, value: [*:0]const u8) c_int;
    fn call(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int {
        _ = overwrite; // _putenv_s always overwrites
        return _putenv_s(name, value);
    }
}.call else struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    fn call(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int {
        return setenv(name, value, overwrite);
    }
}.call;
const ast = @import("ast");
const codegen = @import("codegen");
const parser = @import("parser");
const lexer = @import("lexer");
const utils = @import("utils");
const cli = @import("cli");
const token = lexer.token;

const globals = @import("globals.zig");
const types = @import("types.zig");
const protocol_mod = @import("protocol.zig");
const uri_utils = @import("uri.zig");
const diag_utils = @import("diagnostics.zig");
const positions_mod = @import("positions.zig");
const token_idx = @import("token_index.zig");
const ast_idx = @import("ast_index.zig");
const index_mod = @import("index.zig");

fn ArrayList(comptime T: type) type {
    return std.array_list.Managed(T);
}

const Allocator = std.mem.Allocator;

// --- Globals ---
const globalIo = globals.globalIo;
const nowMs = globals.nowMs;
const fileReadAlloc = globals.fileReadAlloc;

// --- Types ---
const Doc = types.Doc;
const Position = types.Position;
const Range = types.Range;
const Diagnostic = types.Diagnostic;
const DiagnosticWithUri = types.DiagnosticWithUri;
const TextEdit = types.TextEdit;
const CompletionItem = types.CompletionItem;
const CompletionList = types.CompletionList;
const MarkupContent = types.MarkupContent;
const Hover = types.Hover;
const InlayHint = types.InlayHint;
const Location = types.Location;
const SymbolInformation = types.SymbolInformation;
const DocumentSymbol = types.DocumentSymbol;
const ParameterInformation = types.ParameterInformation;
const SignatureInformation = types.SignatureInformation;
const SignatureHelp = types.SignatureHelp;
const SemanticTokens = types.SemanticTokens;
const TokenLiteKind = types.TokenLiteKind;
const TokenLite = types.TokenLite;
const SymbolKind = types.SymbolKind;
const SymbolLite = types.SymbolLite;
const Index = types.Index;

// --- Protocol ---
const stringifyId = protocol_mod.stringifyId;
const jsonStringifyAlloc = protocol_mod.jsonStringifyAlloc;
const writeLspMessageRaw = protocol_mod.writeLspMessageRaw;
const readLspMessage = protocol_mod.readLspMessage;
const writeJsonString = protocol_mod.writeJsonString;
const writeRangeJson = protocol_mod.writeRangeJson;

// --- URI utilities ---
const findSiblingOrPathExe = uri_utils.findSiblingOrPathExe;
const findOnPath = uri_utils.findOnPath;
const pathToUri = uri_utils.pathToUri;
const uriToPath = uri_utils.uriToPath;

// --- Diagnostics ---
const runCaptureStderr = diag_utils.runCaptureStderr;
const parseFunDiagnosticsByUri = diag_utils.parseFunDiagnosticsByUri;
const tryApplyRangedEdit = diag_utils.tryApplyRangedEdit;
const isMissingAwaitDiagnosticCode = diag_utils.isMissingAwaitDiagnosticCode;
const isAwaitOutsideAsyncDiagnosticCode = diag_utils.isAwaitOutsideAsyncDiagnosticCode;
const isMissingAwaitDiagnosticMessage = diag_utils.isMissingAwaitDiagnosticMessage;
const isAwaitOutsideAsyncDiagnosticMessage = diag_utils.isAwaitOutsideAsyncDiagnosticMessage;

// --- Position / range utilities ---
const posInRange = positions_mod.posInRange;
const findTokenAt = positions_mod.findTokenAt;
const findTokenIndexAt = positions_mod.findTokenIndexAt;
const isDotToken = positions_mod.isDotToken;
const isOpenParen = positions_mod.isOpenParen;
const callParenIsDeclaration = positions_mod.callParenIsDeclaration;
const isCloseParen = positions_mod.isCloseParen;
const isOpenBracket = positions_mod.isOpenBracket;
const isCloseBracket = positions_mod.isCloseBracket;
const isCommaToken = positions_mod.isCommaToken;
const isOpenBrace = positions_mod.isOpenBrace;
const isCloseBrace = positions_mod.isCloseBrace;
const findBlockBraceRange = positions_mod.findBlockBraceRange;
const paramNameFromLabel = positions_mod.paramNameFromLabel;
const nextNonTrivialTokenLite = positions_mod.nextNonTrivialTokenLite;
const prevNonTrivialTokenLite = positions_mod.prevNonTrivialTokenLite;
const findMatchingLParenLite = positions_mod.findMatchingLParenLite;
const skipGenericArgsLite = positions_mod.skipGenericArgsLite;
const concreteGenericTypeAtToken = positions_mod.concreteGenericTypeAtToken;
const concreteGenericTypeSliceAtPosition = positions_mod.concreteGenericTypeSliceAtPosition;
const findLastTokenIndexBeforeOrAt = positions_mod.findLastTokenIndexBeforeOrAt;
const rangeFromTokenPos = positions_mod.rangeFromTokenPos;
const rangeStartLessOrEqual = positions_mod.rangeStartLessOrEqual;
const rangeStartGreater = positions_mod.rangeStartGreater;
const rangeStartEqual = positions_mod.rangeStartEqual;
const rangeEqual = positions_mod.rangeEqual;
const findEnclosingFunctionAsyncInsertPosFromTokens = positions_mod.findEnclosingFunctionAsyncInsertPosFromTokens;
const isBuiltinTypeName = positions_mod.isBuiltinTypeName;
const isLetInferTypeName = positions_mod.isLetInferTypeName;
const collectTypeNamesFromTypeString = positions_mod.collectTypeNamesFromTypeString;
const collectReturnAndParamTypeNames = positions_mod.collectReturnAndParamTypeNames;
const buildCallSnippet = positions_mod.buildCallSnippet;
const preferDetailedSymbol = positions_mod.preferDetailedSymbol;
const hasNonBuiltinValueType = positions_mod.hasNonBuiltinValueType;
const numericBuiltinRank = positions_mod.numericBuiltinRank;
const findBestDefinition = positions_mod.findBestDefinition;
const findAnyGlobalDefinition = positions_mod.findAnyGlobalDefinition;
const byteIndexForPosition = positions_mod.byteIndexForPosition;
const normalizePositionToByteColumns = positions_mod.normalizePositionToByteColumns;
const guessIdentifierPrefix = positions_mod.guessIdentifierPrefix;
const guessTypeFromTextFallback = positions_mod.guessTypeFromTextFallback;
const guessReceiverNameBeforeCursor = positions_mod.guessReceiverNameBeforeCursor;
const guessReceiverNameAtCursor = positions_mod.guessReceiverNameAtCursor;
const ReceiverGuess = positions_mod.ReceiverGuess;
const guessReceiverAtCursorWithIndex = positions_mod.guessReceiverAtCursorWithIndex;
const isReceiverStopKeyword = positions_mod.isReceiverStopKeyword;

// --- Token analysis ---
const appendDocCommentAboveLine = token_idx.appendDocCommentAboveLine;
const isArrayTypeName = token_idx.isArrayTypeName;

// --- AST analysis ---
const makeGenericTypeInsertText = ast_idx.makeGenericTypeInsertText;

// --- Index building ---
const buildIndexFromText = index_mod.buildIndexFromText;
const buildIndexFromTextAt = index_mod.buildIndexFromTextAt;
const buildSemanticTokens = index_mod.buildSemanticTokens;
const getOrInitFlsTempDirCached = index_mod.getOrInitFlsTempDirCached;
const IndexBuildScope = index_mod.IndexBuildScope;
const GuessedCallSignature = index_mod.GuessedCallSignature;

fn isLitePunct(t: TokenLite, ch: u8) bool {
    return (t.kind == .symbol or t.kind == .operator) and t.text.len == 1 and t.text[0] == ch;
}

/// A token that closes a chainable receiver expression — `)` (call result) or
/// `]` (index result). A `.` following one of these is a member access on that
/// result, never a bare `.Variant` enum dot-shorthand.
fn isChainCloserLite(t: TokenLite) bool {
    return isLitePunct(t, ')') or isLitePunct(t, ']');
}

/// If `sym` is a data-carrying enum variant whose `detail` holds the payload
/// signature (`Enum.Variant(types)`), return that signature. Returns null when
/// `sym` is not an enum member, has no detail, or its detail is a trailing doc
/// comment rather than a sig (a sig always begins with `enum_name.`).
fn enumVariantSigFromDetail(sym: SymbolLite, enum_name: []const u8) ?[]const u8 {
    if (sym.kind != .enumMember) return null;
    const det = sym.detail orelse return null;
    // Match against the container's base name and the fully-qualified enum name
    // (a shorthand hover may pass either the declared or a specialized name).
    const base = LspServer.baseTypeNameForLookup(enum_name);
    const container = if (sym.container_type) |ct| ct else enum_name;
    const container_base = LspServer.baseTypeNameForLookup(container);
    if (std.mem.startsWith(u8, det, base) and det.len > base.len and det[base.len] == '.') return det;
    if (std.mem.startsWith(u8, det, container_base) and det.len > container_base.len and det[container_base.len] == '.') return det;
    return null;
}

fn fieldNameIndexAfterTypeLite(tokens: []const TokenLite, type_i: usize) ?usize {
    var field_name_i = nextNonTrivialTokenLite(tokens, type_i + 1) orelse return null;

    if (field_name_i < tokens.len and isLitePunct(tokens[field_name_i], '<')) {
        field_name_i = skipGenericArgsLite(tokens, field_name_i);
    }

    while (field_name_i < tokens.len and isLitePunct(tokens[field_name_i], '[')) {
        const rbr_i = nextNonTrivialTokenLite(tokens, field_name_i + 1) orelse return null;
        if (!isLitePunct(tokens[rbr_i], ']')) break;
        field_name_i = nextNonTrivialTokenLite(tokens, rbr_i + 1) orelse return null;
    }

    while (field_name_i < tokens.len and (isLitePunct(tokens[field_name_i], '*') or isLitePunct(tokens[field_name_i], '&'))) {
        field_name_i = nextNonTrivialTokenLite(tokens, field_name_i + 1) orelse return null;
    }

    return field_name_i;
}

fn buildFieldTypeTextFromTokensLite(allocator: Allocator, tokens: []const TokenLite, type_i: usize) ?[]u8 {
    if (type_i >= tokens.len) return null;

    var buf = ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    buf.appendSlice(tokens[type_i].text) catch return null;

    var cursor = nextNonTrivialTokenLite(tokens, type_i + 1) orelse return buf.toOwnedSlice() catch null;

    if (cursor < tokens.len and isLitePunct(tokens[cursor], '<')) {
        var generic_depth: i64 = 0;
        while (cursor < tokens.len) : (cursor += 1) {
            const t = tokens[cursor];
            if (t.kind == .comment) continue;

            if (isLitePunct(t, '<')) {
                generic_depth += 1;
                buf.append('<') catch return null;
                continue;
            }

            if (isLitePunct(t, '>')) {
                generic_depth -= 1;
                buf.append('>') catch return null;
                if (generic_depth == 0) {
                    cursor = nextNonTrivialTokenLite(tokens, cursor + 1) orelse tokens.len;
                    break;
                }
                continue;
            }

            if (generic_depth <= 0) break;

            if (isLitePunct(t, ',')) {
                buf.appendSlice(", ") catch return null;
                continue;
            }

            buf.appendSlice(t.text) catch return null;
        }
    }

    while (cursor < tokens.len and isLitePunct(tokens[cursor], '[')) {
        const rbr_i = nextNonTrivialTokenLite(tokens, cursor + 1) orelse break;
        if (!isLitePunct(tokens[rbr_i], ']')) break;
        buf.appendSlice("[]") catch return null;
        cursor = nextNonTrivialTokenLite(tokens, rbr_i + 1) orelse tokens.len;
    }

    while (cursor < tokens.len and (isLitePunct(tokens[cursor], '*') or isLitePunct(tokens[cursor], '&'))) {
        buf.appendSlice(tokens[cursor].text) catch return null;
        cursor = nextNonTrivialTokenLite(tokens, cursor + 1) orelse tokens.len;
    }

    return buf.toOwnedSlice() catch null;
}

fn findFieldTypeFromCurrentDocTokens(idx: *const Index, container_type: []const u8, field_name: []const u8) ?[]u8 {
    const localBaseTypeName = struct {
        fn call(name: []const u8) []const u8 {
            var base = if (std.mem.indexOfScalar(u8, name, '<')) |idx_lt| name[0..idx_lt] else name;
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
            return base;
        }
    }.call;

    const isIdentLite = struct {
        fn call(t: TokenLite) bool {
            return t.kind == .identifier;
        }
    }.call;

    const isTypeLike = struct {
        fn call(t: TokenLite) bool {
            if (t.kind == .identifier) return true;
            if (t.kind != .keyword) return false;
            const s = t.text;
            return std.mem.eql(u8, s, "num") or std.mem.eql(u8, s, "dec") or std.mem.eql(u8, s, "str") or std.mem.eql(u8, s, "bin") or std.mem.eql(u8, s, "chr") or std.mem.eql(u8, s, "raw") or std.mem.eql(u8, s, "void") or std.mem.eql(u8, s, "f32") or std.mem.eql(u8, s, "f64") or std.mem.eql(u8, s, "i8") or std.mem.eql(u8, s, "i16") or std.mem.eql(u8, s, "i32") or std.mem.eql(u8, s, "i64") or std.mem.eql(u8, s, "u8") or std.mem.eql(u8, s, "u16") or std.mem.eql(u8, s, "u32") or std.mem.eql(u8, s, "u64");
        }
    }.call;

    const target_type = localBaseTypeName(container_type);
    const arena_alloc = @constCast(&idx.arena).allocator();

    var i: usize = 0;
    while (i < idx.tokens.len) : (i += 1) {
        if (idx.tokens[i].kind != .keyword or !std.mem.eql(u8, idx.tokens[i].text, "compound")) continue;

        const name_i = nextNonTrivialTokenLite(idx.tokens, i + 1) orelse continue;
        if (!isIdentLite(idx.tokens[name_i])) continue;
        if (!std.mem.eql(u8, localBaseTypeName(idx.tokens[name_i].text), target_type)) continue;

        var j_opt = nextNonTrivialTokenLite(idx.tokens, name_i + 1);
        while (j_opt) |j| {
            if (!isLitePunct(idx.tokens[j], '{')) {
                j_opt = nextNonTrivialTokenLite(idx.tokens, j + 1);
                continue;
            }

            var depth: i64 = 1;
            var k: usize = j + 1;
            while (k < idx.tokens.len and depth > 0) : (k += 1) {
                const tk = idx.tokens[k];
                if (isLitePunct(tk, '{')) depth += 1;
                if (isLitePunct(tk, '}')) depth -= 1;
                if (depth != 1) continue;
                if (!isTypeLike(tk)) continue;

                const field_name_i = fieldNameIndexAfterTypeLite(idx.tokens, k) orelse continue;
                if (!isIdentLite(idx.tokens[field_name_i])) continue;
                if (!std.mem.eql(u8, idx.tokens[field_name_i].text, field_name)) continue;

                const after_name_i = nextNonTrivialTokenLite(idx.tokens, field_name_i + 1) orelse continue;
                if (!isLitePunct(idx.tokens[after_name_i], ';')) continue;

                return buildFieldTypeTextFromTokensLite(arena_alloc, idx.tokens, k);
            }

            break;
        }
    }

    return null;
}

/// Cached result of a single diagnostic subprocess run.
/// Keyed in `LspServer.diag_cache` by the URI of the file that was compiled.
/// Cached result of a single diagnostic subprocess run.
/// Keyed in `LspServer.diag_cache` by the URI of the file that was compiled.
const DiagCacheEntry = struct {
    /// Wyhash of the raw editor text that was compiled.
    content_hash: u64,
    /// Wyhash of the *formatted* text produced by the last compile run.
    /// Zero when this entry was created by `computeDiagnostics` (which does not format).
    /// Used so that `computeDiagnostics` can hit the cache when called with already-formatted
    /// text (the common format-on-save flow sends `didChange` with the formatted text and
    /// then immediately fires `didSave`).
    formatted_hash: u64,
    /// Parsed diagnostics from the last compile run.  Owned by the server allocator.
    diags: []DiagnosticWithUri,
    /// The formatted source text produced by the last compile run.
    /// Null when the cache was populated from a plain `computeDiagnostics` call
    /// (which does not format the source).  Owned by the server allocator.
    formatted: ?[]u8,
};

/// Deep-copy a slice of `DiagnosticWithUri`.  The returned slice is owned by the caller.
fn dupeDiags(allocator: Allocator, src: []const DiagnosticWithUri) ![]DiagnosticWithUri {
    const out = try allocator.alloc(DiagnosticWithUri, src.len);
    var i: usize = 0;
    errdefer {
        for (out[0..i]) |d| {
            allocator.free(d.uri);
            allocator.free(d.diag.message);
            if (d.diag.code) |c| allocator.free(c);
        }
        allocator.free(out);
    }
    while (i < src.len) : (i += 1) {
        const s = src[i];
        out[i] = .{
            .uri = try allocator.dupe(u8, s.uri),
            .diag = .{
                .range = s.diag.range,
                .severity = s.diag.severity,
                .message = try allocator.dupe(u8, s.diag.message),
                .code = if (s.diag.code) |c| try allocator.dupe(u8, c) else null,
            },
        };
    }
    return out;
}

/// Free a slice of `DiagnosticWithUri` and all its string fields.
fn freeDiags(allocator: Allocator, diags: []const DiagnosticWithUri) void {
    for (diags) |d| {
        allocator.free(d.uri);
        allocator.free(d.diag.message);
        if (d.diag.code) |c| allocator.free(c);
    }
    allocator.free(diags);
}

pub const LspServer = struct {
    allocator: Allocator,
    docs: std.StringHashMap(Doc),
    io: std.Io,
    stdin: std.Io.File,
    stdout: std.Io.File,
    fun_exe_path: []const u8,
    fls_exe_path: ?[:0]u8 = null,
    published_diag_uris: std.StringHashMap(void),
    root_uri: ?[]u8 = null,
    root_path: ?[]u8 = null,
    stdlib_root_path: ?[]u8 = null,
    debug_enabled: bool = false,
    debug_imports: bool = false,
    debug_definitions: bool = false,
    did_log_stdlib_root_resolution: bool = false,
    /// Recursion guard for the query-time type engine: `guessVariableType` may
    /// re-infer a binding's initializer expression, which can recurse back into
    /// `guessVariableType` (e.g. `let b = a.f()` where `a` is itself inferred). Bound
    /// the depth so a cyclic/self-referential chain can't blow the stack.
    type_infer_depth: u32 = 0,

    /// Per-URI diagnostic result cache.  Keyed by URI string (owned by map).
    /// Each entry stores the Wyhash of the formatted source text and the raw
    /// stderr bytes that the last compiler run produced.  When the same
    /// formatted text is seen again, we skip the subprocess entirely.
    diag_cache: std.StringHashMap(DiagCacheEntry),

    fn envFlag(name: [:0]const u8) bool {
        const z = std.c.getenv(name) orelse return false;
        const v = std.mem.sliceTo(z, 0);
        const s = std.mem.trim(u8, v, " \t\r\n");
        if (s.len == 0) return false;
        if (std.ascii.eqlIgnoreCase(s, "0")) return false;
        if (std.ascii.eqlIgnoreCase(s, "false")) return false;
        if (std.ascii.eqlIgnoreCase(s, "no")) return false;
        if (std.ascii.eqlIgnoreCase(s, "off")) return false;
        return true;
    }

    fn dbg(self: *const LspServer, enabled: bool, comptime category: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (!enabled) return;
        var buf: [2048]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[fls:" ++ category ++ "] " ++ fmt ++ "\n", args) catch return;
        std.Io.File.stderr().writeStreamingAll(self.io, msg) catch {};
    }

    fn log(self: *const LspServer, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        std.Io.File.stderr().writeStreamingAll(self.io, msg) catch {};
    }

    pub fn init(allocator: Allocator, io: std.Io) !LspServer {
        const dbg_all = envFlag("FLS_DEBUG");
        const dbg_imports = dbg_all or envFlag("FLS_DEBUG_IMPORTS");
        const dbg_defs = dbg_all or envFlag("FLS_DEBUG_DEFINITIONS");
        globals.g_runtime_io = io;
        return .{
            .allocator = allocator,
            .io = io,
            .docs = std.StringHashMap(Doc).init(allocator),
            .stdin = std.Io.File.stdin(),
            .stdout = std.Io.File.stdout(),
            .fun_exe_path = try findSiblingOrPathExe(allocator, io, "fun"),
            .fls_exe_path = std.process.executablePathAlloc(io, allocator) catch null,
            .published_diag_uris = std.StringHashMap(void).init(allocator),
            .diag_cache = std.StringHashMap(DiagCacheEntry).init(allocator),
            .root_uri = null,
            .root_path = null,
            .stdlib_root_path = null,
            .debug_enabled = dbg_all or dbg_imports or dbg_defs,
            .debug_imports = dbg_imports,
            .debug_definitions = dbg_defs,
            .did_log_stdlib_root_resolution = false,
        };
    }

    pub fn deinit(self: *LspServer) void {
        var it = self.docs.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.uri);
            self.allocator.free(entry.value_ptr.text);
            if (entry.value_ptr.index) |idx| idx.deinit();
        }
        self.docs.deinit();
        var dit = self.published_diag_uris.iterator();
        while (dit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.published_diag_uris.deinit();
        var cit = self.diag_cache.iterator();
        while (cit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeDiags(self.allocator, entry.value_ptr.diags);
            if (entry.value_ptr.formatted) |f| self.allocator.free(f);
        }
        self.diag_cache.deinit();
        self.allocator.free(self.fun_exe_path);
        if (self.fls_exe_path) |p| self.allocator.free(p);
        if (self.root_uri) |u| self.allocator.free(u);
        if (self.root_path) |p| self.allocator.free(p);
        if (self.stdlib_root_path) |p| self.allocator.free(p);
    }

    fn getStdlibRootPath(self: *LspServer) ?[]const u8 {
        if (self.stdlib_root_path) |p| return p;

        if (self.debug_imports and !self.did_log_stdlib_root_resolution) {
            self.did_log_stdlib_root_resolution = true;
            self.dbg(true, "imports", "resolving stdlib root (env/exe/workspace/cwd)", .{});
            if (self.root_path) |rp| self.dbg(true, "imports", "root_path={s}", .{rp});
            self.dbg(true, "imports", "fun_exe_path={s}", .{self.fun_exe_path});
            if (self.fls_exe_path) |fp| self.dbg(true, "imports", "fls_exe_path={s}", .{fp});
        }

        // Prefer repo/workspace checkout layout when available.
        // This keeps fls working correctly when developing in a fun checkout even if
        // the machine also has a global install (or FUN_STDLIB_DIR) configured.
        if (self.tryStdlibRootFromWorkspace()) {
            if (self.debug_imports) self.dbg(true, "imports", "stdlib root from workspace => {s}", .{self.stdlib_root_path.?});
            return self.stdlib_root_path.?;
        }

        // Optional override for custom installs.
        if (self.tryStdlibRootFromEnv("FUN_STDLIB_DIR")) {
            if (self.debug_imports) self.dbg(true, "imports", "stdlib root from FUN_STDLIB_DIR => {s}", .{self.stdlib_root_path.?});
            return self.stdlib_root_path.?;
        }

        // Prefer installed layout next to the running binaries (matches transpiler behavior).
        if (self.fls_exe_path) |p| {
            if (self.tryStdlibRootFromExe(p)) return self.stdlib_root_path.?;
            if (self.tryStdlibRootFromExeDirWalk(p)) return self.stdlib_root_path.?;
        }
        if (self.tryStdlibRootFromExe(self.fun_exe_path)) return self.stdlib_root_path.?;
        if (self.tryStdlibRootFromExeDirWalk(self.fun_exe_path)) return self.stdlib_root_path.?;

        // Repo/workspace checkout layout (fallback).
        if (self.tryStdlibRootFromWorkspace()) {
            if (self.debug_imports) self.dbg(true, "imports", "stdlib root from workspace => {s}", .{self.stdlib_root_path.?});
            return self.stdlib_root_path.?;
        }

        // Final fallback: try resolving relative to the server's current working directory.
        // VS Code launches `fls` with `cwd` set to the workspace root, but some clients/flows
        // don't provide a usable `rootUri` or the document may be `untitled:`.
        if (self.trySetStdlibRoot("stdlib")) {
            if (self.debug_imports) self.dbg(true, "imports", "stdlib root from cwd relative 'stdlib' => {s}", .{self.stdlib_root_path.?});
            return self.stdlib_root_path.?;
        }
        if (self.trySetStdlibRoot("zig-out/share/fun/stdlib")) {
            if (self.debug_imports) self.dbg(true, "imports", "stdlib root from cwd relative 'zig-out/share/fun/stdlib' => {s}", .{self.stdlib_root_path.?});
            return self.stdlib_root_path.?;
        }

        return null;
    }

    fn tryStdlibRootFromExeDirWalk(self: *LspServer, exe_path: []const u8) bool {
        // Repo/worktree layout when running from zig-out/bin:
        // <repo>/zig-out/bin/fls(.exe)
        // <repo>/stdlib/std/...
        // Walk up a few levels looking for a sibling `stdlib/`.
        var dir_opt: ?[]const u8 = std.fs.path.dirname(exe_path);
        var depth: usize = 0;
        while (dir_opt) |dir| : (depth += 1) {
            if (depth > 10) break;

            const cand = std.fs.path.join(self.allocator, &.{ dir, "stdlib" }) catch break;
            const ok = self.trySetStdlibRoot(cand);
            self.allocator.free(cand);
            if (ok) return true;

            dir_opt = std.fs.path.dirname(dir);
        }
        return false;
    }

    fn isStdlibRootAbsolute(path_abs: []const u8) bool {
        if (!std.fs.path.isAbsolute(path_abs)) return false;

        // Expect: <path>/std/...
        const std_dir = std.fs.path.join(std.heap.page_allocator, &.{ path_abs, "std" }) catch return false;
        defer std.heap.page_allocator.free(std_dir);

        // Defensive: `openDirAbsolute` asserts that its input is absolute on this OS.
        if (!std.fs.path.isAbsolute(std_dir)) return false;

        var d = std.Io.Dir.openDirAbsolute(globalIo(), std_dir, .{}) catch return false;
        d.close(globalIo());
        return true;
    }

    fn checkStdlibRootAbsolute(self: *LspServer, root_abs: []const u8) bool {
        if (!std.fs.path.isAbsolute(root_abs)) return false;

        const std_dir = std.fs.path.join(std.heap.page_allocator, &.{ root_abs, "std" }) catch return false;
        defer std.heap.page_allocator.free(std_dir);

        if (!std.fs.path.isAbsolute(std_dir)) return false;
        var d = std.Io.Dir.openDirAbsolute(globalIo(), std_dir, .{}) catch |err| {
            if (self.debug_imports) self.dbg(true, "imports", "stdlib root check failed: root={s} std_dir={s} err={s}", .{ root_abs, std_dir, @errorName(err) });
            return false;
        };
        d.close(globalIo());
        return true;
    }

    fn trySetStdlibRoot(self: *LspServer, path: []const u8) bool {
        if (self.debug_imports) self.dbg(true, "imports", "trySetStdlibRoot candidate={s}", .{path});
        // Ensure we store an absolute path and never pass a non-absolute string to
        // `openDirAbsolute` (which asserts in Zig stdlib).
        var abs = if (std.fs.path.isAbsolute(path))
            (self.allocator.dupe(u8, path) catch return false)
        else
            (std.Io.Dir.cwd().realPathFileAlloc(globalIo(), path, self.allocator) catch return false);

        // Normalize/derive: accept a variety of installed layouts.
        // We ultimately store `<root>` such that `<root>/std/...` exists.
        if (!self.checkStdlibRootAbsolute(abs)) {
            const base = std.fs.path.basename(abs);

            // Common: caller points at `<root>/std`.
            if (std.ascii.eqlIgnoreCase(base, "std")) {
                const parent = std.fs.path.dirname(abs) orelse null;
                if (parent) |p| {
                    if (self.checkStdlibRootAbsolute(p)) {
                        if (self.debug_imports) self.dbg(true, "imports", "normalized stdlib root from .../std => {s}", .{p});
                        self.allocator.free(abs);
                        abs = self.allocator.dupe(u8, p) catch return false;
                    }
                }
            }

            // Back-compat / common confusion: env points at `<root>/stdlib` but install layout
            // actually places `std/` directly under `<root>` (e.g. `<prefix>/share/fun/std`).
            if (!self.checkStdlibRootAbsolute(abs) and std.ascii.eqlIgnoreCase(base, "stdlib")) {
                const parent = std.fs.path.dirname(abs) orelse null;
                if (parent) |p| {
                    if (self.checkStdlibRootAbsolute(p)) {
                        if (self.debug_imports) self.dbg(true, "imports", "normalized stdlib root from .../stdlib => {s}", .{p});
                        self.allocator.free(abs);
                        abs = self.allocator.dupe(u8, p) catch return false;
                    }
                }
            }

            // If still not valid, try common prefixes where the env var might point to the install prefix
            // or to `.../share`/`.../share/fun`.
            if (!self.checkStdlibRootAbsolute(abs)) {
                const derived1 = std.fs.path.join(self.allocator, &.{ abs, "stdlib" }) catch null;
                if (derived1) |p| {
                    defer self.allocator.free(p);
                    if (self.debug_imports) self.dbg(true, "imports", "trySetStdlibRoot derived(suffix stdlib)={s}", .{p});
                    if (self.checkStdlibRootAbsolute(p)) {
                        if (self.debug_imports) self.dbg(true, "imports", "accepted derived stdlib root => {s}", .{p});
                        self.allocator.free(abs);
                        abs = self.allocator.dupe(u8, p) catch return false;
                    }
                }

                // Current installer layout: `<prefix>/share/fun/std/...` (no `stdlib/` directory).
                if (!self.checkStdlibRootAbsolute(abs)) {
                    const derived_share_fun = std.fs.path.join(self.allocator, &.{ abs, "share", "fun" }) catch null;
                    if (derived_share_fun) |p| {
                        defer self.allocator.free(p);
                        if (self.debug_imports) self.dbg(true, "imports", "trySetStdlibRoot derived(suffix share/fun)={s}", .{p});
                        if (self.checkStdlibRootAbsolute(p)) {
                            if (self.debug_imports) self.dbg(true, "imports", "accepted derived stdlib root => {s}", .{p});
                            self.allocator.free(abs);
                            abs = self.allocator.dupe(u8, p) catch return false;
                        }
                    }
                }

                if (!self.checkStdlibRootAbsolute(abs)) {
                    const derived2 = std.fs.path.join(self.allocator, &.{ abs, "share", "fun", "stdlib" }) catch null;
                    if (derived2) |p| {
                        defer self.allocator.free(p);
                        if (self.debug_imports) self.dbg(true, "imports", "trySetStdlibRoot derived(suffix share/fun/stdlib)={s}", .{p});
                        if (self.checkStdlibRootAbsolute(p)) {
                            if (self.debug_imports) self.dbg(true, "imports", "accepted derived stdlib root => {s}", .{p});
                            self.allocator.free(abs);
                            abs = self.allocator.dupe(u8, p) catch return false;
                        }
                    }
                }

                if (!self.checkStdlibRootAbsolute(abs)) {
                    const derived3 = std.fs.path.join(self.allocator, &.{ abs, "fun", "stdlib" }) catch null;
                    if (derived3) |p| {
                        defer self.allocator.free(p);
                        if (self.debug_imports) self.dbg(true, "imports", "trySetStdlibRoot derived(suffix fun/stdlib)={s}", .{p});
                        if (self.checkStdlibRootAbsolute(p)) {
                            if (self.debug_imports) self.dbg(true, "imports", "accepted derived stdlib root => {s}", .{p});
                            self.allocator.free(abs);
                            abs = self.allocator.dupe(u8, p) catch return false;
                        }
                    }
                }
            }
        }

        var keep: bool = false;
        defer if (!keep) self.allocator.free(abs);

        if (!self.checkStdlibRootAbsolute(abs)) {
            if (self.debug_imports) self.dbg(true, "imports", "reject stdlib root (unable to open 'std/'?) abs={s}", .{abs});
            return false;
        }

        if (self.stdlib_root_path) |p| self.allocator.free(p);
        self.stdlib_root_path = abs;
        keep = true;
        // Propagate to this process's env so child compiler subprocesses (diagnostics)
        // resolve imports deterministically via FUN_STDLIB_DIR rather than their own
        // discovery — which intermittently mis-flagged stdlib symbols (e.g. `parse`)
        // as "unknown function" on a cold open. Best-effort; ignore failure.
        if (self.allocator.dupeZ(u8, abs)) |abs_z| {
            defer self.allocator.free(abs_z);
            _ = setEnvVar("FUN_STDLIB_DIR", abs_z.ptr, 1);
        } else |_| {}
        if (self.debug_imports) self.dbg(true, "imports", "accepted stdlib root abs={s}", .{abs});
        return true;
    }

    fn tryStdlibRootFromEnv(self: *LspServer, comptime name: [:0]const u8) bool {
        const z = std.c.getenv(name) orelse return false;
        const v = std.mem.sliceTo(z, 0);
        const trimmed = std.mem.trim(u8, v, " \t\r\n");
        if (trimmed.len == 0) return false;
        const unquoted = blk: {
            if ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'')) {
                if (trimmed.len <= 2) break :blk "";
                break :blk trimmed[1 .. trimmed.len - 1];
            }
            break :blk trimmed;
        };
        if (unquoted.len == 0) return false;
        return self.trySetStdlibRoot(unquoted);
    }

    fn tryStdlibRootFromWorkspace(self: *LspServer) bool {
        const root = self.root_path orelse return false;
        const p = std.fs.path.join(self.allocator, &.{ root, "stdlib" }) catch return false;
        defer self.allocator.free(p);
        return self.trySetStdlibRoot(p);
    }

    fn tryStdlibRootFromExe(self: *LspServer, exe_path: []const u8) bool {
        const exe_dir = std.fs.path.dirname(exe_path) orelse return false;

        // Support both layouts:
        // 1) Typical install layout:
        //    <prefix>/bin/fls(.exe)
        //    <prefix>/share/fun/stdlib/std/...
        // 2) Portable/zip layout where binaries live directly under <prefix>:
        //    <prefix>/fls(.exe)
        //    <prefix>/share/fun/stdlib/std/...
        const exe_dir_base = std.fs.path.basename(exe_dir);
        const prefix = if (std.ascii.eqlIgnoreCase(exe_dir_base, "bin"))
            (std.fs.path.dirname(exe_dir) orelse return false)
        else
            exe_dir;

        // Typical install layout:
        // <prefix>/bin/fun(.exe)
        // <prefix>/share/fun/stdlib/std/c/...
        const p = std.fs.path.join(self.allocator, &.{ prefix, "share", "fun", "stdlib" }) catch return false;
        defer self.allocator.free(p);
        return self.trySetStdlibRoot(p);
    }

    fn tryStdlibRootFromCurrentDoc(self: *LspServer, current_uri: []const u8) void {
        // If initialize didn't provide a usable workspace root (or the client is in single-file mode),
        // fall back to discovering the repo root by walking up from the current file.
        if (self.stdlib_root_path != null) return;
        const current_path = uriToPath(self.allocator, current_uri) catch return;
        defer self.allocator.free(current_path);

        var dir_opt: ?[]const u8 = std.fs.path.dirname(current_path);
        var depth: usize = 0;
        while (dir_opt) |dir| : (depth += 1) {
            if (depth > 32) break;

            const cand = std.fs.path.join(self.allocator, &.{ dir, "stdlib" }) catch break;
            const ok = self.trySetStdlibRoot(cand);
            self.allocator.free(cand);
            if (ok) return;

            dir_opt = std.fs.path.dirname(dir);
        }
    }

    pub fn run(self: *LspServer) !void {
        var stdin_buf: [65536]u8 = undefined;
        var reader = self.stdin.reader(self.io, &stdin_buf);
        const inr = &reader;

        while (true) {
            const msg_bytes = readLspMessage(self.allocator, &inr.interface) catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            defer self.allocator.free(msg_bytes);

            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, msg_bytes, .{}) catch |err| {
                // Bad JSON should not kill the server; VS Code will keep going.
                self.log("[fls] json parse failed: {s}\n", .{@errorName(err)});
                continue;
            };
            defer parsed.deinit();

            const root = parsed.value;
            if (root != .object) continue;
            const obj = root.object;

            const method_val = obj.get("method") orelse null;
            const id_val = obj.get("id") orelse null;
            const method = if (method_val != null and method_val.? == .string) method_val.?.string else "";

            // Never let a single bad request/notification kill the server.
            // VS Code formatting+save can trigger unusual edit shapes; we prefer to log and keep going.
            const is_request = id_val != null;

            if (std.mem.eql(u8, method, "initialize")) {
                self.handleInitialize(id_val, obj.get("params") orelse null) catch |err| {
                    self.log("[fls] initialize failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "null") catch {};
                };
                continue;
            }
            if (std.mem.eql(u8, method, "shutdown")) {
                self.sendResponseJson(id_val, "null") catch {};
                continue;
            }
            if (std.mem.eql(u8, method, "exit")) {
                return;
            }

            if (std.mem.eql(u8, method, "textDocument/didOpen")) {
                self.handleDidOpen(obj.get("params") orelse null) catch |err| {
                    self.log("[fls] didOpen failed: {s}\n", .{@errorName(err)});
                };
                continue;
            }
            if (std.mem.eql(u8, method, "textDocument/didChange")) {
                self.handleDidChange(obj.get("params") orelse null) catch |err| {
                    self.log("[fls] didChange failed: {s}\n", .{@errorName(err)});
                };
                continue;
            }
            if (std.mem.eql(u8, method, "textDocument/didSave")) {
                self.handleDidSave(obj.get("params") orelse null) catch |err| {
                    self.log("[fls] didSave failed: {s}\n", .{@errorName(err)});
                };
                continue;
            }
            if (std.mem.eql(u8, method, "textDocument/didClose")) {
                self.handleDidClose(obj.get("params") orelse null) catch |err| {
                    self.log("[fls] didClose failed: {s}\n", .{@errorName(err)});
                };
                continue;
            }

            if (std.mem.eql(u8, method, "textDocument/formatting")) {
                self.handleFormatting(id_val, obj.get("params") orelse null) catch |err| {
                    self.log("[fls] formatting request failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "[]") catch {};
                };
                continue;
            }

            if (std.mem.eql(u8, method, "textDocument/hover")) {
                self.handleHover(id_val, obj.get("params") orelse null) catch |err| {
                    self.log("[fls] hover failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "null") catch {};
                };
                continue;
            }
            if (std.mem.eql(u8, method, "textDocument/definition") or
                std.mem.eql(u8, method, "textDocument/declaration") or
                std.mem.eql(u8, method, "textDocument/typeDefinition") or
                std.mem.eql(u8, method, "textDocument/implementation"))
            {
                const mode: DefinitionMode = if (std.mem.eql(u8, method, "textDocument/typeDefinition")) .type_definition else .definition;
                self.handleDefinition(mode, id_val, obj.get("params") orelse null) catch |err| {
                    self.log("[fls] definition-like request failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "[]") catch {};
                };
                continue;
            }
            if (std.mem.eql(u8, method, "textDocument/references")) {
                self.handleReferences(id_val, obj.get("params") orelse null) catch |err| {
                    self.log("[fls] references failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "[]") catch {};
                };
                continue;
            }
            if (std.mem.eql(u8, method, "textDocument/rename")) {
                self.handleRename(id_val, obj.get("params") orelse null) catch |err| {
                    self.log("[fls] rename failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "null") catch {};
                };
                continue;
            }
            if (std.mem.eql(u8, method, "textDocument/codeAction")) {
                self.handleCodeAction(id_val, obj.get("params") orelse null) catch |err| {
                    self.log("[fls] codeAction failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "[]") catch {};
                };
                continue;
            }
            if (std.mem.eql(u8, method, "textDocument/completion")) {
                self.handleCompletion(id_val, obj.get("params") orelse null) catch |err| {
                    self.log("[fls] completion failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "{\"isIncomplete\":false,\"items\":[]}") catch {};
                };
                continue;
            }
            if (std.mem.eql(u8, method, "textDocument/signatureHelp")) {
                self.handleSignatureHelp(id_val, obj.get("params") orelse null) catch |err| {
                    self.log("[fls] signatureHelp failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "null") catch {};
                };
                continue;
            }
            if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
                self.handleDocumentSymbols(id_val, obj.get("params") orelse null) catch |err| {
                    self.log("[fls] documentSymbol failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "[]") catch {};
                };
                continue;
            }
            if (std.mem.eql(u8, method, "workspace/symbol")) {
                self.handleWorkspaceSymbols(id_val, obj.get("params") orelse null) catch |err| {
                    self.log("[fls] workspace/symbol failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "[]") catch {};
                };
                continue;
            }
            if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
                self.handleSemanticTokensFull(id_val, obj.get("params") orelse null) catch |err| {
                    self.log("[fls] semanticTokens failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "null") catch {};
                };
                continue;
            }
            if (std.mem.eql(u8, method, "textDocument/inlayHint")) {
                self.handleInlayHint(id_val, obj.get("params") orelse null) catch |err| {
                    self.log("[fls] inlayHint failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "[]") catch {};
                };
                continue;
            }

            if (is_request) {
                self.sendResponseJson(id_val, "null") catch {};
            }
        }
    }

    fn handleInitialize(self: *LspServer, id_val: ?std.json.Value, params_val: ?std.json.Value) !void {
        // Per the LSP spec, positions are UTF-16 code-unit offsets unless the
        // server negotiates `positionEncoding: "utf-8"` — this server always
        // treats `character` as UTF-16 (see `normalizePositionToByteColumns`
        // in positions.zig for why: comments/strings can contain non-ASCII
        // text, and misreading UTF-16 units as raw bytes desyncs every
        // position on a line with non-ASCII content before the target
        // column), so it never declares `positionEncoding` and always expects
        // UTF-16 input, matching the default every LSP client assumes absent
        // negotiation.
        const InitializeResult = struct {
            capabilities: struct {
                textDocumentSync: struct {
                    openClose: bool = true,
                    change: i64,
                    save: struct {
                        includeText: bool = false,
                    } = .{},
                },
                documentFormattingProvider: bool,
                hoverProvider: bool,
                definitionProvider: bool,
                declarationProvider: bool,
                typeDefinitionProvider: bool,
                implementationProvider: bool,
                referencesProvider: bool,
                renameProvider: bool,
                codeActionProvider: bool,
                completionProvider: struct {
                    resolveProvider: bool = false,
                    triggerCharacters: []const []const u8 = &[_][]const u8{ ".", "(", ":" },
                    completionItem: struct {
                        labelDetailsSupport: bool = true,
                    } = .{},
                },
                signatureHelpProvider: struct {
                    triggerCharacters: []const []const u8 = &[_][]const u8{ "(", "," },
                },
                documentSymbolProvider: bool,
                workspaceSymbolProvider: bool,
                inlayHintProvider: bool,
                semanticTokensProvider: struct {
                    legend: struct {
                        tokenTypes: []const []const u8,
                        tokenModifiers: []const []const u8,
                    },
                    full: bool,
                },
            },
        };

        const res: InitializeResult = .{
            .capabilities = .{
                .textDocumentSync = .{ .change = 2 }, // Incremental (VS Code format/save often sends ranged edits)
                .documentFormattingProvider = true,
                .hoverProvider = true,
                .definitionProvider = true,
                .declarationProvider = true,
                .typeDefinitionProvider = true,
                .implementationProvider = true,
                .referencesProvider = true,
                .renameProvider = true,
                .codeActionProvider = true,
                .completionProvider = .{ .triggerCharacters = &[_][]const u8{ ".", "(", ":" } },
                .signatureHelpProvider = .{ .triggerCharacters = &[_][]const u8{ "(", "," } },
                .documentSymbolProvider = true,
                .workspaceSymbolProvider = true,
                .inlayHintProvider = true,
                .semanticTokensProvider = .{
                    .legend = .{
                        .tokenTypes = &[_][]const u8{
                            "keyword",
                            "comment",
                            "string",
                            "number",
                            "operator",
                            "function",
                            "variable",
                            "type",
                            "enumMember",
                            "boolean",
                        },
                        .tokenModifiers = &[_][]const u8{
                            "defaultLibrary",
                        },
                    },
                    .full = true,
                },
            },
        };

        const json = blk: {
            var aw = std.Io.Writer.Allocating.init(self.allocator);
            try std.json.fmt(res, .{}).format(&aw.writer);
            break :blk try aw.toOwnedSlice();
        };
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);

        // Best-effort workspace indexing so completion/definition work across imports and other files.
        self.captureRootFromInitialize(params_val) catch {};
        self.indexWorkspace() catch {};
    }

    fn captureRootFromInitialize(self: *LspServer, params_val: ?std.json.Value) !void {
        const params = params_val orelse return;
        if (params != .object) return;

        var chosen_uri: ?[]const u8 = null;
        if (params.object.get("rootUri")) |rv| {
            if (rv == .string and rv.string.len != 0) chosen_uri = rv.string;
        }
        if (chosen_uri == null) {
            if (params.object.get("workspaceFolders")) |wf| {
                if (wf == .array and wf.array.items.len != 0) {
                    const first = wf.array.items[0];
                    if (first == .object) {
                        if (first.object.get("uri")) |u| {
                            if (u == .string and u.string.len != 0) chosen_uri = u.string;
                        }
                    }
                }
            }
        }
        if (chosen_uri == null) {
            if (params.object.get("rootPath")) |rp| {
                if (rp == .string and rp.string.len != 0) {
                    // Older clients send a filesystem path.
                    if (self.root_path) |p| self.allocator.free(p);
                    self.root_path = try self.allocator.dupe(u8, rp.string);
                    return;
                }
            }
        }
        if (chosen_uri == null) return;

        if (self.root_uri) |u| self.allocator.free(u);
        self.root_uri = try self.allocator.dupe(u8, chosen_uri.?);

        const path = uriToPath(self.allocator, chosen_uri.?) catch return;
        if (self.root_path) |p| self.allocator.free(p);
        self.root_path = path;

        if (self.debug_imports) {
            self.dbg(true, "imports", "initialize captured root_uri={s}", .{self.root_uri.?});
            self.dbg(true, "imports", "initialize captured root_path={s}", .{self.root_path.?});
        }
    }

    fn indexWorkspace(self: *LspServer) !void {
        const root_path = self.root_path orelse return;
        var dir = try std.Io.Dir.openDirAbsolute(globalIo(), root_path, .{ .iterate = true });
        defer dir.close(globalIo());

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next(globalIo())) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".fn")) continue;

            // Skip generated/internal files to avoid indexing junk (and to prevent
            // temp artifacts from crashing the lexer on restart).
            if (std.mem.startsWith(u8, entry.path, ".zig-cache")) continue;
            if (std.mem.startsWith(u8, entry.path, "zig-out")) continue;

            const base = std.fs.path.basename(entry.path);
            if (std.mem.startsWith(u8, base, "_fls_idx_")) continue;
            if (std.mem.startsWith(u8, base, "__fls_unused__")) continue;

            const abs_path = try std.fs.path.join(self.allocator, &[_][]const u8{ root_path, entry.path });
            defer self.allocator.free(abs_path);

            const uri = try pathToUri(self.allocator, abs_path);
            defer self.allocator.free(uri);

            self.ensureDocIndexedFromDisk(uri) catch {};
        }
    }

    fn handleDidOpen(self: *LspServer, params_val: ?std.json.Value) !void {
        const params = params_val orelse return;
        if (params != .object) return;
        const text_document = params.object.get("textDocument") orelse return;
        if (text_document != .object) return;

        const uri = (text_document.object.get("uri") orelse return).string;
        const version = (text_document.object.get("version") orelse std.json.Value{ .integer = 0 }).integer;
        const text = (text_document.object.get("text") orelse return).string;

        try self.upsertDoc(uri, version, text);
        try self.rebuildIndex(uri);
        self.maybePublishDiagnostics(uri, text, true) catch |err| {
            self.log("[fls] publishDiagnostics failed on didOpen: {s}\n", .{@errorName(err)});
            self.sendPublishDiagnostics(uri, &[_]Diagnostic{}) catch {};
        };
    }

    fn handleDidChange(self: *LspServer, params_val: ?std.json.Value) !void {
        const params = params_val orelse return;
        if (params != .object) return;
        const text_document = params.object.get("textDocument") orelse return;
        if (text_document != .object) return;

        const uri = (text_document.object.get("uri") orelse return).string;
        const version = (text_document.object.get("version") orelse std.json.Value{ .integer = 0 }).integer;
        const changes = params.object.get("contentChanges") orelse return;
        if (changes != .array or changes.array.items.len == 0) return;

        // If we don't have a baseline document yet (e.g. fls restarted and got a didChange first),
        // ranged edits are unsafe and can "wipe" the in-memory text. Wait for didOpen/full text.
        if (self.docs.get(uri) == null) {
            var has_full_replace = false;
            for (changes.array.items) |chg| {
                if (chg == .object and chg.object.get("range") == null) {
                    has_full_replace = true;
                    break;
                }
            }
            if (!has_full_replace) return;
        }

        const existing = self.docs.get(uri);
        var working = if (existing) |d| try self.allocator.dupe(u8, d.text) else try self.allocator.dupe(u8, "");
        defer self.allocator.free(working);

        // Apply changes in order (LSP specifies ordered application).
        for (changes.array.items) |chg| {
            if (chg != .object) continue;
            const new_text = (chg.object.get("text") orelse continue).string;

            if (chg.object.get("range")) |rv| {
                if (rv != .object) continue;
                const start_v = rv.object.get("start") orelse continue;
                const end_v = rv.object.get("end") orelse continue;
                if (start_v != .object or end_v != .object) continue;
                const sl = (start_v.object.get("line") orelse continue).integer;
                const sc = (start_v.object.get("character") orelse continue).integer;
                const el = (end_v.object.get("line") orelse continue).integer;
                const ec = (end_v.object.get("character") orelse continue).integer;

                const start_pos: Position = .{ .line = sl, .character = sc };
                const end_pos: Position = .{ .line = el, .character = ec };

                if (try tryApplyRangedEdit(self.allocator, working, start_pos, end_pos, new_text)) |updated| {
                    self.allocator.free(working);
                    working = updated;
                }
            } else {
                // Full content replacement.
                const duped = try self.allocator.dupe(u8, new_text);
                self.allocator.free(working);
                working = duped;
            }
        }

        try self.upsertDoc(uri, version, working);
        try self.rebuildIndex(uri);
        self.maybePublishDiagnostics(uri, working, false) catch |err| {
            self.log("[fls] publishDiagnostics failed on didChange: {s}\n", .{@errorName(err)});
            self.sendPublishDiagnostics(uri, &[_]Diagnostic{}) catch {};
        };
    }

    fn handleDidSave(self: *LspServer, params_val: ?std.json.Value) !void {
        const params = params_val orelse return;
        if (params != .object) return;
        const text_document = params.object.get("textDocument") orelse return;
        if (text_document != .object) return;
        const uri = (text_document.object.get("uri") orelse return).string;

        const doc = self.docs.get(uri) orelse return;
        // If formatting already ran diagnostics within the last 1500 ms (which happens
        // when format-on-save is enabled), skip the redundant diagnostics subprocess entirely.
        const since_last_diag = nowMs() - doc.last_diag_ms;
        if (doc.last_diag_ms != 0 and since_last_diag >= 0 and since_last_diag < 1500) return;
        const force = doc.last_diag_ms == 0 or since_last_diag > 1500 or since_last_diag < 0;
        self.maybePublishDiagnostics(uri, doc.text, force) catch |err| {
            self.log("[fls] publishDiagnostics failed on didSave: {s}\n", .{@errorName(err)});
            self.sendPublishDiagnostics(uri, &[_]Diagnostic{}) catch {};
        };
    }

    fn handleDidClose(self: *LspServer, params_val: ?std.json.Value) !void {
        const params = params_val orelse return;
        if (params != .object) return;
        const text_document = params.object.get("textDocument") orelse return;
        if (text_document != .object) return;
        const uri = (text_document.object.get("uri") orelse return).string;

        if (self.docs.fetchRemove(uri)) |kv| {
            self.allocator.free(kv.value.uri);
            self.allocator.free(kv.value.text);
            if (kv.value.index) |idx| idx.deinit();
        }

        try self.sendPublishDiagnostics(uri, &[_]Diagnostic{});
    }

    fn handleFormatting(self: *LspServer, id_val: ?std.json.Value, params_val: ?std.json.Value) !void {
        const empty = "[]";
        const params = params_val orelse {
            try self.sendResponseJson(id_val, empty);
            return;
        };
        if (params != .object) {
            try self.sendResponseJson(id_val, empty);
            return;
        }
        const text_document = params.object.get("textDocument") orelse {
            try self.sendResponseJson(id_val, empty);
            return;
        };
        if (text_document != .object) {
            try self.sendResponseJson(id_val, empty);
            return;
        }
        const uri = (text_document.object.get("uri") orelse return).string;
        const doc = self.docs.get(uri) orelse {
            try self.sendResponseJson(id_val, empty);
            return;
        };

        // Formatting is pure token work — it needs no imports/typecheck. Run the
        // in-process token formatter (byte-identical to `fun -fmt`) instead of
        // spawning the full `fun -fmt-diag` diagnostics subprocess. Diagnostics
        // remain on their own trigger (didOpen/didChange/didSave).
        const formatted_opt = self.formatInProcess(uri, doc.text) catch |err| {
            self.log("[fls] formatting failed: {s}\n", .{@errorName(err)});
            try self.sendResponseJson(id_val, empty);
            return;
        };
        defer if (formatted_opt) |f| self.allocator.free(f);

        // Send format edits only if we got a non-empty formatted result.
        if (formatted_opt) |formatted| {
            const edits = [_]TextEdit{.{
                .range = .{
                    .start = .{ .line = 0, .character = 0 },
                    .end = .{ .line = 1_000_000, .character = 0 },
                },
                .newText = formatted,
            }};
            const json = try jsonStringifyAlloc(self.allocator, edits);
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
        } else {
            try self.sendResponseJson(id_val, empty);
        }
    }

    /// Format `text` using the in-process token formatter (`cli.format_source`).
    /// This is lexing-only: no transpile/typecheck, no imports, no stdlib walk,
    /// so it is an order of magnitude faster than the diagnostics subprocess.
    ///
    /// The formatter lexes from a real file, so we materialise `text` into a
    /// stable temp file next to the document (same convention as the diagnostics
    /// path) and remove it afterwards. Returns an allocator-owned formatted
    /// string, or null when the formatter produced nothing usable.
    fn formatInProcess(self: *LspServer, current_uri: []const u8, text: []const u8) !?[]u8 {
        var tmp_name_buf: [80]u8 = undefined;
        const tmp_name = try std.fmt.bufPrint(&tmp_name_buf, ".__fls_fmt_{x:0>6}.fn", .{std.hash.Wyhash.hash(0, current_uri) & 0xFFFFFF});

        const current_path_opt = uriToPath(self.allocator, current_uri) catch null;
        defer if (current_path_opt) |p| self.allocator.free(p);
        const current_dir_opt = if (current_path_opt) |p| std.fs.path.dirname(p) else null;

        var base_dir = if (current_dir_opt) |d|
            try std.Io.Dir.openDirAbsolute(globalIo(), d, .{})
        else
            std.Io.Dir.cwd();
        defer if (current_dir_opt != null) base_dir.close(globalIo());

        {
            const f = try base_dir.createFile(globalIo(), tmp_name, .{ .read = true, .truncate = true });
            defer f.close(globalIo());
            try f.writeStreamingAll(globalIo(), text);
        }
        defer base_dir.deleteFile(globalIo(), tmp_name) catch {};

        const tmp_abs_path = blk: {
            if (current_dir_opt) |d|
                break :blk try std.fs.path.join(self.allocator, &[_][]const u8{ d, tmp_name });
            break :blk try self.allocator.dupe(u8, tmp_name);
        };
        defer self.allocator.free(tmp_abs_path);

        const formatted = cli.format_source(self.allocator, tmp_abs_path, text) catch |err| {
            self.log("[fls] in-process format error: {s}\n", .{@errorName(err)});
            return null;
        };
        // Defensive: never send an edit that wipes a non-empty doc.
        if (formatted.len == 0 and text.len != 0) {
            self.allocator.free(formatted);
            return null;
        }
        return formatted;
    }

    fn handleHover(self: *LspServer, id_val: ?std.json.Value, params_val: ?std.json.Value) !void {
        const parsed = try parseTextDocPosition(params_val);
        if (parsed == null) {
            try self.sendResponseJson(id_val, "null");
            return;
        }
        const uri = parsed.?.uri;
        const pos = parsed.?.pos;
        const doc = self.docs.get(uri) orelse {
            try self.sendResponseJson(id_val, "null");
            return;
        };
        const idx = doc.index orelse {
            try self.sendResponseJson(id_val, "null");
            return;
        };

        const tok = findTokenAt(idx.tokens, pos) orelse {
            try self.sendResponseJson(id_val, "null");
            return;
        };
        if (tok.kind == .keyword) {
            var buf = ArrayList(u8).init(self.allocator);
            defer buf.deinit();

            if (std.mem.eql(u8, tok.text, "async")) {
                try buf.appendSlice(
                    "```fun\n" ++
                        "async fun name(...) Type { ... }\n" ++
                        "```\n" ++
                        "Marks a function or method as asynchronous. Invoke it with\n" ++
                        "`await f(...)` to wait for and get its result, or with\n" ++
                        "`fork f(...)` to spawn it as a fire-and-forget virtual thread.\n",
                );
            } else if (std.mem.eql(u8, tok.text, "await")) {
                try buf.appendSlice(
                    "```fun\n" ++
                        "await some_async_call();\n" ++
                        "```\n" ++
                        "Waits for an async call and yields its result.\n" ++
                        "`await` is only valid inside `async` functions.\n",
                );
            } else if (std.mem.eql(u8, tok.text, "nil")) {
                try buf.appendSlice(
                    "```fun\n" ++
                        "nil\n" ++
                        "```\n" ++
                        "The null literal. Coerces to any pointer type and to `str`,\n" ++
                        "and compares with `==` / `!=`. Transpiles to C `NULL`.\n",
                );
            } else if (std.mem.eql(u8, tok.text, "fork")) {
                try buf.appendSlice(
                    "```fun\n" ++
                        "fork async_fn(args);\n" ++
                        "```\n" ++
                        "Spawns a fire-and-forget virtual thread: the call runs on an\n" ++
                        "M:N scheduler pool. The target must be an `async fun`; results\n" ++
                        "flow back over channels. `main` drains all forks before exiting.\n",
                );
            } else {
                try self.sendResponseJson(id_val, "null");
                return;
            }

            const hover: Hover = .{ .contents = .{ .value = buf.items }, .range = tok.range };
            const json = try jsonStringifyAlloc(self.allocator, hover);
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return;
        }
        if (tok.kind != .identifier) {
            try self.sendResponseJson(id_val, "null");
            return;
        }

        // Import namespace hover (custom modules): if hovering a segment of `imp a.b.c;` and that
        // segment resolves to a directory with a README, show it.
        if (try self.trySendImportNamespaceHoverLineBased(id_val, uri, doc.text, pos)) return;
        if (findTokenIndexAt(idx.tokens, pos)) |tok_i| {
            if (try self.trySendImportNamespaceHover(id_val, uri, idx, pos, tok_i)) return;
        }

        // Stdlib namespace hover (e.g. `std`, `std.c`, `std.c.io`, `std.c.io.printf`).
        // Do this early and for any identifier token so hovering `std` itself works.
        if (findTokenIndexAt(idx.tokens, pos)) |tok_i| {
            if (try self.trySendStdNamespaceHover(id_val, uri, idx, tok_i)) return;
        }

        // Builtin hover.
        if (std.mem.eql(u8, tok.text, "sizeof")) {
            var buf = ArrayList(u8).init(self.allocator);
            defer buf.deinit();
            try buf.appendSlice(
                "```fun\n" ++
                    "sizeof(Type) num\n" ++
                    "```\n" ++
                    "Returns the size in bytes of `Type`.\n" ++
                    "The argument must be a type name.\n",
            );

            const hover: Hover = .{ .contents = .{ .value = buf.items }, .range = tok.range };
            const json = try jsonStringifyAlloc(self.allocator, hover);
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return;
        }

        // Enum dot-shorthand hover: `.Variant` where the enum type is inferred from context.
        if (findTokenIndexAt(idx.tokens, pos)) |tok_i| {
            const t = idx.tokens[tok_i];
            const merged = (t.kind == .identifier and t.text.len > 1 and t.text[0] == '.');
            const is_shorthand = merged or (tok_i > 0 and isDotToken(idx.tokens[tok_i - 1]));
            const not_member = merged or (tok_i < 2 or idx.tokens[tok_i - 2].kind != .identifier);
            if (is_shorthand and not_member) {
                const variant_name = if (merged) t.text[1..] else tok.text;
                if (self.guessEnumTypeForDotShorthand(uri, idx, tok_i)) |enum_name| {
                    if (self.findMemberByContainer(uri, enum_name, variant_name, .enumMember)) |h| {
                        var buf = ArrayList(u8).init(self.allocator);
                        defer buf.deinit();
                        // A data-carrying variant stores its payload signature
                        // (`Enum.Variant(types)`) in `detail`; render that so the
                        // payload types are visible. A trailing doc comment does NOT
                        // start with the `Enum.` prefix, so it is distinguishable.
                        // Prefer the fit-arm-specific resolution, which substitutes
                        // concrete generic args (`Option.Some(dec)`) over the plain
                        // indexed detail (`Option.Some(T)`).
                        const variant_sig = self.resolveFitVariantConcreteSig(idx, uri, pos) orelse enumVariantSigFromDetail(h.sym, enum_name);
                        if (variant_sig) |vs| {
                            try buf.print("```fun\n{s}\n```\n", .{vs});
                        } else {
                            try buf.print("```fun\n{s}.{s}\n```\n", .{ enum_name, variant_name });
                        }
                        var had_leading_doc = false;
                        if (self.docs.get(h.uri)) |hdoc| {
                            had_leading_doc = try appendDocCommentAboveLine(self.allocator, &buf, hdoc.text, h.sym.decl_range.start.line);
                        }
                        // Fall back to the variant's trailing doc comment (stored in
                        // `detail`) when there's no leading doc: `Number(num), // ...`.
                        // Skip when `detail` is actually the payload sig.
                        if (!had_leading_doc and variant_sig == null) {
                            if (h.sym.detail) |variant_doc| {
                                if (variant_doc.len != 0) try buf.print("\n{s}\n", .{variant_doc});
                            }
                        }
                        const hover: Hover = .{ .contents = .{ .value = buf.items }, .range = tok.range };
                        const json = try jsonStringifyAlloc(self.allocator, hover);
                        defer self.allocator.free(json);
                        try self.sendResponseJson(id_val, json);
                        return;
                    }
                }
            }
        }

        // Member hover: show info for `a.b` / `a.b.c` / `a.f().g` by resolving the
        // receiver's type. The receiver may be an identifier OR a method-call result
        // (`as_array()` -> `Option<...>`), an indexing, etc. — `resolveTypeOfExprEndingAtToken`
        // follows all of those (a `)`-ending receiver routes through resolveCallReturnType).
        if (findTokenIndexAt(idx.tokens, pos)) |tok_i| {
            if (tok_i > 0 and isDotToken(idx.tokens[tok_i - 1])) {
                if (tok_i >= 2) {
                    if (self.resolveTypeOfExprEndingAtToken(idx, uri, pos, tok_i - 2)) |recv_type| {
                        const name = tok.text;
                        const hit = self.findMemberByContainerFresh(uri, recv_type, name, .field) orelse
                            self.findMemberByContainerFresh(uri, recv_type, name, .property) orelse
                            self.findMemberByContainerFresh(uri, recv_type, name, .enumMember) orelse
                            self.findMemberByContainerFresh(uri, recv_type, name, .method);
                        if (hit) |h| {
                            var buf = ArrayList(u8).init(self.allocator);
                            defer buf.deinit();
                            switch (h.sym.kind) {
                                .field, .property => {
                                    if (h.sym.value_type) |vt| {
                                        var specialized_vt_owned: ?[]u8 = null;
                                        defer if (specialized_vt_owned) |sv| self.allocator.free(sv);

                                        const shown_vt: []const u8 = blk: {
                                            if (h.sym.container_type) |declared_container| {
                                                if (try self.specializeMemberTypeForReceiver(declared_container, recv_type, vt)) |sv| {
                                                    specialized_vt_owned = sv;
                                                    break :blk sv;
                                                }
                                            }
                                            break :blk vt;
                                        };

                                        try buf.print("```fun\n{s} {s}\n```\n", .{ shown_vt, name });
                                    } else {
                                        try buf.print("_field_\n", .{});
                                    }
                                },
                                .enumMember => {
                                    if (self.resolveFitVariantConcreteSig(idx, uri, pos)) |vs| {
                                        try buf.print("```fun\n{s}\n```\n", .{vs});
                                    } else if (enumVariantSigFromDetail(h.sym, recv_type)) |vs| {
                                        try buf.print("```fun\n{s}\n```\n", .{vs});
                                    } else {
                                        try buf.print("```fun\n{s}.{s}\n```\n", .{ recv_type, name });
                                    }
                                },
                                .method => {
                                    if (h.sym.detail) |det| {
                                        // Specialize generic type params against the concrete
                                        // receiver type so hovering `o.unwrap_or` on an
                                        // `Option<num>` shows `unwrap_or(num ...) num` rather
                                        // than the raw `unwrap_or(T ...) T`. Mirrors the
                                        // signature-help specialization.
                                        var spec_owned: ?[]u8 = null;
                                        defer if (spec_owned) |s| self.allocator.free(s);
                                        const shown: []const u8 = blk: {
                                            if (h.sym.container_type) |declared_container| {
                                                if (self.specializeMemberLabelForReceiver(self.allocator, declared_container, recv_type, det) catch null) |sv| {
                                                    spec_owned = sv;
                                                    break :blk sv;
                                                }
                                            }
                                            break :blk det;
                                        };
                                        try buf.print("```fun\n{s}\n```\n", .{shown});
                                    } else {
                                        try buf.print("_method on {s}_\n", .{recv_type});
                                    }
                                },
                                else => {
                                    try buf.print("_{s}_\n", .{@tagName(h.sym.kind)});
                                },
                            }

                            var member_had_leading_doc = false;
                            if (self.docs.get(h.uri)) |hdoc| {
                                member_had_leading_doc = try appendDocCommentAboveLine(self.allocator, &buf, hdoc.text, h.sym.decl_range.start.line);
                            }
                            // An enum variant carries its trailing doc comment in
                            // `detail` (`Number(num), // ...`); surface it when there
                            // is no leading doc above the variant. Skip when `detail`
                            // is actually the payload signature (already rendered).
                            if (!member_had_leading_doc and h.sym.kind == .enumMember and
                                enumVariantSigFromDetail(h.sym, recv_type) == null)
                            {
                                if (h.sym.detail) |variant_doc| {
                                    if (variant_doc.len != 0) try buf.print("\n{s}\n", .{variant_doc});
                                }
                            }
                            try self.appendSeeAlsoForSymbol(&buf, uri, h.sym);

                            const hover: Hover = .{ .contents = .{ .value = buf.items }, .range = tok.range };
                            const json = try jsonStringifyAlloc(self.allocator, hover);
                            defer self.allocator.free(json);
                            try self.sendResponseJson(id_val, json);
                            return;
                        }
                    }
                }
            }
        }

        // Prefer definition in current doc; else search direct imports.
        var def_local_opt: ?SymbolLite = findBestDefinition(idx.symbols, tok.text, pos) orelse null;
        const def_import = if (def_local_opt == null) self.findAnyGlobalDefinitionInDirectImports(uri, tok.text) else null;
        if (def_local_opt == null and def_import == null) {
            if (try self.trySendAliasHover(id_val, uri, idx, tok.text, tok.range)) return;
        }

        var concrete_hover_type_owned: ?[]u8 = null;
        defer if (concrete_hover_type_owned) |s| self.allocator.free(s);
        var concrete_hover_type: ?[]const u8 = concreteGenericTypeSliceAtPosition(doc.text, pos);
        if (findTokenIndexAt(idx.tokens, pos)) |tok_i| {
            concrete_hover_type_owned = try concreteGenericTypeAtToken(self.allocator, idx.tokens, tok_i);
            if (concrete_hover_type_owned) |owned| {
                concrete_hover_type = owned;
            }
        }

        var buf = ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        const pickBestLocal = struct {
            fn call(symbols: []const SymbolLite, name: []const u8, at: Position) ?SymbolLite {
                var best: ?SymbolLite = null;
                var best_non_builtin: ?SymbolLite = null;
                var best_rank: u8 = 0;
                for (symbols) |s| {
                    if (s.kind != .variable) continue;
                    if (!std.mem.eql(u8, s.name, name)) continue;
                    if (s.container_fn_range) |cr| {
                        if (!posInRange(at, cr)) continue;
                    } else {
                        continue;
                    }
                    if (!rangeStartLessOrEqual(s.selection_range, at)) continue;

                    if (best == null or rangeStartGreater(s.selection_range, best.?.selection_range) or
                        (rangeStartEqual(s.selection_range, best.?.selection_range) and preferDetailedSymbol(s, best.?)))
                    {
                        best = s;
                    }

                    if (s.value_type) |vt| {
                        const rank = numericBuiltinRank(vt);
                        if (rank > best_rank) {
                            best_rank = rank;
                            best = s;
                        }
                    }

                    if (hasNonBuiltinValueType(s)) {
                        if (best_non_builtin == null or rangeStartGreater(s.selection_range, best_non_builtin.?.selection_range) or
                            (rangeStartEqual(s.selection_range, best_non_builtin.?.selection_range) and preferDetailedSymbol(s, best_non_builtin.?)))
                        {
                            best_non_builtin = s;
                        }
                    }
                }
                return best_non_builtin orelse best;
            }
        }.call;

        if (def_local_opt) |d| {
            if (d.kind == .variable) {
                if (pickBestLocal(idx.symbols, tok.text, pos)) |picked| {
                    def_local_opt = picked;
                }

                var best_non_builtin: ?SymbolLite = null;
                for (idx.symbols) |cand| {
                    if (cand.kind != .variable) continue;
                    if (!std.mem.eql(u8, cand.name, tok.text)) continue;
                    if (cand.container_fn_range) |cr| {
                        if (!posInRange(pos, cr)) continue;
                    } else {
                        continue;
                    }
                    if (!hasNonBuiltinValueType(cand)) continue;
                    if (best_non_builtin == null or preferDetailedSymbol(cand, best_non_builtin.?)) {
                        best_non_builtin = cand;
                    }
                }
                if (best_non_builtin) |bn| {
                    def_local_opt = bn;
                }
            }
        }

        if (self.debug_definitions and def_local_opt != null and def_local_opt.?.kind == .variable) {
            const d = def_local_opt.?;
            self.dbg(true, "defs", "hover pick name={s} detail={s} value_type={s} decl=({d},{d}) sel=({d},{d})", .{
                d.name,
                d.detail orelse "",
                d.value_type orelse "",
                d.decl_range.start.line,
                d.decl_range.start.character,
                d.selection_range.start.line,
                d.selection_range.start.character,
            });
        }

        if (def_local_opt) |d| {
            const let_infer_detail = d.kind == .variable and ((d.value_type != null and isLetInferTypeName(d.value_type.?)) or
                (d.detail != null and std.mem.startsWith(u8, d.detail.?, "__let_infer__")));
            if (d.detail) |det| {
                if (let_infer_detail) {
                    // Skip placeholder let inference details; fall back to value_type/guess.
                } else {
                    if (d.kind == .struct_ or d.kind == .interface or d.kind == .enum_) {
                        // Render type symbols in the kind-specific branch below so we can
                        // include concrete generic arguments from the hover site.
                    } else if (d.kind == .enumMember) {
                        // Rendered in the enumMember branch below (which knows how to
                        // pick between the payload sig and the plain `Enum.Variant`).
                    } else if (d.kind == .function and d.value_type != null) {
                        const det_trim = std.mem.trimEnd(u8, det, " \t\r\n");
                        if (det_trim.len != 0 and det_trim[det_trim.len - 1] == ')') {
                            try buf.print("```fun\n{s} {s}\n```\n", .{ det_trim, d.value_type.? });
                        } else {
                            try buf.print("```fun\n{s}\n```\n", .{det});
                        }
                    } else {
                        try buf.print("```fun\n{s}\n```\n", .{det});
                    }
                }
            }
            if (d.kind == .variable and (d.detail == null or let_infer_detail)) {
                // `guessVariableType` now also resolves `fit`-arm payload bindings
                // (incl. imported generic enums), so a single call covers all cases.
                const vt = d.value_type orelse self.guessVariableType(idx, uri, tok.text, pos);
                if (vt) |vts| {
                    if (!isLetInferTypeName(vts)) {
                        try buf.print("```fun\n{s} {s}\n```\n", .{ vts, tok.text });
                    }
                } else {
                    try buf.print("_{s}_\n", .{@tagName(d.kind)});
                }
            } else if (d.kind == .enumMember) {
                const recv_type = d.container_type orelse d.value_type orelse "";
                // Prefer the fit-arm-pattern-specific resolution, which substitutes
                // concrete generic args (`Option.Some(dec)`) over the plain indexed
                // detail (`Option.Some(T)`) when hovering the variant name itself.
                if (self.resolveFitVariantConcreteSig(idx, uri, pos)) |vs| {
                    try buf.print("```fun\n{s}\n```\n", .{vs});
                } else if (enumVariantSigFromDetail(d, recv_type)) |vs| {
                    try buf.print("```fun\n{s}\n```\n", .{vs});
                } else if (recv_type.len != 0) {
                    try buf.print("```fun\n{s}.{s}\n```\n", .{ recv_type, tok.text });
                } else {
                    try buf.print("_{s}_\n", .{@tagName(d.kind)});
                }
            } else if ((d.kind == .field or d.kind == .property) and d.value_type != null) {
                // Field/property inside a compound: render `type name`.
                try buf.print("```fun\n{s} {s}\n```\n", .{ d.value_type.?, tok.text });
            } else if ((d.kind == .struct_ or d.kind == .interface or d.kind == .enum_)) {
                const kw = if (d.kind == .struct_) "compound" else if (d.kind == .interface) "quirk" else "enum";
                if (concrete_hover_type) |concrete| {
                    try buf.print("```fun\n{s} {s}\n```\n", .{ kw, concrete });
                } else if (d.detail) |det| {
                    try buf.print("```fun\n{s}\n```\n", .{det});
                } else {
                    try buf.print("```fun\n{s} {s}\n```\n", .{ kw, tok.text });
                }
            } else if (d.detail == null or let_infer_detail) {
                // Only show a bare kind label when no signature was rendered above.
                try buf.print("_{s}_\n", .{@tagName(d.kind)});
            }
            _ = try appendDocCommentAboveLine(self.allocator, &buf, doc.text, d.decl_range.start.line);
            try self.appendSeeAlsoForSymbol(&buf, uri, d);
        } else if (def_import) |hit| {
            const d = hit.sym;

            var printed_detail = false;
            if (d.detail) |det| {
                if (!(d.kind == .struct_ or d.kind == .interface or d.kind == .enum_ or d.kind == .enumMember)) {
                    if (d.kind == .function and d.value_type != null) {
                        const det_trim = std.mem.trimEnd(u8, det, " \t\r\n");
                        if (det_trim.len != 0 and det_trim[det_trim.len - 1] == ')') {
                            try buf.print("```fun\n{s} {s}\n```\n", .{ det_trim, d.value_type.? });
                        } else {
                            try buf.print("```fun\n{s}\n```\n", .{det});
                        }
                    } else {
                        try buf.print("```fun\n{s}\n```\n", .{det});
                    }
                    printed_detail = true;
                }
            }
            if (!printed_detail) {
                if (d.kind == .variable) {
                    const vt = d.value_type orelse self.guessVariableType(idx, uri, tok.text, pos);
                    if (vt) |vts| {
                        try buf.print("```fun\n{s} {s}\n```\n", .{ vts, tok.text });
                    } else {
                        try buf.print("_{s}_\n", .{@tagName(d.kind)});
                    }
                } else if (d.kind == .enumMember) {
                    const recv_type = d.container_type orelse d.value_type orelse "";
                    if (self.resolveFitVariantConcreteSig(idx, uri, pos)) |vs| {
                        try buf.print("```fun\n{s}\n```\n", .{vs});
                    } else if (enumVariantSigFromDetail(d, recv_type)) |vs| {
                        try buf.print("```fun\n{s}\n```\n", .{vs});
                    } else if (recv_type.len != 0) {
                        try buf.print("```fun\n{s}.{s}\n```\n", .{ recv_type, tok.text });
                    } else {
                        try buf.print("_{s}_\n", .{@tagName(d.kind)});
                    }
                } else if ((d.kind == .field or d.kind == .property) and d.value_type != null) {
                    // Field/property inside a compound: render `type name`.
                    try buf.print("```fun\n{s} {s}\n```\n", .{ d.value_type.?, tok.text });
                } else if ((d.kind == .struct_ or d.kind == .interface or d.kind == .enum_)) {
                    const kw = if (d.kind == .struct_) "compound" else if (d.kind == .interface) "quirk" else "enum";
                    if (concrete_hover_type) |concrete| {
                        try buf.print("```fun\n{s} {s}\n```\n", .{ kw, concrete });
                    } else if (d.detail) |det| {
                        try buf.print("```fun\n{s}\n```\n", .{det});
                    } else {
                        try buf.print("```fun\n{s} {s}\n```\n", .{ kw, tok.text });
                    }
                } else {
                    try buf.print("_{s}_\n", .{@tagName(d.kind)});
                }
            }
            if (self.docs.get(hit.uri)) |idoc| {
                _ = try appendDocCommentAboveLine(self.allocator, &buf, idoc.text, d.decl_range.start.line);
            }
            try self.appendSeeAlsoForSymbol(&buf, uri, d);
        } else {
            if (self.guessVariableType(idx, uri, tok.text, pos)) |vt| {
                try buf.print("```fun\n{s} {s}\n```\n", .{ vt, tok.text });
            }
        }

        const hover: Hover = .{
            .contents = .{ .value = buf.items },
            .range = tok.range,
        };
        const json = try jsonStringifyAlloc(self.allocator, hover);
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
    }

    /// Appends a Go-doc-style "See also" footer to a hover buffer, linking to the
    /// definitions of user-defined types related to the hovered symbol (its
    /// declared/return type, owning type, and any generic type arguments).
    /// Builtins are skipped, duplicates de-duplicated, and only types that
    /// resolve to a definition are linked (as clickable `file://` markdown links).
    /// No section is emitted if nothing resolves. `preferred_uri` is the document
    /// the hover originated from (used to prefer same-doc/imported definitions).
    fn appendSeeAlsoForSymbol(self: *LspServer, buf: *ArrayList(u8), preferred_uri: []const u8, sym: SymbolLite) !void {
        // Gather candidate type names from the symbol.
        var candidates = ArrayList([]const u8).init(self.allocator);
        defer candidates.deinit();
        if (sym.value_type) |vt| try collectTypeNamesFromTypeString(&candidates, vt);
        if (sym.container_type) |ct| try collectTypeNamesFromTypeString(&candidates, ct);
        if (sym.detail) |det| try collectReturnAndParamTypeNames(&candidates, det);

        // Resolve, de-dup, and render links.
        var links = ArrayList(u8).init(self.allocator);
        defer links.deinit();
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();
        var count: usize = 0;
        for (candidates.items) |raw| {
            const name = std.mem.trim(u8, raw, " \t\r\n*[]");
            if (name.len == 0) continue;
            if (isBuiltinTypeName(name)) continue;
            // Skip the symbol's own name (don't "see also" yourself).
            if (std.mem.eql(u8, name, sym.name)) continue;
            if (seen.contains(name)) continue;
            try seen.put(name, {});

            const hit = self.findTypeDefinitionAnyDoc(preferred_uri, name) orelse continue;
            const target_uri = self.pathOrUriToFileUri(hit.uri) catch continue;
            defer self.allocator.free(target_uri);
            if (count > 0) try links.appendSlice(", ");
            // 1-based line for the editor's #L fragment.
            try links.print("[`{s}`]({s}#L{d})", .{ name, target_uri, hit.sym.selection_range.start.line + 1 });
            count += 1;
            if (count >= 8) break; // keep the footer compact
        }

        if (count == 0) return;
        try buf.appendSlice("\n---\n\nSee also: ");
        try buf.appendSlice(links.items);
        try buf.append('\n');
    }

    /// Normalizes an indexed `uri` (which may already be a `file://` URI or a
    /// plain filesystem path) into a `file://` URI suitable for a markdown link.
    /// Caller owns the returned slice.
    fn pathOrUriToFileUri(self: *LspServer, uri_or_path: []const u8) ![]u8 {
        if (std.mem.startsWith(u8, uri_or_path, "file://")) {
            return self.allocator.dupe(u8, uri_or_path);
        }
        return pathToUri(self.allocator, uri_or_path);
    }

    fn resolveTypeOfChainUpTo(self: *LspServer, idx: *const Index, uri: []const u8, at: Position, last_ident_i: usize) ?[]const u8 {
        // Resolve type of a dot-chain ending at `last_ident_i` (identifier index).
        // Example: for `rect.a.x`, if last_ident_i is `a`, returns type of `rect.a`.
        if (idx.tokens[last_ident_i].kind != .identifier) return null;

        // Find chain start scanning left over `. <ident>`.
        var start_i: usize = last_ident_i;
        while (start_i >= 2) {
            const dot = idx.tokens[start_i - 1];
            const left = idx.tokens[start_i - 2];
            if (isDotToken(dot) and left.kind == .identifier and
                left.range.start.line == dot.range.start.line and
                dot.range.start.line == idx.tokens[start_i].range.start.line)
            {
                start_i -= 2;
                continue;
            }
            break;
        }

        // Collect identifier indices from start_i to last_ident_i.
        var ids = ArrayList(usize).init(self.allocator);
        defer ids.deinit();
        var j: usize = start_i;
        while (j <= last_ident_i) {
            if (idx.tokens[j].kind != .identifier) return null;
            ids.append(j) catch return null;
            if (j == last_ident_i) break;
            if (j + 2 > last_ident_i) return null;
            if (!isDotToken(idx.tokens[j + 1])) return null;
            if (idx.tokens[j].range.start.line != idx.tokens[j + 1].range.start.line or
                idx.tokens[j + 1].range.start.line != idx.tokens[j + 2].range.start.line)
            {
                return null;
            }
            j += 2;
        }
        if (ids.items.len == 0) return null;

        var current_type: ?[]const u8 = null;
        var segment_start: usize = 1;

        if (start_i >= 2 and isDotToken(idx.tokens[start_i - 1]) and idx.tokens[start_i - 1].range.start.line == idx.tokens[start_i].range.start.line) {
            current_type = self.resolveTypeOfExprEndingAtToken(idx, uri, at, start_i - 2);
            segment_start = 0;
        } else {
            const base_name = idx.tokens[ids.items[0]].text;
            if (std.mem.eql(u8, base_name, "self")) {
                current_type = self.guessEnclosingImplType(idx, at);
            } else if (self.isKnownTypeName(uri, base_name)) {
                current_type = base_name;
            } else {
                current_type = self.guessVariableType(idx, uri, base_name, at);
            }
            if (self.debug_definitions) {
                self.dbg(true, "defs", "chain base name={s} at=({d},{d}) type={s}", .{
                    base_name,
                    at.line,
                    at.character,
                    current_type orelse "",
                });
            }
        }
        if (current_type == null) return null;

        if (segment_start >= ids.items.len) return current_type.?;

        // Walk remaining segments as fields/properties.
        var si: usize = segment_start;
        while (si < ids.items.len) : (si += 1) {
            const seg = idx.tokens[ids.items[si]].text;
            const field = self.findMemberByContainer(uri, current_type.?, seg, .field) orelse
                self.findMemberByContainer(uri, current_type.?, seg, .property);
            if (field) |hit| {
                if (hit.sym.value_type) |vt| {
                    // Substitute the field type's generic params against the owner's
                    // concrete args: `Box<AsyncCounter>.v` where `v: T` -> `AsyncCounter`,
                    // so the next segment (`.add`) resolves on the real type instead of a
                    // bare `T` (which triggered an O(files) member-miss scan and failed).
                    var spec: ?[]const u8 = null;
                    if (hit.sym.container_type) |declared_container| {
                        if (self.specializeMemberTypeForReceiver(declared_container, current_type.?, vt) catch null) |sv| {
                            const arena = @constCast(&idx.arena).allocator();
                            spec = arena.dupe(u8, sv) catch null;
                            self.allocator.free(sv);
                        }
                    }
                    const eff = spec orelse vt;
                    if (self.debug_definitions) {
                        self.dbg(true, "defs", "chain segment owner={s} seg={s} field_type={s}", .{ current_type.?, seg, eff });
                    }
                    current_type = eff;
                    continue;
                }
            }

            const fallback_vt = findFieldTypeFromCurrentDocTokens(idx, current_type.?, seg) orelse return null;
            if (self.debug_definitions) {
                self.dbg(true, "defs", "chain segment fallback owner={s} seg={s} field_type={s}", .{
                    current_type.?,
                    seg,
                    fallback_vt,
                });
            }
            current_type = fallback_vt;
        }

        return current_type.?;
    }

    fn resolveTypeOfExprEndingAtToken(self: *LspServer, idx: *const Index, uri: []const u8, at: Position, expr_last_i: usize) ?[]const u8 {
        if (expr_last_i >= idx.tokens.len) return null;

        const tok = idx.tokens[expr_last_i];
        if (tok.kind == .identifier) {
            if (self.resolveTypeOfChainUpTo(idx, uri, at, expr_last_i)) |resolved| return resolved;

            if (std.mem.eql(u8, tok.text, "self")) return self.guessEnclosingImplType(idx, at);
            if (self.isKnownTypeName(uri, tok.text)) return tok.text;
            return self.guessVariableType(idx, uri, tok.text, at);
        }

        if ((tok.kind == .symbol or tok.kind == .operator) and std.mem.eql(u8, tok.text, "]")) {
            const lbrack_i = findMatchingLBracketLite(idx.tokens, expr_last_i) orelse return null;
            const base_end_i = prevNonTrivialTokenLite(idx.tokens, lbrack_i) orelse return null;
            const base_type = self.resolveTypeOfExprEndingAtToken(idx, uri, at, base_end_i) orelse return null;
            return stripOneArraySuffix(base_type);
        }

        // Method/free call: the expression ends in `)`. Resolve `recv.method(args)` to
        // the method's RETURN type, specializing the callee's generic params against the
        // receiver's concrete type (so `doc.as_array()` on JsonValue -> Option<Vec<JsonValue>>,
        // and a further `.unwrap_or(x)` -> Vec<JsonValue>). This is what lets a whole
        // method chain — and any `let`/for binding derived from one — be typed.
        if ((tok.kind == .symbol or tok.kind == .operator) and std.mem.eql(u8, tok.text, ")")) {
            return self.resolveCallReturnType(idx, uri, at, expr_last_i);
        }

        return null;
    }

    /// Resolve the return type of a call expression whose closing `)` is at `rparen_i`.
    /// Handles `recv.method(...)` (method on a resolved receiver, with generic-param
    /// substitution) and a bare `name(...)` free function. Returns the FULL return type
    /// spelling (e.g. `Vec<JsonValue>`), or null.
    fn resolveCallReturnType(self: *LspServer, idx: *const Index, uri: []const u8, at: Position, rparen_i: usize) ?[]const u8 {
        const toks = idx.tokens;
        const lparen_i = findMatchingLParenLite(toks, rparen_i) orelse return null;
        const name_i = prevNonTrivialTokenLite(toks, lparen_i) orelse return null;
        if (toks[name_i].kind != .identifier) return null;
        const method_name = toks[name_i].text;

        // Is this a method call (`recv.method(`) or a free function (`name(`)?
        const before_name = prevNonTrivialTokenLite(toks, name_i);
        const is_method = before_name != null and isDotToken(toks[before_name.?]);

        if (is_method) {
            const recv_end_i = prevNonTrivialTokenLite(toks, before_name.?) orelse return null;
            const recv_type = self.resolveTypeOfExprEndingAtToken(idx, uri, at, recv_end_i) orelse return null;
            const mhit = self.findMemberByContainer(uri, baseTypeNameForLookup(recv_type), method_name, .method) orelse return null;
            const detail = mhit.sym.detail orelse return null;
            // Specialize the method label's generic params against the concrete receiver
            // (`unwrap_or(T) T` on `Option<Vec<JsonValue>>` -> `unwrap_or(Vec<JsonValue>) Vec<JsonValue>`),
            // then read the (now concrete) return type.
            const declared_container = mhit.sym.container_type orelse recv_type;
            var spec_owned: ?[]u8 = null;
            defer if (spec_owned) |s| self.allocator.free(s);
            const eff_label: []const u8 = blk: {
                if (self.specializeMemberLabelForReceiver(self.allocator, declared_container, recv_type, detail) catch null) |sv| {
                    spec_owned = sv;
                    break :blk sv;
                }
                break :blk detail;
            };
            const rt = returnTypeFullFromSignatureLabel(eff_label) orelse return null;
            // Copy into the index arena so the result outlives `spec_owned`.
            const arena = @constCast(&idx.arena).allocator();
            return arena.dupe(u8, rt) catch null;
        }

        // Free function: resolve via its signature (current doc + imports).
        if (self.calleeSignatureDetail(uri, idx, name_i)) |detail| {
            // If the callee is generic (`some<T>(T value) Option<T>`), bind its type
            // params against the concrete argument types and substitute them into the
            // return type so hover shows `Option<str>` rather than the declared `Option<T>`.
            // Falls back to the verbatim return type when nothing can be bound so a
            // non-generic (or unresolvable) call keeps its current behavior.
            if (self.specializeGenericFreeFnReturn(uri, idx, at, lparen_i, rparen_i, detail)) |spec| {
                defer self.allocator.free(spec);
                const arena = @constCast(&idx.arena).allocator();
                return arena.dupe(u8, spec) catch null;
            }
            const rt = returnTypeFullFromSignatureLabel(detail) orelse return null;
            const arena = @constCast(&idx.arena).allocator();
            return arena.dupe(u8, rt) catch null;
        }
        return null;
    }

    /// For a generic FREE function call `name(args)` whose closing `)` is at
    /// `rparen_i` and opening `(` at `lparen_i`, bind the callee's generic type
    /// params against the resolved types of the actual call arguments and
    /// substitute the bindings into the declared return-type spelling.
    ///
    /// Example: `some("hi")` where the signature is `fun some<T>(T value) Option<T>`
    /// binds `T = str` and returns `Option<str>`. Returns an allocator-owned string
    /// (caller frees) or null when the callee is not generic, has no bindable args,
    /// or the return type can't be substituted — in which case the caller falls back
    /// to the verbatim declared return type (preserving prior behavior).
    ///
    /// This is a self-contained re-implementation of the arg->param binding loop used
    /// by `specializeGenericSignatureHelpLabel`; signatureHelp is intentionally left
    /// untouched (this only adds hover-side return specialization).
    fn specializeGenericFreeFnReturn(
        self: *LspServer,
        uri: []const u8,
        idx: *const Index,
        at: Position,
        lparen_i: usize,
        rparen_i: usize,
        detail: []const u8,
    ) ?[]u8 {
        const TypeBinding = struct { param: []const u8, arg: []const u8 };

        const findSignatureParenBounds = struct {
            const Bounds = struct { open: usize, close: usize };
            fn call(label: []const u8) ?Bounds {
                const open_i = std.mem.indexOfScalar(u8, label, '(') orelse return null;
                var depth: i64 = 0;
                var i = open_i;
                while (i < label.len) : (i += 1) {
                    const ch = label[i];
                    if (ch == '(') {
                        depth += 1;
                        continue;
                    }
                    if (ch == ')') {
                        depth -= 1;
                        if (depth == 0) return .{ .open = open_i, .close = i };
                    }
                }
                return null;
            }
        }.call;

        const splitTopLevelCsv = struct {
            fn call(text: []const u8, out: *ArrayList([]const u8)) !void {
                var angle_depth: i64 = 0;
                var paren_depth: i64 = 0;
                var brack_depth: i64 = 0;
                var brace_depth: i64 = 0;
                var start: usize = 0;
                var i: usize = 0;
                while (i <= text.len) : (i += 1) {
                    const at_end = i == text.len;
                    const ch: u8 = if (!at_end) text[i] else 0;
                    if (!at_end) {
                        switch (ch) {
                            '<' => angle_depth += 1,
                            '>' => {
                                if (angle_depth > 0) angle_depth -= 1;
                            },
                            '(' => paren_depth += 1,
                            ')' => {
                                if (paren_depth > 0) paren_depth -= 1;
                            },
                            '[' => brack_depth += 1,
                            ']' => {
                                if (brack_depth > 0) brack_depth -= 1;
                            },
                            '{' => brace_depth += 1,
                            '}' => {
                                if (brace_depth > 0) brace_depth -= 1;
                            },
                            else => {},
                        }
                    }
                    if (at_end or (ch == ',' and angle_depth == 0 and paren_depth == 0 and brack_depth == 0 and brace_depth == 0)) {
                        var seg = text[start..i];
                        seg = std.mem.trim(u8, seg, " \t\r\n");
                        if (seg.len != 0) try out.append(seg);
                        start = i + 1;
                    }
                }
            }
        }.call;

        const normalizeGenericParamName = struct {
            fn call(param_raw: []const u8) []const u8 {
                var p = std.mem.trim(u8, param_raw, " \t\r\n");
                if (p.len == 0) return p;
                var cut = p.len;
                var j: usize = 0;
                while (j < p.len) : (j += 1) {
                    const ch = p[j];
                    if (ch == ':' or ch == '=' or ch == ' ' or ch == '\t') {
                        cut = j;
                        break;
                    }
                }
                return std.mem.trim(u8, p[0..cut], " \t\r\n");
            }
        }.call;

        const parseGenericParamNamesFromLabel = struct {
            fn call(splitCsv: anytype, normParam: anytype, bounds_fn: anytype, label: []const u8, out: *ArrayList([]const u8)) !void {
                const bounds = bounds_fn(label) orelse return;
                const head = label[0..bounds.open];
                var depth: i64 = 0;
                var lt_i: ?usize = null;
                var gt_i: ?usize = null;
                var i: usize = 0;
                while (i < head.len) : (i += 1) {
                    const ch = head[i];
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

                var raw = ArrayList([]const u8).init(std.heap.page_allocator);
                defer raw.deinit();
                splitCsv(head[lt_i.? + 1 .. gt_i.?], &raw) catch return;
                for (raw.items) |it| {
                    const p = normParam(it);
                    if (p.len == 0) continue;
                    try out.append(p);
                }
            }
        }.call;

        const parseParamTypesFromLabel = struct {
            fn call(splitCsv: anytype, bounds_fn: anytype, label: []const u8, out: *ArrayList([]const u8)) !void {
                const bounds = bounds_fn(label) orelse return;
                if (bounds.close <= bounds.open + 1) return;
                const inner = std.mem.trim(u8, label[bounds.open + 1 .. bounds.close], " \t\r\n");
                if (inner.len == 0) return;

                var raw = ArrayList([]const u8).init(std.heap.page_allocator);
                defer raw.deinit();
                splitCsv(inner, &raw) catch return;
                for (raw.items) |seg0| {
                    const seg = std.mem.trim(u8, seg0, " \t\r\n");
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
                        const maybe_t = std.mem.trim(u8, seg[0..s], " \t\r\n");
                        if (maybe_t.len != 0) tname = maybe_t;
                    }
                    try out.append(tname);
                }
            }
        }.call;

        const parseGenericCore = struct {
            const Core = struct { base: []const u8, inner: []const u8 };
            fn call(type_name_raw: []const u8) ?Core {
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
                    }
                }
                if (gt == null or gt.? <= lt) return null;
                if (std.mem.trim(u8, tname[gt.? + 1 ..], " \t\r\n").len != 0) return null;
                return .{ .base = std.mem.trim(u8, tname[0..lt], " \t\r\n"), .inner = tname[lt + 1 .. gt.?] };
            }
        }.call;

        const isGenericParam = struct {
            fn call(gparams: []const []const u8, name: []const u8) bool {
                for (gparams) |gp| {
                    if (std.mem.eql(u8, gp, name)) return true;
                }
                return false;
            }
        }.call;

        const lookupBinding = struct {
            fn call(bindings: []const TypeBinding, name: []const u8) ?[]const u8 {
                for (bindings) |b| {
                    if (std.mem.eql(u8, b.param, name)) return b.arg;
                }
                return null;
            }
        }.call;

        const bindIfMissing = struct {
            fn call(bindings: *ArrayList(TypeBinding), param: []const u8, arg: []const u8) !void {
                for (bindings.items) |b| {
                    if (std.mem.eql(u8, b.param, param)) return;
                }
                try bindings.append(.{ .param = param, .arg = arg });
            }
        }.call;

        const bindFromParamType = struct {
            fn call(
                splitCsv: anytype,
                coreFn: anytype,
                isGP: anytype,
                bindMissing: anytype,
                gparams: []const []const u8,
                bindings: *ArrayList(TypeBinding),
                ptype_raw: []const u8,
                atype_raw: []const u8,
            ) !void {
                const ptype = std.mem.trim(u8, ptype_raw, " \t\r\n");
                const atype = std.mem.trim(u8, atype_raw, " \t\r\n");
                if (ptype.len == 0 or atype.len == 0) return;

                if (isGP(gparams, ptype)) {
                    try bindMissing(bindings, ptype, atype);
                    return;
                }
                if (std.mem.endsWith(u8, ptype, "[]") and std.mem.endsWith(u8, atype, "[]")) {
                    try call(splitCsv, coreFn, isGP, bindMissing, gparams, bindings, ptype[0 .. ptype.len - 2], atype[0 .. atype.len - 2]);
                    return;
                }
                if (coreFn(ptype)) |pc| {
                    if (coreFn(atype)) |ac| {
                        if (!std.mem.eql(u8, pc.base, ac.base)) return;
                        var pinner = ArrayList([]const u8).init(std.heap.page_allocator);
                        defer pinner.deinit();
                        var ainner = ArrayList([]const u8).init(std.heap.page_allocator);
                        defer ainner.deinit();
                        splitCsv(pc.inner, &pinner) catch return;
                        splitCsv(ac.inner, &ainner) catch return;
                        const n = @min(pinner.items.len, ainner.items.len);
                        var i: usize = 0;
                        while (i < n) : (i += 1) {
                            try call(splitCsv, coreFn, isGP, bindMissing, gparams, bindings, pinner.items[i], ainner.items[i]);
                        }
                    }
                }
            }
        }.call;

        const substituteLabelTypeParams = struct {
            fn isIdentStart(ch: u8) bool {
                return std.ascii.isAlphabetic(ch) or ch == '_';
            }
            fn isIdentChar(ch: u8) bool {
                return std.ascii.isAlphanumeric(ch) or ch == '_';
            }
            fn call(lookup: anytype, allocator_: Allocator, label: []const u8, bindings: []const TypeBinding) ?[]u8 {
                if (bindings.len == 0) return null;
                var out = ArrayList(u8).init(allocator_);
                defer out.deinit();
                var changed = false;
                var i: usize = 0;
                while (i < label.len) {
                    const ch = label[i];
                    if (!isIdentStart(ch)) {
                        out.append(ch) catch return null;
                        i += 1;
                        continue;
                    }
                    const start = i;
                    i += 1;
                    while (i < label.len and isIdentChar(label[i])) : (i += 1) {}
                    const ident = label[start..i];
                    if (lookup(bindings, ident)) |mapped| {
                        out.appendSlice(mapped) catch return null;
                        changed = true;
                    } else {
                        out.appendSlice(ident) catch return null;
                    }
                }
                if (!changed) return null;
                return out.toOwnedSlice() catch null;
            }
        }.call;

        // 1. Parse generic param names. No params -> not generic -> fall back.
        var generic_params = ArrayList([]const u8).init(self.allocator);
        defer generic_params.deinit();
        parseGenericParamNamesFromLabel(splitTopLevelCsv, normalizeGenericParamName, findSignatureParenBounds, detail, &generic_params) catch return null;
        if (generic_params.items.len == 0) return null;

        // 2. Parse declared param-type spellings from the signature label.
        var param_types = ArrayList([]const u8).init(self.allocator);
        defer param_types.deinit();
        parseParamTypesFromLabel(splitTopLevelCsv, findSignatureParenBounds, detail, &param_types) catch return null;
        if (param_types.items.len == 0) return null;

        // 3. Walk the call's argument token ranges between `(` and `)`.
        const ArgRange = struct { start: usize, end: usize };
        var arg_ranges = ArrayList(ArgRange).init(self.allocator);
        defer arg_ranges.deinit();
        collectFreeCallArgRanges(idx.tokens, lparen_i, rparen_i, ArgRange, &arg_ranges) catch return null;
        if (arg_ranges.items.len == 0) return null;

        // 4. Bind each param spelling against the resolved type of its argument.
        //    Guard the recursion depth: resolving an argument type can re-enter the
        //    call-return engine (`resolveTypeOfExprEndingAtToken` -> ... -> here).
        if (self.type_infer_depth >= 16) return null;
        self.type_infer_depth += 1;
        defer self.type_infer_depth -= 1;

        var bindings = ArrayList(TypeBinding).init(self.allocator);
        defer bindings.deinit();

        const pair_n = @min(param_types.items.len, arg_ranges.items.len);
        var pi: usize = 0;
        while (pi < pair_n) : (pi += 1) {
            const rg = arg_ranges.items[pi];
            const arg_t = self.inferFreeCallArgType(idx, uri, at, rg.start, rg.end) orelse continue;
            bindFromParamType(splitTopLevelCsv, parseGenericCore, isGenericParam, bindIfMissing, generic_params.items, &bindings, param_types.items[pi], arg_t) catch continue;
        }

        if (bindings.items.len == 0) return null;

        // 5. Substitute bindings into the WHOLE label, then read the (now concrete)
        //    return type so we can hand back a plain, owned return-type spelling.
        const spec_label = substituteLabelTypeParams(lookupBinding, self.allocator, detail, bindings.items) orelse return null;
        defer self.allocator.free(spec_label);
        const rt = returnTypeFullFromSignatureLabel(spec_label) orelse return null;
        return self.allocator.dupe(u8, rt) catch null;
    }

    /// Collect top-level argument token ranges of a call whose `(` is at
    /// `lparen_i` and matching `)` at `rparen_i`. Splits on top-level commas
    /// (ignoring commas nested in `()[]{}<>`). `RangeT` must be a struct
    /// `{ start: usize, end: usize }`.
    fn collectFreeCallArgRanges(
        tokens: []const TokenLite,
        lparen_i: usize,
        rparen_i: usize,
        comptime RangeT: type,
        out: *ArrayList(RangeT),
    ) !void {
        if (rparen_i <= lparen_i + 1) return;

        const nextNonComment = struct {
            fn call(toks: []const TokenLite, start_i: usize, end_excl: usize) ?usize {
                var i = start_i;
                while (i < end_excl) : (i += 1) {
                    if (toks[i].kind == .comment) continue;
                    return i;
                }
                return null;
            }
        }.call;

        const trimRange = struct {
            fn call(toks: []const TokenLite, s0: usize, e0: usize) ?RangeT {
                var s = s0;
                var e = e0;
                while (s < e and toks[s].kind == .comment) : (s += 1) {}
                while (e > s and toks[e - 1].kind == .comment) : (e -= 1) {}
                if (s >= e) return null;
                return .{ .start = s, .end = e };
            }
        }.call;

        var seg_start = nextNonComment(tokens, lparen_i + 1, rparen_i) orelse return;

        var p_depth: i64 = 0;
        var b_depth: i64 = 0;
        var c_depth: i64 = 0;
        var g_depth: i64 = 0;

        var i = lparen_i + 1;
        while (i < rparen_i) : (i += 1) {
            const t = tokens[i];
            if (t.kind == .comment) continue;
            // Literal tokens are atomic: their text can contain `,` `(` `<` etc.
            // (e.g. `"Hello, world!"`, `'>'`) which are NOT structural delimiters.
            if (t.kind == .string or t.kind == .number or t.kind == .boolean) continue;

            var saw_top_comma = false;
            for (t.text) |ch| {
                switch (ch) {
                    '(' => p_depth += 1,
                    ')' => {
                        if (p_depth > 0) p_depth -= 1;
                    },
                    '[' => b_depth += 1,
                    ']' => {
                        if (b_depth > 0) b_depth -= 1;
                    },
                    '{' => c_depth += 1,
                    '}' => {
                        if (c_depth > 0) c_depth -= 1;
                    },
                    '<' => g_depth += 1,
                    '>' => {
                        if (g_depth > 0) g_depth -= 1;
                    },
                    ',' => {
                        if (p_depth == 0 and b_depth == 0 and c_depth == 0 and g_depth == 0) saw_top_comma = true;
                    },
                    else => {},
                }
            }

            if (saw_top_comma) {
                if (trimRange(tokens, seg_start, i)) |rg| try out.append(rg);
                seg_start = nextNonComment(tokens, i + 1, rparen_i) orelse rparen_i;
            }
        }

        if (seg_start < rparen_i) {
            if (trimRange(tokens, seg_start, rparen_i)) |rg| try out.append(rg);
        }
    }

    /// Resolve the type of a single call argument occupying tokens `[start_i, end_i)`.
    /// String/number/bool/char literals map to their builtin type; a single
    /// identifier or a dot-chain is resolved through the existing type engine.
    fn inferFreeCallArgType(self: *LspServer, idx: *const Index, uri: []const u8, at: Position, start_i: usize, end_i: usize) ?[]const u8 {
        var s = start_i;
        var e = end_i;
        while (s < e and idx.tokens[s].kind == .comment) : (s += 1) {}
        while (e > s and idx.tokens[e - 1].kind == .comment) : (e -= 1) {}
        if (s >= e) return null;

        if (e == s + 1) {
            const t = idx.tokens[s];
            return switch (t.kind) {
                .string => "str",
                .boolean => "bin",
                .number => blk: {
                    if (t.text.len >= 2 and t.text[0] == '\'' and t.text[t.text.len - 1] == '\'') break :blk "chr";
                    if (std.mem.indexOfScalar(u8, t.text, '.') != null) break :blk "dec";
                    break :blk "num";
                },
                .identifier => self.guessVariableType(idx, uri, t.text, at) orelse
                    if (self.isKnownTypeName(uri, t.text)) t.text else null,
                else => null,
            };
        }

        // Any other expression (dot-chains, nested calls, indexing, ...): resolve
        // via the general expression engine ending at the last token of the range.
        return self.resolveTypeOfExprEndingAtToken(idx, uri, at, e - 1);
    }

    fn findMatchingLBracketLite(tokens: []const TokenLite, rbrack_i: usize) ?usize {
        if (rbrack_i >= tokens.len) return null;
        var depth: i64 = 0;
        var i: isize = @intCast(rbrack_i);
        while (i >= 0) : (i -= 1) {
            const t = tokens[@intCast(i)];
            if (t.kind != .symbol and t.kind != .operator) continue;
            if (std.mem.eql(u8, t.text, "]")) {
                depth += 1;
                continue;
            }
            if (std.mem.eql(u8, t.text, "[")) {
                depth -= 1;
                if (depth == 0) return @intCast(i);
            }
        }
        return null;
    }

    fn stripOneArraySuffix(name: []const u8) ?[]const u8 {
        var trimmed = std.mem.trim(u8, name, " \t\r\n");
        if (trimmed.len < 2 or !std.mem.eql(u8, trimmed[trimmed.len - 2 ..], "[]")) return null;
        trimmed = std.mem.trim(u8, trimmed[0 .. trimmed.len - 2], " \t\r\n");
        if (trimmed.len == 0) return null;
        return trimmed;
    }

    fn baseTypeNameForLookup(name: []const u8) []const u8 {
        var base = if (std.mem.indexOfScalar(u8, name, '<')) |idx| name[0..idx] else name;
        base = std.mem.trim(u8, base, " \t\r\n");

        // Drop trailing array/pointer/reference suffixes used in type strings.
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

        // Normalize qualified names like `a.b.Type` to `Type`.
        if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
            base = base[dot + 1 ..];
        }

        return base;
    }

    fn specializeMemberTypeForReceiver(
        self: *LspServer,
        declared_container_type: []const u8,
        receiver_type: []const u8,
        declared_member_type: []const u8,
    ) !?[]u8 {
        const GenericCore = struct {
            base: []const u8,
            inner: []const u8,
        };

        const parseGenericCore = struct {
            fn call(type_name_raw: []const u8) ?GenericCore {
                const type_name = std.mem.trim(u8, type_name_raw, " \t\r\n");
                const lt = std.mem.indexOfScalar(u8, type_name, '<') orelse return null;

                var depth: i64 = 0;
                var close_i: ?usize = null;
                var i = lt;
                while (i < type_name.len) : (i += 1) {
                    const ch = type_name[i];
                    if (ch == '<') {
                        depth += 1;
                        continue;
                    }
                    if (ch == '>') {
                        depth -= 1;
                        if (depth == 0) {
                            close_i = i;
                            break;
                        }
                    }
                }
                if (close_i == null) return null;

                const tail = std.mem.trim(u8, type_name[close_i.? + 1 ..], " \t\r\n");
                if (tail.len != 0) return null;

                const base = std.mem.trim(u8, type_name[0..lt], " \t\r\n");
                const inner = std.mem.trim(u8, type_name[lt + 1 .. close_i.?], " \t\r\n");
                if (base.len == 0 or inner.len == 0) return null;
                return .{ .base = base, .inner = inner };
            }
        }.call;

        const splitTopLevelCsv = struct {
            fn call(text: []const u8, out_list: *ArrayList([]const u8)) !void {
                var start: usize = 0;
                var angle_depth: i64 = 0;
                var paren_depth: i64 = 0;
                var bracket_depth: i64 = 0;
                var i: usize = 0;

                while (i < text.len) : (i += 1) {
                    const ch = text[i];
                    switch (ch) {
                        '<' => angle_depth += 1,
                        '>' => {
                            if (angle_depth > 0) angle_depth -= 1;
                        },
                        '(' => paren_depth += 1,
                        ')' => {
                            if (paren_depth > 0) paren_depth -= 1;
                        },
                        '[' => bracket_depth += 1,
                        ']' => {
                            if (bracket_depth > 0) bracket_depth -= 1;
                        },
                        ',' => {
                            if (angle_depth == 0 and paren_depth == 0 and bracket_depth == 0) {
                                const seg = std.mem.trim(u8, text[start..i], " \t\r\n");
                                if (seg.len != 0) try out_list.append(seg);
                                start = i + 1;
                            }
                        },
                        else => {},
                    }
                }

                const tail = std.mem.trim(u8, text[start..], " \t\r\n");
                if (tail.len != 0) try out_list.append(tail);
            }
        }.call;

        const TypeCoreSuffix = struct {
            core: []const u8,
            suffix: []const u8,
        };

        const splitCoreSuffix = struct {
            fn call(type_name_raw: []const u8) TypeCoreSuffix {
                const s = std.mem.trim(u8, type_name_raw, " \t\r\n");
                var cut = s.len;

                while (cut > 0) {
                    if (cut >= 2 and std.mem.eql(u8, s[cut - 2 .. cut], "[]")) {
                        cut -= 2;
                        continue;
                    }
                    const ch = s[cut - 1];
                    if (ch == '*' or ch == '&') {
                        cut -= 1;
                        continue;
                    }
                    break;
                }

                return .{
                    .core = std.mem.trim(u8, s[0..cut], " \t\r\n"),
                    .suffix = s[cut..],
                };
            }
        }.call;

        const mapTemplateParam = struct {
            fn normalizeParamName(param_raw: []const u8) []const u8 {
                const trimmed = std.mem.trim(u8, param_raw, " \t\r\n");
                if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
                    return std.mem.trim(u8, trimmed[0..colon], " \t\r\n");
                }
                return trimmed;
            }

            fn call(template_params: []const []const u8, concrete_args: []const []const u8, needle_raw: []const u8) ?[]const u8 {
                const needle = std.mem.trim(u8, needle_raw, " \t\r\n");
                if (needle.len == 0) return null;

                const n = @min(template_params.len, concrete_args.len);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const p = normalizeParamName(template_params[i]);
                    if (!std.mem.eql(u8, p, needle)) continue;
                    return std.mem.trim(u8, concrete_args[i], " \t\r\n");
                }
                return null;
            }
        }.call;

        const receiver_core = parseGenericCore(receiver_type) orelse return null;
        const declared_core_opt = parseGenericCore(declared_container_type);

        if (declared_core_opt == null) {
            // Fallback for symbol sources that only retain the base owner name
            // (`Box`) while the receiver is concrete (`Box<num>`).
            if (!std.mem.eql(u8, baseTypeNameForLookup(declared_container_type), baseTypeNameForLookup(receiver_core.base))) {
                return null;
            }

            var receiver_args_only = ArrayList([]const u8).init(self.allocator);
            defer receiver_args_only.deinit();
            try splitTopLevelCsv(receiver_core.inner, &receiver_args_only);
            if (receiver_args_only.items.len != 1) return null;

            const member = splitCoreSuffix(declared_member_type);
            if (!(member.core.len == 1 and std.ascii.isUpper(member.core[0]))) return null;

            const mapped_core = std.mem.trim(u8, receiver_args_only.items[0], " \t\r\n");
            if (mapped_core.len == 0) return null;

            return if (member.suffix.len == 0)
                try self.allocator.dupe(u8, mapped_core)
            else
                try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ mapped_core, member.suffix });
        }

        const declared_core = declared_core_opt.?;
        if (!std.mem.eql(u8, baseTypeNameForLookup(declared_core.base), baseTypeNameForLookup(receiver_core.base))) {
            return null;
        }

        var declared_params = ArrayList([]const u8).init(self.allocator);
        defer declared_params.deinit();
        var receiver_args = ArrayList([]const u8).init(self.allocator);
        defer receiver_args.deinit();

        try splitTopLevelCsv(declared_core.inner, &declared_params);
        try splitTopLevelCsv(receiver_core.inner, &receiver_args);
        if (declared_params.items.len == 0 or receiver_args.items.len == 0) return null;

        const member = splitCoreSuffix(declared_member_type);
        if (member.core.len == 0) return null;

        if (mapTemplateParam(declared_params.items, receiver_args.items, member.core)) |mapped_core| {
            return if (member.suffix.len == 0)
                try self.allocator.dupe(u8, mapped_core)
            else
                try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ mapped_core, member.suffix });
        }

        if (parseGenericCore(member.core)) |member_core| {
            var member_args = ArrayList([]const u8).init(self.allocator);
            defer member_args.deinit();
            try splitTopLevelCsv(member_core.inner, &member_args);
            if (member_args.items.len == 0) return null;

            var changed = false;
            var out = ArrayList(u8).init(self.allocator);
            errdefer out.deinit();

            try out.print("{s}<", .{member_core.base});
            for (member_args.items, 0..) |arg, ai| {
                const arg_trim = std.mem.trim(u8, arg, " \t\r\n");
                const use_arg = if (mapTemplateParam(declared_params.items, receiver_args.items, arg_trim)) |mapped_arg| blk: {
                    changed = true;
                    break :blk mapped_arg;
                } else arg_trim;

                if (ai != 0) try out.appendSlice(", ");
                try out.appendSlice(use_arg);
            }
            try out.append('>');
            if (member.suffix.len != 0) try out.appendSlice(member.suffix);

            if (!changed) {
                out.deinit();
                return null;
            }

            return @as(?[]u8, try out.toOwnedSlice());
        }

        return null;
    }

    fn specializeMemberLabelForReceiver(
        self: *LspServer,
        allocator: Allocator,
        declared_container_type: []const u8,
        receiver_type: []const u8,
        label: []const u8,
    ) !?[]u8 {
        _ = self;
        const GenericCore = struct {
            base: []const u8,
            inner: []const u8,
        };

        const TypeBinding = struct {
            param: []const u8,
            arg: []const u8,
        };

        const parseGenericCore = struct {
            fn call(type_name_raw: []const u8) ?GenericCore {
                const type_name = std.mem.trim(u8, type_name_raw, " \t\r\n");
                const lt = std.mem.indexOfScalar(u8, type_name, '<') orelse return null;

                var depth: i64 = 0;
                var close_i: ?usize = null;
                var i = lt;
                while (i < type_name.len) : (i += 1) {
                    const ch = type_name[i];
                    if (ch == '<') {
                        depth += 1;
                        continue;
                    }
                    if (ch == '>') {
                        depth -= 1;
                        if (depth == 0) {
                            close_i = i;
                            break;
                        }
                    }
                }
                if (close_i == null) return null;

                const tail = std.mem.trim(u8, type_name[close_i.? + 1 ..], " \t\r\n");
                if (tail.len != 0) return null;

                const base = std.mem.trim(u8, type_name[0..lt], " \t\r\n");
                const inner = std.mem.trim(u8, type_name[lt + 1 .. close_i.?], " \t\r\n");
                if (base.len == 0 or inner.len == 0) return null;
                return .{ .base = base, .inner = inner };
            }
        }.call;

        const splitTopLevelCsv = struct {
            fn call(text: []const u8, out_list: *ArrayList([]const u8)) !void {
                var start: usize = 0;
                var angle_depth: i64 = 0;
                var paren_depth: i64 = 0;
                var bracket_depth: i64 = 0;
                var i: usize = 0;

                while (i < text.len) : (i += 1) {
                    const ch = text[i];
                    switch (ch) {
                        '<' => angle_depth += 1,
                        '>' => {
                            if (angle_depth > 0) angle_depth -= 1;
                        },
                        '(' => paren_depth += 1,
                        ')' => {
                            if (paren_depth > 0) paren_depth -= 1;
                        },
                        '[' => bracket_depth += 1,
                        ']' => {
                            if (bracket_depth > 0) bracket_depth -= 1;
                        },
                        ',' => {
                            if (angle_depth == 0 and paren_depth == 0 and bracket_depth == 0) {
                                const seg = std.mem.trim(u8, text[start..i], " \t\r\n");
                                if (seg.len != 0) try out_list.append(seg);
                                start = i + 1;
                            }
                        },
                        else => {},
                    }
                }

                const tail = std.mem.trim(u8, text[start..], " \t\r\n");
                if (tail.len != 0) try out_list.append(tail);
            }
        }.call;

        const normalizeGenericParamName = struct {
            fn call(param_raw: []const u8) []const u8 {
                var p = std.mem.trim(u8, param_raw, " \t\r\n");
                if (p.len == 0) return p;
                var cut = p.len;
                var i: usize = 0;
                while (i < p.len) : (i += 1) {
                    const ch = p[i];
                    if (ch == ':' or ch == '=' or ch == ' ' or ch == '\t') {
                        cut = i;
                        break;
                    }
                }
                return std.mem.trim(u8, p[0..cut], " \t\r\n");
            }
        }.call;

        const lookupBinding = struct {
            fn call(bindings: []const TypeBinding, name: []const u8) ?[]const u8 {
                for (bindings) |b| {
                    if (std.mem.eql(u8, b.param, name)) return b.arg;
                }
                return null;
            }
        }.call;

        const substituteLabelTypeParams = struct {
            fn isIdentStart(ch: u8) bool {
                return std.ascii.isAlphabetic(ch) or ch == '_';
            }

            fn isIdentChar(ch: u8) bool {
                return std.ascii.isAlphanumeric(ch) or ch == '_';
            }

            fn call(allocator_: Allocator, in_label: []const u8, bindings: []const TypeBinding) ?[]u8 {
                if (bindings.len == 0) return null;

                var out = ArrayList(u8).init(allocator_);
                defer out.deinit();

                var changed = false;
                var i: usize = 0;
                while (i < in_label.len) {
                    const ch = in_label[i];
                    if (!isIdentStart(ch)) {
                        out.append(ch) catch return null;
                        i += 1;
                        continue;
                    }

                    const start = i;
                    i += 1;
                    while (i < in_label.len and isIdentChar(in_label[i])) : (i += 1) {}
                    const ident = in_label[start..i];
                    if (lookupBinding(bindings, ident)) |mapped| {
                        out.appendSlice(mapped) catch return null;
                        changed = true;
                    } else {
                        out.appendSlice(ident) catch return null;
                    }
                }

                if (!changed) return null;
                return out.toOwnedSlice() catch null;
            }
        }.call;

        const declared_core = parseGenericCore(declared_container_type) orelse return null;
        const receiver_core = parseGenericCore(receiver_type) orelse return null;
        if (!std.mem.eql(u8, baseTypeNameForLookup(declared_core.base), baseTypeNameForLookup(receiver_core.base))) return null;

        var declared_params = ArrayList([]const u8).init(allocator);
        defer declared_params.deinit();
        var receiver_args = ArrayList([]const u8).init(allocator);
        defer receiver_args.deinit();

        try splitTopLevelCsv(declared_core.inner, &declared_params);
        try splitTopLevelCsv(receiver_core.inner, &receiver_args);
        if (declared_params.items.len == 0 or receiver_args.items.len == 0) return null;

        var bindings = ArrayList(TypeBinding).init(allocator);
        defer bindings.deinit();

        const bind_n = @min(declared_params.items.len, receiver_args.items.len);
        var i: usize = 0;
        while (i < bind_n) : (i += 1) {
            const param = normalizeGenericParamName(declared_params.items[i]);
            const arg = std.mem.trim(u8, receiver_args.items[i], " \t\r\n");
            if (param.len == 0 or arg.len == 0) continue;
            try bindings.append(.{ .param = param, .arg = arg });
        }

        return substituteLabelTypeParams(allocator, label, bindings.items);
    }

    fn hasTypeDeclarationInDoc(self: *LspServer, uri: []const u8, type_name: []const u8) bool {
        const doc = self.docs.get(uri) orelse return false;
        if (doc.index) |idx| {
            if (hasTypeDeclarationInTokens(idx, type_name)) return true;
        }
        return hasTypeDeclarationInText(doc.text, type_name);
    }

    fn hasTypeDeclarationInTokens(idx: *const Index, type_name: []const u8) bool {
        var i: usize = 0;
        while (i < idx.tokens.len) : (i += 1) {
            const t = idx.tokens[i];
            if (t.kind != .keyword) continue;
            if (!(std.mem.eql(u8, t.text, "compound") or std.mem.eql(u8, t.text, "quirk") or std.mem.eql(u8, t.text, "enum"))) continue;

            var j = i + 1;
            while (j < idx.tokens.len and idx.tokens[j].kind == .comment) : (j += 1) {}
            if (j >= idx.tokens.len) continue;
            if (idx.tokens[j].kind != .identifier) continue;
            const decl_name = if (std.mem.indexOfScalar(u8, idx.tokens[j].text, '<')) |idx_lt| idx.tokens[j].text[0..idx_lt] else idx.tokens[j].text;
            if (std.mem.eql(u8, decl_name, type_name)) return true;
        }
        return false;
    }

    fn hasTypeDeclarationInText(text: []const u8, type_name: []const u8) bool {
        const kws = [_][]const u8{ "compound", "quirk", "enum" };

        const isIdentChar = struct {
            fn call(ch: u8) bool {
                return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
            }
        }.call;

        for (kws) |kw| {
            var pat_buf: [128]u8 = undefined;
            const pat = std.fmt.bufPrint(&pat_buf, "{s} {s}", .{ kw, type_name }) catch continue;

            var from: usize = 0;
            while (std.mem.indexOfPos(u8, text, from, pat)) |at| {
                const before_ok = at == 0 or !isIdentChar(text[at - 1]);
                const end = at + pat.len;
                const after_ok = end >= text.len or !isIdentChar(text[end]);
                if (before_ok and after_ok) return true;
                from = at + 1;
            }
        }

        return false;
    }

    fn appendMemberCompletionsForType(
        self: *LspServer,
        items: *ArrayList(CompletionItem),
        seen: *std.StringHashMap(void),
        preferred_uri: []const u8,
        container_type: []const u8,
        prefix: []const u8,
    ) !void {
        const container_base = baseTypeNameForLookup(container_type);

        // If this document declares the type, do not merge same-name members
        // from other docs.
        if (self.hasTypeDeclarationInDoc(preferred_uri, container_base)) {
            if (self.docs.get(preferred_uri)) |local_doc| {
                if (local_doc.index) |local_idx| {
                    try self.appendMemberCompletionsFromIndexForType(items, seen, local_idx, container_type, prefix);
                }
            }
            try self.appendMemberCompletionsFromUriForType(items, seen, preferred_uri, preferred_uri, container_base, container_type, prefix);
            return;
        }

        // Use the resolved type declaration first so same-name types in other
        // indexed docs do not pollute member completion.
        if (self.findTypeDefinitionAnyDoc(preferred_uri, container_type)) |type_def| {
            try self.appendMemberCompletionsFromUriForType(items, seen, preferred_uri, type_def.uri, container_base, container_type, prefix);

            // Methods can live in separate `impl` files; merge visible methods
            // from all docs after priming fields/properties from the type-def doc.
            var it_methods = self.docs.iterator();
            while (it_methods.next()) |entry| {
                const sym_uri = entry.value_ptr.uri;
                const doc = self.docs.get(sym_uri) orelse continue;
                const didx = doc.index orelse continue;

                for (didx.symbols) |s| {
                    if (s.container_fn_range != null) continue;
                    if (s.container_type == null) continue;
                    if (!std.mem.eql(u8, baseTypeNameForLookup(s.container_type.?), container_base)) continue;
                    if (s.kind != .method) continue;
                    if (prefix.len != 0 and !std.mem.startsWith(u8, s.name, prefix)) continue;
                    if (!self.isSymbolVisibleFromUri(preferred_uri, sym_uri, s)) continue;

                    var key_buf = ArrayList(u8).init(self.allocator);
                    defer key_buf.deinit();
                    try key_buf.print("method:{s}", .{s.name});
                    const key = try self.allocator.dupe(u8, key_buf.items);
                    if (seen.contains(key)) {
                        self.allocator.free(key);
                        continue;
                    }
                    try seen.put(key, {});

                    const detail: ?[]u8 = if (s.detail) |d|
                        try self.allocator.dupe(u8, d)
                    else blk: {
                        var db = ArrayList(u8).init(self.allocator);
                        defer db.deinit();
                        try db.print("{s}.{s}", .{ container_type, s.name });
                        break :blk try self.allocator.dupe(u8, db.items);
                    };

                    try items.append(.{
                        .label = try self.allocator.dupe(u8, s.name),
                        .kind = 2,
                        .detail = detail,
                    });
                }
            }
            return;
        }

        var it = self.docs.iterator();
        while (it.next()) |entry| {
            try self.appendMemberCompletionsFromUriForType(items, seen, preferred_uri, entry.value_ptr.uri, container_base, container_type, prefix);
        }
    }

    fn appendMemberCompletionsFromUriForType(
        self: *LspServer,
        items: *ArrayList(CompletionItem),
        seen: *std.StringHashMap(void),
        preferred_uri: []const u8,
        sym_uri: []const u8,
        container_base: []const u8,
        container_type: []const u8,
        prefix: []const u8,
    ) !void {
        const doc = self.docs.get(sym_uri) orelse return;
        const didx = doc.index orelse return;

        for (didx.symbols) |s| {
            if (s.container_fn_range != null) continue;
            if (s.container_type == null) continue;
            if (!std.mem.eql(u8, baseTypeNameForLookup(s.container_type.?), container_base)) continue;
            if (!(s.kind == .field or s.kind == .property or s.kind == .method or s.kind == .enumMember)) continue;
            if (prefix.len != 0 and !std.mem.startsWith(u8, s.name, prefix)) continue;
            if (!self.isSymbolVisibleFromUri(preferred_uri, sym_uri, s)) continue;

            const kind: i64 = switch (s.kind) {
                .method => 2,
                .field, .property => 5,
                .enumMember => 20,
                else => 6,
            };

            // Dedup members by name+kind.
            var key_buf = ArrayList(u8).init(self.allocator);
            defer key_buf.deinit();
            try key_buf.print("{s}:{s}", .{ @tagName(s.kind), s.name });
            const key = try self.allocator.dupe(u8, key_buf.items);
            if (seen.contains(key)) {
                self.allocator.free(key);
                continue;
            }
            try seen.put(key, {});

            const detail: ?[]u8 = blk: {
                if (s.kind == .field or s.kind == .property) {
                    if (s.value_type) |vt| {
                        if (s.container_type) |declared_container| {
                            if (try self.specializeMemberTypeForReceiver(declared_container, container_type, vt)) |specialized_vt| {
                                break :blk specialized_vt;
                            }
                        }
                        break :blk try self.allocator.dupe(u8, vt);
                    }
                }
                if (s.kind == .enumMember) {
                    var db = ArrayList(u8).init(self.allocator);
                    defer db.deinit();
                    try db.print("{s}.{s}", .{ container_type, s.name });
                    break :blk try self.allocator.dupe(u8, db.items);
                }
                if (s.kind == .method) {
                    if (s.detail) |d| break :blk try self.allocator.dupe(u8, d);
                    var db = ArrayList(u8).init(self.allocator);
                    defer db.deinit();
                    try db.print("{s}.{s}", .{ container_type, s.name });
                    break :blk try self.allocator.dupe(u8, db.items);
                }
                break :blk null;
            };

            try items.append(.{
                .label = try self.allocator.dupe(u8, s.name),
                .kind = kind,
                .detail = detail,
            });
        }
    }

    fn appendMemberCompletionsFromIndexForType(
        self: *LspServer,
        items: *ArrayList(CompletionItem),
        seen: *std.StringHashMap(void),
        idx: *const Index,
        container_type: []const u8,
        prefix: []const u8,
    ) !void {
        const container_base = baseTypeNameForLookup(container_type);

        for (idx.symbols) |s| {
            if (s.container_fn_range != null) continue;
            if (s.container_type == null) continue;
            if (!std.mem.eql(u8, baseTypeNameForLookup(s.container_type.?), container_base)) continue;
            if (!(s.kind == .field or s.kind == .property or s.kind == .method or s.kind == .enumMember)) continue;
            if (prefix.len != 0 and !std.mem.startsWith(u8, s.name, prefix)) continue;

            var key_buf = ArrayList(u8).init(self.allocator);
            defer key_buf.deinit();
            try key_buf.print("{s}:{s}", .{ @tagName(s.kind), s.name });
            const key = try self.allocator.dupe(u8, key_buf.items);
            if (seen.contains(key)) {
                self.allocator.free(key);
                continue;
            }
            try seen.put(key, {});

            const kind: i64 = switch (s.kind) {
                .method => 2,
                .field, .property => 5,
                .enumMember => 20,
                else => 6,
            };

            const detail: ?[]u8 = blk: {
                if (s.kind == .field or s.kind == .property) {
                    if (s.value_type) |vt| {
                        if (s.container_type) |declared_container| {
                            if (try self.specializeMemberTypeForReceiver(declared_container, container_type, vt)) |specialized_vt| {
                                break :blk specialized_vt;
                            }
                        }
                        break :blk try self.allocator.dupe(u8, vt);
                    }
                }
                if (s.kind == .enumMember) {
                    var db = ArrayList(u8).init(self.allocator);
                    defer db.deinit();
                    try db.print("{s}.{s}", .{ container_type, s.name });
                    break :blk try self.allocator.dupe(u8, db.items);
                }
                if (s.kind == .method) {
                    if (s.detail) |d| break :blk try self.allocator.dupe(u8, d);
                    var db = ArrayList(u8).init(self.allocator);
                    defer db.deinit();
                    try db.print("{s}.{s}", .{ container_type, s.name });
                    break :blk try self.allocator.dupe(u8, db.items);
                }
                break :blk null;
            };

            try items.append(.{
                .label = try self.allocator.dupe(u8, s.name),
                .kind = kind,
                .detail = detail,
            });
        }
    }

    fn appendMemberFieldCompletionsFromTokens(
        self: *LspServer,
        items: *ArrayList(CompletionItem),
        seen: *std.StringHashMap(void),
        idx: *const Index,
        container_type: []const u8,
        prefix: []const u8,
    ) !void {
        const nextNonComment = struct {
            fn call(tokens: []const TokenLite, start_index: usize) ?usize {
                var i = start_index;
                while (i < tokens.len) : (i += 1) {
                    if (tokens[i].kind != .comment) return i;
                }
                return null;
            }
        }.call;

        const isIdentLite = struct {
            fn call(t: TokenLite) bool {
                return t.kind == .identifier;
            }
        }.call;

        const isSymbolLite = struct {
            fn call(t: TokenLite, ch: u8) bool {
                return (t.kind == .symbol or t.kind == .operator) and t.text.len == 1 and t.text[0] == ch;
            }
        }.call;

        const isTypeLike = struct {
            fn call(t: TokenLite) bool {
                if (t.kind == .identifier) return true;
                if (t.kind != .keyword) return false;
                const s = t.text;
                return std.mem.eql(u8, s, "num") or std.mem.eql(u8, s, "dec") or std.mem.eql(u8, s, "str") or std.mem.eql(u8, s, "bin") or std.mem.eql(u8, s, "chr") or std.mem.eql(u8, s, "raw") or std.mem.eql(u8, s, "void") or std.mem.eql(u8, s, "f32") or std.mem.eql(u8, s, "f64") or std.mem.eql(u8, s, "i8") or std.mem.eql(u8, s, "i16") or std.mem.eql(u8, s, "i32") or std.mem.eql(u8, s, "i64") or std.mem.eql(u8, s, "u8") or std.mem.eql(u8, s, "u16") or std.mem.eql(u8, s, "u32") or std.mem.eql(u8, s, "u64");
            }
        }.call;

        const target_type = baseTypeNameForLookup(container_type);

        var i: usize = 0;
        while (i < idx.tokens.len) : (i += 1) {
            if (idx.tokens[i].kind != .keyword or !std.mem.eql(u8, idx.tokens[i].text, "compound")) continue;

            const name_i = nextNonComment(idx.tokens, i + 1) orelse continue;
            if (!isIdentLite(idx.tokens[name_i])) continue;
            if (!std.mem.eql(u8, baseTypeNameForLookup(idx.tokens[name_i].text), target_type)) continue;

            var j_opt = nextNonComment(idx.tokens, name_i + 1);
            while (j_opt) |j| {
                if (!isSymbolLite(idx.tokens[j], '{')) {
                    j_opt = nextNonComment(idx.tokens, j + 1);
                    continue;
                }

                var depth: i64 = 1;
                var k: usize = j + 1;
                while (k < idx.tokens.len and depth > 0) : (k += 1) {
                    const tk = idx.tokens[k];
                    if (isSymbolLite(tk, '{')) depth += 1;
                    if (isSymbolLite(tk, '}')) depth -= 1;
                    if (depth != 1) continue;
                    if (!isTypeLike(tk)) continue;

                    const field_name_i = fieldNameIndexAfterTypeLite(idx.tokens, k) orelse continue;
                    if (!isIdentLite(idx.tokens[field_name_i])) continue;
                    const after_name_i = nextNonTrivialTokenLite(idx.tokens, field_name_i + 1) orelse continue;
                    if (!isSymbolLite(idx.tokens[after_name_i], ';')) continue;

                    const fname = idx.tokens[field_name_i].text;
                    if (prefix.len != 0 and !std.mem.startsWith(u8, fname, prefix)) {
                        k = after_name_i;
                        continue;
                    }

                    var key_buf = ArrayList(u8).init(self.allocator);
                    defer key_buf.deinit();
                    try key_buf.print("field:{s}", .{fname});
                    const key = try self.allocator.dupe(u8, key_buf.items);
                    if (seen.contains(key)) {
                        self.allocator.free(key);
                        k = after_name_i;
                        continue;
                    }
                    try seen.put(key, {});

                    const detail = try self.allocator.dupe(u8, tk.text);
                    try items.append(.{
                        .label = try self.allocator.dupe(u8, fname),
                        .kind = 5,
                        .detail = detail,
                    });

                    k = after_name_i;
                }

                break;
            }
        }

        // Add local enum variants from `enum Type { ... }` blocks.
        i = 0;
        while (i < idx.tokens.len) : (i += 1) {
            if (idx.tokens[i].kind != .keyword or !std.mem.eql(u8, idx.tokens[i].text, "enum")) continue;

            const name_i = nextNonComment(idx.tokens, i + 1) orelse continue;
            if (!isIdentLite(idx.tokens[name_i])) continue;
            if (!std.mem.eql(u8, baseTypeNameForLookup(idx.tokens[name_i].text), target_type)) continue;

            var j_opt = nextNonComment(idx.tokens, name_i + 1);
            while (j_opt) |j| {
                if (!isSymbolLite(idx.tokens[j], '{')) {
                    j_opt = nextNonComment(idx.tokens, j + 1);
                    continue;
                }

                var depth: i64 = 1;
                var k: usize = j + 1;
                while (k < idx.tokens.len and depth > 0) : (k += 1) {
                    const tk = idx.tokens[k];
                    if (isSymbolLite(tk, '{')) {
                        depth += 1;
                        continue;
                    }
                    if (isSymbolLite(tk, '}')) {
                        depth -= 1;
                        continue;
                    }
                    if (depth != 1 or !isIdentLite(tk)) continue;

                    const vname = tk.text;
                    if (prefix.len != 0 and !std.mem.startsWith(u8, vname, prefix)) continue;

                    var key_buf = ArrayList(u8).init(self.allocator);
                    defer key_buf.deinit();
                    try key_buf.print("enumMember:{s}", .{vname});
                    const key = try self.allocator.dupe(u8, key_buf.items);
                    if (seen.contains(key)) {
                        self.allocator.free(key);
                        continue;
                    }
                    try seen.put(key, {});

                    var db = ArrayList(u8).init(self.allocator);
                    defer db.deinit();
                    try db.print("{s}.{s}", .{ container_type, vname });

                    try items.append(.{
                        .label = try self.allocator.dupe(u8, vname),
                        .kind = 20,
                        .detail = try self.allocator.dupe(u8, db.items),
                    });
                }
                break;
            }
        }

        // Add local methods from `impl Type { ... }` blocks in the same doc.
        i = 0;
        while (i < idx.tokens.len) : (i += 1) {
            if (idx.tokens[i].kind != .keyword or !std.mem.eql(u8, idx.tokens[i].text, "impl")) continue;

            const type_i = nextNonComment(idx.tokens, i + 1) orelse continue;
            if (!isIdentLite(idx.tokens[type_i])) continue;
            if (!std.mem.eql(u8, idx.tokens[type_i].text, target_type)) continue;

            var j_opt = nextNonComment(idx.tokens, type_i + 1);
            while (j_opt) |j| {
                if (!isSymbolLite(idx.tokens[j], '{')) {
                    j_opt = nextNonComment(idx.tokens, j + 1);
                    continue;
                }

                var depth: i64 = 1;
                var k: usize = j + 1;
                while (k < idx.tokens.len and depth > 0) : (k += 1) {
                    const tk = idx.tokens[k];
                    if (isSymbolLite(tk, '{')) {
                        depth += 1;
                        continue;
                    }
                    if (isSymbolLite(tk, '}')) {
                        depth -= 1;
                        continue;
                    }
                    if (depth != 1) continue;
                    if (!isIdentLite(tk)) continue;

                    const after_name_i = nextNonComment(idx.tokens, k + 1) orelse continue;
                    if (!isSymbolLite(idx.tokens[after_name_i], '(')) continue;

                    const mname = tk.text;
                    if (prefix.len != 0 and !std.mem.startsWith(u8, mname, prefix)) continue;

                    var key_buf = ArrayList(u8).init(self.allocator);
                    defer key_buf.deinit();
                    try key_buf.print("method:{s}", .{mname});
                    const key = try self.allocator.dupe(u8, key_buf.items);
                    if (seen.contains(key)) {
                        self.allocator.free(key);
                        continue;
                    }
                    try seen.put(key, {});

                    var db = ArrayList(u8).init(self.allocator);
                    defer db.deinit();
                    try db.print("{s}.{s}", .{ container_type, mname });

                    try items.append(.{
                        .label = try self.allocator.dupe(u8, mname),
                        .kind = 2,
                        .detail = try self.allocator.dupe(u8, db.items),
                    });
                }
                break;
            }
        }
    }

    fn filterMemberCompletionItemsToLocalType(
        self: *LspServer,
        items: *ArrayList(CompletionItem),
        idx: *const Index,
        doc_text: []const u8,
        container_type: []const u8,
    ) !void {
        const target_type = baseTypeNameForLookup(container_type);
        if (!hasTypeDeclarationInTokens(idx, target_type) and !hasTypeDeclarationInText(doc_text, target_type)) return;

        var allowed = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = allowed.iterator();
            while (it.next()) |e| self.allocator.free(e.key_ptr.*);
            allowed.deinit();
        }

        for (idx.symbols) |s| {
            const declared_container = s.container_type orelse continue;
            if (!std.mem.eql(u8, baseTypeNameForLookup(declared_container), target_type)) continue;
            switch (s.kind) {
                .field, .property, .method, .enumMember => {
                    const key = try self.allocator.dupe(u8, s.name);
                    if (allowed.contains(key)) {
                        self.allocator.free(key);
                        continue;
                    }
                    try allowed.put(key, {});
                },
                else => {},
            }
        }

        const nextNonComment = struct {
            fn call(tokens: []const TokenLite, start_index: usize) ?usize {
                var i = start_index;
                while (i < tokens.len) : (i += 1) {
                    if (tokens[i].kind != .comment) return i;
                }
                return null;
            }
        }.call;
        const isIdentLite = struct {
            fn call(t: TokenLite) bool {
                return t.kind == .identifier;
            }
        }.call;
        const isSymbolLite = struct {
            fn call(t: TokenLite, ch: u8) bool {
                return (t.kind == .symbol or t.kind == .operator) and t.text.len == 1 and t.text[0] == ch;
            }
        }.call;

        var i: usize = 0;
        while (i < idx.tokens.len) : (i += 1) {
            if (idx.tokens[i].kind != .keyword or !std.mem.eql(u8, idx.tokens[i].text, "compound")) continue;

            const name_i = nextNonComment(idx.tokens, i + 1) orelse continue;
            if (!isIdentLite(idx.tokens[name_i])) continue;
            if (!std.mem.eql(u8, baseTypeNameForLookup(idx.tokens[name_i].text), target_type)) continue;

            var j_opt = nextNonComment(idx.tokens, name_i + 1);
            while (j_opt) |j| {
                if (!isSymbolLite(idx.tokens[j], '{')) {
                    j_opt = nextNonComment(idx.tokens, j + 1);
                    continue;
                }

                var depth: i64 = 1;
                var k: usize = j + 1;
                while (k < idx.tokens.len and depth > 0) : (k += 1) {
                    const tk = idx.tokens[k];
                    if (isSymbolLite(tk, '{')) depth += 1;
                    if (isSymbolLite(tk, '}')) depth -= 1;
                    if (depth != 1) continue;
                    if (tk.kind != .identifier and tk.kind != .keyword) continue;

                    // Inline method shape at the top level of the compound body:
                    // `name(...)` — recognise it so inline methods aren't filtered
                    // out of member completion for this compound. (An `async` modifier
                    // may precede the name.)
                    if (isIdentLite(tk)) {
                        const after_ident_i = nextNonTrivialTokenLite(idx.tokens, k + 1) orelse idx.tokens.len;
                        if (after_ident_i < idx.tokens.len and isSymbolLite(idx.tokens[after_ident_i], '(')) {
                            const mkey = try self.allocator.dupe(u8, tk.text);
                            if (allowed.contains(mkey)) {
                                self.allocator.free(mkey);
                            } else {
                                try allowed.put(mkey, {});
                            }
                            // Fall through: also try the field shape below (harmless;
                            // it will fail the `;` check for a method).
                        }
                    }

                    const field_name_i = fieldNameIndexAfterTypeLite(idx.tokens, k) orelse continue;
                    if (!isIdentLite(idx.tokens[field_name_i])) continue;
                    const after_name_i = nextNonTrivialTokenLite(idx.tokens, field_name_i + 1) orelse continue;
                    if (!isSymbolLite(idx.tokens[after_name_i], ';')) continue;

                    const key = try self.allocator.dupe(u8, idx.tokens[field_name_i].text);
                    if (allowed.contains(key)) {
                        self.allocator.free(key);
                    } else {
                        try allowed.put(key, {});
                    }
                    k = after_name_i;
                }
                break;
            }
        }

        i = 0;
        while (i < idx.tokens.len) : (i += 1) {
            if (idx.tokens[i].kind != .keyword or !std.mem.eql(u8, idx.tokens[i].text, "enum")) continue;

            const name_i = nextNonComment(idx.tokens, i + 1) orelse continue;
            if (!isIdentLite(idx.tokens[name_i])) continue;
            if (!std.mem.eql(u8, baseTypeNameForLookup(idx.tokens[name_i].text), target_type)) continue;

            var j_opt = nextNonComment(idx.tokens, name_i + 1);
            while (j_opt) |j| {
                if (!isSymbolLite(idx.tokens[j], '{')) {
                    j_opt = nextNonComment(idx.tokens, j + 1);
                    continue;
                }

                var depth: i64 = 1;
                var k: usize = j + 1;
                while (k < idx.tokens.len and depth > 0) : (k += 1) {
                    const tk = idx.tokens[k];
                    if (isSymbolLite(tk, '{')) {
                        depth += 1;
                        continue;
                    }
                    if (isSymbolLite(tk, '}')) {
                        depth -= 1;
                        continue;
                    }
                    if (depth != 1 or !isIdentLite(tk)) continue;

                    const key = try self.allocator.dupe(u8, tk.text);
                    if (allowed.contains(key)) {
                        self.allocator.free(key);
                    } else {
                        try allowed.put(key, {});
                    }
                }
                break;
            }
        }

        i = 0;
        while (i < idx.tokens.len) : (i += 1) {
            if (idx.tokens[i].kind != .keyword or !std.mem.eql(u8, idx.tokens[i].text, "impl")) continue;

            const type_i = nextNonComment(idx.tokens, i + 1) orelse continue;
            if (!isIdentLite(idx.tokens[type_i])) continue;
            if (!std.mem.eql(u8, idx.tokens[type_i].text, target_type)) continue;

            var j_opt = nextNonComment(idx.tokens, type_i + 1);
            while (j_opt) |j| {
                if (!isSymbolLite(idx.tokens[j], '{')) {
                    j_opt = nextNonComment(idx.tokens, j + 1);
                    continue;
                }

                var depth: i64 = 1;
                var k: usize = j + 1;
                while (k < idx.tokens.len and depth > 0) : (k += 1) {
                    const tk = idx.tokens[k];
                    if (isSymbolLite(tk, '{')) {
                        depth += 1;
                        continue;
                    }
                    if (isSymbolLite(tk, '}')) {
                        depth -= 1;
                        continue;
                    }
                    if (depth != 1 or !isIdentLite(tk)) continue;

                    const after_name_i = nextNonComment(idx.tokens, k + 1) orelse continue;
                    if (!isSymbolLite(idx.tokens[after_name_i], '(')) continue;

                    const key = try self.allocator.dupe(u8, tk.text);
                    if (allowed.contains(key)) {
                        self.allocator.free(key);
                    } else {
                        try allowed.put(key, {});
                    }
                }
                break;
            }
        }

        var ri: usize = items.items.len;
        while (ri > 0) {
            ri -= 1;
            const it = items.items[ri];
            if (allowed.contains(it.label)) continue;

            self.allocator.free(it.label);
            if (it.detail) |d| self.allocator.free(d);
            if (it.insertText) |ins| self.allocator.free(ins);
            if (it.labelDetails) |ld| {
                if (ld.detail) |d| self.allocator.free(d);
                if (ld.description) |d| self.allocator.free(d);
            }
            if (it.filterText) |ft| self.allocator.free(ft);
            _ = items.orderedRemove(ri);
        }
    }

    const DefinitionMode = enum {
        definition,
        type_definition,
    };

    fn handleDefinition(self: *LspServer, mode: DefinitionMode, id_val: ?std.json.Value, params_val: ?std.json.Value) !void {
        const parsed = try parseTextDocPosition(params_val);
        if (parsed == null) {
            try self.sendResponseJson(id_val, "[]");
            return;
        }
        const uri = parsed.?.uri;
        const doc = self.docs.get(uri) orelse {
            try self.sendResponseJson(id_val, "[]");
            return;
        };
        // Convert the client's UTF-16-based position into the byte-column
        // convention every token/symbol range in the index already uses —
        // see `normalizePositionToByteColumns`. Every use of `pos` in this
        // handler (directly and via `guessVariableType`/
        // `tryHandleMemberChainDefinition`/`findBestDefinition`) is a
        // token/symbol-range comparison, never raw text-slicing, so this
        // conversion is safe for the whole function body.
        const pos = normalizePositionToByteColumns(doc.text, parsed.?.pos);
        const idx = doc.index orelse {
            try self.sendResponseJson(id_val, "[]");
            return;
        };

        const tok_i = findTokenIndexAt(idx.tokens, pos) orelse {
            try self.sendResponseJson(id_val, "[]");
            return;
        };

        const tok = idx.tokens[tok_i];

        if (self.debug_definitions) {
            self.dbg(true, "defs", "definition request uri={s} pos=({d},{d}) tok='{s}' kind={s}", .{ uri, pos.line, pos.character, tok.text, @tagName(tok.kind) });
        }

        if (mode == .type_definition) {
            // Best-effort: resolve the declared type for an identifier, then jump to that type's definition.
            if (tok.kind != .identifier) {
                try self.sendResponseJson(id_val, "[]");
                return;
            }

            // 1) If the identifier itself is a known type name, go to its declaration.
            if (self.isKnownTypeName(uri, tok.text)) {
                if (self.findTypeDefinitionAnyDoc(uri, tok.text)) |hit| {
                    const locs = [_]Location{.{ .uri = hit.uri, .range = hit.sym.selection_range }};
                    const json = try jsonStringifyAlloc(self.allocator, locs);
                    defer self.allocator.free(json);
                    try self.sendResponseJson(id_val, json);
                    return;
                }
                try self.sendResponseJson(id_val, "[]");
                return;
            }

            // 2) If it's a variable, use its value_type to locate the type definition.
            const var_type = self.guessVariableType(idx, uri, tok.text, pos);
            if (var_type) |vt| {
                if (self.isKnownTypeName(uri, vt)) {
                    if (self.findTypeDefinitionAnyDoc(uri, vt)) |hit| {
                        const locs = [_]Location{.{ .uri = hit.uri, .range = hit.sym.selection_range }};
                        const json = try jsonStringifyAlloc(self.allocator, locs);
                        defer self.allocator.free(json);
                        try self.sendResponseJson(id_val, json);
                        return;
                    }
                }
            }

            try self.sendResponseJson(id_val, "[]");
            return;
        }

        // Import path definition: `imp std.c.io;` (identifier chain)
        if (tok.kind == .identifier or isDotToken(tok)) {
            if (try self.trySendImportDefinition(id_val, uri, idx, tok_i)) {
                return;
            }
        }

        if (tok.kind != .identifier) {
            try self.sendResponseJson(id_val, "[]");
            return;
        }

        // Enum dot-shorthand definition: `.Variant` -> enum member declaration.
        {
            const merged = (tok.text.len > 1 and tok.text[0] == '.');
            const is_shorthand = merged or (tok_i > 0 and isDotToken(idx.tokens[tok_i - 1]));
            const not_member = merged or (tok_i < 2 or idx.tokens[tok_i - 2].kind != .identifier);
            if (is_shorthand and not_member) {
                const variant_name = if (merged) tok.text[1..] else tok.text;
                if (self.guessEnumTypeForDotShorthand(uri, idx, tok_i)) |enum_name| {
                    if (self.findMemberByContainer(uri, enum_name, variant_name, .enumMember)) |h| {
                        const locs = [_]Location{.{ .uri = h.uri, .range = h.sym.selection_range }};
                        const json = try jsonStringifyAlloc(self.allocator, locs);
                        defer self.allocator.free(json);
                        try self.sendResponseJson(id_val, json);
                        return;
                    }
                }
            }
        }

        // stdlib namespace definition: `std.<module>.<symbol>`.
        if (try self.trySendStdNamespaceDefinition(id_val, uri, idx, tok_i)) {
            return;
        }

        // Alias definition: `imp foo.bar as m;` => `m`.
        if (try self.trySendAliasDefinition(id_val, uri, idx, tok_i)) {
            return;
        }

        // Member chain definition: `a.b.c` or `obj.method(...)`
        // We resolve by:
        // 1) inferring the base type (self / local var / known type),
        // 2) walking intermediate fields to get the final receiver type,
        // 3) looking up field/method declarations in the workspace index.
        if (try self.tryHandleMemberChainDefinition(id_val, uri, pos, idx, tok_i)) {
            return;
        }

        // Prefer definition in the current document.
        if (findBestDefinition(idx.symbols, tok.text, pos)) |def| {
            const locs = [_]Location{.{ .uri = uri, .range = def.selection_range }};
            const json = try jsonStringifyAlloc(self.allocator, locs);
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return;
        }

        // Fall back to global definition in direct imports.
        if (self.findAnyGlobalDefinitionInDirectImports(uri, tok.text)) |hit| {
            const locs = [_]Location{.{ .uri = hit.uri, .range = hit.sym.selection_range }};
            const json = try jsonStringifyAlloc(self.allocator, locs);
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return;
        }

        // Final fallback for types: if the identifier is a known type name anywhere in the workspace,
        // jump to its declaration even if the current file forgot to import it.
        if (self.isKnownTypeName(uri, tok.text)) {
            if (self.findTypeDefinitionAnyDoc(uri, tok.text)) |hit| {
                const locs = [_]Location{.{ .uri = hit.uri, .range = hit.sym.selection_range }};
                const json = try jsonStringifyAlloc(self.allocator, locs);
                defer self.allocator.free(json);
                try self.sendResponseJson(id_val, json);
                return;
            }
        }

        try self.sendResponseJson(id_val, "[]");
    }

    fn trySendImportDefinition(self: *LspServer, id_val: ?std.json.Value, current_uri: []const u8, idx: *const Index, tok_i: usize) !bool {
        // Scan backwards to find an `imp` keyword without crossing ';'
        var imp_i_opt: ?usize = null;
        var k: isize = @intCast(tok_i);
        while (k >= 0) : (k -= 1) {
            const t = idx.tokens[@intCast(k)];
            if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, ";")) break;
            if (t.kind == .keyword and std.mem.eql(u8, t.text, "imp")) {
                imp_i_opt = @intCast(k);
                break;
            }
        }
        if (imp_i_opt == null) return false;

        const imp_i = imp_i_opt.?;

        // Parse import segments: `imp <ident> ('.' <ident>)* ';'`
        var segs = ArrayList(struct { name: []const u8, tok_i: usize }).init(self.allocator);
        defer segs.deinit();

        var i: usize = imp_i + 1;
        while (i < idx.tokens.len) : (i += 1) {
            const t = idx.tokens[i];
            if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, ";")) break;
            if (t.kind == .identifier) {
                try segs.append(.{ .name = t.text, .tok_i = i });
            }
        }
        if (segs.items.len == 0) return false;

        // Determine which segment the user clicked.
        var selected_seg_index_opt: ?usize = null;
        const cur_tok = idx.tokens[tok_i];
        if (cur_tok.kind == .identifier) {
            for (segs.items, 0..) |s, si| {
                if (s.tok_i == tok_i) {
                    selected_seg_index_opt = si;
                    break;
                }
            }
        } else if (isDotToken(cur_tok)) {
            // If clicking on '.', prefer the next identifier segment.
            var next_ident: ?usize = null;
            var prev_ident: ?usize = null;
            var k2: isize = @intCast(tok_i);
            while (k2 >= 0) : (k2 -= 1) {
                const t = idx.tokens[@intCast(k2)];
                if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, ";")) break;
                if (t.kind == .identifier) {
                    prev_ident = @intCast(k2);
                    break;
                }
            }
            var k3: usize = tok_i + 1;
            while (k3 < idx.tokens.len) : (k3 += 1) {
                const t = idx.tokens[k3];
                if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, ";")) break;
                if (t.kind == .identifier) {
                    next_ident = k3;
                    break;
                }
            }
            const chosen_ident = next_ident orelse prev_ident;
            if (chosen_ident) |ci| {
                for (segs.items, 0..) |s, si| {
                    if (s.tok_i == ci) {
                        selected_seg_index_opt = si;
                        break;
                    }
                }
            }
        }
        if (selected_seg_index_opt == null) return false;
        const selected_seg_index = selected_seg_index_opt.?;

        const current_path = uriToPath(self.allocator, current_uri) catch return false;
        defer self.allocator.free(current_path);
        const current_dir = std.fs.path.dirname(current_path) orelse return false;

        // Fast path: hovering the first import segment (e.g. `imp mylib.foo;` on `mylib`).
        // Show `<current_dir>/<segment>/README.md` when present.
        const is_first_segment = blk: {
            var scan_tok_i: usize = imp_i + 1;
            while (scan_tok_i < idx.tokens.len) : (scan_tok_i += 1) {
                const t2 = idx.tokens[scan_tok_i];
                if ((t2.kind == .symbol or t2.kind == .operator) and std.mem.eql(u8, t2.text, ";")) break;
                if (t2.kind == .identifier) break :blk (scan_tok_i == tok_i);
            }
            break :blk false;
        };
        if (is_first_segment) {
            const seg_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ current_dir, idx.tokens[tok_i].text });
            defer self.allocator.free(seg_dir);
            const readme_path_fast = try std.fs.path.join(self.allocator, &[_][]const u8{ seg_dir, "README.md" });
            defer self.allocator.free(readme_path_fast);
            if (self.tryOpenExistingFile(readme_path_fast)) {
                const readme_text = blk: {
                    if (std.fs.path.isAbsolute(readme_path_fast)) {
                        var f = std.Io.Dir.openFileAbsolute(globalIo(), readme_path_fast, .{}) catch return false;
                        defer f.close(globalIo());
                        break :blk fileReadAlloc(self.allocator, f, 128 * 1024) catch return false;
                    }
                    break :blk std.Io.Dir.cwd().readFileAlloc(globalIo(), readme_path_fast, self.allocator, .limited(128 * 1024)) catch return false;
                };
                defer self.allocator.free(readme_text);

                const hover: Hover = .{ .contents = .{ .value = readme_text }, .range = idx.tokens[tok_i].range };
                const json = try jsonStringifyAlloc(self.allocator, hover);
                defer self.allocator.free(json);
                try self.sendResponseJson(id_val, json);
                return true;
            }
        }

        // Resolve filesystem base and relative segments.
        var base_segs = ArrayList([]const u8).init(self.allocator);
        defer base_segs.deinit();

        var rel_from: usize = 0;
        if (std.mem.eql(u8, segs.items[0].name, "std")) {
            var stdlib_root = self.getStdlibRootPath() orelse null;
            if (stdlib_root == null) {
                self.tryStdlibRootFromCurrentDoc(current_uri);
                stdlib_root = self.getStdlibRootPath() orelse null;
            }
            const root = stdlib_root orelse return false;

            // If the user clicked `std` itself, jump to stdlib README (nice, read-only-ish entrypoint).
            if (selected_seg_index == 0) {
                const readme_path = try std.fs.path.join(self.allocator, &.{ root, "README.md" });
                defer self.allocator.free(readme_path);
                if (std.fs.path.isAbsolute(readme_path)) {
                    var f = std.Io.Dir.openFileAbsolute(globalIo(), readme_path, .{}) catch return false;
                    f.close(globalIo());
                } else {
                    std.Io.Dir.cwd().access(globalIo(), readme_path, .{}) catch return false;
                }
                const target_uri = try pathToUri(self.allocator, readme_path);
                defer self.allocator.free(target_uri);
                const locs = [_]Location{.{
                    .uri = target_uri,
                    .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
                }};
                const json = try jsonStringifyAlloc(self.allocator, locs);
                defer self.allocator.free(json);
                try self.sendResponseJson(id_val, json);
                return true;
            }

            try base_segs.append(root);
            try base_segs.append("std");

            rel_from = 1;
        } else {
            try base_segs.append(current_dir);
            rel_from = 0;
        }

        // Build a directory path for the selected segment.
        var sel_path_segs = ArrayList([]const u8).init(self.allocator);
        defer sel_path_segs.deinit();
        try sel_path_segs.appendSlice(base_segs.items);
        {
            var si: usize = rel_from;
            while (si <= selected_seg_index) : (si += 1) {
                try sel_path_segs.append(segs.items[si].name);
            }
        }

        const sel_joined = try std.fs.path.join(self.allocator, sel_path_segs.items);
        defer self.allocator.free(sel_joined);

        const is_last = selected_seg_index == segs.items.len - 1;

        if (is_last) {
            // Final segment: prefer module file, but if it doesn't exist treat it as a directory.
            const file_path = try std.mem.concat(self.allocator, u8, &[_][]const u8{ sel_joined, ".fn" });
            defer self.allocator.free(file_path);
            if (self.tryOpenExistingFile(file_path)) {
                const target_uri = try pathToUri(self.allocator, file_path);
                defer self.allocator.free(target_uri);
                self.ensureDocIndexedFromDisk(target_uri) catch {};
                const locs = [_]Location{.{
                    .uri = target_uri,
                    .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
                }};
                const json = try jsonStringifyAlloc(self.allocator, locs);
                defer self.allocator.free(json);
                try self.sendResponseJson(id_val, json);
                return true;
            }
            // Else fall through to directory handling.
        }

        // Directory segment: if README exists, prefer it.
        const dir_readme_path = try std.fs.path.join(self.allocator, &[_][]const u8{ sel_joined, "README.md" });
        defer self.allocator.free(dir_readme_path);
        if (self.tryOpenExistingFile(dir_readme_path)) {
            const target_uri = try pathToUri(self.allocator, dir_readme_path);
            defer self.allocator.free(target_uri);
            const locs = [_]Location{.{
                .uri = target_uri,
                .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
            }};
            const json = try jsonStringifyAlloc(self.allocator, locs);
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return true;
        }

        // Directory segment: return a list of modules in this directory.
        var dir = if (std.fs.path.isAbsolute(sel_joined))
            (std.Io.Dir.openDirAbsolute(globalIo(), sel_joined, .{ .iterate = true }) catch return false)
        else
            (std.Io.Dir.cwd().openDir(globalIo(), sel_joined, .{ .iterate = true }) catch return false);
        defer dir.close(globalIo());

        var locs_list = ArrayList(Location).init(self.allocator);
        defer {
            for (locs_list.items) |l| self.allocator.free(l.uri);
            locs_list.deinit();
        }

        var it = dir.iterate();
        while (try it.next(globalIo())) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".fn")) continue;
            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ sel_joined, entry.name });
            defer self.allocator.free(full_path);
            const u = try pathToUri(self.allocator, full_path);
            errdefer self.allocator.free(u);
            try locs_list.append(.{ .uri = u, .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } } });
        }

        if (locs_list.items.len == 0) return false;

        // Best-effort index so peek list is fast.
        for (locs_list.items) |l| {
            self.ensureDocIndexedFromDisk(l.uri) catch {};
        }

        const json = try jsonStringifyAlloc(self.allocator, locs_list.items);
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
        return true;
    }

    fn trySendAliasDefinition(self: *LspServer, id_val: ?std.json.Value, current_uri: []const u8, idx: *const Index, tok_i: usize) !bool {
        if (idx.tokens[tok_i].kind != .identifier) return false;

        const alias_name = idx.tokens[tok_i].text;
        const info = self.findAliasedImportSpecAndRange(idx, alias_name) orelse return false;
        defer self.allocator.free(info.spec);

        var locs = ArrayList(Location).init(self.allocator);
        defer locs.deinit();

        try locs.append(.{ .uri = current_uri, .range = info.range });

        var resolved_uri: ?[]u8 = null;
        if (self.resolveImportUri(current_uri, info.spec) catch null) |target_uri| {
            resolved_uri = target_uri;
            self.ensureDocIndexedFromDisk(target_uri) catch {};
            try locs.append(.{ .uri = target_uri, .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } } });
        }

        const json = try jsonStringifyAlloc(self.allocator, locs.items);
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);

        if (resolved_uri) |u| self.allocator.free(u);
        return true;
    }

    fn trySendImportNamespaceHover(self: *LspServer, id_val: ?std.json.Value, current_uri: []const u8, idx: *const Index, pos: Position, tok_i: usize) !bool {
        if (idx.tokens[tok_i].kind != .identifier) return false;

        // Scan backwards to find an `imp` keyword without crossing ';'
        var imp_i_opt: ?usize = null;
        var k: isize = @intCast(tok_i);
        while (k >= 0) : (k -= 1) {
            const t = idx.tokens[@intCast(k)];
            if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, ";")) break;
            if (t.kind == .keyword and std.mem.eql(u8, t.text, "imp")) {
                imp_i_opt = @intCast(k);
                break;
            }
        }
        if (imp_i_opt == null) return false;
        const imp_i = imp_i_opt.?;

        // Resolve the full import spec including dot-runs like `..` / `....`.
        const spec = try self.parseImportSpecFromTokens(idx, imp_i) orelse return false;
        defer self.allocator.free(spec);

        // If this is a stdlib import, let std namespace hover handle it.
        if (std.mem.startsWith(u8, spec, "std") and (spec.len == 3 or spec[3] == '.')) return false;

        const parsed = struct {
            fn addSegments(out: *ArrayList([]const u8), s: []const u8) !void {
                var start: usize = 0;
                var i: usize = 0;
                while (i < s.len) {
                    if (s[i] != '.') {
                        i += 1;
                        continue;
                    }

                    // Flush preceding identifier segment.
                    if (i > start) {
                        const seg = std.mem.trim(u8, s[start..i], " \t\r\n\"");
                        if (seg.len != 0) try out.append(seg);
                    }

                    // Consume dot run.
                    var j = i;
                    while (j < s.len and s[j] == '.') : (j += 1) {}
                    const run_len = j - i;
                    const parents = run_len / 2;
                    var p: usize = 0;
                    while (p < parents) : (p += 1) {
                        try out.append("..");
                    }

                    i = j;
                    start = i;
                }

                if (s.len > start) {
                    const seg = std.mem.trim(u8, s[start..], " \t\r\n\"");
                    if (seg.len != 0) try out.append(seg);
                }
            }
        };

        var parts = ArrayList([]const u8).init(self.allocator);
        defer parts.deinit();
        try parsed.addSegments(&parts, spec);
        if (parts.items.len == 0) return false;

        // Collect identifier tokens in the import statement and locate which one is hovered.
        var ident_toks = ArrayList(usize).init(self.allocator);
        defer ident_toks.deinit();
        var scan_tok_i: usize = imp_i + 1;
        while (scan_tok_i < idx.tokens.len) : (scan_tok_i += 1) {
            const t = idx.tokens[scan_tok_i];
            if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, ";")) break;
            if (t.kind == .identifier) try ident_toks.append(scan_tok_i);
        }
        if (ident_toks.items.len == 0) return false;

        var selected_ident_ord_opt: ?usize = null;
        for (ident_toks.items, 0..) |ti, ord| {
            if (ti == tok_i) {
                selected_ident_ord_opt = ord;
                break;
            }
        }
        var selected_ident_ord: usize = selected_ident_ord_opt orelse 0;

        // Map identifier ordinal -> part index (skip parent segments "..").
        var non_parent_part_indices = ArrayList(usize).init(self.allocator);
        defer non_parent_part_indices.deinit();
        for (parts.items, 0..) |p, pi| {
            if (!std.mem.eql(u8, p, "..")) try non_parent_part_indices.append(pi);
        }
        if (non_parent_part_indices.items.len != ident_toks.items.len) {
            // Some lexers tokenize `mylib.foo` as a single identifier token.
            // Fall back to selecting the segment based on hover position within that token.
            if (ident_toks.items.len != 1) return false;
            const t = idx.tokens[tok_i];
            const dot_in_token = std.mem.indexOfScalar(u8, t.text, '.');
            if (dot_in_token == null) return false;

            if (pos.line != t.range.start.line) return false;
            if (pos.character < t.range.start.character) return false;
            const off: usize = @intCast(pos.character - t.range.start.character);

            var seg_ord: usize = 0;
            var start: usize = 0;
            var scan_i: usize = 0;
            while (scan_i <= t.text.len) : (scan_i += 1) {
                if (scan_i == t.text.len or t.text[scan_i] == '.') {
                    const seg_start = start;
                    const seg_end = scan_i;
                    if (off >= seg_start and off < seg_end) {
                        selected_ident_ord = seg_ord;
                        break;
                    }
                    // Cursor on dot: treat as next segment if possible.
                    if (off == scan_i and scan_i != t.text.len) {
                        selected_ident_ord = seg_ord + 1;
                        break;
                    }
                    seg_ord += 1;
                    start = scan_i + 1;
                }
            }
        }

        if (selected_ident_ord >= non_parent_part_indices.items.len) return false;
        const selected_part_index = non_parent_part_indices.items[selected_ident_ord];

        const current_path = uriToPath(self.allocator, current_uri) catch return false;
        defer self.allocator.free(current_path);
        const current_dir = std.fs.path.dirname(current_path) orelse return false;

        const has_parent_segments = blk: {
            for (parts.items) |p| {
                if (std.mem.eql(u8, p, "..")) break :blk true;
            }
            break :blk false;
        };
        const base_dir = if (!has_parent_segments and self.root_path != null) self.root_path.? else current_dir;

        // Build the filesystem path (no extension) for the selected segment.
        var path_segs = ArrayList([]const u8).init(self.allocator);
        defer path_segs.deinit();
        try path_segs.append(base_dir);
        var si: usize = 0;
        while (si <= selected_part_index) : (si += 1) {
            try path_segs.append(parts.items[si]);
        }

        const selected_path_no_ext = try std.fs.path.join(self.allocator, path_segs.items);
        defer self.allocator.free(selected_path_no_ext);

        // Prefer README hover for directory segments (and for last segment if it is a directory).
        const readme_path = try std.fs.path.join(self.allocator, &[_][]const u8{ selected_path_no_ext, "README.md" });
        defer self.allocator.free(readme_path);
        if (self.tryOpenExistingFile(readme_path)) {
            const readme_text = blk: {
                if (std.fs.path.isAbsolute(readme_path)) {
                    var f = std.Io.Dir.openFileAbsolute(globalIo(), readme_path, .{}) catch return false;
                    defer f.close(globalIo());
                    break :blk fileReadAlloc(self.allocator, f, 128 * 1024) catch return false;
                }
                break :blk std.Io.Dir.cwd().readFileAlloc(globalIo(), readme_path, self.allocator, .limited(128 * 1024)) catch return false;
            };
            defer self.allocator.free(readme_text);

            const hover: Hover = .{ .contents = .{ .value = readme_text }, .range = idx.tokens[tok_i].range };
            const json = try jsonStringifyAlloc(self.allocator, hover);
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return true;
        }

        // Otherwise, if this segment is a module file, show its leading `//` doc block.
        const module_file = try std.mem.concat(self.allocator, u8, &[_][]const u8{ selected_path_no_ext, ".fn" });
        defer self.allocator.free(module_file);
        if (!self.tryOpenExistingFile(module_file)) return false;

        const module_text = blk: {
            if (std.fs.path.isAbsolute(module_file)) {
                var f = std.Io.Dir.openFileAbsolute(globalIo(), module_file, .{}) catch return false;
                defer f.close(globalIo());
                break :blk fileReadAlloc(self.allocator, f, 128 * 1024) catch return false;
            }
            break :blk std.Io.Dir.cwd().readFileAlloc(globalIo(), module_file, self.allocator, .limited(128 * 1024)) catch return false;
        };
        defer self.allocator.free(module_text);

        var buf = ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        var wrote_doc: bool = false;
        var li: usize = 0;
        while (li < module_text.len) {
            const line_start = li;
            while (li < module_text.len and module_text[li] != '\n') : (li += 1) {}
            const line = std.mem.trimEnd(u8, module_text[line_start..@min(li, module_text.len)], "\r");
            if (line.len < 2 or line[0] != '/' or line[1] != '/') break;
            var content = line[2..];
            if (content.len != 0 and content[0] == ' ') content = content[1..];
            try buf.appendSlice(content);
            try buf.append('\n');
            wrote_doc = true;
            if (li < module_text.len and module_text[li] == '\n') li += 1;
        }
        if (!wrote_doc) {
            try buf.print("_module_\n", .{});
        }

        const hover: Hover = .{ .contents = .{ .value = buf.items }, .range = idx.tokens[tok_i].range };
        const json = try jsonStringifyAlloc(self.allocator, hover);
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
        return true;
    }

    fn tryHandleMemberChainDefinition(self: *LspServer, id_val: ?std.json.Value, uri: []const u8, pos: Position, idx: *const Index, tok_i: usize) !bool {
        if (tok_i == 0) return false;

        // Receiver-is-an-expression fast path: `recv.member` where `recv` ends in a
        // call/index (`doc.as_array().unwrap_or`). The pure-identifier chain walk below
        // can't cross `()`/`[]`, so resolve the receiver via the general expression
        // engine and jump straight to the member's definition.
        if (idx.tokens[tok_i].kind == .identifier and tok_i >= 2 and isDotToken(idx.tokens[tok_i - 1])) {
            const before = idx.tokens[tok_i - 2];
            const recv_is_expr = (before.kind == .symbol or before.kind == .operator) and
                (std.mem.eql(u8, before.text, ")") or std.mem.eql(u8, before.text, "]"));
            if (recv_is_expr) {
                const member_name = idx.tokens[tok_i].text;
                const recv_opt = self.resolveTypeOfExprEndingAtToken(idx, uri, pos, tok_i - 2);
                if (self.debug_definitions) {
                    self.dbg(true, "defs", "chained-recv def member='{s}' recv_type='{s}'", .{ member_name, recv_opt orelse "<null>" });
                }
                if (recv_opt) |recv_type| {
                    const base = baseTypeNameForLookup(recv_type);
                    const hit = self.findMemberByContainerFresh(uri, base, member_name, .method) orelse
                        self.findMemberByContainerFresh(uri, base, member_name, .field) orelse
                        self.findMemberByContainerFresh(uri, base, member_name, .property) orelse
                        self.findMemberByContainerFresh(uri, base, member_name, .enumMember);
                    if (self.debug_definitions) {
                        self.dbg(true, "defs", "chained-recv def base='{s}' hit={s}", .{ base, if (hit) |h| h.uri else "<none>" });
                    }
                    if (hit) |h| {
                        const locs = [_]Location{.{ .uri = h.uri, .range = h.sym.selection_range }};
                        const json = try jsonStringifyAlloc(self.allocator, locs);
                        defer self.allocator.free(json);
                        try self.sendResponseJson(id_val, json);
                        return true;
                    }
                }
            }
        }

        // Find chain start by scanning left through `. <ident>` pairs.
        var start_i: usize = tok_i;
        while (start_i >= 2) {
            const dot = idx.tokens[start_i - 1];
            const left = idx.tokens[start_i - 2];
            if ((dot.kind == .symbol or dot.kind == .operator) and std.mem.eql(u8, dot.text, ".") and left.kind == .identifier) {
                start_i -= 2;
                continue;
            }
            break;
        }
        if (start_i == tok_i) return false; // not part of a member chain

        // Collect identifier token indices in chain order.
        var ids = ArrayList(usize).init(self.allocator);
        defer ids.deinit();
        var j: usize = start_i;
        while (j <= tok_i) {
            if (idx.tokens[j].kind != .identifier) return false;
            try ids.append(j);
            if (j == tok_i) break;
            if (j + 2 > tok_i) return false;
            const dot = idx.tokens[j + 1];
            if (!((dot.kind == .symbol or dot.kind == .operator) and std.mem.eql(u8, dot.text, "."))) return false;
            j += 2;
        }
        if (ids.items.len < 2) return false;

        const base_name = idx.tokens[ids.items[0]].text;
        var current_type: ?[]const u8 = null;

        if (std.mem.eql(u8, base_name, "self")) {
            current_type = self.guessEnclosingImplType(idx, pos);
        } else if (self.isKnownTypeName(uri, base_name)) {
            current_type = base_name;
        } else {
            current_type = self.guessVariableType(idx, uri, base_name, pos);
        }

        if (current_type == null) return false;

        // Walk intermediate segments as fields.
        if (ids.items.len > 2) {
            var si: usize = 1;
            while (si + 1 < ids.items.len) : (si += 1) {
                const seg = idx.tokens[ids.items[si]].text;
                const field = self.findMemberByContainer(uri, current_type.?, seg, .field) orelse
                    self.findMemberByContainer(uri, current_type.?, seg, .property) orelse return false;
                if (field.sym.value_type) |vt| {
                    current_type = vt;
                } else {
                    return false;
                }
            }
        }

        const member_name = idx.tokens[ids.items[ids.items.len - 1]].text;

        // Prefer methods first when the member is used like a call: `name(`.
        var looks_like_call = false;
        if (tok_i + 1 < idx.tokens.len) {
            var ni = tok_i + 1;
            while (ni < idx.tokens.len and idx.tokens[ni].kind == .comment) : (ni += 1) {}
            if (ni < idx.tokens.len) {
                const nt = idx.tokens[ni];
                if ((nt.kind == .symbol or nt.kind == .operator) and std.mem.eql(u8, nt.text, "(")) {
                    looks_like_call = true;
                }
            }
        }

        const found = if (looks_like_call)
            (self.findMemberByContainer(uri, current_type.?, member_name, .method) orelse
                self.findMemberByContainer(uri, current_type.?, member_name, .field) orelse
                self.findMemberByContainer(uri, current_type.?, member_name, .property) orelse
                self.findMemberByContainer(uri, current_type.?, member_name, .enumMember))
        else
            (self.findMemberByContainer(uri, current_type.?, member_name, .field) orelse
                self.findMemberByContainer(uri, current_type.?, member_name, .property) orelse
                self.findMemberByContainer(uri, current_type.?, member_name, .enumMember) orelse
                self.findMemberByContainer(uri, current_type.?, member_name, .method));

        if (found) |hit| {
            const locs = [_]Location{.{ .uri = hit.uri, .range = hit.sym.selection_range }};
            const json = try jsonStringifyAlloc(self.allocator, locs);
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return true;
        }

        return false;
    }

    const MemberHit = struct { uri: []const u8, sym: SymbolLite };

    fn isSymbolVisibleFromUri(self: *LspServer, preferred_uri: []const u8, sym_uri: []const u8, s: SymbolLite) bool {
        if (std.mem.eql(u8, preferred_uri, sym_uri)) return true;
        if (!s.is_public) return false;

        if (s.container_type) |ct| {
            const ct_base = baseTypeNameForLookup(ct);
            if (self.docs.get(sym_uri)) |doc| {
                if (doc.index) |idx| {
                    for (idx.symbols) |ts| {
                        if (ts.container_fn_range != null) continue;
                        if (ts.container_type != null) continue;
                        if (!std.mem.eql(u8, ts.name, ct_base)) continue;
                        if (ts.kind != .struct_ and ts.kind != .interface and ts.kind != .enum_) continue;
                        if (!ts.is_public) return false;
                        break;
                    }
                }
            }
        }

        return true;
    }

    fn completionInsertTextForSymbol(self: *LspServer, s: SymbolLite) !?[]const u8 {
        if (!(s.kind == .struct_ or s.kind == .interface or s.kind == .enum_)) return null;
        return try makeGenericTypeInsertText(self.allocator, s.name, s.detail);
    }

    const CompletionInsert = struct {
        text: ?[]const u8 = null,
        /// 2 = Snippet (LSP InsertTextFormat).
        format: ?i64 = null,
    };

    /// Builds the completion insert text for a symbol. For functions and methods
    /// with a known signature this produces a snippet with parameter placeholders
    /// (`name(${1:arg}, ${2:arg})`), like gopls, so the editor drops the cursor
    /// into the first argument. Generic types keep their `<...>` snippet. Other
    /// symbols insert plainly (null text → editor uses the label).
    fn completionInsertForSymbol(self: *LspServer, s: SymbolLite) !CompletionInsert {
        if (s.kind == .struct_ or s.kind == .interface or s.kind == .enum_) {
            const t = try makeGenericTypeInsertText(self.allocator, s.name, s.detail);
            // makeGenericTypeInsertText returns a snippet (with ${..}) only when
            // the type has generic params; otherwise it returns null/plain.
            const is_snip = if (t) |tt| std.mem.indexOfScalar(u8, tt, '$') != null else false;
            return .{ .text = t, .format = if (is_snip) 2 else null };
        }
        if (s.kind == .function or s.kind == .method) {
            if (s.detail) |det| {
                if (try buildCallSnippet(self.allocator, s.name, det)) |snip| {
                    return .{ .text = snip, .format = 2 };
                }
            }
        }
        return .{};
    }

    /// Builds gopls-style structured label details for a symbol: the parameter
    /// list shown dimmed after the name, and the return type shown right-aligned.
    /// Returns null when there is nothing useful to show. Caller owns the strings.
    fn completionLabelDetailsForSymbol(self: *LspServer, s: SymbolLite) !?types.CompletionLabelDetails {
        if (s.kind != .function and s.kind != .method) return null;
        const det = s.detail orelse return null;
        const open = std.mem.indexOfScalar(u8, det, '(') orelse return null;
        const close = std.mem.lastIndexOfScalar(u8, det, ')') orelse return null;
        if (close < open) return null;

        const params = det[open .. close + 1]; // includes the parens
        const detail_owned = try self.allocator.dupe(u8, params);

        var desc_owned: ?[]const u8 = null;
        if (close + 1 < det.len) {
            const rtype = std.mem.trim(u8, det[close + 1 ..], " \t\r\n");
            if (rtype.len != 0) desc_owned = try self.allocator.dupe(u8, rtype);
        }
        return .{ .detail = detail_owned, .description = desc_owned };
    }

    /// Builds a fully-formed CompletionItem for a top-level symbol (function,
    /// method, type, or variable): label, LSP kind, detail (full signature),
    /// gopls-style structured labelDetails, and a parameter-placeholder snippet
    /// for callables. All strings are owned by `self.allocator` (freed when the
    /// completion list is freed).
    fn buildSymbolCompletionItem(self: *LspServer, s: SymbolLite) !CompletionItem {
        const kind: i64 = switch (s.kind) {
            .function => 3,
            .method => 2,
            .struct_ => 7,
            .interface => 8,
            .variable => 6,
            else => 6,
        };
        const ins = try self.completionInsertForSymbol(s);
        return .{
            .label = try self.allocator.dupe(u8, s.name),
            .kind = kind,
            .detail = blk: {
                if (s.detail) |d| break :blk try self.allocator.dupe(u8, d);
                if (s.kind == .variable) {
                    if (s.value_type) |vt| {
                        if (!isLetInferTypeName(vt)) break :blk try self.allocator.dupe(u8, vt);
                    }
                }
                break :blk null;
            },
            .labelDetails = try self.completionLabelDetailsForSymbol(s),
            .insertText = ins.text,
            .insertTextFormat = ins.format,
        };
    }

    fn findMemberByContainer(self: *LspServer, preferred_uri: []const u8, container_type: []const u8, name: []const u8, kind: SymbolKind) ?MemberHit {
        const container_base = baseTypeNameForLookup(container_type);

        if (self.hasTypeDeclarationInDoc(preferred_uri, container_base)) {
            if (self.findMemberByContainerInUri(preferred_uri, container_base, name, kind)) |s| {
                return .{ .uri = preferred_uri, .sym = s };
            }
            return null;
        }

        if (self.findTypeDefinitionAnyDoc(preferred_uri, container_type)) |type_def| {
            if (self.findMemberByContainerInUri(type_def.uri, container_base, name, kind)) |s| {
                return .{ .uri = type_def.uri, .sym = s };
            }
            return null;
        }

        // Prefer current document first.
        if (self.docs.get(preferred_uri)) |doc| {
            if (doc.index != null) {
                if (self.findMemberByContainerInUri(preferred_uri, container_base, name, kind)) |s| {
                    return .{ .uri = preferred_uri, .sym = s };
                }
            }
        }

        var best_hit: ?MemberHit = null;
        var it = self.docs.iterator();
        while (it.next()) |entry| {
            const uri = entry.value_ptr.uri;
            if (std.mem.eql(u8, uri, preferred_uri)) continue;
            const s = self.findMemberByContainerInUri(uri, container_base, name, kind) orelse continue;
            if (!self.isSymbolVisibleFromUri(preferred_uri, uri, s)) continue;
            if (best_hit == null or preferDetailedSymbol(s, best_hit.?.sym)) {
                best_hit = .{ .uri = uri, .sym = s };
            }
        }
        return best_hit;
    }

    fn findMemberByContainerInUri(self: *LspServer, uri: []const u8, container_base: []const u8, name: []const u8, kind: SymbolKind) ?SymbolLite {
        const doc = self.docs.get(uri) orelse return null;
        const idx = doc.index orelse return null;
        var best: ?SymbolLite = null;
        var container_match_count: usize = 0;
        var name_match_count: usize = 0;
        for (idx.symbols) |s| {
            if (s.container_fn_range != null) continue;
            if (s.kind != kind) continue;
            if (s.container_type == null) continue;
            if (!std.mem.eql(u8, baseTypeNameForLookup(s.container_type.?), container_base)) continue;
            container_match_count += 1;
            if (!std.mem.eql(u8, s.name, name)) continue;
            name_match_count += 1;
            if (best == null or preferDetailedSymbol(s, best.?)) {
                best = s;
            }
        }
        if (self.debug_definitions and best == null) {
            self.dbg(true, "defs", "member miss uri={s} container={s} name={s} kind={s} container_matches={d} name_matches={d}", .{
                uri,
                container_base,
                name,
                @tagName(kind),
                container_match_count,
                name_match_count,
            });
        }
        return best;
    }

    fn isKnownTypeName(self: *LspServer, preferred_uri: []const u8, name: []const u8) bool {
        const base = if (std.mem.indexOfScalar(u8, name, '<')) |idx| name[0..idx] else name;
        var it = self.docs.iterator();
        while (it.next()) |entry| {
            const uri = entry.value_ptr.uri;
            const idx = entry.value_ptr.index orelse continue;
            for (idx.symbols) |s| {
                if (s.container_fn_range != null) continue;
                if (!std.mem.eql(u8, s.name, base)) continue;
                switch (s.kind) {
                    .struct_, .interface, .enum_ => {},
                    else => continue,
                }
                if (!self.isSymbolVisibleFromUri(preferred_uri, uri, s)) continue;
                return true;
            }
        }
        return false;
    }

    fn findEnumDefinitionAnyDoc(self: *LspServer, preferred_uri: []const u8, enum_name: []const u8) ?GlobalDefHit {
        if (self.findTypeDefinitionAnyDoc(preferred_uri, enum_name)) |hit| {
            if (hit.sym.kind == .enum_) return hit;
        }
        return null;
    }

    fn isEnumTypeName(self: *LspServer, preferred_uri: []const u8, name: []const u8) bool {
        return self.findEnumDefinitionAnyDoc(preferred_uri, name) != null;
    }

    fn findTypeDefinitionAnyDoc(self: *LspServer, preferred_uri: []const u8, type_name: []const u8) ?GlobalDefHit {
        const base = if (std.mem.indexOfScalar(u8, type_name, '<')) |idx| type_name[0..idx] else type_name;
        // Prefer current document first.
        if (self.docs.get(preferred_uri)) |doc| {
            if (doc.index) |idx| {
                for (idx.symbols) |s| {
                    if (s.container_fn_range != null) continue;
                    if (!std.mem.eql(u8, s.name, base)) continue;
                    if (s.kind != .struct_ and s.kind != .interface and s.kind != .enum_) continue;
                    return .{ .uri = preferred_uri, .sym = s };
                }
            }
        }

        // Prefer direct imports of the current doc next.
        if (self.findAnyGlobalDefinitionInDirectImports(preferred_uri, base)) |hit| {
            if (hit.sym.kind == .struct_ or hit.sym.kind == .interface or hit.sym.kind == .enum_) return hit;
        }

        // Finally, scan all indexed docs.
        var it = self.docs.iterator();
        while (it.next()) |entry| {
            const uri = entry.value_ptr.uri;
            if (std.mem.eql(u8, uri, preferred_uri)) continue;
            const idx = entry.value_ptr.index orelse continue;
            for (idx.symbols) |s| {
                if (s.container_fn_range != null) continue;
                if (!std.mem.eql(u8, s.name, base)) continue;
                if (s.kind != .struct_ and s.kind != .interface and s.kind != .enum_) continue;
                if (!self.isSymbolVisibleFromUri(preferred_uri, uri, s)) continue;
                return .{ .uri = uri, .sym = s };
            }
        }
        return null;
    }

    fn guessVariableType(self: *LspServer, idx: *const Index, preferred_uri: []const u8, var_name: []const u8, at: Position) ?[]const u8 {
        // Prefer symbol table (locals + globals) when available.
        if (findBestDefinition(idx.symbols, var_name, at)) |d| {
            if (d.kind == .variable) {
                if (d.value_type) |vt| {
                    if (!isLetInferTypeName(vt)) return vt;
                }
                // Untyped local: it may be a `fit`-arm payload binding, or a `let`/`for`
                // binding whose initializer is a method chain the index-time typing
                // couldn't resolve (e.g. it bottoms out at a fit payload). Re-infer it
                // through the query-time engine. Bounded recursion depth (these paths can
                // re-enter guessVariableType for the chain's base receiver).
                if (self.type_infer_depth < 16) {
                    self.type_infer_depth += 1;
                    defer self.type_infer_depth -= 1;
                    if (self.resolveFitBindingType(idx, preferred_uri, d.decl_range.start)) |ft| return ft;
                    if (self.resolveBindingInitType(idx, preferred_uri, d.decl_range.start)) |bt| return bt;
                }
            }
        }

        // Scan for simple declarations like:
        // - `Type name;` / `Type name = ...;`
        // - `Type* name;` / `Type * name = ...;`
        // - `Type& name;` / `Type & name = ...;`
        // (best-effort fallback)
        var best: ?[]const u8 = null;

        const baseTypeName = struct {
            fn go(s: []const u8) []const u8 {
                var end = s.len;
                var cut = end;
                var i: usize = 0;
                while (i < s.len) : (i += 1) {
                    if (s[i] == '<') {
                        cut = i;
                        break;
                    }
                }
                end = cut;
                while (end > 0) {
                    const ch = s[end - 1];
                    if (ch == '*' or ch == '&') {
                        end -= 1;
                        continue;
                    }
                    break;
                }
                return s[0..end];
            }
        }.go;

        var i: usize = 0;
        while (i + 1 < idx.tokens.len) : (i += 1) {
            const t_type = idx.tokens[i];
            if (!rangeStartLessOrEqual(t_type.range, at)) break;

            const is_type_tok = (t_type.kind == .keyword and utils.keyword_is_datatype(t_type.text)) or blk: {
                if (t_type.kind != .identifier) break :blk false;
                const base = baseTypeName(t_type.text);
                if (base.len == 0) break :blk false;
                // Treat any identifier as a potential type token in explicit declarations.
                break :blk true;
            };
            if (!is_type_tok) continue;

            // Skip type identifiers that are part of declarations like `compound T`, `quirk Q`, `impl T`, `fun f`.
            if (i > 0 and idx.tokens[i - 1].kind == .keyword) {
                const kw = idx.tokens[i - 1].text;
                if (std.mem.eql(u8, kw, "compound") or std.mem.eql(u8, kw, "quirk") or std.mem.eql(u8, kw, "impl") or std.mem.eql(u8, kw, "enum") or std.mem.eql(u8, kw, "fun")) {
                    continue;
                }
            }

            // Allow generic args and pointer/reference markers between the base type token and the name.
            // We still return the base type so member completion can match `impl Type { ... }`.
            var name_i: usize = i + 1;
            while (name_i < idx.tokens.len) {
                const tt = idx.tokens[name_i];
                if (tt.kind == .comment) {
                    name_i += 1;
                    continue;
                }
                if ((tt.kind == .symbol or tt.kind == .operator) and std.mem.eql(u8, tt.text, "<")) {
                    name_i = skipGenericArgsLite(idx.tokens, name_i);
                    continue;
                }
                if ((tt.kind == .operator or tt.kind == .symbol) and (std.mem.eql(u8, tt.text, "*") or std.mem.eql(u8, tt.text, "&"))) {
                    name_i += 1;
                    continue;
                }
                break;
            }
            if (name_i >= idx.tokens.len) continue;

            const t_name = idx.tokens[name_i];
            if (t_name.kind != .identifier) continue;
            if (!std.mem.eql(u8, t_name.text, var_name)) continue;

            // Ensure the name token is also before position.
            if (!rangeStartLessOrEqual(t_name.range, at)) continue;
            best = if (t_type.kind == .identifier) baseTypeName(t_type.text) else t_type.text;
        }
        return best;
    }

    fn parseTypeNameFromParamLabel(self: *LspServer, label: []const u8) ?[]const u8 {
        _ = self;
        var s = std.mem.trim(u8, label, " \t\r\n");
        if (s.len == 0) return null;
        const space_i = std.mem.indexOfAny(u8, s, " \t") orelse s.len;
        var t = s[0..space_i];
        while (t.len != 0 and (t[t.len - 1] == '*' or t[t.len - 1] == '&')) {
            t = t[0 .. t.len - 1];
        }
        if (t.len == 0) return null;
        return t;
    }

    fn parseReturnTypeFromSignatureLabel(self: *LspServer, label: []const u8) ?[]const u8 {
        _ = self;
        const open_i = std.mem.indexOfScalar(u8, label, '(') orelse return null;
        var depth: i64 = 0;
        var close_i: ?usize = null;
        var i = open_i;
        while (i < label.len) : (i += 1) {
            const ch = label[i];
            if (ch == '(') {
                depth += 1;
                continue;
            }
            if (ch == ')') {
                depth -= 1;
                if (depth == 0) {
                    close_i = i;
                    break;
                }
            }
        }
        const ci = close_i orelse return null;
        const tail = std.mem.trim(u8, label[ci + 1 ..], " \t\r\n");
        if (tail.len == 0) return null;
        return tail;
    }

    fn inferDeclTypeBeforeName(self: *LspServer, idx: *const Index, name_i: usize) ?[]const u8 {
        _ = self;
        if (name_i == 0) return null;
        var i: isize = @as(isize, @intCast(name_i)) - 1;
        while (i >= 0) : (i -= 1) {
            const t = idx.tokens[@intCast(i)];
            if (t.kind == .comment) continue;
            if (t.kind == .operator and (std.mem.eql(u8, t.text, "*") or std.mem.eql(u8, t.text, "&"))) continue;
            if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, "]")) {
                var j: isize = i - 1;
                while (j >= 0) : (j -= 1) {
                    const tj = idx.tokens[@intCast(j)];
                    if (tj.kind == .comment) continue;
                    if ((tj.kind == .symbol or tj.kind == .operator) and std.mem.eql(u8, tj.text, "[")) break;
                }
                i = j;
                continue;
            }
            if (t.kind == .identifier or t.kind == .keyword) return t.text;
            break;
        }
        return null;
    }

    fn guessEnumTypeForDotShorthand(self: *LspServer, uri: []const u8, idx: *const Index, tok_i: usize) ?[]const u8 {
        var dot_i_opt: ?usize = null;
        if (idx.tokens[tok_i].kind == .identifier) {
            // Some tokenizers may emit `.Variant` as a single identifier token (text starts with '.')
            // rather than '.' + 'Variant'. Treat that as shorthand.
            if (idx.tokens[tok_i].text.len > 1 and idx.tokens[tok_i].text[0] == '.') {
                dot_i_opt = tok_i;
            } else {
                if (tok_i == 0 or !isDotToken(idx.tokens[tok_i - 1])) return null;
                if (tok_i >= 2 and idx.tokens[tok_i - 2].kind == .identifier) return null; // not shorthand (e.g., Color.Red)
                dot_i_opt = tok_i - 1;
            }
        } else if (isDotToken(idx.tokens[tok_i])) {
            dot_i_opt = tok_i;
        } else {
            return null;
        }

        const dot_i = dot_i_opt.?;
        const dot_pos = idx.tokens[dot_i].range.start;

        // 1) Function-call context: use signature help to infer expected enum type.
        if (self.guessCallSignatureAt(uri, idx, dot_pos)) |sig| {
            const parsed = self.parseParamsFromSignatureLabel(sig.label) catch null;
            if (parsed) |params| {
                defer {
                    for (params.items) |p| self.allocator.free(p.label);
                    params.deinit();
                }
                if (params.items.len != 0) {
                    var active: i64 = sig.active_param;
                    const max_param: i64 = @intCast(params.items.len - 1);
                    if (active > max_param) active = max_param;
                    if (active < 0) active = 0;
                    const p = params.items[@intCast(active)];
                    if (self.parseTypeNameFromParamLabel(p.label)) |tname| {
                        if (self.findEnumDefinitionAnyDoc(uri, tname)) |hit| return hit.sym.name;
                    }
                }
            }
        }

        // 2) Binary context: `x = .Variant` or `x == .Variant`.
        var k: isize = @as(isize, @intCast(dot_i)) - 1;
        while (k >= 0) : (k -= 1) {
            const t = idx.tokens[@intCast(k)];
            if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, ";")) break;
            if (t.kind == .symbol or t.kind == .operator) {
                if (std.mem.eql(u8, t.text, "=") or std.mem.eql(u8, t.text, "==") or std.mem.eql(u8, t.text, "!=")) {
                    var j: isize = k - 1;
                    while (j >= 0) : (j -= 1) {
                        const lt = idx.tokens[@intCast(j)];
                        if (lt.kind == .comment) continue;
                        if (lt.kind == .identifier) {
                            if (std.mem.eql(u8, t.text, "=")) {
                                if (self.inferDeclTypeBeforeName(idx, @intCast(j))) |tn| {
                                    if (self.isEnumTypeName(uri, tn)) return tn;
                                }
                            }
                            if (self.isEnumTypeName(uri, lt.text)) return lt.text;
                            if (self.guessVariableType(idx, uri, lt.text, dot_pos)) |vt| {
                                if (self.isEnumTypeName(uri, vt)) return vt;
                            }
                            break;
                        }
                        if ((lt.kind == .symbol or lt.kind == .operator) and std.mem.eql(u8, lt.text, ";")) break;
                    }
                    break;
                }
            }
        }

        // 3) Fit context: `fit <enum_expr> { .Variant -> ... }`. The subject may be a
        // bare variable/enum name OR a call whose return type is the enum (`fit
        // parse(src) { .Ok -> ... }` where parse returns `Result<JsonValue>`).
        var f: isize = @as(isize, @intCast(dot_i)) - 1;
        while (f >= 0) : (f -= 1) {
            const t = idx.tokens[@intCast(f)];
            if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, ";")) break;
            if (t.kind == .keyword and std.mem.eql(u8, t.text, "fit")) {
                var after_i = nextNonTrivialTokenLite(idx.tokens, @as(usize, @intCast(f + 1))) orelse return null;
                // Skip a leading `await` so `fit await ch.recv_result() { .Ok -> }`
                // resolves the same as `fit ch.recv_result()` — the awaited expression's
                // type is the awaited call's return type.
                if (idx.tokens[after_i].kind == .keyword and std.mem.eql(u8, idx.tokens[after_i].text, "await")) {
                    after_i = nextNonTrivialTokenLite(idx.tokens, after_i + 1) orelse return null;
                }
                if (idx.tokens[after_i].kind != .identifier) return null;
                const name = idx.tokens[after_i].text;
                if (self.isEnumTypeName(uri, name)) return name;
                if (self.guessVariableType(idx, uri, name, dot_pos)) |vt| {
                    if (self.isEnumTypeName(uri, vt)) return vt;
                }
                // Call subject: resolve the callee's return type and, if it names an
                // enum (possibly generic, `Result<JsonValue>` -> `Result`), use it.
                const next_after = nextNonTrivialTokenLite(idx.tokens, after_i + 1) orelse return null;
                if (isOpenParen(idx.tokens[next_after])) {
                    if (self.calleeSignatureDetail(uri, idx, after_i)) |detail| {
                        if (returnTypeNameFromSignatureLabel(detail)) |rt| {
                            if (self.isEnumTypeName(uri, rt)) return rt;
                        }
                    }
                }
                // Method-call / chain subject: `fit ch.recv_result() { .Ok -> ... }`.
                // The subject is an expression ending in `)`, not a bare name or a
                // direct free call. Find the subject's closing `)` (the last paren
                // before the fit body `{`) and resolve its type through the general
                // expression engine (which follows method-call returns + generics).
                {
                    var s: usize = after_i;
                    var depth: i64 = 0;
                    var subj_close: ?usize = null;
                    while (s < @as(usize, @intCast(dot_i))) : (s += 1) {
                        const st = idx.tokens[s];
                        if (st.kind == .symbol or st.kind == .operator) {
                            if (std.mem.eql(u8, st.text, "(")) {
                                depth += 1;
                            } else if (std.mem.eql(u8, st.text, ")")) {
                                depth -= 1;
                                if (depth == 0) subj_close = s;
                            } else if (depth == 0 and std.mem.eql(u8, st.text, "{")) {
                                break;
                            }
                        }
                    }
                    if (subj_close) |sc| {
                        if (self.resolveTypeOfExprEndingAtToken(idx, uri, dot_pos, sc)) |ty| {
                            const base = baseTypeNameForLookup(ty);
                            if (self.isEnumTypeName(uri, base)) return base;
                        }
                    }
                }
                return null;
            }
        }

        // 4) Return context: `ret .Variant` inside a function/method whose declared
        // return type is an enum (e.g. `pub index_of_opt(...) Option<num> { ret .Some(i); }`).
        // Confirm a `ret` precedes the dot in the same statement, then read the
        // enclosing function's return-type base name.
        var r: isize = @as(isize, @intCast(dot_i)) - 1;
        while (r >= 0) : (r -= 1) {
            const t = idx.tokens[@intCast(r)];
            if (t.kind == .comment) continue;
            // Stop at a statement/block boundary that means we're not in a `ret` expr.
            if ((t.kind == .symbol or t.kind == .operator) and
                (std.mem.eql(u8, t.text, ";") or std.mem.eql(u8, t.text, "{") or std.mem.eql(u8, t.text, "}"))) break;
            if (t.kind == .keyword and std.mem.eql(u8, t.text, "ret")) {
                const rt_opt = self.enclosingFunctionReturnTypeName(idx, dot_i);
                if (self.debug_definitions) self.dbg(true, "defs", "shorthand ret-ctx: enclosing_return={s} is_enum={}", .{ rt_opt orelse "<none>", if (rt_opt) |rt| self.isEnumTypeName(uri, rt) else false });
                if (rt_opt) |rt| {
                    if (self.isEnumTypeName(uri, rt)) return rt;
                }
                break;
            }
        }

        return null;
    }

    /// Base name of the return type of the function/method whose body lexically encloses
    /// `tok_i`. Climbs OUT through nested blocks (`if`/`for`/`fit` arms/bare blocks),
    /// and for each enclosing block checks whether its opening `{` is preceded by a
    /// function-header `) RetType {`; the first such header found is the enclosing
    /// function (e.g. `... ) Option<num> {` -> "Option"). Returns null if not inside a
    /// typed function body, or the nearest enclosing function has no named return type.
    fn enclosingFunctionReturnTypeName(self: *LspServer, idx: *const Index, tok_i: usize) ?[]const u8 {
        _ = self;
        const toks = idx.tokens;
        var search_from: isize = @as(isize, @intCast(tok_i)) - 1;

        // Climb one enclosing block per iteration until we find a function header or run out.
        while (search_from >= 0) {
            // Find the `{` opening the block that encloses search_from (net depth 0).
            var depth: i64 = 0;
            var open_i: ?usize = null;
            var k: isize = search_from;
            while (k >= 0) : (k -= 1) {
                const t = toks[@intCast(k)];
                if (t.kind != .symbol and t.kind != .operator) continue;
                if (std.mem.eql(u8, t.text, "}")) {
                    depth += 1;
                } else if (std.mem.eql(u8, t.text, "{")) {
                    if (depth == 0) {
                        open_i = @intCast(k);
                        break;
                    }
                    depth -= 1;
                }
            }
            const oi = open_i orelse return null;
            if (oi == 0) return null;

            // Does this `{` open a function body? Look left for a `) RetType {` shape:
            // the matching `)` of a param list, with a return-type run between it and `{`.
            var j: isize = @as(isize, @intCast(oi)) - 1;
            var rparen_i: ?usize = null;
            var angle: i64 = 0;
            var hit_boundary = false;
            while (j >= 0) : (j -= 1) {
                const t = toks[@intCast(j)];
                if (t.kind == .symbol or t.kind == .operator) {
                    if (std.mem.eql(u8, t.text, ">")) {
                        angle += 1;
                    } else if (std.mem.eql(u8, t.text, "<")) {
                        if (angle > 0) angle -= 1;
                    } else if (angle == 0 and std.mem.eql(u8, t.text, ")")) {
                        rparen_i = @intCast(j);
                        break;
                    } else if (angle == 0 and (std.mem.eql(u8, t.text, "{") or std.mem.eql(u8, t.text, "}") or std.mem.eql(u8, t.text, ";"))) {
                        // This block is NOT a function body (e.g. `if (...) {`, `for ... {`,
                        // a `fit` arm `-> {`, or a bare block). Keep climbing outward.
                        hit_boundary = true;
                        break;
                    }
                }
            }
            if (hit_boundary or rparen_i == null) {
                // Climb to the block enclosing THIS `{`.
                search_from = @as(isize, @intCast(oi)) - 1;
                continue;
            }
            const rp = rparen_i.?;
            // Return-type base name = first identifier token after `)` (before `{`).
            var m: usize = rp + 1;
            while (m < oi) : (m += 1) {
                const t = toks[m];
                if (t.kind == .comment) continue;
                if (t.kind == .identifier) return baseTypeNameForLookup(t.text);
                if (t.kind == .symbol or t.kind == .operator) {
                    // `) {` with nothing between -> a void function (or a non-fn header like
                    // `if (...) {`). No named return type here; stop (don't misclimb).
                    if (std.mem.eql(u8, t.text, "{")) return null;
                }
            }
            return null;
        }
        return null;
    }

    /// Extract the base type name from a function signature label's return type, e.g.
    /// `parse(str src) Result<JsonValue>` -> `Result`. Returns null when there is no
    /// return type. The base name strips any generic args (`<...>`).
    fn returnTypeNameFromSignatureLabel(detail: []const u8) ?[]const u8 {
        // The return type follows the parameter list's closing `)`.
        const close = std.mem.lastIndexOfScalar(u8, detail, ')') orelse return null;
        var s = detail[close + 1 ..];
        // Trim leading spaces.
        while (s.len != 0 and (s[0] == ' ' or s[0] == '\t')) s = s[1..];
        if (s.len == 0) return null;
        // Base name = up to the first non-identifier char (`<`, space, `*`, `[`).
        var end: usize = 0;
        while (end < s.len) : (end += 1) {
            const c = s[end];
            const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
            if (!ok) break;
        }
        if (end == 0) return null;
        return s[0..end];
    }

    /// Re-infer the type of a binding whose initializer is an expression the index-time
    /// typing couldn't resolve: `let X = <expr>;` and the `for`-loop forms
    /// (`for X : <iter>`, `for i, X :: <map>`). Resolves the initializer/iterable through
    /// the query-time expression engine (which now follows method chains + generics), so
    /// a binding derived from a `fit` payload (`let items = doc.as_array().unwrap_or(...)`,
    /// then `for item : items`) gets a real type. Arena-owned result, or null.
    fn resolveBindingInitType(self: *LspServer, idx: *const Index, uri: []const u8, at: Position) ?[]const u8 {
        const toks = idx.tokens;
        const bind_i = findTokenIndexAt(toks, at) orelse return null;
        if (toks[bind_i].kind != .identifier) return null;

        // Find the statement keyword introducing this binding by scanning left to a
        // boundary. We care about `let` and `for`.
        var kw_i: ?usize = null;
        var is_for = false;
        {
            var k: isize = @as(isize, @intCast(bind_i)) - 1;
            var guard: usize = 0;
            while (k >= 0 and guard < 12) : (k -= 1) {
                const t = toks[@intCast(k)];
                if (t.kind == .keyword and std.mem.eql(u8, t.text, "let")) {
                    kw_i = @intCast(k);
                    break;
                }
                if (t.kind == .keyword and std.mem.eql(u8, t.text, "for")) {
                    kw_i = @intCast(k);
                    is_for = true;
                    break;
                }
                // Stop at a clear statement boundary.
                if ((t.kind == .symbol or t.kind == .operator) and
                    (std.mem.eql(u8, t.text, ";") or std.mem.eql(u8, t.text, "{") or std.mem.eql(u8, t.text, "}")))
                    return null;
                guard += 1;
            }
        }
        if (kw_i == null) return null;

        if (!is_for) {
            // `let X = <RHS> ;` — resolve the RHS expression's type.
            var eq_i: ?usize = null;
            var p = bind_i + 1;
            while (p < toks.len) : (p += 1) {
                const t = toks[p];
                if (t.kind == .comment) continue;
                if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, "=")) {
                    eq_i = p;
                    break;
                }
                // `let X = ...` has `=` directly after the name; anything else => not it.
                if (t.kind != .identifier) break;
            }
            const eqi = eq_i orelse return null;

            // Channel receive: `let n = <- ch;` — the RHS is `<- <operand>` where the
            // operand's type is a `Channel<T>` (or `Channel<T>*`). The binding's type
            // is the channel's element type `T`. `<-` may lex as a single `<-`
            // operator or as `<` followed by `-`; handle both.
            {
                const first_rhs = nextNonTrivialTokenLite(toks, eqi + 1);
                if (first_rhs) |fr| {
                    const t0 = toks[fr];
                    const is_arrow_single = (t0.kind == .operator or t0.kind == .symbol) and std.mem.eql(u8, t0.text, "<-");
                    const is_arrow_split = (t0.kind == .operator or t0.kind == .symbol) and std.mem.eql(u8, t0.text, "<") and blk_arrow: {
                        const nxt = nextNonTrivialTokenLite(toks, fr + 1) orelse break :blk_arrow false;
                        break :blk_arrow (toks[nxt].kind == .operator or toks[nxt].kind == .symbol) and std.mem.eql(u8, toks[nxt].text, "-");
                    };
                    if (is_arrow_single or is_arrow_split) {
                        // Resolve the operand's type, then unwrap its first generic arg.
                        const operand_start = if (is_arrow_split) (nextNonTrivialTokenLite(toks, fr + 1) orelse return null) + 1 else fr + 1;
                        // Find the last significant RHS token before `;`.
                        var oe: ?usize = null;
                        var oq = operand_start;
                        var od: i64 = 0;
                        while (oq < toks.len) : (oq += 1) {
                            const t = toks[oq];
                            if (isOpenParen(t) or (t.kind == .symbol and std.mem.eql(u8, t.text, "["))) od += 1;
                            if (isCloseParen(t) or (t.kind == .symbol and std.mem.eql(u8, t.text, "]"))) od -= 1;
                            if (od <= 0 and (t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, ";")) break;
                            if (t.kind != .comment) oe = oq;
                        }
                        const oei = oe orelse return null;
                        const chan_type = self.resolveTypeOfExprEndingAtToken(idx, uri, at, oei) orelse return null;
                        // `Channel<T>` / `Channel<T>*` -> T (first generic arg).
                        if (genericArgSpellingsArena(idx, chan_type)) |args| {
                            if (args.len != 0) return args[0];
                        }
                        return null;
                    }
                }
            }

            // Find the last significant token of the RHS (just before the terminating `;`).
            var end_i: ?usize = null;
            var q = eqi + 1;
            var depth: i64 = 0;
            while (q < toks.len) : (q += 1) {
                const t = toks[q];
                if (isOpenParen(t) or (t.kind == .symbol and std.mem.eql(u8, t.text, "["))) depth += 1;
                if (isCloseParen(t) or (t.kind == .symbol and std.mem.eql(u8, t.text, "]"))) depth -= 1;
                if (depth <= 0 and (t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, ";")) break;
                if (t.kind != .comment) end_i = q;
            }
            const ei = end_i orelse return null;
            return self.resolveTypeOfExprEndingAtToken(idx, uri, at, ei);
        }

        // for-loop binding: `for <bind> : <iter> {` or `for i, <bind> :: <map> {`.
        // The iterable is between the separator (`:`/`::`) and the body `{`.
        var sep_i: ?usize = null;
        var double = false;
        {
            var p = bind_i + 1;
            while (p < toks.len) : (p += 1) {
                const t = toks[p];
                if (t.kind == .comment) continue;
                if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, "::")) {
                    sep_i = p;
                    double = true;
                    break;
                }
                if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, ":")) {
                    sep_i = p;
                    break;
                }
                if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, "{")) return null;
            }
        }
        const sepi = sep_i orelse return null;
        // Iterable expression ends just before the body `{`.
        var iter_end: ?usize = null;
        {
            var q = sepi + 1;
            while (q < toks.len) : (q += 1) {
                const t = toks[q];
                if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, "{")) break;
                if (t.kind != .comment) iter_end = q;
            }
        }
        const ie = iter_end orelse return null;
        const iter_type = self.resolveTypeOfExprEndingAtToken(idx, uri, at, ie) orelse return null;
        // Element type of the iterable's collection type:
        //   `for x : Vec<T>` / `Set<T>`           -> T
        //   `for k : Map<K,V>` (single binding)   -> K
        //   `for i, v :: Map<K,V>` (double, value) -> V (the 2nd binding); `i` is num
        const args = genericArgSpellingsArena(idx, iter_type) orelse return null;
        if (args.len == 0) return null;
        const base = baseTypeNameForLookup(iter_type);
        if (double and std.mem.eql(u8, base, "Map")) {
            // The binding at `bind_i` is the VALUE (second name) in `for i, v :: map`.
            // (The index/key binding is a separate symbol typed `num`/the key type.)
            return if (args.len >= 2) args[1] else null;
        }
        // Single binding: Vec/Set element is arg[0]; Map key is arg[0].
        return args[0];
    }

    /// Split a type spelling's top-level generic args into arena-owned slices, e.g.
    /// `Map<str, num>` -> ["str", "num"]. Null when there are no args.
    fn genericArgSpellingsArena(idx: *const Index, type_str: []const u8) ?[]const []const u8 {
        const arena = @constCast(&idx.arena).allocator();
        const lt = std.mem.indexOfScalar(u8, type_str, '<') orelse return null;
        const gt = std.mem.lastIndexOfScalar(u8, type_str, '>') orelse return null;
        if (gt <= lt + 1) return null;
        const inner = type_str[lt + 1 .. gt];
        var out = ArrayList([]const u8).init(arena);
        var depth: i64 = 0;
        var start: usize = 0;
        var i: usize = 0;
        while (i < inner.len) : (i += 1) {
            const c = inner[i];
            if (c == '<') depth += 1;
            if (c == '>') depth -= 1;
            if (c == ',' and depth == 0) {
                out.append(arena.dupe(u8, std.mem.trim(u8, inner[start..i], " ")) catch return null) catch return null;
                start = i + 1;
            }
        }
        out.append(arena.dupe(u8, std.mem.trim(u8, inner[start..], " ")) catch return null) catch return null;
        return out.toOwnedSlice() catch null;
    }

    /// Resolve the type of a `fit`-arm payload BINDING at `at`, working CROSS-FILE.
    /// For `fit s { Result.Ok(doc) -> ... }` where `s: Result<JsonValue>` and `Result`
    /// is imported, returns `JsonValue` for `doc`. The single-file token prescan can't
    /// type these (the enum lives in another doc), so this consults imported enum
    /// definitions on demand. Returns a slice owned by the index's arena (lives with
    /// the doc index; callers treat it as borrowed, like other type lookups), or null.
    fn resolveFitBindingType(self: *LspServer, idx: *const Index, uri: []const u8, at: Position) ?[]const u8 {
        const arena = @constCast(&idx.arena).allocator();
        const toks = idx.tokens;
        const ti = findTokenIndexAt(toks, at) orelse return null;
        if (toks[ti].kind != .identifier) return null;

        // Walk back to the pattern's `(`, counting which positional binding `ti` is.
        var depth: i64 = 0;
        var arg_index: usize = 0;
        var open_i: ?usize = null;
        var k: isize = @as(isize, @intCast(ti)) - 1;
        while (k >= 0) : (k -= 1) {
            const t = toks[@intCast(k)];
            if (isCloseParen(t)) {
                depth += 1;
                continue;
            }
            if (isOpenParen(t)) {
                if (depth == 0) {
                    open_i = @intCast(k);
                    break;
                }
                depth -= 1;
                continue;
            }
            if (depth == 0 and isCommaToken(t)) arg_index += 1;
            // A `->`/`{`/`;`/`}` before the `(` means we're not in a pattern arg list.
            if (depth == 0 and (t.kind == .symbol or t.kind == .operator)) {
                const s = t.text;
                if (std.mem.eql(u8, s, "->") or std.mem.eql(u8, s, "{") or std.mem.eql(u8, s, "}") or std.mem.eql(u8, s, ";")) return null;
            }
        }
        const oi = open_i orelse return null;

        // The variant identifier sits immediately before `(`.
        const var_i = prevNonTrivialTokenLite(toks, oi) orelse return null;
        if (toks[var_i].kind != .identifier) return null;
        const variant_name = toks[var_i].text;

        // Confirm a `->` follows the matching `)` (this is a fit arm, not a call).
        var d2: i64 = 0;
        var m: usize = oi;
        var close_i: usize = oi;
        while (m < toks.len) : (m += 1) {
            if (isOpenParen(toks[m])) d2 += 1;
            if (isCloseParen(toks[m])) {
                d2 -= 1;
                if (d2 == 0) {
                    close_i = m;
                    break;
                }
            }
        }
        const after = nextNonTrivialTokenLite(toks, close_i + 1) orelse return null;
        if (!((toks[after].kind == .operator or toks[after].kind == .symbol) and std.mem.eql(u8, toks[after].text, "->"))) return null;

        // Resolve the enum the variant belongs to. A qualified pattern (`Result.Ok`)
        // names the enum directly in the token before the `.`; a shorthand (`.Ok`)
        // defers to the dot-shorthand inference (which reads the fit subject's type).
        const enum_name = blk: {
            const before_var = prevNonTrivialTokenLite(toks, var_i);
            if (before_var) |bv| {
                if ((toks[bv].kind == .operator or toks[bv].kind == .symbol) and std.mem.eql(u8, toks[bv].text, ".")) {
                    const enum_tok = prevNonTrivialTokenLite(toks, bv);
                    if (enum_tok) |et| {
                        if (toks[et].kind == .identifier) break :blk toks[et].text;
                    }
                }
            }
            break :blk self.guessEnumTypeForDotShorthand(uri, idx, var_i) orelse return null;
        };
        const enum_base = baseTypeNameForLookup(enum_name);

        // The enum may live in an imported doc not yet indexed (the per-file index
        // doesn't preload imports). Index the direct imports from disk so the enum
        // definition lookup below can find them.
        {
            var import_uris = ArrayList([]u8).init(self.allocator);
            defer {
                for (import_uris.items) |u| self.allocator.free(u);
                import_uris.deinit();
            }
            self.collectDirectImportUris(&import_uris, uri, idx) catch {};
            for (import_uris.items) |iu| self.ensureDocIndexedFromDisk(iu) catch {};
        }

        // Locate the enum's declaring document, then read the variant's payload type +
        // the enum's type params straight from THAT doc's tokens (the cross-file
        // enumMember symbol carries neither — only its trailing doc comment).
        const ehit = self.findEnumDefinitionAnyDoc(uri, enum_base) orelse return null;
        const edoc = self.docs.get(ehit.uri) orelse return null;
        const eidx = edoc.index orelse return null;
        // FULL payload spelling, e.g. `T`, `Box<num>`, `Node*`, `num[]`. Owned via
        // self.allocator here; the final RESULT is copied into the index arena below.
        const payload_type = enumVariantPayloadFromDoc(self.allocator, eidx, enum_base, variant_name, arg_index) orelse return null;
        defer self.allocator.free(payload_type);

        // Substitute only when the WHOLE payload is a bare type parameter of the enum
        // (`Ok(T)`). A payload that merely mentions a param inside generics
        // (`Boxed(Box<T>)`) is returned verbatim — fully resolving nested params would
        // need a recursive rewrite; the common cases (`T`, concrete `Vec2`/`Box<num>`)
        // are exact.
        const eparams = enumTypeParamsFromDoc(eidx, enum_base);
        var pidx: ?usize = null;
        for (eparams, 0..) |p, i| {
            if (std.mem.eql(u8, p, payload_type)) {
                pidx = i;
                break;
            }
        }
        if (pidx == null) {
            // Concrete payload (e.g. `Point(Vec2)`, `Box<num>`): return it directly.
            return arena.dupe(u8, payload_type) catch null;
        }

        // Resolve the fit subject's concrete generic args and substitute the bare param.
        // (Arena-owned — no manual free; see fitSubjectConcreteArgs.)
        const subj_args = self.fitSubjectConcreteArgs(idx, uri, var_i, at) orelse return null;
        if (pidx.? >= subj_args.len) return null;
        return arena.dupe(u8, subj_args[pidx.?]) catch null;
    }

    /// Resolve the CONCRETE signature of a `fit`-arm variant PATTERN itself at `at`
    /// (hovering `Some`/`Ok` in `Result.Ok(doc) -> ...`, as opposed to the payload
    /// binding `doc` — see `resolveFitBindingType` for that case). For a generic
    /// enum this substitutes each bare type-param payload with the fit subject's
    /// concrete arg (`Option.Some(T)` -> `Option.Some(dec)` when the subject is
    /// `Option<dec>`), working cross-file like `resolveFitBindingType`. Returns null
    /// (falling back to the plain indexed detail) when `at` isn't a payload-carrying
    /// variant pattern, or the variant has no payload to substitute.
    fn resolveFitVariantConcreteSig(self: *LspServer, idx: *const Index, uri: []const u8, at: Position) ?[]const u8 {
        const arena = @constCast(&idx.arena).allocator();
        const toks = idx.tokens;
        const var_i = findTokenIndexAt(toks, at) orelse return null;
        if (toks[var_i].kind != .identifier) return null;
        const variant_name = toks[var_i].text;

        const oi = nextNonTrivialTokenLite(toks, var_i + 1) orelse return null;
        if (!isOpenParen(toks[oi])) return null;

        // Confirm a `->` follows the matching `)` (this is a fit arm, not a call).
        var d2: i64 = 0;
        var m: usize = oi;
        var close_i: usize = oi;
        while (m < toks.len) : (m += 1) {
            if (isOpenParen(toks[m])) d2 += 1;
            if (isCloseParen(toks[m])) {
                d2 -= 1;
                if (d2 == 0) {
                    close_i = m;
                    break;
                }
            }
        }
        const after = nextNonTrivialTokenLite(toks, close_i + 1) orelse return null;
        if (!((toks[after].kind == .operator or toks[after].kind == .symbol) and std.mem.eql(u8, toks[after].text, "->"))) return null;

        // Resolve the enum the variant belongs to (same as resolveFitBindingType).
        const enum_name = blk: {
            const before_var = prevNonTrivialTokenLite(toks, var_i);
            if (before_var) |bv| {
                if ((toks[bv].kind == .operator or toks[bv].kind == .symbol) and std.mem.eql(u8, toks[bv].text, ".")) {
                    const enum_tok = prevNonTrivialTokenLite(toks, bv);
                    if (enum_tok) |et| {
                        if (toks[et].kind == .identifier) break :blk toks[et].text;
                    }
                }
            }
            break :blk self.guessEnumTypeForDotShorthand(uri, idx, var_i) orelse return null;
        };
        const enum_base = baseTypeNameForLookup(enum_name);

        {
            var import_uris = ArrayList([]u8).init(self.allocator);
            defer {
                for (import_uris.items) |u| self.allocator.free(u);
                import_uris.deinit();
            }
            self.collectDirectImportUris(&import_uris, uri, idx) catch {};
            for (import_uris.items) |iu| self.ensureDocIndexedFromDisk(iu) catch {};
        }

        const ehit = self.findEnumDefinitionAnyDoc(uri, enum_base) orelse return null;
        const edoc = self.docs.get(ehit.uri) orelse return null;
        const eidx = edoc.index orelse return null;
        const eparams = enumTypeParamsFromDoc(eidx, enum_base);

        // Substitute every positional payload (not just one binding), building the
        // full `Variant(arg0, arg1, ...)` argument list.
        var args = ArrayList(u8).init(arena);
        var arg_index: usize = 0;
        var any_payload = false;
        while (true) : (arg_index += 1) {
            const payload_type = enumVariantPayloadFromDoc(self.allocator, eidx, enum_base, variant_name, arg_index) orelse break;
            defer self.allocator.free(payload_type);
            any_payload = true;

            var pidx: ?usize = null;
            for (eparams, 0..) |p, i| {
                if (std.mem.eql(u8, p, payload_type)) {
                    pidx = i;
                    break;
                }
            }

            const resolved: []const u8 = blk: {
                if (pidx == null) break :blk payload_type;
                const subj_args = self.fitSubjectConcreteArgs(idx, uri, var_i, at) orelse break :blk payload_type;
                if (pidx.? >= subj_args.len) break :blk payload_type;
                break :blk subj_args[pidx.?];
            };

            if (arg_index != 0) args.appendSlice(", ") catch return null;
            args.appendSlice(resolved) catch return null;
        }
        if (!any_payload) return null;

        return std.fmt.allocPrint(arena, "{s}.{s}({s})", .{ enum_name, variant_name, args.items }) catch null;
    }

    /// Locate the `enum <name>` declaration's `{` token index in a doc's TokenLite
    /// stream, having skipped an optional `<...>` type-param list. Returns the index of
    /// the enum-name token, the body `{` index, and the type-param token indices.
    const EnumDeclLoc = struct { name_i: usize, lbrace_i: usize, param_names: [8][]const u8, param_count: usize };
    fn locateEnumDeclInDoc(idx: *const Index, enum_base: []const u8) ?EnumDeclLoc {
        const toks = idx.tokens;
        var i: usize = 0;
        while (i < toks.len) : (i += 1) {
            if (!(toks[i].kind == .keyword and std.mem.eql(u8, toks[i].text, "enum"))) continue;
            const name_i = nextNonTrivialTokenLite(toks, i + 1) orelse continue;
            if (toks[name_i].kind != .identifier or !std.mem.eql(u8, toks[name_i].text, enum_base)) continue;
            var loc = EnumDeclLoc{ .name_i = name_i, .lbrace_i = 0, .param_names = undefined, .param_count = 0 };
            var k = nextNonTrivialTokenLite(toks, name_i + 1) orelse continue;
            // Optional `<A, B>` type-param list.
            if ((toks[k].kind == .operator or toks[k].kind == .symbol) and std.mem.eql(u8, toks[k].text, "<")) {
                var angle: i64 = 0;
                while (k < toks.len) : (k += 1) {
                    const t = toks[k];
                    if ((t.kind == .operator or t.kind == .symbol) and std.mem.eql(u8, t.text, "<")) angle += 1;
                    if ((t.kind == .operator or t.kind == .symbol) and std.mem.eql(u8, t.text, ">")) {
                        angle -= 1;
                        if (angle <= 0) break;
                    }
                    if (angle == 1 and t.kind == .identifier and loc.param_count < loc.param_names.len) {
                        loc.param_names[loc.param_count] = t.text;
                        loc.param_count += 1;
                    }
                }
                k = nextNonTrivialTokenLite(toks, k + 1) orelse continue;
            }
            if (!((toks[k].kind == .symbol or toks[k].kind == .operator) and std.mem.eql(u8, toks[k].text, "{"))) continue;
            loc.lbrace_i = k;
            return loc;
        }
        return null;
    }

    /// The generic type-param spellings of `enum_base` declared in `idx`'s doc
    /// (`Result` -> ["T"]). Empty for a non-generic enum. Slices borrow from the doc.
    fn enumTypeParamsFromDoc(idx: *const Index, enum_base: []const u8) []const []const u8 {
        const Holder = struct {
            var store: [8][]const u8 = undefined;
        };
        const loc = locateEnumDeclInDoc(idx, enum_base) orelse return &.{};
        var n: usize = 0;
        while (n < loc.param_count) : (n += 1) Holder.store[n] = loc.param_names[n];
        return Holder.store[0..loc.param_count];
    }

    /// The FULL payload type spelling at positional index `arg_index` of
    /// `enum_base.variant` declared in `idx`'s doc — base name plus any generic args,
    /// pointer (`*`) and array (`[]`) suffixes: `Ok(T)`->"T", `Boxed(Box<num>)`->"Box<num>",
    /// `Node(Node*)`->"Node*". Returns an allocated string (caller frees), or null when
    /// the variant/payload is absent.
    fn enumVariantPayloadFromDoc(allocator: Allocator, idx: *const Index, enum_base: []const u8, variant: []const u8, arg_index: usize) ?[]u8 {
        const toks = idx.tokens;
        const loc = locateEnumDeclInDoc(idx, enum_base) orelse return null;
        // Walk the enum body at depth 1 looking for `variant (` .
        var depth: i64 = 1;
        var i: usize = loc.lbrace_i + 1;
        while (i < toks.len and depth > 0) : (i += 1) {
            const t = toks[i];
            if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, "{")) {
                depth += 1;
                continue;
            }
            if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, "}")) {
                depth -= 1;
                continue;
            }
            if (depth != 1 or t.kind != .identifier or !std.mem.eql(u8, t.text, variant)) continue;
            const open = nextNonTrivialTokenLite(toks, i + 1) orelse return null;
            if (!isOpenParen(toks[open])) return null;
            // Find the start token of the arg at positional index `arg_index`.
            var pidx: usize = 0;
            var j = nextNonTrivialTokenLite(toks, open + 1) orelse return null;
            var pdepth: i64 = 0;
            while (j < toks.len) : (j = nextNonTrivialTokenLite(toks, j + 1) orelse break) {
                const tj = toks[j];
                if (isOpenParen(tj)) {
                    pdepth += 1;
                    continue;
                }
                if (isCloseParen(tj)) {
                    if (pdepth == 0) break;
                    pdepth -= 1;
                    continue;
                }
                if (pdepth == 0 and (tj.kind == .symbol or tj.kind == .operator) and std.mem.eql(u8, tj.text, ",")) {
                    pidx += 1;
                    continue;
                }
                if (pdepth == 0 and pidx == arg_index and (tj.kind == .identifier or tj.kind == .keyword)) {
                    return spellPayloadType(allocator, toks, j);
                }
            }
            return null;
        }
        return null;
    }

    /// Build the full type spelling starting at token `start` (a type name): the base
    /// name, a balanced `<...>` generic-arg run, and trailing `*`/`[]` suffixes. Owned.
    fn spellPayloadType(allocator: Allocator, toks: []const TokenLite, start: usize) ?[]u8 {
        var buf = ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        buf.appendSlice(toks[start].text) catch return null;
        var i = nextNonTrivialTokenLite(toks, start + 1) orelse return buf.toOwnedSlice() catch null;
        // Optional `<...>` generic args (depth-balanced).
        if ((toks[i].kind == .operator or toks[i].kind == .symbol) and std.mem.eql(u8, toks[i].text, "<")) {
            var angle: i64 = 0;
            while (i < toks.len) : (i += 1) {
                const t = toks[i];
                const txt = t.text;
                // Emit `<`/`>`/`,` with the spacing used elsewhere (`Map<str, num>`).
                if ((t.kind == .operator or t.kind == .symbol) and std.mem.eql(u8, txt, "<")) {
                    buf.append('<') catch return null;
                    angle += 1;
                    continue;
                }
                if ((t.kind == .operator or t.kind == .symbol) and std.mem.eql(u8, txt, ">")) {
                    buf.append('>') catch return null;
                    angle -= 1;
                    if (angle <= 0) {
                        i += 1;
                        break;
                    }
                    continue;
                }
                if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, txt, ",")) {
                    buf.appendSlice(", ") catch return null;
                    continue;
                }
                if (txt.len != 0) buf.appendSlice(txt) catch return null;
            }
        }
        // Trailing pointer / array suffixes.
        while (i < toks.len) : (i = nextNonTrivialTokenLite(toks, i + 1) orelse break) {
            const t = toks[i];
            if ((t.kind == .operator or t.kind == .symbol) and std.mem.eql(u8, t.text, "*")) {
                buf.append('*') catch return null;
            } else if ((t.kind == .operator or t.kind == .symbol) and std.mem.eql(u8, t.text, "[")) {
                buf.append('[') catch return null;
            } else if ((t.kind == .operator or t.kind == .symbol) and std.mem.eql(u8, t.text, "]")) {
                buf.append(']') catch return null;
            } else break;
        }
        return buf.toOwnedSlice() catch null;
    }

    /// Resolve the concrete generic args of the `fit` subject enclosing the variant
    /// token `var_i` (e.g. `Result<JsonValue>` -> ["JsonValue"]). Handles a variable
    /// subject (`fit r {`) and a call subject (`fit parse(x) {`). The returned slice and
    /// its element strings are allocated in the INDEX ARENA (freed with the doc), so the
    /// caller treats the result as borrowed — no manual free (a previous manual
    /// `free(slice)` leaked every element string and corrupted the allocator over time).
    fn fitSubjectConcreteArgs(self: *LspServer, idx: *const Index, uri: []const u8, var_i: usize, at: Position) ?[]const []const u8 {
        const arena = @constCast(&idx.arena).allocator();
        // Find the enclosing `fit` keyword and its subject token span.
        var f: isize = @as(isize, @intCast(var_i)) - 1;
        var subj_first: ?usize = null;
        while (f >= 0) : (f -= 1) {
            const t = idx.tokens[@intCast(f)];
            if (t.kind == .keyword and std.mem.eql(u8, t.text, "fit")) {
                subj_first = nextNonTrivialTokenLite(idx.tokens, @as(usize, @intCast(f)) + 1);
                break;
            }
        }
        const sf = subj_first orelse return null;
        const subj_tok = idx.tokens[sf];
        if (subj_tok.kind != .identifier) return null;

        // Resolve the subject's type spelling.
        var subj_type: ?[]const u8 = null;
        const next_after = nextNonTrivialTokenLite(idx.tokens, sf + 1);
        if (next_after != null and isOpenParen(idx.tokens[next_after.?])) {
            // Call subject: use the callee return type.
            if (self.calleeSignatureDetail(uri, idx, sf)) |detail| {
                subj_type = returnTypeFullFromSignatureLabel(detail);
            }
        } else {
            subj_type = self.guessVariableType(idx, uri, subj_tok.text, at);
        }
        const st = subj_type orelse return null;

        // Split the subject type's generic args into owned strings.
        const lt = std.mem.indexOfScalar(u8, st, '<') orelse return null;
        const gt = std.mem.lastIndexOfScalar(u8, st, '>') orelse return null;
        if (gt <= lt + 1) return null;
        const inner = st[lt + 1 .. gt];
        var out = ArrayList([]const u8).init(arena);
        var depth: i64 = 0;
        var start: usize = 0;
        var i: usize = 0;
        while (i < inner.len) : (i += 1) {
            const c = inner[i];
            if (c == '<') depth += 1;
            if (c == '>') depth -= 1;
            if (c == ',' and depth == 0) {
                const piece = std.mem.trim(u8, inner[start..i], " ");
                out.append(arena.dupe(u8, piece) catch return null) catch return null;
                start = i + 1;
            }
        }
        const last = std.mem.trim(u8, inner[start..], " ");
        out.append(arena.dupe(u8, last) catch return null) catch return null;
        return out.toOwnedSlice() catch null;
    }

    /// The FULL return-type spelling (with generic args) from a function/method
    /// signature label: `parse(str src) Result<JsonValue>` -> `Result<JsonValue>`,
    /// `unwrap_or(Vec<JsonValue> fallback) Vec<JsonValue>` -> `Vec<JsonValue>`.
    ///
    /// Robust against labels that also contain a method BODY (some index details carry
    /// the whole declaration): it closes the FIRST balanced parameter `(...)`, then
    /// reads only the return-type token-run (base name + balanced `<...>` + `*`/`[]`),
    /// stopping at the body `{` / a second declaration. Returns null when void/absent.
    fn returnTypeFullFromSignatureLabel(detail: []const u8) ?[]const u8 {
        // Close the first balanced parameter list.
        const open = std.mem.indexOfScalar(u8, detail, '(') orelse return null;
        var depth: i64 = 0;
        var i = open;
        var close: ?usize = null;
        while (i < detail.len) : (i += 1) {
            if (detail[i] == '(') depth += 1;
            if (detail[i] == ')') {
                depth -= 1;
                if (depth == 0) {
                    close = i;
                    break;
                }
            }
        }
        const ci = close orelse return null;
        var s = detail[ci + 1 ..];
        // Skip whitespace between `)` and the return type.
        while (s.len != 0 and (s[0] == ' ' or s[0] == '\t' or s[0] == '\n' or s[0] == '\r')) s = s[1..];
        if (s.len == 0) return null;
        // No return type when a body `{` (or another decl) follows immediately.
        if (s[0] == '{') return null;
        // Read base name.
        var end: usize = 0;
        while (end < s.len) {
            const c = s[end];
            const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
            if (!ok) break;
            end += 1;
        }
        if (end == 0) return null;
        // Optional balanced `<...>` generic args.
        if (end < s.len and s[end] == '<') {
            var ad: i64 = 0;
            while (end < s.len) : (end += 1) {
                if (s[end] == '<') ad += 1;
                if (s[end] == '>') {
                    ad -= 1;
                    if (ad == 0) {
                        end += 1;
                        break;
                    }
                }
            }
        }
        // Trailing `*` / `[]`.
        while (end < s.len and (s[end] == '*' or s[end] == '[' or s[end] == ']')) end += 1;
        return std.mem.trim(u8, s[0..end], " ");
    }

    fn guessEnclosingImplType(self: *LspServer, idx: *const Index, at: Position) ?[]const u8 {
        _ = self;
        // Track brace depth and active `impl <Type> {` blocks.
        const Ctx = struct { type_name: []const u8, depth_at_start: i64 };
        var stack = ArrayList(Ctx).init(std.heap.page_allocator);
        defer stack.deinit();

        var pending_impl_type: ?[]const u8 = null;
        var depth: i64 = 0;

        var i: usize = 0;
        while (i < idx.tokens.len) : (i += 1) {
            const t = idx.tokens[i];
            if (t.range.start.line > at.line or (t.range.start.line == at.line and t.range.start.character > at.character)) break;

            if (t.kind == .keyword and std.mem.eql(u8, t.text, "impl")) {
                // Find next identifier token as the concrete type.
                var j = i + 1;
                while (j < idx.tokens.len and (idx.tokens[j].kind == .comment or idx.tokens[j].kind == .keyword)) : (j += 1) {}
                if (j < idx.tokens.len and idx.tokens[j].kind == .identifier) {
                    pending_impl_type = baseTypeNameForLookup(idx.tokens[j].text);
                }
            }

            if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, "{")) {
                depth += 1;
                if (pending_impl_type) |tn| {
                    stack.append(.{ .type_name = tn, .depth_at_start = depth }) catch {};
                    pending_impl_type = null;
                }
                continue;
            }

            if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, "}")) {
                if (stack.items.len != 0 and stack.items[stack.items.len - 1].depth_at_start == depth) {
                    _ = stack.pop();
                }
                depth -= 1;
                continue;
            }
        }

        if (stack.items.len == 0) return null;
        return stack.items[stack.items.len - 1].type_name;
    }

    fn handleReferences(self: *LspServer, id_val: ?std.json.Value, params_val: ?std.json.Value) !void {
        const parsed = try parseTextDocPosition(params_val);
        if (parsed == null) {
            try self.sendResponseJson(id_val, "[]");
            return;
        }
        const uri = parsed.?.uri;
        const doc = self.docs.get(uri) orelse {
            try self.sendResponseJson(id_val, "[]");
            return;
        };
        const pos = normalizePositionToByteColumns(doc.text, parsed.?.pos);
        const idx = doc.index orelse {
            try self.sendResponseJson(id_val, "[]");
            return;
        };
        const tok = findTokenAt(idx.tokens, pos) orelse {
            try self.sendResponseJson(id_val, "[]");
            return;
        };
        if (tok.kind != .identifier) {
            try self.sendResponseJson(id_val, "[]");
            return;
        }

        var out = ArrayList(Location).init(self.allocator);
        defer out.deinit();
        var it = self.docs.iterator();
        while (it.next()) |entry| {
            const this_uri = entry.value_ptr.uri;
            const this_idx = entry.value_ptr.index orelse continue;
            for (this_idx.tokens) |t| {
                if (t.kind == .identifier and std.mem.eql(u8, t.text, tok.text)) {
                    try out.append(.{ .uri = this_uri, .range = t.range });
                }
            }
        }

        const json = try jsonStringifyAlloc(self.allocator, out.items);
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
    }

    fn handleRename(self: *LspServer, id_val: ?std.json.Value, params_val: ?std.json.Value) !void {
        const parsed = try parseRenameParams(params_val);
        if (parsed == null) {
            try self.sendResponseJson(id_val, "null");
            return;
        }
        const uri = parsed.?.uri;
        const new_name = parsed.?.new_name;
        const doc = self.docs.get(uri) orelse {
            try self.sendResponseJson(id_val, "null");
            return;
        };
        const pos = normalizePositionToByteColumns(doc.text, parsed.?.pos);
        const idx = doc.index orelse {
            try self.sendResponseJson(id_val, "null");
            return;
        };
        const tok = findTokenAt(idx.tokens, pos) orelse {
            try self.sendResponseJson(id_val, "null");
            return;
        };
        if (tok.kind != .identifier) {
            try self.sendResponseJson(id_val, "null");
            return;
        }

        // WorkspaceEdit needs dynamic map keys (URIs), so we build JSON manually.
        // Best-effort rename across all indexed documents.
        var json_buf = ArrayList(u8).init(self.allocator);
        defer json_buf.deinit();

        try json_buf.appendSlice("{\"changes\":{");
        var first: bool = true;

        var it = self.docs.iterator();
        while (it.next()) |entry| {
            const this_uri = entry.value_ptr.uri;
            const this_idx = entry.value_ptr.index orelse continue;

            var edits = ArrayList(TextEdit).init(self.allocator);
            defer edits.deinit();
            for (this_idx.tokens) |t| {
                if (t.kind == .identifier and std.mem.eql(u8, t.text, tok.text)) {
                    try edits.append(.{ .range = t.range, .newText = new_name });
                }
            }
            if (edits.items.len == 0) continue;

            if (!first) try json_buf.appendSlice(",");
            first = false;
            try writeJsonString(&json_buf, this_uri);
            try json_buf.appendSlice(":");
            const edits_json = try jsonStringifyAlloc(self.allocator, edits.items);
            defer self.allocator.free(edits_json);
            try json_buf.appendSlice(edits_json);
        }
        try json_buf.appendSlice("}}");

        try self.sendResponseJson(id_val, json_buf.items);
    }

    fn handleCodeAction(self: *LspServer, id_val: ?std.json.Value, params_val: ?std.json.Value) !void {
        const parsed = try parseCodeActionParams(params_val);
        if (parsed == null) {
            try self.sendResponseJson(id_val, "[]");
            return;
        }

        const uri = parsed.?.uri;
        const doc = self.docs.get(uri) orelse {
            try self.sendResponseJson(id_val, "[]");
            return;
        };
        const idx = doc.index orelse {
            try self.sendResponseJson(id_val, "[]");
            return;
        };

        const CodeActionFix = struct {
            title: []const u8,
            range: Range,
            new_text: []const u8,
            is_preferred: bool = true,
        };

        var fixes = ArrayList(CodeActionFix).init(self.allocator);
        defer fixes.deinit();

        // Backing storage for fixes whose `new_text` is built dynamically
        // (unlike the static "async "/"await " literals below) — freed once
        // the JSON response has been serialized.
        var owned_texts = ArrayList([]u8).init(self.allocator);
        defer {
            for (owned_texts.items) |t| self.allocator.free(t);
            owned_texts.deinit();
        }

        for (parsed.?.diagnostics) |diag_val| {
            if (diag_val != .object) continue;
            const range_val = diag_val.object.get("range") orelse continue;

            const msg_val_opt = diag_val.object.get("message");
            const msg_opt: ?[]const u8 = if (msg_val_opt) |mv| switch (mv) {
                .string => mv.string,
                else => null,
            } else null;

            const diag_code = parseDiagnosticCodeValue(diag_val.object.get("code"));

            const diag_range = parseJsonRange(range_val) orelse continue;

            const matches_missing_await = isMissingAwaitDiagnosticCode(diag_code) or
                (diag_code == null and msg_opt != null and isMissingAwaitDiagnosticMessage(msg_opt.?));
            if (matches_missing_await) {
                const insert_range: Range = .{ .start = diag_range.start, .end = diag_range.start };
                const fix: CodeActionFix = .{
                    .title = "Insert 'await'",
                    .range = insert_range,
                    .new_text = "await ",
                    .is_preferred = true,
                };

                var exists = false;
                for (fixes.items) |it| {
                    if (std.mem.eql(u8, it.title, fix.title) and std.mem.eql(u8, it.new_text, fix.new_text) and rangeEqual(it.range, fix.range)) {
                        exists = true;
                        break;
                    }
                }
                if (!exists) try fixes.append(fix);
                continue;
            }

            const matches_await_outside_async = isAwaitOutsideAsyncDiagnosticCode(diag_code) or
                (diag_code == null and msg_opt != null and isAwaitOutsideAsyncDiagnosticMessage(msg_opt.?));
            if (matches_await_outside_async) {
                const insert_pos = findEnclosingFunctionAsyncInsertPosFromTokens(idx.tokens, diag_range.start.line) orelse continue;
                const insert_range: Range = .{ .start = insert_pos, .end = insert_pos };
                const fix: CodeActionFix = .{
                    .title = "Mark enclosing function async",
                    .range = insert_range,
                    .new_text = "async ",
                    .is_preferred = true,
                };

                var exists = false;
                for (fixes.items) |it| {
                    if (std.mem.eql(u8, it.title, fix.title) and std.mem.eql(u8, it.new_text, fix.new_text) and rangeEqual(it.range, fix.range)) {
                        exists = true;
                        break;
                    }
                }
                if (!exists) try fixes.append(fix);
            }

            // `fit` over an enum missing variants (`fit_non_exhaustive` with a
            // named "(missing: Enum.A, Enum.B)" list — the bin/num/unknown
            // variants of this warning have no enumerable set and are left to
            // the diagnostic's own "add catch-all '_'" suggestion).
            if (msg_opt) |m| {
                if (std.mem.indexOf(u8, m, "fit statement is not exhausted for enum '") != null and
                    std.mem.indexOf(u8, m, "(missing: ") != null)
                {
                    if (try self.tryBuildFitMissingArmsFix(idx, uri, m, diag_range)) |built| {
                        try owned_texts.append(built.new_text);
                        const insert_range: Range = .{ .start = built.insert_pos, .end = built.insert_pos };
                        const fix: CodeActionFix = .{
                            .title = "Fill in missing fit arms",
                            .range = insert_range,
                            .new_text = built.new_text,
                            .is_preferred = true,
                        };
                        var exists = false;
                        for (fixes.items) |it| {
                            if (std.mem.eql(u8, it.title, fix.title) and rangeEqual(it.range, fix.range)) {
                                exists = true;
                                break;
                            }
                        }
                        if (!exists) try fixes.append(fix);
                    }
                }

                // `impl Type as Quirk` missing one or more required methods.
                if (std.mem.indexOf(u8, m, "' is missing ") != null and
                    std.mem.indexOf(u8, m, "method(s):\n") != null)
                {
                    if (try self.tryBuildQuirkMissingMethodsFix(idx, m, diag_range)) |built| {
                        try owned_texts.append(built.new_text);
                        const insert_range: Range = .{ .start = built.insert_pos, .end = built.insert_pos };
                        const fix: CodeActionFix = .{
                            .title = "Implement missing quirk methods",
                            .range = insert_range,
                            .new_text = built.new_text,
                            .is_preferred = true,
                        };
                        var exists = false;
                        for (fixes.items) |it| {
                            if (std.mem.eql(u8, it.title, fix.title) and rangeEqual(it.range, fix.range)) {
                                exists = true;
                                break;
                            }
                        }
                        if (!exists) try fixes.append(fix);
                    }
                }
            }
        }

        if (fixes.items.len == 0) {
            try self.sendResponseJson(id_val, "[]");
            return;
        }

        var json_buf = ArrayList(u8).init(self.allocator);
        defer json_buf.deinit();

        try json_buf.append('[');
        for (fixes.items, 0..) |fix, i| {
            if (i != 0) try json_buf.append(',');

            try json_buf.appendSlice("{\"title\":");
            try writeJsonString(&json_buf, fix.title);
            try json_buf.appendSlice(",\"kind\":\"quickfix\",\"isPreferred\":");
            try json_buf.appendSlice(if (fix.is_preferred) "true" else "false");
            try json_buf.appendSlice(",\"edit\":{\"changes\":{");
            try writeJsonString(&json_buf, uri);
            try json_buf.appendSlice(":[{\"range\":");
            try writeRangeJson(&json_buf, fix.range);
            try json_buf.appendSlice(",\"newText\":");
            try writeJsonString(&json_buf, fix.new_text);
            try json_buf.appendSlice("}]}}}");
        }
        try json_buf.append(']');

        try self.sendResponseJson(id_val, json_buf.items);
    }

    /// Build a "Fill in missing fit arms" fix for a `fit_non_exhaustive`
    /// diagnostic over an enum (message shape: "fit statement is not
    /// exhausted for enum 'Name' condition (missing: Name.A, Name.B; add
    /// catch-all '_' branch to silence)"). Inserts one arm per missing
    /// variant, right before the fit block's closing `}`, working cross-file
    /// like `resolveFitBindingType` to read each variant's payload arity.
    /// Returns null when the message/tokens don't match the expected shape.
    fn tryBuildFitMissingArmsFix(self: *LspServer, idx: *const Index, uri: []const u8, msg: []const u8, diag_range: Range) !?struct { insert_pos: Position, new_text: []u8 } {
        const enum_marker = "for enum '";
        const em_i = std.mem.indexOf(u8, msg, enum_marker) orelse return null;
        const after_em = msg[em_i + enum_marker.len ..];
        const enum_end = std.mem.indexOfScalar(u8, after_em, '\'') orelse return null;
        const enum_name = after_em[0..enum_end];

        const missing_marker = "(missing: ";
        const mm_i = std.mem.indexOf(u8, msg, missing_marker) orelse return null;
        const after_mm = msg[mm_i + missing_marker.len ..];
        const missing_end = std.mem.indexOfScalar(u8, after_mm, ';') orelse return null;
        const missing_list = after_mm[0..missing_end];

        const fit_tok_i = findTokenIndexAt(idx.tokens, diag_range.start) orelse return null;
        const braces = findBlockBraceRange(idx.tokens, fit_tok_i) orelse return null;
        const insert_pos = idx.tokens[braces.close_i].range.start;

        const enum_base = baseTypeNameForLookup(enum_name);
        {
            var import_uris = ArrayList([]u8).init(self.allocator);
            defer {
                for (import_uris.items) |u| self.allocator.free(u);
                import_uris.deinit();
            }
            self.collectDirectImportUris(&import_uris, uri, idx) catch {};
            for (import_uris.items) |iu| self.ensureDocIndexedFromDisk(iu) catch {};
        }
        const ehit = self.findEnumDefinitionAnyDoc(uri, enum_base) orelse return null;
        const edoc = self.docs.get(ehit.uri) orelse return null;
        const eidx = edoc.index orelse return null;

        var new_text = ArrayList(u8).init(self.allocator);
        errdefer new_text.deinit();

        var it = std.mem.splitSequence(u8, missing_list, ", ");
        while (it.next()) |entry| {
            const trimmed = std.mem.trim(u8, entry, " ");
            const dot_i = std.mem.lastIndexOfScalar(u8, trimmed, '.') orelse continue;
            const variant_name = trimmed[dot_i + 1 ..];

            var arity: usize = 0;
            while (true) {
                const p = enumVariantPayloadFromDoc(self.allocator, eidx, enum_base, variant_name, arity) orelse break;
                self.allocator.free(p);
                arity += 1;
            }

            try new_text.appendSlice("    ");
            try new_text.appendSlice(enum_name);
            try new_text.append('.');
            try new_text.appendSlice(variant_name);
            if (arity > 0) {
                try new_text.append('(');
                var vi: usize = 0;
                while (vi < arity) : (vi += 1) {
                    if (vi != 0) try new_text.appendSlice(", ");
                    try new_text.print("v{d}", .{vi});
                }
                try new_text.append(')');
            }
            try new_text.appendSlice(" -> {}\n");
        }

        if (new_text.items.len == 0) {
            new_text.deinit();
            return null;
        }

        return .{ .insert_pos = insert_pos, .new_text = try new_text.toOwnedSlice() };
    }

    /// Build an "Implement missing quirk methods" fix for the impl-missing-
    /// methods diagnostic (message shape: "impl 'Type' for quirk 'Quirk' is
    /// missing N method(s):\n- name(args) rtype\n..."). Inserts an empty
    /// `pub` stub per missing method, right before the impl block's closing
    /// `}`. Returns null when the message/tokens don't match the expected
    /// shape (e.g. no method lines actually parsed).
    fn tryBuildQuirkMissingMethodsFix(self: *LspServer, idx: *const Index, msg: []const u8, diag_range: Range) !?struct { insert_pos: Position, new_text: []u8 } {
        const header_end = std.mem.indexOfScalar(u8, msg, '\n') orelse return null;

        const impl_tok_i = findTokenIndexAt(idx.tokens, diag_range.start) orelse return null;
        const braces = findBlockBraceRange(idx.tokens, impl_tok_i) orelse return null;
        const insert_pos = idx.tokens[braces.close_i].range.start;

        var new_text = ArrayList(u8).init(self.allocator);
        errdefer new_text.deinit();

        var lines = std.mem.splitScalar(u8, msg[header_end + 1 ..], '\n');
        var any = false;
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r");
            if (trimmed.len == 0) continue;
            if (!std.mem.startsWith(u8, trimmed, "- ")) continue;
            const sig = trimmed[2..];
            try new_text.appendSlice("  pub ");
            try new_text.appendSlice(sig);
            try new_text.appendSlice(" {\n    // TODO: implement\n  }\n");
            any = true;
        }

        if (!any) {
            new_text.deinit();
            return null;
        }
        return .{ .insert_pos = insert_pos, .new_text = try new_text.toOwnedSlice() };
    }

    fn handleCompletion(self: *LspServer, id_val: ?std.json.Value, params_val: ?std.json.Value) !void {
        const parsed = try parseTextDocPosition(params_val);
        if (parsed == null) {
            try self.sendResponseJson(id_val, "{\"isIncomplete\":false,\"items\":[]}");
            return;
        }
        const uri = parsed.?.uri;
        const pos = parsed.?.pos;
        const doc = self.docs.get(uri) orelse {
            try self.sendResponseJson(id_val, "{\"isIncomplete\":false,\"items\":[]}");
            return;
        };

        // Import path completion: `imp std.c.io;` (no quotes)
        // This does not require a successful full index build, so try it first.
        if (try self.trySendImportCompletions(id_val, uri, doc.text, pos)) return;

        const prefix = guessIdentifierPrefix(doc.text, pos);

        // Warning id completion: `allow <id>, "reason";` / `expect <id>, "reason";`
        if (try self.trySendWarningIdCompletions(id_val, doc.text, pos, prefix)) return;

        // If indexing failed (common while typing / for incomplete files), still return keyword completions.
        const idx = doc.index orelse {
            var items = ArrayList(CompletionItem).init(self.allocator);
            defer {
                for (items.items) |it| {
                    self.allocator.free(it.label);
                    if (it.detail) |d| self.allocator.free(d);
                }
                items.deinit();
            }

            const keywords = [_][]const u8{
                "imp",  "as",    "pub",    "async", "fun",   "compound", "quirk", "impl", "enum", "asm", "volatile", "arch", "defer", "await", "ret",   "if",
                "elif", "else",  "for",    "fit",   "break", "continue", "void",  "raw",  "num",  "dec", "str",      "bin",  "chr",   "true",  "false", "nil",
                "fork", "allow", "expect",
            };
            for (keywords) |kw| {
                if (prefix.len == 0 or std.mem.startsWith(u8, kw, prefix)) {
                    const kw_detail: ?[]u8 = if (std.mem.eql(u8, kw, "async"))
                        try self.allocator.dupe(u8, "keyword: declare async function or method")
                    else if (std.mem.eql(u8, kw, "await"))
                        try self.allocator.dupe(u8, "keyword: await async call result (inside async functions)")
                    else if (std.mem.eql(u8, kw, "nil"))
                        try self.allocator.dupe(u8, "keyword: the null literal (transpiles to NULL)")
                    else if (std.mem.eql(u8, kw, "fork"))
                        try self.allocator.dupe(u8, "keyword: spawn a fire-and-forget virtual thread")
                    else
                        null;
                    try items.append(.{ .label = try self.allocator.dupe(u8, kw), .kind = 14, .detail = kw_detail });
                }
            }

            // Builtins.
            if (prefix.len == 0 or std.mem.startsWith(u8, "sizeof", prefix)) {
                try items.append(.{ .label = try self.allocator.dupe(u8, "sizeof"), .kind = 3 });
            }

            const list: CompletionList = .{ .items = items.items };
            const json = try jsonStringifyAlloc(self.allocator, list);
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return;
        };

        var items = ArrayList(CompletionItem).init(self.allocator);
        defer {
            for (items.items) |it| {
                self.allocator.free(it.label);
                if (it.detail) |d| self.allocator.free(d);
                if (it.insertText) |ins| self.allocator.free(ins);
                if (it.labelDetails) |ld| {
                    if (ld.detail) |d| self.allocator.free(d);
                    if (ld.description) |d| self.allocator.free(d);
                }
                if (it.filterText) |ft| self.allocator.free(ft);
            }
            items.deinit();
        }

        // Compound init field completion (e.g. `User{ na| }` / `.{ ag| }`).
        if (try self.trySendCompoundInitFieldCompletions(id_val, uri, idx, doc.text, pos, prefix)) return;

        // Robust text-based member completion for `receiver.` before other fallbacks.
        const recv_info_opt: ?ReceiverGuess = guessReceiverAtCursorWithIndex(doc.text, pos) orelse blk: {
            if (guessReceiverNameAtCursor(doc.text, pos) orelse guessReceiverNameBeforeCursor(doc.text, pos)) |name| {
                break :blk .{ .name = name, .indexed = false };
            }
            break :blk null;
        };
        if (recv_info_opt) |recv_info| {
            const recv_name = recv_info.name;
            if (try self.trySendAliasNamespaceCompletions(id_val, uri, idx, recv_name, prefix)) return;

            var recv_type: ?[]const u8 = null;
            if (std.mem.eql(u8, recv_name, "self")) {
                recv_type = self.guessEnclosingImplType(idx, pos);
            } else if (self.isKnownTypeName(uri, recv_name)) {
                recv_type = recv_name;
            } else {
                recv_type = self.guessVariableType(idx, uri, recv_name, pos);
            }
            if (recv_type == null) {
                recv_type = guessTypeFromTextFallback(doc.text, recv_name, pos);
            }

            if (recv_type) |rt0| {
                var rt = rt0;
                if (recv_info.indexed and isArrayTypeName(rt)) {
                    rt = rt[0 .. rt.len - 2];
                }
                var seen = std.StringHashMap(void).init(self.allocator);
                defer {
                    var it = seen.iterator();
                    while (it.next()) |e| self.allocator.free(e.key_ptr.*);
                    seen.deinit();
                }
                try self.appendMemberCompletionsFromIndexForType(&items, &seen, idx, rt, prefix);
                try self.appendMemberCompletionsForType(&items, &seen, uri, rt, prefix);
                try self.appendMemberFieldCompletionsFromTokens(&items, &seen, idx, rt, prefix);
                try self.filterMemberCompletionItemsToLocalType(&items, idx, doc.text, rt);
                if (items.items.len != 0) {
                    const list: CompletionList = .{ .items = items.items };
                    const json = try jsonStringifyAlloc(self.allocator, list);
                    defer self.allocator.free(json);
                    try self.sendResponseJson(id_val, json);
                    return;
                }
            }
        }

        // Text-based dot completion fallback.
        // Some lexer states can treat `u.` as a single token, which breaks the
        // token-based dot detection below. Prefer the user's cursor context: if the
        // character immediately before the cursor is '.', offer members for the
        // resolved receiver identifier.
        {
            const cursor_b = byteIndexForPosition(doc.text, pos);
            const dot_i_opt: ?usize = blk: {
                if (cursor_b > 0 and doc.text[cursor_b - 1] == '.') break :blk cursor_b - 1;
                if (cursor_b < doc.text.len and doc.text[cursor_b] == '.') break :blk cursor_b;
                break :blk null;
            };

            if (dot_i_opt) |dot_i| {
                // Find the identifier directly before the dot.
                var j: usize = dot_i;
                while (j > 0) {
                    const ch = doc.text[j - 1];
                    if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
                        j -= 1;
                        continue;
                    }
                    break;
                }
                var start: usize = j;
                while (start > 0) {
                    const ch = doc.text[start - 1];
                    const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
                    if (!ok) break;
                    start -= 1;
                }
                const recv_name = if (start < j) doc.text[start..j] else "";

                if (recv_name.len != 0) {
                    if (try self.trySendAliasNamespaceCompletions(id_val, uri, idx, recv_name, prefix)) return;

                    var recv_type: ?[]const u8 = null;
                    if (std.mem.eql(u8, recv_name, "self")) {
                        recv_type = self.guessEnclosingImplType(idx, pos);
                    } else if (self.isKnownTypeName(uri, recv_name)) {
                        recv_type = recv_name;
                    } else {
                        recv_type = self.guessVariableType(idx, uri, recv_name, pos);
                    }

                    if (recv_type == null) {
                        recv_type = guessTypeFromTextFallback(doc.text, recv_name, pos);
                    }

                    if (recv_type) |rt| {
                        var seen = std.StringHashMap(void).init(self.allocator);
                        defer {
                            var it = seen.iterator();
                            while (it.next()) |e| self.allocator.free(e.key_ptr.*);
                            seen.deinit();
                        }

                        try self.appendMemberCompletionsFromIndexForType(&items, &seen, idx, rt, prefix);
                        try self.appendMemberCompletionsForType(&items, &seen, uri, rt, prefix);
                        try self.appendMemberFieldCompletionsFromTokens(&items, &seen, idx, rt, prefix);
                        try self.filterMemberCompletionItemsToLocalType(&items, idx, doc.text, rt);
                        if (items.items.len != 0) {
                            const list: CompletionList = .{ .items = items.items };
                            const json = try jsonStringifyAlloc(self.allocator, list);
                            defer self.allocator.free(json);
                            try self.sendResponseJson(id_val, json);
                            return;
                        }
                    }
                }
            }
        }

        // If we're completing after a '.', offer members of the resolved receiver type.
        const tok_i_opt = findTokenIndexAt(idx.tokens, pos) orelse findLastTokenIndexBeforeOrAt(idx.tokens, pos);
        if (tok_i_opt) |tok_i| {
            const t = idx.tokens[tok_i];
            var receiver_last_ident_i: ?usize = null;
            var dot_i_opt: ?usize = null;

            if (isDotToken(t)) {
                dot_i_opt = tok_i;
                if (tok_i >= 1 and idx.tokens[tok_i - 1].kind == .identifier) receiver_last_ident_i = tok_i - 1;
            } else if (t.kind == .identifier and tok_i >= 1 and isDotToken(idx.tokens[tok_i - 1])) {
                dot_i_opt = tok_i - 1;
                if (tok_i >= 2 and idx.tokens[tok_i - 2].kind == .identifier) receiver_last_ident_i = tok_i - 2;
            }

            if (receiver_last_ident_i == null) {
                if (dot_i_opt) |dot_i| {
                    if (dot_i >= 1 and idx.tokens[dot_i - 1].text.len == 1 and idx.tokens[dot_i - 1].text[0] == ']') {
                        var depth: i64 = 0;
                        var k: isize = @intCast(dot_i);
                        var ident_i_opt: ?usize = null;
                        while (k > 0) : (k -= 1) {
                            const tk = idx.tokens[@intCast(k - 1)];
                            if (tk.text.len == 1 and tk.text[0] == ']') depth += 1;
                            if (tk.text.len == 1 and tk.text[0] == '[') {
                                depth -= 1;
                                if (depth == 0) {
                                    if (k >= 2 and idx.tokens[@intCast(k - 2)].kind == .identifier) {
                                        ident_i_opt = @intCast(k - 2);
                                    }
                                    break;
                                }
                            }
                        }

                        if (ident_i_opt) |ii| {
                            const recv_name = idx.tokens[ii].text;
                            if (try self.trySendAliasNamespaceCompletions(id_val, uri, idx, recv_name, prefix)) return;

                            var recv_type: ?[]const u8 = null;
                            if (std.mem.eql(u8, recv_name, "self")) {
                                recv_type = self.guessEnclosingImplType(idx, pos);
                            } else if (self.isKnownTypeName(uri, recv_name)) {
                                recv_type = recv_name;
                            } else {
                                recv_type = self.guessVariableType(idx, uri, recv_name, pos);
                            }
                            if (recv_type == null) {
                                recv_type = guessTypeFromTextFallback(doc.text, recv_name, pos);
                            }

                            if (recv_type) |rt0| {
                                var rt = rt0;
                                if (isArrayTypeName(rt)) {
                                    rt = rt[0 .. rt.len - 2];
                                }
                                var seen = std.StringHashMap(void).init(self.allocator);
                                defer {
                                    var it = seen.iterator();
                                    while (it.next()) |e| self.allocator.free(e.key_ptr.*);
                                    seen.deinit();
                                }
                                try self.appendMemberCompletionsFromIndexForType(&items, &seen, idx, rt, prefix);
                                try self.appendMemberCompletionsForType(&items, &seen, uri, rt, prefix);
                                try self.appendMemberFieldCompletionsFromTokens(&items, &seen, idx, rt, prefix);
                                try self.filterMemberCompletionItemsToLocalType(&items, idx, doc.text, rt);
                                if (items.items.len != 0) {
                                    const list: CompletionList = .{ .items = items.items };
                                    const json = try jsonStringifyAlloc(self.allocator, list);
                                    defer self.allocator.free(json);
                                    try self.sendResponseJson(id_val, json);
                                    return;
                                }
                            }
                        }
                    } else if (dot_i >= 1 and idx.tokens[dot_i - 1].text.len == 1 and idx.tokens[dot_i - 1].text[0] == ')') {
                        // Method-chain result: the receiver expression ends in `)`
                        // (e.g. `a.get(x).unwrap_or(y).`). Resolve the chain-result
                        // type and offer ITS members. A data-enum chain result must
                        // route here (member methods), NOT into the `.Variant`
                        // dot-shorthand path — that path is only for a bare `.Variant`
                        // with no receiver expression.
                        const expr_last_i = prevNonTrivialTokenLite(idx.tokens, dot_i) orelse idx.tokens.len;
                        if (expr_last_i < idx.tokens.len) {
                            if (self.resolveTypeOfExprEndingAtToken(idx, uri, pos, expr_last_i)) |recv_type| {
                                var seen = std.StringHashMap(void).init(self.allocator);
                                defer {
                                    var it = seen.iterator();
                                    while (it.next()) |e| self.allocator.free(e.key_ptr.*);
                                    seen.deinit();
                                }
                                try self.appendMemberCompletionsFromIndexForType(&items, &seen, idx, recv_type, prefix);
                                try self.appendMemberCompletionsForType(&items, &seen, uri, recv_type, prefix);
                                try self.appendMemberFieldCompletionsFromTokens(&items, &seen, idx, recv_type, prefix);
                                try self.filterMemberCompletionItemsToLocalType(&items, idx, doc.text, recv_type);
                                if (items.items.len != 0) {
                                    const list: CompletionList = .{ .items = items.items };
                                    const json = try jsonStringifyAlloc(self.allocator, list);
                                    defer self.allocator.free(json);
                                    try self.sendResponseJson(id_val, json);
                                    return;
                                }
                            }
                        }
                    }
                }
            }

            if (receiver_last_ident_i) |ri| {
                // Special-case: `std.<...>` behaves like a module namespace.
                // This does not go through value-type inference.
                if (try self.trySendStdNamespaceCompletions(id_val, uri, idx, pos, ri, prefix)) return;

                if (try self.trySendAliasNamespaceCompletions(id_val, uri, idx, idx.tokens[ri].text, prefix)) return;

                if (self.resolveTypeOfChainUpTo(idx, uri, pos, ri)) |recv_type| {
                    var seen = std.StringHashMap(void).init(self.allocator);
                    defer {
                        var it = seen.iterator();
                        while (it.next()) |e| self.allocator.free(e.key_ptr.*);
                        seen.deinit();
                    }
                    try self.appendMemberCompletionsFromIndexForType(&items, &seen, idx, recv_type, prefix);
                    try self.appendMemberCompletionsForType(&items, &seen, uri, recv_type, prefix);
                    try self.appendMemberFieldCompletionsFromTokens(&items, &seen, idx, recv_type, prefix);
                    try self.filterMemberCompletionItemsToLocalType(&items, idx, doc.text, recv_type);
                    if (items.items.len != 0) {
                        const list: CompletionList = .{ .items = items.items };
                        const json = try jsonStringifyAlloc(self.allocator, list);
                        defer self.allocator.free(json);
                        try self.sendResponseJson(id_val, json);
                        return;
                    }
                } else {
                    const recv_name = idx.tokens[ri].text;
                    if (guessTypeFromTextFallback(doc.text, recv_name, pos)) |rt| {
                        var seen = std.StringHashMap(void).init(self.allocator);
                        defer {
                            var it = seen.iterator();
                            while (it.next()) |e| self.allocator.free(e.key_ptr.*);
                            seen.deinit();
                        }
                        try self.appendMemberCompletionsFromIndexForType(&items, &seen, idx, rt, prefix);
                        try self.appendMemberCompletionsForType(&items, &seen, uri, rt, prefix);
                        try self.appendMemberFieldCompletionsFromTokens(&items, &seen, idx, rt, prefix);
                        try self.filterMemberCompletionItemsToLocalType(&items, idx, doc.text, rt);
                        if (items.items.len != 0) {
                            const list: CompletionList = .{ .items = items.items };
                            const json = try jsonStringifyAlloc(self.allocator, list);
                            defer self.allocator.free(json);
                            try self.sendResponseJson(id_val, json);
                            return;
                        }
                    }
                }
            }

            // Fallback: some lexer states may emit `u.` as a single identifier token (`"u."`).
            // When that happens, the dot-token path above can't trigger.
            if (t.kind == .identifier and t.text.len > 1 and std.mem.endsWith(u8, t.text, ".")) {
                const recv_name = t.text[0 .. t.text.len - 1];
                if (recv_name.len != 0) {
                    if (try self.trySendAliasNamespaceCompletions(id_val, uri, idx, recv_name, prefix)) return;

                    var recv_type: ?[]const u8 = null;
                    if (std.mem.eql(u8, recv_name, "self")) {
                        recv_type = self.guessEnclosingImplType(idx, pos);
                    } else if (self.isKnownTypeName(uri, recv_name)) {
                        recv_type = recv_name;
                    } else {
                        recv_type = self.guessVariableType(idx, uri, recv_name, pos);
                    }

                    if (recv_type) |rt| {
                        var seen = std.StringHashMap(void).init(self.allocator);
                        defer {
                            var it = seen.iterator();
                            while (it.next()) |e| self.allocator.free(e.key_ptr.*);
                            seen.deinit();
                        }
                        try self.appendMemberCompletionsFromIndexForType(&items, &seen, idx, rt, prefix);
                        try self.appendMemberCompletionsForType(&items, &seen, uri, rt, prefix);
                        try self.appendMemberFieldCompletionsFromTokens(&items, &seen, idx, rt, prefix);
                        try self.filterMemberCompletionItemsToLocalType(&items, idx, doc.text, rt);
                        if (items.items.len != 0) {
                            const list: CompletionList = .{ .items = items.items };
                            const json = try jsonStringifyAlloc(self.allocator, list);
                            defer self.allocator.free(json);
                            try self.sendResponseJson(id_val, json);
                            return;
                        }
                    }
                }
            }
        }

        // Keywords. Statement/declaration keywords (`imp`, `pub`, `fun`, `if`,
        // `for`, ...) and bare type keywords (`num`, `str`, ...) can never
        // start a value expression, so offering them right after `(` or `,`
        // — i.e. at the start of a call argument — is pure noise; only the
        // literal-value keywords stay relevant there.
        const at_call_arg_start: bool = blk: {
            const ti_opt = findTokenIndexAt(idx.tokens, pos) orelse findLastTokenIndexBeforeOrAt(idx.tokens, pos);
            const ti = ti_opt orelse break :blk false;
            const check_tok = idx.tokens[ti];
            const paren_i: usize = if (isOpenParen(check_tok))
                ti
            else pi: {
                // Cursor is inside/after a partial identifier (the completion
                // `prefix`); check the token immediately before IT instead.
                const prev_i = prevNonTrivialTokenLite(idx.tokens, ti) orelse break :blk false;
                if (!isOpenParen(idx.tokens[prev_i])) break :blk false;
                break :pi prev_i;
            };
            // A `(` right after `fun`/`pub`/`async <name>` is a PARAMETER LIST
            // (or an `if`/`fit`/`for` subject call), where type names and other
            // keywords are still valid completions — only suppress for a plain
            // call/grouping paren. (A `,`-preceded position is left as-is too,
            // to keep this check simple and safe.)
            const name_i = prevNonTrivialTokenLite(idx.tokens, paren_i) orelse break :blk true;
            if (idx.tokens[name_i].kind == .identifier and callParenIsDeclaration(idx.tokens, name_i, paren_i)) {
                break :blk false;
            }
            break :blk true;
        };
        const keywords_all = [_][]const u8{
            "imp",  "as",    "pub",    "async", "fun",   "compound", "quirk", "impl", "enum", "asm", "volatile", "arch", "defer", "await", "ret",   "if",
            "elif", "else",  "for",    "fit",   "break", "continue", "void",  "raw",  "num",  "dec", "str",      "bin",  "chr",   "true",  "false", "nil",
            "fork", "allow", "expect",
        };
        const keywords_call_arg = [_][]const u8{ "true", "false", "nil" };
        const keywords: []const []const u8 = if (at_call_arg_start) &keywords_call_arg else &keywords_all;
        for (keywords) |kw| {
            if (prefix.len == 0 or std.mem.startsWith(u8, kw, prefix)) {
                const kw_detail: ?[]u8 = if (std.mem.eql(u8, kw, "async"))
                    try self.allocator.dupe(u8, "keyword: declare async function or method")
                else if (std.mem.eql(u8, kw, "await"))
                    try self.allocator.dupe(u8, "keyword: await async call result (inside async functions)")
                else
                    null;
                try items.append(.{ .label = try self.allocator.dupe(u8, kw), .kind = 14, .detail = kw_detail });
            }
        }

        // Builtins.
        if (prefix.len == 0 or std.mem.startsWith(u8, "sizeof", prefix)) {
            try items.append(.{
                .label = try self.allocator.dupe(u8, "sizeof"),
                .kind = 3, // CompletionItemKind.Function
                .detail = try self.allocator.dupe(u8, "builtin: sizeof(Type) num"),
            });
        }

        // C macro constants (best-effort): offer completions when the corresponding
        // C header module is imported. We intentionally do NOT model these as Fun
        // globals/consts because they are macros provided by the C preprocessor.
        try self.appendCMacroCompletionsForImports(&items, idx, prefix);

        // Symbols (only current file + direct imports).
        var seen = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = seen.iterator();
            while (it.next()) |e| self.allocator.free(e.key_ptr.*);
            seen.deinit();
        }

        // --- Dot shorthand enum completions ---
        // If the cursor is at a position where a dot shorthand is valid (e.g., after '=' or in a function argument),
        // and the expected type is an enum, suggest only the matching enum members (no leading '.' in labels).
        const dot_shorthand_active: bool = blk: {
            // Prefer token-based detection when possible.
            const ti_opt = findTokenIndexAt(idx.tokens, pos) orelse findLastTokenIndexBeforeOrAt(idx.tokens, pos);
            if (ti_opt) |ti| {
                const t = idx.tokens[ti];
                if (t.kind == .identifier and t.text.len > 1 and t.text[0] == '.') {
                    break :blk true;
                }
                if (t.kind == .identifier and ti > 0 and isDotToken(idx.tokens[ti - 1])) {
                    // Not shorthand when a receiver expression precedes the dot:
                    // `Type.Member`, or a call/index result `foo().Member` / `a[i].Member`.
                    if (ti >= 2 and idx.tokens[ti - 2].kind == .identifier) break :blk false;
                    if (ti >= 2 and isChainCloserLite(idx.tokens[ti - 2])) break :blk false;
                    break :blk true;
                }
                if (isDotToken(t)) {
                    // Not shorthand when a receiver expression precedes the dot:
                    // `Type.`, or a call/index result `foo().` / `a[i].`.
                    if (ti >= 1 and idx.tokens[ti - 1].kind == .identifier) break :blk false;
                    if (ti >= 1 and isChainCloserLite(idx.tokens[ti - 1])) break :blk false;
                    break :blk true;
                }
            }

            // Fallback: raw text heuristic (handles some lexer edge cases).
            const cursor_b = byteIndexForPosition(doc.text, pos);
            const prefix_start: usize = if (cursor_b >= prefix.len) cursor_b - prefix.len else cursor_b;

            const dot_i_opt: ?usize = blk2: {
                if (prefix.len != 0 and prefix_start > 0 and doc.text[prefix_start - 1] == '.') break :blk2 prefix_start - 1;
                if (cursor_b > 0 and doc.text[cursor_b - 1] == '.') break :blk2 cursor_b - 1;
                if (cursor_b < doc.text.len and doc.text[cursor_b] == '.') break :blk2 cursor_b;
                break :blk2 null;
            };
            if (dot_i_opt == null) break :blk false;

            // Ensure there's no receiver identifier before the dot (shorthand only).
            // The receiver would have to be adjacent to the dot on the SAME line,
            // so skip only spaces/tabs (never newlines). A Fun keyword before the
            // dot (e.g. `ret .`) is NOT a receiver — treat it as bare-dot shorthand.
            var j: usize = dot_i_opt.?;
            while (j > 0) {
                const ch = doc.text[j - 1];
                if (ch == ' ' or ch == '\t') {
                    j -= 1;
                    continue;
                }
                break;
            }
            // A call/index result (`)` / `]`) before the dot is a member access on
            // that result, never a bare `.Variant` shorthand.
            if (j > 0 and (doc.text[j - 1] == ')' or doc.text[j - 1] == ']')) break :blk false;
            var start: usize = j;
            while (start > 0) {
                const ch = doc.text[start - 1];
                const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
                if (!ok) break;
                start -= 1;
            }
            const recv_name = if (start < j) doc.text[start..j] else "";
            break :blk recv_name.len == 0 or isReceiverStopKeyword(recv_name);
        };

        if ((prefix.len == 1 and prefix[0] == '.') or dot_shorthand_active) {
            // A dot shorthand (`.Variant`) or a bare `.` never completes to keywords
            // or arbitrary symbols. Drop anything appended above (the unconditional
            // keyword/symbol dump) so we return an enum-only (or empty) list.
            for (items.items) |it| {
                self.allocator.free(it.label);
                if (it.detail) |d| self.allocator.free(d);
                if (it.insertText) |ins| self.allocator.free(ins);
                if (it.labelDetails) |ld| {
                    if (ld.detail) |d| self.allocator.free(d);
                    if (ld.description) |d| self.allocator.free(d);
                }
                if (it.filterText) |ft| self.allocator.free(ft);
            }
            items.clearRetainingCapacity();

            const dot_tok_i_opt = findTokenIndexAt(idx.tokens, pos) orelse findLastTokenIndexBeforeOrAt(idx.tokens, pos);
            if (dot_tok_i_opt) |dot_tok_i| {
                if (self.guessEnumTypeForDotShorthand(uri, idx, dot_tok_i)) |enum_name| {
                    const enum_base = baseTypeNameForLookup(enum_name);
                    // Offer only members of the inferred enum.
                    // Current doc.
                    for (idx.symbols) |s| {
                        if (s.kind != .enumMember) continue;
                        if (s.container_type == null or !std.mem.eql(u8, baseTypeNameForLookup(s.container_type.?), enum_base)) continue;
                        const ft = try std.fmt.allocPrint(self.allocator, ".{s}", .{s.name});
                        const det: []const u8 = enumVariantSigFromDetail(s, enum_name) orelse enum_name;
                        try items.append(.{
                            .label = try self.allocator.dupe(u8, s.name),
                            .kind = 20,
                            .detail = try self.allocator.dupe(u8, det),
                            .insertText = try self.allocator.dupe(u8, s.name),
                            .filterText = ft,
                        });
                    }

                    // Direct imports.
                    var import_uris = ArrayList([]u8).init(self.allocator);
                    defer {
                        for (import_uris.items) |u| self.allocator.free(u);
                        import_uris.deinit();
                    }
                    try self.collectDirectImportUris(&import_uris, uri, idx);
                    for (import_uris.items) |iu| {
                        self.ensureDocIndexedFromDisk(iu) catch {};
                        const imported = self.docs.get(iu) orelse continue;
                        const didx = imported.index orelse continue;
                        for (didx.symbols) |s| {
                            if (s.kind != .enumMember) continue;
                            if (s.container_type == null or !std.mem.eql(u8, baseTypeNameForLookup(s.container_type.?), enum_base)) continue;
                            if (!self.isSymbolVisibleFromUri(uri, iu, s)) continue;
                            const ft = try std.fmt.allocPrint(self.allocator, ".{s}", .{s.name});
                            const det: []const u8 = enumVariantSigFromDetail(s, enum_name) orelse enum_name;
                            try items.append(.{
                                .label = try self.allocator.dupe(u8, s.name),
                                .kind = 20,
                                .detail = try self.allocator.dupe(u8, det),
                                .insertText = try self.allocator.dupe(u8, s.name),
                                .filterText = ft,
                            });
                        }
                    }

                    const list: CompletionList = .{ .items = items.items };
                    const json = try jsonStringifyAlloc(self.allocator, list);
                    defer self.allocator.free(json);
                    try self.sendResponseJson(id_val, json);
                    return;
                }
            }
            // Fallback: offer members of all enums in scope.
            var enums = ArrayList(struct { name: []const u8, uri: []const u8 }).init(self.allocator);
            defer {
                for (enums.items) |e| self.allocator.free(e.name);
                enums.deinit();
            }
            for (idx.symbols) |s| {
                if (s.kind == .enum_ and s.container_type == null) {
                    try enums.append(.{ .name = try self.allocator.dupe(u8, s.name), .uri = uri });
                }
            }
            var import_uris = ArrayList([]u8).init(self.allocator);
            defer {
                for (import_uris.items) |u| self.allocator.free(u);
                import_uris.deinit();
            }
            try self.collectDirectImportUris(&import_uris, uri, idx);
            for (import_uris.items) |iu| {
                self.ensureDocIndexedFromDisk(iu) catch {};
                const imported = self.docs.get(iu) orelse continue;
                const didx = imported.index orelse continue;
                for (didx.symbols) |s| {
                    if (s.kind == .enum_ and s.container_type == null) {
                        if (!self.isSymbolVisibleFromUri(uri, iu, s)) continue;
                        try enums.append(.{ .name = try self.allocator.dupe(u8, s.name), .uri = iu });
                    }
                }
            }
            for (enums.items) |e| {
                const eidx = self.docs.get(e.uri).?.index orelse continue;
                for (eidx.symbols) |s| {
                    if (s.kind != .enumMember) continue;
                    if (s.container_type == null or !std.mem.eql(u8, s.container_type.?, e.name)) continue;
                    if (!self.isSymbolVisibleFromUri(uri, e.uri, s)) continue;
                    const ft = try std.fmt.allocPrint(self.allocator, ".{s}", .{s.name});
                    const det: []const u8 = enumVariantSigFromDetail(s, e.name) orelse e.name;
                    try items.append(.{
                        .label = try self.allocator.dupe(u8, s.name),
                        .kind = 20,
                        .detail = try self.allocator.dupe(u8, det),
                        .insertText = try self.allocator.dupe(u8, s.name),
                        .filterText = ft,
                    });
                }
            }
            const list: CompletionList = .{ .items = items.items };
            const json = try jsonStringifyAlloc(self.allocator, list);
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return;
        }
        // Current doc.
        var has_locals_in_scope = false;
        for (idx.symbols) |s| {
            if (s.container_fn_range) |cr| {
                if (posInRange(pos, cr)) {
                    has_locals_in_scope = true;
                    break;
                }
            }
        }

        // 1) Locals first (prefer locals on name collisions).
        for (idx.symbols) |s| {
            if (s.container_type != null) continue;
            if (s.container_fn_range == null) continue;
            if (has_locals_in_scope) {
                if (s.container_fn_range) |cr| {
                    if (!posInRange(pos, cr)) continue;
                }
            }
            if (prefix.len != 0 and !std.mem.startsWith(u8, s.name, prefix)) continue;

            const key = try self.allocator.dupe(u8, s.name);
            if (seen.contains(key)) {
                self.allocator.free(key);
                continue;
            }
            try seen.put(key, {});

            try items.append(try self.buildSymbolCompletionItem(s));
        }

        // 2) Current-document globals/types/functions.
        for (idx.symbols) |s| {
            if (s.container_type != null) continue;
            if (s.container_fn_range != null) continue;
            if (prefix.len != 0 and !std.mem.startsWith(u8, s.name, prefix)) continue;

            const key = try self.allocator.dupe(u8, s.name);
            if (seen.contains(key)) {
                self.allocator.free(key);
                continue;
            }
            try seen.put(key, {});

            try items.append(try self.buildSymbolCompletionItem(s));
        }

        // Direct imports.
        var import_uris = ArrayList([]u8).init(self.allocator);
        defer {
            for (import_uris.items) |u| self.allocator.free(u);
            import_uris.deinit();
        }
        try self.collectDirectImportUris(&import_uris, uri, idx);

        for (import_uris.items) |iu| {
            self.ensureDocIndexedFromDisk(iu) catch {};
            const imported = self.docs.get(iu) orelse continue;
            const didx = imported.index orelse continue;
            for (didx.symbols) |s| {
                // Only suggest non-member-ish items for global completion.
                // (Fields/properties are typically completed after '.' and can be very noisy.)
                if (s.container_type != null) continue;
                if (s.container_fn_range != null) continue;
                if (!self.isSymbolVisibleFromUri(uri, iu, s)) continue;

                if (prefix.len != 0 and !std.mem.startsWith(u8, s.name, prefix)) continue;

                const key = try self.allocator.dupe(u8, s.name);
                if (seen.contains(key)) {
                    self.allocator.free(key);
                    continue;
                }
                try seen.put(key, {});

                try items.append(try self.buildSymbolCompletionItem(s));
            }
        }

        const list: CompletionList = .{ .items = items.items };
        const json = try jsonStringifyAlloc(self.allocator, list);
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
    }

    fn trySendAliasHover(self: *LspServer, id_val: ?std.json.Value, current_uri: []const u8, idx: *const Index, alias_name: []const u8, range: Range) !bool {
        const info = self.findAliasedImportSpecAndRange(idx, alias_name) orelse return false;
        defer self.allocator.free(info.spec);

        var buf = ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        try buf.print("_alias for `{s}`_\n", .{info.spec});

        if (self.resolveImportUri(current_uri, info.spec) catch null) |target_uri| {
            defer self.allocator.free(target_uri);
            if (uriToPath(self.allocator, target_uri) catch null) |target_path| {
                defer self.allocator.free(target_path);
                try buf.print("\n`{s}`\n", .{target_path});
            }
        }

        const hover: Hover = .{ .contents = .{ .value = buf.items }, .range = range };
        const json = try jsonStringifyAlloc(self.allocator, hover);
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
        return true;
    }

    fn findAliasedImportUri(self: *LspServer, current_uri: []const u8, idx: *const Index, alias_name: []const u8) ?[]u8 {
        for (idx.tokens, 0..) |t, i| {
            if (t.kind != .keyword or !std.mem.eql(u8, t.text, "imp")) continue;

            const spec = self.parseImportSpecFromTokens(idx, i) catch null orelse continue;
            defer self.allocator.free(spec);

            var j: usize = i + 1;
            var saw_as = false;
            while (j < idx.tokens.len) : (j += 1) {
                const tk = idx.tokens[j];
                if ((tk.kind == .symbol or tk.kind == .operator) and std.mem.eql(u8, tk.text, ";")) break;
                if (!saw_as and tk.kind == .keyword and std.mem.eql(u8, tk.text, "as")) {
                    saw_as = true;
                    continue;
                }
                if (saw_as and tk.kind == .identifier) {
                    if (std.mem.eql(u8, tk.text, alias_name)) {
                        return (self.resolveImportUri(current_uri, spec) catch null);
                    }
                    saw_as = false;
                }
            }
        }

        // Fallback: line-based parse (handles some incomplete-token states while typing).
        if (self.docs.get(current_uri)) |doc| {
            const text = doc.text;
            var line_start: usize = 0;
            while (line_start < text.len) {
                var line_end = line_start;
                while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}

                const line_raw = text[line_start..line_end];
                const line = std.mem.trim(u8, line_raw, " \t\r");
                if (line.len >= 4 and std.mem.startsWith(u8, line, "imp ")) {
                    const after_imp = std.mem.trim(u8, line[4..], " \t\r");
                    if (std.mem.indexOf(u8, after_imp, " as ")) |as_idx| {
                        const spec = std.mem.trim(u8, after_imp[0..as_idx], " \t\r");
                        var alias_part = std.mem.trim(u8, after_imp[as_idx + 4 ..], " \t\r");
                        if (alias_part.len > 0 and alias_part[alias_part.len - 1] == ';') {
                            alias_part = std.mem.trim(u8, alias_part[0 .. alias_part.len - 1], " \t\r");
                        }
                        if (std.mem.eql(u8, alias_part, alias_name)) {
                            return (self.resolveImportUri(current_uri, spec) catch null);
                        }
                    }
                }

                line_start = if (line_end < text.len) line_end + 1 else line_end;
            }
        }

        return null;
    }

    fn findAliasedImportSpecAndRange(self: *LspServer, idx: *const Index, alias_name: []const u8) ?struct { spec: []u8, range: Range } {
        for (idx.tokens, 0..) |t, i| {
            if (t.kind != .keyword or !std.mem.eql(u8, t.text, "imp")) continue;

            const spec = self.parseImportSpecFromTokens(idx, i) catch null orelse continue;

            var j: usize = i + 1;
            var saw_as = false;
            var matched = false;
            var matched_range: Range = undefined;
            while (j < idx.tokens.len) : (j += 1) {
                const tk = idx.tokens[j];
                if ((tk.kind == .symbol or tk.kind == .operator) and std.mem.eql(u8, tk.text, ";")) break;
                if (!saw_as and tk.kind == .keyword and std.mem.eql(u8, tk.text, "as")) {
                    saw_as = true;
                    continue;
                }
                if (saw_as and tk.kind == .identifier) {
                    if (std.mem.eql(u8, tk.text, alias_name)) {
                        matched = true;
                        matched_range = tk.range;
                        break;
                    }
                    saw_as = false;
                }
            }

            if (matched) {
                return .{ .spec = spec, .range = matched_range };
            }
            self.allocator.free(spec);
        }

        return null;
    }

    fn appendCompoundInitFieldCompletionsForType(
        self: *LspServer,
        items: *ArrayList(CompletionItem),
        seen: *std.StringHashMap(void),
        preferred_uri: []const u8,
        container_type: []const u8,
        prefix: []const u8,
    ) !void {
        const container_base = baseTypeNameForLookup(container_type);
        var it = self.docs.iterator();
        while (it.next()) |entry| {
            const uri = entry.value_ptr.uri;
            const didx = entry.value_ptr.index orelse continue;
            for (didx.symbols) |s| {
                if (s.container_fn_range != null) continue;
                if (s.container_type == null) continue;
                if (!std.mem.eql(u8, baseTypeNameForLookup(s.container_type.?), container_base)) continue;
                if (!(s.kind == .field or s.kind == .property)) continue;
                if (prefix.len != 0 and !std.mem.startsWith(u8, s.name, prefix)) continue;
                if (!self.isSymbolVisibleFromUri(preferred_uri, uri, s)) continue;

                const key = try self.allocator.dupe(u8, s.name);
                if (seen.contains(key)) {
                    self.allocator.free(key);
                    continue;
                }
                try seen.put(key, {});

                const detail = if (s.value_type) |vt| try self.allocator.dupe(u8, vt) else null;

                var insert_buf = ArrayList(u8).init(self.allocator);
                defer insert_buf.deinit();
                try insert_buf.print("{s} = ", .{s.name});

                try items.append(.{
                    .label = try self.allocator.dupe(u8, s.name),
                    .kind = 5, // CompletionItemKind.Field
                    .detail = detail,
                    .insertText = try self.allocator.dupe(u8, insert_buf.items),
                });
            }
        }
    }

    fn appendCompoundInitFieldCompletionsFromTokens(
        self: *LspServer,
        items: *ArrayList(CompletionItem),
        seen: *std.StringHashMap(void),
        idx: *const Index,
        container_type: []const u8,
        prefix: []const u8,
    ) !void {
        const nextNonComment = struct {
            fn call(tokens: []const TokenLite, start_index: usize) ?usize {
                var i = start_index;
                while (i < tokens.len) : (i += 1) {
                    if (tokens[i].kind != .comment) return i;
                }
                return null;
            }
        }.call;

        const isIdentLite = struct {
            fn call(t: TokenLite) bool {
                return t.kind == .identifier;
            }
        }.call;

        const isSymbolLite = struct {
            fn call(t: TokenLite, ch: u8) bool {
                return (t.kind == .symbol or t.kind == .operator) and t.text.len == 1 and t.text[0] == ch;
            }
        }.call;

        const isTypeLike = struct {
            fn call(t: TokenLite) bool {
                if (t.kind == .identifier) return true;
                if (t.kind != .keyword) return false;
                const s = t.text;
                return std.mem.eql(u8, s, "num") or std.mem.eql(u8, s, "dec") or std.mem.eql(u8, s, "str") or std.mem.eql(u8, s, "bin") or std.mem.eql(u8, s, "chr") or std.mem.eql(u8, s, "raw") or std.mem.eql(u8, s, "void") or std.mem.eql(u8, s, "f32") or std.mem.eql(u8, s, "f64") or std.mem.eql(u8, s, "i8") or std.mem.eql(u8, s, "i16") or std.mem.eql(u8, s, "i32") or std.mem.eql(u8, s, "i64") or std.mem.eql(u8, s, "u8") or std.mem.eql(u8, s, "u16") or std.mem.eql(u8, s, "u32") or std.mem.eql(u8, s, "u64");
            }
        }.call;

        var i: usize = 0;
        while (i < idx.tokens.len) : (i += 1) {
            if (idx.tokens[i].kind != .keyword or !std.mem.eql(u8, idx.tokens[i].text, "compound")) continue;

            const name_i = nextNonComment(idx.tokens, i + 1) orelse continue;
            if (!isIdentLite(idx.tokens[name_i])) continue;
            if (!std.mem.eql(u8, idx.tokens[name_i].text, container_type)) continue;

            var j_opt = nextNonComment(idx.tokens, name_i + 1);
            while (j_opt) |j| {
                if (!isSymbolLite(idx.tokens[j], '{')) {
                    j_opt = nextNonComment(idx.tokens, j + 1);
                    continue;
                }

                var depth: i64 = 1;
                var k: usize = j + 1;
                while (k < idx.tokens.len and depth > 0) : (k += 1) {
                    const tk = idx.tokens[k];
                    if (isSymbolLite(tk, '{')) depth += 1;
                    if (isSymbolLite(tk, '}')) depth -= 1;
                    if (depth != 1) continue;
                    if (!isTypeLike(tk)) continue;

                    const field_name_i = fieldNameIndexAfterTypeLite(idx.tokens, k) orelse continue;
                    if (!isIdentLite(idx.tokens[field_name_i])) continue;
                    const after_name_i = nextNonTrivialTokenLite(idx.tokens, field_name_i + 1) orelse continue;
                    if (!isSymbolLite(idx.tokens[after_name_i], ';')) continue;

                    const fname = idx.tokens[field_name_i].text;
                    if (prefix.len != 0 and !std.mem.startsWith(u8, fname, prefix)) {
                        k = after_name_i;
                        continue;
                    }

                    const key = try self.allocator.dupe(u8, fname);
                    if (seen.contains(key)) {
                        self.allocator.free(key);
                        k = after_name_i;
                        continue;
                    }
                    try seen.put(key, {});

                    var insert_buf = ArrayList(u8).init(self.allocator);
                    defer insert_buf.deinit();
                    try insert_buf.print("{s} = ", .{fname});

                    try items.append(.{
                        .label = try self.allocator.dupe(u8, fname),
                        .kind = 5,
                        .detail = null,
                        .insertText = try self.allocator.dupe(u8, insert_buf.items),
                    });

                    k = after_name_i;
                }

                break;
            }
        }
    }

    fn appendCompoundInitFieldCompletionsFromText(
        self: *LspServer,
        items: *ArrayList(CompletionItem),
        seen: *std.StringHashMap(void),
        text: []const u8,
        container_type: []const u8,
        prefix: []const u8,
    ) !void {
        var line_start: usize = 0;
        var in_target = false;

        while (line_start < text.len) {
            var line_end = line_start;
            while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}

            const raw = text[line_start..line_end];
            var line = std.mem.trim(u8, raw, " \t\r");

            if (!in_target) {
                if (line.len >= "compound ".len and std.mem.startsWith(u8, line, "compound ")) {
                    var rest = std.mem.trim(u8, line["compound ".len..], " \t\r");
                    var name_end: usize = 0;
                    while (name_end < rest.len) : (name_end += 1) {
                        const ch = rest[name_end];
                        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
                        if (!ok) break;
                    }
                    if (name_end > 0 and std.mem.eql(u8, rest[0..name_end], container_type)) {
                        in_target = true;
                    }
                }
            } else {
                if (std.mem.indexOfScalar(u8, line, '}') != null) {
                    in_target = false;
                } else {
                    if (line.len >= 4 and std.mem.startsWith(u8, line, "pub ")) {
                        line = std.mem.trim(u8, line[4..], " \t\r");
                    }

                    const semi_idx = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
                    const decl = std.mem.trim(u8, line[0..semi_idx], " \t\r");

                    const sp = std.mem.lastIndexOfScalar(u8, decl, ' ') orelse {
                        line_start = if (line_end < text.len) line_end + 1 else line_end;
                        continue;
                    };
                    const field_name = std.mem.trim(u8, decl[sp + 1 ..], " \t\r");
                    if (field_name.len == 0) {
                        line_start = if (line_end < text.len) line_end + 1 else line_end;
                        continue;
                    }

                    if (prefix.len != 0 and !std.mem.startsWith(u8, field_name, prefix)) {
                        line_start = if (line_end < text.len) line_end + 1 else line_end;
                        continue;
                    }

                    const key = try self.allocator.dupe(u8, field_name);
                    if (seen.contains(key)) {
                        self.allocator.free(key);
                        line_start = if (line_end < text.len) line_end + 1 else line_end;
                        continue;
                    }
                    try seen.put(key, {});

                    var insert_buf = ArrayList(u8).init(self.allocator);
                    defer insert_buf.deinit();
                    try insert_buf.print("{s} = ", .{field_name});

                    try items.append(.{
                        .label = try self.allocator.dupe(u8, field_name),
                        .kind = 5,
                        .detail = null,
                        .insertText = try self.allocator.dupe(u8, insert_buf.items),
                    });
                }
            }

            line_start = if (line_end < text.len) line_end + 1 else line_end;
        }
    }

    fn detectCompoundInitTypeAtCursor(
        self: *LspServer,
        uri: []const u8,
        idx: *const Index,
        text: []const u8,
        pos: Position,
    ) ?[]const u8 {
        const cursor = byteIndexForPosition(text, pos);

        // Find nearest unmatched '{' before cursor.
        var depth: i64 = 0;
        var i: usize = cursor;
        var open_i: ?usize = null;
        while (i > 0) {
            i -= 1;
            const ch = text[i];
            if (ch == '}') {
                depth += 1;
                continue;
            }
            if (ch == '{') {
                if (depth == 0) {
                    open_i = i;
                    break;
                }
                depth -= 1;
            }
        }
        if (open_i == null) return null;

        // Examine token(s) before '{'.
        var j: usize = open_i.?;
        while (j > 0 and (text[j - 1] == ' ' or text[j - 1] == '\t' or text[j - 1] == '\r' or text[j - 1] == '\n')) : (j -= 1) {}
        if (j == 0) return null;

        // Generic compound init: `Box<num>{ ... }` / `Map<str, num>{ ... }`.
        // Skip backward over a balanced `<...>` generic-argument run so the
        // identifier scan below lands on the base type name (`Box`/`Map`). The
        // field index keys fields under the base name and matching already strips
        // generics, so recovering the base name is all that's needed.
        if (j > 0 and text[j - 1] == '>') {
            var gdepth: i64 = 0;
            var gi: usize = j;
            while (gi > 0) {
                gi -= 1;
                const ch = text[gi];
                if (ch == '>') {
                    gdepth += 1;
                } else if (ch == '<') {
                    gdepth -= 1;
                    if (gdepth == 0) {
                        j = gi;
                        break;
                    }
                } else if (ch == ';' or ch == '{' or ch == '}') {
                    // Not a generic-arg run (e.g. a stray `>`); leave `j` as-is.
                    break;
                }
            }
            // Skip any whitespace between the type name and `<`.
            while (j > 0 and (text[j - 1] == ' ' or text[j - 1] == '\t' or text[j - 1] == '\r' or text[j - 1] == '\n')) : (j -= 1) {}
            if (j == 0) return null;
        }

        // Shorthand compound init: `.{ ... }`
        if (text[j - 1] == '.') {
            // Infer expected type from simple assignment context: `x = .{ ... }`.
            var k: usize = j - 1;
            var eq_i: ?usize = null;
            while (k > 0) {
                k -= 1;
                const ch = text[k];
                if (ch == '=' and (k == 0 or text[k - 1] != '=')) {
                    eq_i = k;
                    break;
                }
                if (ch == ';' or ch == '\n' or ch == '{' or ch == '}') break;
            }
            if (eq_i) |eqp| {
                var r: usize = eqp;
                while (r > 0 and (text[r - 1] == ' ' or text[r - 1] == '\t' or text[r - 1] == '\r' or text[r - 1] == '\n')) : (r -= 1) {}

                var start: usize = r;
                while (start > 0) {
                    const ch = text[start - 1];
                    const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
                    if (!ok) break;
                    start -= 1;
                }

                if (start < r) {
                    const lhs_name = text[start..r];
                    if (self.guessVariableType(idx, uri, lhs_name, pos)) |tname| return tname;
                    if (guessTypeFromTextFallback(text, lhs_name, pos)) |tname| return tname;
                }
            }
            return null;
        }

        // Explicit init: `Type{ ... }` / `alias.Type{ ... }`.
        const end_ident: usize = j;
        var start_ident: usize = end_ident;
        while (start_ident > 0) {
            const ch = text[start_ident - 1];
            const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
            if (!ok) break;
            start_ident -= 1;
        }
        if (start_ident == end_ident) return null;

        // Hardening: don't treat a `compound`/`enum`/`quirk` DEFINITION body as an
        // init literal. If the identifier before `{` is itself immediately preceded
        // (modulo whitespace) by one of those keywords, the cursor is inside a type
        // definition, not a `Type{...}` initializer — returning the type name here
        // sends completion down the field-init path, which previously could hang on
        // a partial field line. (Primary hang fix is the line_start advance above;
        // this closes the whole class.)
        {
            var kw_end: usize = start_ident;
            while (kw_end > 0 and (text[kw_end - 1] == ' ' or text[kw_end - 1] == '\t' or text[kw_end - 1] == '\r' or text[kw_end - 1] == '\n')) : (kw_end -= 1) {}
            var kw_start: usize = kw_end;
            while (kw_start > 0) {
                const ch = text[kw_start - 1];
                const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
                if (!ok) break;
                kw_start -= 1;
            }
            if (kw_start < kw_end) {
                const kw = text[kw_start..kw_end];
                if (std.mem.eql(u8, kw, "compound") or std.mem.eql(u8, kw, "enum") or std.mem.eql(u8, kw, "quirk") or std.mem.eql(u8, kw, "impl")) {
                    return null;
                }
            }
        }

        const type_name = text[start_ident..end_ident];
        return type_name;
    }

    fn trySendCompoundInitFieldCompletions(
        self: *LspServer,
        id_val: ?std.json.Value,
        uri: []const u8,
        idx: *const Index,
        text: []const u8,
        pos: Position,
        prefix: []const u8,
    ) !bool {
        const container_type = self.detectCompoundInitTypeAtCursor(uri, idx, text, pos) orelse return false;

        var items = ArrayList(CompletionItem).init(self.allocator);
        defer {
            for (items.items) |it| {
                self.allocator.free(it.label);
                if (it.detail) |d| self.allocator.free(d);
                if (it.insertText) |ins| self.allocator.free(ins);
                if (it.labelDetails) |ld| {
                    if (ld.detail) |d| self.allocator.free(d);
                    if (ld.description) |d| self.allocator.free(d);
                }
            }
            items.deinit();
        }

        var seen = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = seen.iterator();
            while (it.next()) |e| self.allocator.free(e.key_ptr.*);
            seen.deinit();
        }

        try self.appendCompoundInitFieldCompletionsForType(&items, &seen, uri, container_type, prefix);
        if (items.items.len == 0) {
            try self.appendCompoundInitFieldCompletionsFromTokens(&items, &seen, idx, baseTypeNameForLookup(container_type), prefix);
        }
        if (items.items.len == 0) {
            if (self.docs.get(uri)) |doc| {
                try self.appendCompoundInitFieldCompletionsFromText(&items, &seen, doc.text, baseTypeNameForLookup(container_type), prefix);
            }
        }
        if (items.items.len == 0) return false;

        if (items.items.len == 0) return false;

        const list: CompletionList = .{ .items = items.items };
        const json = try jsonStringifyAlloc(self.allocator, list);
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
        return true;
    }

    fn trySendAliasNamespaceCompletions(self: *LspServer, id_val: ?std.json.Value, current_uri: []const u8, idx: *const Index, alias_name: []const u8, prefix: []const u8) !bool {
        const target_uri = self.findAliasedImportUri(current_uri, idx, alias_name) orelse return false;
        defer self.allocator.free(target_uri);

        self.ensureDocIndexedFromDisk(target_uri) catch {};
        const didx_opt: ?*const Index = blk: {
            const doc = self.docs.get(target_uri) orelse break :blk null;
            const didx = doc.index orelse break :blk null;
            break :blk didx;
        };

        var items = ArrayList(CompletionItem).init(self.allocator);
        defer {
            for (items.items) |it| {
                self.allocator.free(it.label);
                if (it.detail) |d| self.allocator.free(d);
                if (it.insertText) |ins| self.allocator.free(ins);
                if (it.labelDetails) |ld| {
                    if (ld.detail) |d| self.allocator.free(d);
                    if (ld.description) |d| self.allocator.free(d);
                }
                if (it.filterText) |ft| self.allocator.free(ft);
            }
            items.deinit();
        }

        var seen = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = seen.iterator();
            while (it.next()) |e| self.allocator.free(e.key_ptr.*);
            seen.deinit();
        }

        if (didx_opt) |didx| {
            for (didx.symbols) |s| {
                if (!s.is_public) continue;
                if (s.container_fn_range != null) continue;
                if (s.container_type != null) continue;
                if (prefix.len != 0 and !std.mem.startsWith(u8, s.name, prefix)) continue;

                const ck: i64 = switch (s.kind) {
                    .function => 3,
                    .variable => 6,
                    .constant => 21,
                    .enum_ => 13,
                    .struct_, .class, .interface, .typeParameter => 7,
                    else => 6,
                };

                var key_buf = ArrayList(u8).init(self.allocator);
                defer key_buf.deinit();
                try key_buf.print("{s}:{d}", .{ s.name, ck });
                const key = try self.allocator.dupe(u8, key_buf.items);
                if (seen.contains(key)) {
                    self.allocator.free(key);
                    continue;
                }
                try seen.put(key, {});

                const insert_text = try self.completionInsertTextForSymbol(s);

                try items.append(.{
                    .label = try self.allocator.dupe(u8, s.name),
                    .kind = ck,
                    .detail = if (s.detail) |d| try self.allocator.dupe(u8, d) else null,
                    .insertText = insert_text,
                });
            }
        }

        if (items.items.len == 0) {
            const target_path = uriToPath(self.allocator, target_uri) catch null;
            if (target_path) |p| {
                defer self.allocator.free(p);
                const module_text = if (std.fs.path.isAbsolute(p))
                    (std.Io.Dir.openFileAbsolute(globalIo(), p, .{}) catch null)
                else
                    (std.Io.Dir.cwd().openFile(globalIo(), p, .{}) catch null);

                if (module_text) |f| {
                    defer f.close(globalIo());
                    const text = fileReadAlloc(self.allocator, f, 512 * 1024) catch null;
                    if (text) |src| {
                        defer self.allocator.free(src);

                        var line_start: usize = 0;
                        while (line_start < src.len) {
                            var line_end = line_start;
                            while (line_end < src.len and src[line_end] != '\n') : (line_end += 1) {}

                            const raw = src[line_start..line_end];
                            const line = std.mem.trim(u8, raw, " \t\r");

                            if (line.len >= 4 and std.mem.startsWith(u8, line, "pub ")) {
                                const rest = std.mem.trim(u8, line[4..], " \t\r");
                                var label: ?[]const u8 = null;
                                var kind: i64 = 6;

                                if (std.mem.startsWith(u8, rest, "fun ")) {
                                    const sig = rest[4..];
                                    const lp = std.mem.indexOfScalar(u8, sig, '(') orelse sig.len;
                                    const name = std.mem.trim(u8, sig[0..lp], " \t\r");
                                    if (name.len != 0) {
                                        label = name;
                                        kind = 3;
                                    }
                                } else if (std.mem.startsWith(u8, rest, "compound ")) {
                                    const s = rest[9..];
                                    var nend: usize = 0;
                                    while (nend < s.len) : (nend += 1) {
                                        const ch = s[nend];
                                        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
                                        if (!ok) break;
                                    }
                                    if (nend > 0) {
                                        label = s[0..nend];
                                        kind = 7;
                                    }
                                } else if (std.mem.startsWith(u8, rest, "quirk ")) {
                                    const s = rest[6..];
                                    var nend: usize = 0;
                                    while (nend < s.len) : (nend += 1) {
                                        const ch = s[nend];
                                        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
                                        if (!ok) break;
                                    }
                                    if (nend > 0) {
                                        label = s[0..nend];
                                        kind = 8;
                                    }
                                } else if (std.mem.startsWith(u8, rest, "enum ")) {
                                    const s = rest[5..];
                                    var nend: usize = 0;
                                    while (nend < s.len) : (nend += 1) {
                                        const ch = s[nend];
                                        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
                                        if (!ok) break;
                                    }
                                    if (nend > 0) {
                                        label = s[0..nend];
                                        kind = 13;
                                    }
                                } else {
                                    // pub <type> <name> [= ...];
                                    if (std.mem.lastIndexOfScalar(u8, rest, ' ')) |sp| {
                                        var name_raw = std.mem.trim(u8, rest[sp + 1 ..], " \t\r");
                                        if (std.mem.indexOfScalar(u8, name_raw, '=')) |eqp| {
                                            name_raw = std.mem.trim(u8, name_raw[0..eqp], " \t\r");
                                        }
                                        if (name_raw.len > 0 and name_raw[name_raw.len - 1] == ';') {
                                            name_raw = std.mem.trim(u8, name_raw[0 .. name_raw.len - 1], " \t\r");
                                        }
                                        if (name_raw.len != 0) {
                                            label = name_raw;
                                            kind = 6;
                                        }
                                    }
                                }

                                if (label) |name| {
                                    if (prefix.len == 0 or std.mem.startsWith(u8, name, prefix)) {
                                        const key = try self.allocator.dupe(u8, name);
                                        if (!seen.contains(key)) {
                                            try seen.put(key, {});
                                            try items.append(.{ .label = try self.allocator.dupe(u8, name), .kind = kind });
                                        } else {
                                            self.allocator.free(key);
                                        }
                                    }
                                }
                            }

                            line_start = if (line_end < src.len) line_end + 1 else line_end;
                        }
                    }
                }
            }
        }

        const list: CompletionList = .{ .items = items.items };
        const json = try jsonStringifyAlloc(self.allocator, list);
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
        return true;
    }

    fn appendCMacroCompletionsForImports(self: *LspServer, items: *ArrayList(CompletionItem), idx: *const Index, prefix: []const u8) !void {
        if (prefix.len == 0) return;
        // Macros are ALL_CAPS; only offer them for an uppercase/underscore prefix to
        // avoid noise. Lowercase prefixes may still match a stddef TYPE name (`size_t`),
        // so we don't bail outright — `offer_macros` just gates the macro lists.
        const c0 = prefix[0];
        const offer_macros = (c0 >= 'A' and c0 <= 'Z') or c0 == '_';

        var has_limits = false;
        var has_stddef = false;

        for (idx.tokens, 0..) |t, i| {
            if (t.kind != .keyword or !std.mem.eql(u8, t.text, "imp")) continue;
            const spec = try self.parseImportSpecFromTokens(idx, i) orelse continue;
            defer self.allocator.free(spec);

            if (std.mem.eql(u8, spec, "std.c.limits")) has_limits = true;
            if (std.mem.eql(u8, spec, "std.c.def")) has_stddef = true;
        }

        if (!has_limits and !has_stddef) return;

        const Macro = struct { name: []const u8, detail: []const u8 };

        // `std.c.def` (stddef.h) — value macros. Ownership mirrors the compiler's
        // `c_builtin_owner_module` table (transpiler.zig), so completion matches what
        // actually resolves at compile time.
        const stddef_macros = [_]Macro{
            .{ .name = "NULL", .detail = "stddef.h macro (prefer the `nil` keyword)" },
            .{ .name = "SIZE_MAX", .detail = "stddef.h-related macro" },
            .{ .name = "RSIZE_MAX", .detail = "stddef.h-related macro" },
            .{ .name = "PTRDIFF_MIN", .detail = "stddef.h-related macro" },
            .{ .name = "PTRDIFF_MAX", .detail = "stddef.h-related macro" },
            .{ .name = "WCHAR_MIN", .detail = "stddef.h-related macro" },
            .{ .name = "WCHAR_MAX", .detail = "stddef.h-related macro" },
            .{ .name = "WINT_MIN", .detail = "stddef.h-related macro" },
            .{ .name = "WINT_MAX", .detail = "stddef.h-related macro" },
        };

        // `std.c.def` type names (offered as types when the user opts in).
        const stddef_types = [_]Macro{
            .{ .name = "size_t", .detail = "stddef.h type (numeric-compatible)" },
            .{ .name = "ptrdiff_t", .detail = "stddef.h type (numeric-compatible)" },
            .{ .name = "wchar_t", .detail = "stddef.h type (numeric-compatible)" },
            .{ .name = "rsize_t", .detail = "stddef.h type (numeric-compatible)" },
            .{ .name = "va_list", .detail = "stdarg.h opaque type" },
            .{ .name = "max_align_t", .detail = "stddef.h opaque alignment type" },
        };

        const limits_macros = [_]Macro{
            .{ .name = "CHAR_BIT", .detail = "limits.h macro" },
            .{ .name = "MB_LEN_MAX", .detail = "limits.h macro" },

            .{ .name = "SCHAR_MIN", .detail = "limits.h macro" },
            .{ .name = "SCHAR_MAX", .detail = "limits.h macro" },
            .{ .name = "UCHAR_MAX", .detail = "limits.h macro" },
            .{ .name = "CHAR_MIN", .detail = "limits.h macro" },
            .{ .name = "CHAR_MAX", .detail = "limits.h macro" },

            .{ .name = "SHRT_MIN", .detail = "limits.h macro" },
            .{ .name = "SHRT_MAX", .detail = "limits.h macro" },
            .{ .name = "USHRT_MAX", .detail = "limits.h macro" },

            .{ .name = "INT_MIN", .detail = "limits.h macro" },
            .{ .name = "INT_MAX", .detail = "limits.h macro" },
            .{ .name = "UINT_MAX", .detail = "limits.h macro" },

            .{ .name = "LONG_MIN", .detail = "limits.h macro" },
            .{ .name = "LONG_MAX", .detail = "limits.h macro" },
            .{ .name = "ULONG_MAX", .detail = "limits.h macro" },

            .{ .name = "LLONG_MIN", .detail = "limits.h macro" },
            .{ .name = "LLONG_MAX", .detail = "limits.h macro" },
            .{ .name = "ULLONG_MAX", .detail = "limits.h macro" },
            // Note: SIZE_MAX / RSIZE_MAX / PTRDIFF_* / WCHAR_* / WINT_* are owned by
            // `std.c.def` (see the compiler's c_builtin_owner_module table), so they are
            // offered from `stddef_macros` above, not here.
        };

        if (has_stddef) {
            if (offer_macros) {
                for (stddef_macros) |m| {
                    if (!std.mem.startsWith(u8, m.name, prefix)) continue;
                    try items.append(.{
                        .label = try self.allocator.dupe(u8, m.name),
                        .kind = 21, // CompletionItemKind.Constant
                        .detail = try self.allocator.dupe(u8, m.detail),
                    });
                }
            }
            for (stddef_types) |m| {
                if (!std.mem.startsWith(u8, m.name, prefix)) continue;
                try items.append(.{
                    .label = try self.allocator.dupe(u8, m.name),
                    .kind = 22, // CompletionItemKind.Struct (a type)
                    .detail = try self.allocator.dupe(u8, m.detail),
                });
            }
        }

        if (has_limits and offer_macros) {
            for (limits_macros) |m| {
                if (!std.mem.startsWith(u8, m.name, prefix)) continue;
                try items.append(.{
                    .label = try self.allocator.dupe(u8, m.name),
                    .kind = 21, // CompletionItemKind.Constant
                    .detail = try self.allocator.dupe(u8, m.detail),
                });
            }
        }
    }

    fn trySendStdNamespaceCompletions(
        self: *LspServer,
        id_val: ?std.json.Value,
        current_uri: []const u8,
        idx: *const Index,
        pos: Position,
        receiver_last_ident_i: usize,
        prefix: []const u8,
    ) !bool {
        _ = pos;

        // Reconstruct the identifier chain for the receiver (e.g. `std.io` in `std.io.<cursor>`).
        var ids = ArrayList(usize).init(self.allocator);
        defer ids.deinit();

        var start_i: usize = receiver_last_ident_i;
        while (start_i >= 2) {
            const dot = idx.tokens[start_i - 1];
            const left = idx.tokens[start_i - 2];
            if (isDotToken(dot) and left.kind == .identifier) {
                start_i -= 2;
                continue;
            }
            break;
        }

        var j: usize = start_i;
        while (j <= receiver_last_ident_i) {
            if (idx.tokens[j].kind != .identifier) return false;
            try ids.append(j);
            if (j == receiver_last_ident_i) break;
            if (j + 2 > receiver_last_ident_i) return false;
            if (!isDotToken(idx.tokens[j + 1])) return false;
            j += 2;
        }
        if (ids.items.len == 0) return false;

        const base = idx.tokens[ids.items[0]].text;
        if (!std.mem.eql(u8, base, "std")) return false;

        // We need a stdlib root to serve std namespace completions.
        var stdlib_root = self.getStdlibRootPath() orelse null;
        if (stdlib_root == null) {
            self.tryStdlibRootFromCurrentDoc(current_uri);
            stdlib_root = self.getStdlibRootPath() orelse null;
        }
        const root = stdlib_root orelse return false;

        var items = ArrayList(CompletionItem).init(self.allocator);
        defer {
            for (items.items) |ci| {
                self.allocator.free(ci.label);
                if (ci.detail) |d| self.allocator.free(d);
                if (ci.insertText) |ins| self.allocator.free(ins);
                if (ci.filterText) |ft| self.allocator.free(ft);
            }
            items.deinit();
        }

        // Build the path under stdlib.
        var segs = ArrayList([]const u8).init(self.allocator);
        defer segs.deinit();
        try segs.append(root);
        try segs.append("std");

        // Receiver chain beyond `std`.
        var k: usize = 1;
        while (k < ids.items.len) : (k += 1) {
            try segs.append(idx.tokens[ids.items[k]].text);
        }

        // Candidate module file: <root>/std/c/<chain...>.fn
        const receiver_path_no_ext = try std.fs.path.join(self.allocator, segs.items);
        defer self.allocator.free(receiver_path_no_ext);

        const receiver_file = try std.mem.concat(self.allocator, u8, &[_][]const u8{ receiver_path_no_ext, ".fn" });
        defer self.allocator.free(receiver_file);

        // 1) If receiver resolves to a module file, complete its exported globals.
        // Use openFile rather than access(): it differentiates files from directories.
        var is_file: bool = false;
        if (std.fs.path.isAbsolute(receiver_file)) {
            if (std.Io.Dir.openFileAbsolute(globalIo(), receiver_file, .{}) catch null) |f| {
                f.close(globalIo());
                is_file = true;
            }
        } else {
            if (std.Io.Dir.cwd().openFile(globalIo(), receiver_file, .{}) catch null) |f| {
                f.close(globalIo());
                is_file = true;
            }
        }

        if (is_file) {
            const receiver_uri = try pathToUri(self.allocator, receiver_file);
            defer self.allocator.free(receiver_uri);
            self.ensureDocIndexedFromDisk(receiver_uri) catch {};
            const doc = self.docs.get(receiver_uri) orelse return false;
            const didx = doc.index orelse return false;

            for (didx.symbols) |s| {
                if (s.container_type != null) continue;
                if (s.container_fn_range != null) continue;
                if (prefix.len != 0 and !std.mem.startsWith(u8, s.name, prefix)) continue;
                if (!self.isSymbolVisibleFromUri(current_uri, receiver_uri, s)) continue;

                const kind: i64 = switch (s.kind) {
                    .function => 3,
                    .variable => 6,
                    .struct_ => 7,
                    .interface => 8,
                    else => 6,
                };

                try items.append(.{
                    .label = try self.allocator.dupe(u8, s.name),
                    .kind = kind,
                    .detail = if (s.detail) |d| try self.allocator.dupe(u8, d) else null,
                });
            }

            const list: CompletionList = .{ .items = items.items };
            const json = try jsonStringifyAlloc(self.allocator, list);
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return true;
        }

        // 2) Otherwise treat receiver as a directory and list modules/subfolders.
        if (std.fs.path.isAbsolute(receiver_path_no_ext)) {
            if (std.Io.Dir.openDirAbsolute(globalIo(), receiver_path_no_ext, .{ .iterate = true }) catch null) |dir| {
                var dir_mut = dir;
                defer dir_mut.close(globalIo());
                var it = dir_mut.iterate();

                var saw_c_dir: bool = false;
                var saw_any_fn: bool = false;
                while (it.next(globalIo()) catch null) |entry| {
                    if (entry.kind == .directory) {
                        if (prefix.len != 0 and !std.mem.startsWith(u8, entry.name, prefix)) continue;
                        try items.append(.{ .label = try self.allocator.dupe(u8, entry.name), .kind = 19 });
                        if (ids.items.len == 1 and std.mem.eql(u8, entry.name, "c")) saw_c_dir = true;
                    } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".fn")) {
                        const base_name = entry.name[0 .. entry.name.len - 3];
                        if (prefix.len != 0 and !std.mem.startsWith(u8, base_name, prefix)) continue;
                        try items.append(.{ .label = try self.allocator.dupe(u8, base_name), .kind = 17 });
                        saw_any_fn = true;
                    }
                }

                // Convenience: if completing `std.` and the repo layout places modules under `std/c/*`,
                // surface those leaf modules directly at `std.` (e.g. `io`).
                if (ids.items.len == 1 and saw_c_dir and !saw_any_fn) {
                    const c_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ receiver_path_no_ext, "c" });
                    defer self.allocator.free(c_dir);
                    if (std.Io.Dir.openDirAbsolute(globalIo(), c_dir, .{ .iterate = true }) catch null) |cdir| {
                        var cdir_mut = cdir;
                        defer cdir_mut.close(globalIo());
                        var it2 = cdir_mut.iterate();
                        while (it2.next(globalIo()) catch null) |e2| {
                            if (e2.kind != .file) continue;
                            if (!std.mem.endsWith(u8, e2.name, ".fn")) continue;
                            const base_name = e2.name[0 .. e2.name.len - 3];
                            if (prefix.len != 0 and !std.mem.startsWith(u8, base_name, prefix)) continue;
                            try items.append(.{ .label = try self.allocator.dupe(u8, base_name), .kind = 17 });
                        }
                    }
                }
            }
        }

        const list: CompletionList = .{ .items = items.items };
        const json = try jsonStringifyAlloc(self.allocator, list);
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
        return true;
    }

    fn getStdlibRootForNamespace(self: *LspServer, current_uri: []const u8) ?[]const u8 {
        var stdlib_root = self.getStdlibRootPath() orelse null;
        if (stdlib_root == null) {
            self.tryStdlibRootFromCurrentDoc(current_uri);
            stdlib_root = self.getStdlibRootPath() orelse null;
        }
        return stdlib_root;
    }

    fn collectDotChainIdentifiersAround(
        self: *LspServer,
        idx: *const Index,
        ident_i: usize,
        ids: *ArrayList(usize),
    ) !bool {
        _ = self;
        if (idx.tokens[ident_i].kind != .identifier) return false;

        // Scan left over `. <ident>`.
        var start_i: usize = ident_i;
        while (start_i >= 2) {
            const dot = idx.tokens[start_i - 1];
            const left = idx.tokens[start_i - 2];
            if (isDotToken(dot) and left.kind == .identifier) {
                start_i -= 2;
                continue;
            }
            break;
        }

        // Scan right over `. <ident>`.
        var end_i: usize = ident_i;
        while (end_i + 2 < idx.tokens.len) {
            const dot = idx.tokens[end_i + 1];
            const right = idx.tokens[end_i + 2];
            if (isDotToken(dot) and right.kind == .identifier) {
                end_i += 2;
                continue;
            }
            break;
        }

        var j: usize = start_i;
        while (j <= end_i) {
            if (idx.tokens[j].kind != .identifier) return false;
            try ids.append(j);
            if (j == end_i) break;
            if (j + 2 > end_i) return false;
            if (!isDotToken(idx.tokens[j + 1])) return false;
            j += 2;
        }
        return ids.items.len != 0;
    }

    fn buildStdModuleFilePathFromIds(
        self: *LspServer,
        current_uri: []const u8,
        idx: *const Index,
        ids: []const usize,
        module_last_inclusive: usize,
    ) !?[]u8 {
        if (ids.len == 0) return null;
        if (!std.mem.eql(u8, idx.tokens[ids[0]].text, "std")) return null;

        const root = self.getStdlibRootForNamespace(current_uri) orelse return null;

        var segs = ArrayList([]const u8).init(self.allocator);
        defer segs.deinit();
        try segs.append(root);
        try segs.append("std");

        if (module_last_inclusive < 1) return null;

        var k: usize = 1;
        while (k <= module_last_inclusive) : (k += 1) {
            try segs.append(idx.tokens[ids[k]].text);
        }

        const no_ext = try std.fs.path.join(self.allocator, segs.items);
        errdefer self.allocator.free(no_ext);
        const file_path = try std.mem.concat(self.allocator, u8, &[_][]const u8{ no_ext, ".fn" });
        self.allocator.free(no_ext);
        return file_path;
    }

    fn tryOpenExistingFile(self: *LspServer, abs_or_rel_path: []const u8) bool {
        _ = self;
        if (std.fs.path.isAbsolute(abs_or_rel_path)) {
            if (std.Io.Dir.openFileAbsolute(globalIo(), abs_or_rel_path, .{}) catch null) |f| {
                f.close(globalIo());
                return true;
            }
            return false;
        }

        if (std.Io.Dir.cwd().openFile(globalIo(), abs_or_rel_path, .{}) catch null) |f| {
            f.close(globalIo());
            return true;
        }
        return false;
    }

    fn findTopLevelSymbol(idx: *const Index, name: []const u8) ?SymbolLite {
        for (idx.symbols) |s| {
            if (s.container_type != null) continue;
            if (s.container_fn_range != null) continue;
            if (!s.is_public) continue;
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    fn trySendStdNamespaceDefinition(
        self: *LspServer,
        id_val: ?std.json.Value,
        current_uri: []const u8,
        idx: *const Index,
        tok_i: usize,
    ) !bool {
        if (idx.tokens[tok_i].kind != .identifier) return false;

        var ids = ArrayList(usize).init(self.allocator);
        defer ids.deinit();
        if (!try self.collectDotChainIdentifiersAround(idx, tok_i, &ids)) return false;
        if (ids.items.len == 0) return false;

        if (!std.mem.eql(u8, idx.tokens[ids.items[0]].text, "std")) return false;

        var selected_idx_opt: ?usize = null;
        for (ids.items, 0..) |ti, si| {
            if (ti == tok_i) {
                selected_idx_opt = si;
                break;
            }
        }
        const selected_idx = selected_idx_opt orelse return false;

        // Clicked `std` itself -> jump to stdlib README.
        if (selected_idx == 0) {
            const root = self.getStdlibRootForNamespace(current_uri) orelse return false;
            const readme_path = try std.fs.path.join(self.allocator, &.{ root, "README.md" });
            defer self.allocator.free(readme_path);
            if (!self.tryOpenExistingFile(readme_path)) return false;
            const target_uri = try pathToUri(self.allocator, readme_path);
            defer self.allocator.free(target_uri);
            const locs = [_]Location{.{
                .uri = target_uri,
                .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
            }};
            const json = try jsonStringifyAlloc(self.allocator, locs);
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return true;
        }

        // Determine whether the full chain names a module file. This is critical for nested
        // modules like `std.c.io` (module) vs `std.c.io.printf` (symbol).
        const chain_last: usize = ids.items.len - 1;
        const full_module_file = (try self.buildStdModuleFilePathFromIds(current_uri, idx, ids.items, chain_last)) orelse return false;
        defer self.allocator.free(full_module_file);
        const full_chain_is_module = self.tryOpenExistingFile(full_module_file);

        const is_symbol = (selected_idx == chain_last) and !full_chain_is_module and ids.items.len >= 3;

        if (is_symbol) {
            const symbol_name = idx.tokens[ids.items[ids.items.len - 1]].text;
            const module_last_inclusive: usize = ids.items.len - 2;
            const module_file = (try self.buildStdModuleFilePathFromIds(current_uri, idx, ids.items, module_last_inclusive)) orelse return false;
            defer self.allocator.free(module_file);
            if (!self.tryOpenExistingFile(module_file)) return false;

            const module_uri = try pathToUri(self.allocator, module_file);
            defer self.allocator.free(module_uri);
            self.ensureDocIndexedFromDisk(module_uri) catch {};
            const doc = self.docs.get(module_uri) orelse return false;
            const didx = doc.index orelse return false;

            if (findTopLevelSymbol(didx, symbol_name)) |sym| {
                const locs = [_]Location{.{ .uri = module_uri, .range = sym.selection_range }};
                const json = try jsonStringifyAlloc(self.allocator, locs);
                defer self.allocator.free(json);
                try self.sendResponseJson(id_val, json);
                return true;
            }

            const locs = [_]Location{.{
                .uri = module_uri,
                .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
            }};
            const json = try jsonStringifyAlloc(self.allocator, locs);
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return true;
        }

        // Otherwise treat the selected identifier as a module/directory segment.
        const root = self.getStdlibRootForNamespace(current_uri) orelse return false;

        var segs = ArrayList([]const u8).init(self.allocator);
        defer segs.deinit();
        try segs.append(root);
        try segs.append("std");
        var k: usize = 1;
        while (k <= selected_idx) : (k += 1) {
            try segs.append(idx.tokens[ids.items[k]].text);
        }
        const selected_path_no_ext = try std.fs.path.join(self.allocator, segs.items);
        defer self.allocator.free(selected_path_no_ext);

        // Prefer README.md if this is a directory segment.
        const readme_path = try std.fs.path.join(self.allocator, &[_][]const u8{ selected_path_no_ext, "README.md" });
        defer self.allocator.free(readme_path);
        if (self.tryOpenExistingFile(readme_path)) {
            const target_uri = try pathToUri(self.allocator, readme_path);
            defer self.allocator.free(target_uri);
            const locs = [_]Location{.{
                .uri = target_uri,
                .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
            }};
            const json = try jsonStringifyAlloc(self.allocator, locs);
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return true;
        }

        // Then try module file.
        const module_file = try std.mem.concat(self.allocator, u8, &[_][]const u8{ selected_path_no_ext, ".fn" });
        defer self.allocator.free(module_file);
        if (self.tryOpenExistingFile(module_file)) {
            const module_uri = try pathToUri(self.allocator, module_file);
            defer self.allocator.free(module_uri);
            self.ensureDocIndexedFromDisk(module_uri) catch {};
            const locs = [_]Location{.{
                .uri = module_uri,
                .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
            }};
            const json = try jsonStringifyAlloc(self.allocator, locs);
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return true;
        }

        // If it's a directory, return definitions for contained modules.
        var dir = if (std.fs.path.isAbsolute(selected_path_no_ext))
            (std.Io.Dir.openDirAbsolute(globalIo(), selected_path_no_ext, .{ .iterate = true }) catch return false)
        else
            (std.Io.Dir.cwd().openDir(globalIo(), selected_path_no_ext, .{ .iterate = true }) catch return false);
        defer dir.close(globalIo());

        var locs_list = ArrayList(Location).init(self.allocator);
        defer {
            for (locs_list.items) |l| self.allocator.free(l.uri);
            locs_list.deinit();
        }

        var it = dir.iterate();
        while (try it.next(globalIo())) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".fn")) continue;
            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ selected_path_no_ext, entry.name });
            defer self.allocator.free(full_path);
            const u = try pathToUri(self.allocator, full_path);
            try locs_list.append(.{ .uri = u, .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } } });
        }

        if (locs_list.items.len == 0) return false;
        const json = try jsonStringifyAlloc(self.allocator, locs_list.items);
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
        return true;
    }

    fn trySendStdNamespaceHover(
        self: *LspServer,
        id_val: ?std.json.Value,
        current_uri: []const u8,
        idx: *const Index,
        tok_i: usize,
    ) !bool {
        if (idx.tokens[tok_i].kind != .identifier) return false;

        var ids = ArrayList(usize).init(self.allocator);
        defer ids.deinit();
        if (!try self.collectDotChainIdentifiersAround(idx, tok_i, &ids)) return false;
        if (ids.items.len == 0) return false;
        if (!std.mem.eql(u8, idx.tokens[ids.items[0]].text, "std")) return false;

        var selected_idx_opt: ?usize = null;
        for (ids.items, 0..) |ti, si| {
            if (ti == tok_i) {
                selected_idx_opt = si;
                break;
            }
        }
        const selected_idx = selected_idx_opt orelse return false;

        const root = self.getStdlibRootForNamespace(current_uri) orelse return false;

        // Helper: build the filesystem path (no extension) for a module chain up to `last_inclusive`.
        // `last_inclusive` is an index into `ids.items` (identifier index within the chain).
        const PathBuild = struct {
            fn moduleNoExt(allocator: Allocator, root_path: []const u8, idx2: *const Index, ids2: []const usize, last_inclusive: usize) ![]u8 {
                var segs = ArrayList([]const u8).init(allocator);
                defer segs.deinit();
                try segs.append(root_path);
                try segs.append("std");
                var k: usize = 1;
                while (k <= last_inclusive) : (k += 1) {
                    try segs.append(idx2.tokens[ids2[k]].text);
                }
                return try std.fs.path.join(allocator, segs.items);
            }
        };

        // `std` itself: show stdlib README in hover.
        if (selected_idx == 0) {
            const readme_path = try std.fs.path.join(self.allocator, &.{ root, "README.md" });
            defer self.allocator.free(readme_path);
            if (!self.tryOpenExistingFile(readme_path)) return false;

            const readme_text = blk: {
                if (std.fs.path.isAbsolute(readme_path)) {
                    var f = std.Io.Dir.openFileAbsolute(globalIo(), readme_path, .{}) catch return false;
                    defer f.close(globalIo());
                    break :blk fileReadAlloc(self.allocator, f, 128 * 1024) catch return false;
                }
                break :blk std.Io.Dir.cwd().readFileAlloc(globalIo(), readme_path, self.allocator, .limited(128 * 1024)) catch return false;
            };
            defer self.allocator.free(readme_text);

            const hover: Hover = .{ .contents = .{ .value = readme_text }, .range = idx.tokens[tok_i].range };
            const json = try jsonStringifyAlloc(self.allocator, hover);
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return true;
        }

        // Determine whether the *full* chain (up to last identifier) names a module file.
        // This is critical for nested modules like `std.c.io`.
        const chain_last: usize = ids.items.len - 1;
        const full_no_ext = try PathBuild.moduleNoExt(self.allocator, root, idx, ids.items, chain_last);
        defer self.allocator.free(full_no_ext);
        const full_module_file = try std.mem.concat(self.allocator, u8, &[_][]const u8{ full_no_ext, ".fn" });
        defer self.allocator.free(full_module_file);
        const full_chain_is_module = self.tryOpenExistingFile(full_module_file);

        const is_last = selected_idx == chain_last;
        const is_symbol = is_last and !full_chain_is_module and ids.items.len >= 3;

        var buf = ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        if (is_symbol) {
            const symbol_name = idx.tokens[ids.items[ids.items.len - 1]].text;
            const module_last_inclusive: usize = ids.items.len - 2;
            const module_file = (try self.buildStdModuleFilePathFromIds(current_uri, idx, ids.items, module_last_inclusive)) orelse return false;
            defer self.allocator.free(module_file);
            if (!self.tryOpenExistingFile(module_file)) return false;

            const module_uri = try pathToUri(self.allocator, module_file);
            defer self.allocator.free(module_uri);
            self.ensureDocIndexedFromDisk(module_uri) catch {};
            const doc = self.docs.get(module_uri) orelse return false;
            const didx = doc.index orelse return false;

            const sym = findTopLevelSymbol(didx, symbol_name) orelse return false;

            if (sym.detail) |det| {
                try buf.print("```fun\n{s}\n```\n", .{det});
            } else if (sym.kind == .variable) {
                if (sym.value_type) |vt| {
                    try buf.print("```fun\n{s} {s}\n```\n", .{ vt, symbol_name });
                } else {
                    try buf.print("_{s}_\n", .{@tagName(sym.kind)});
                }
            } else if (sym.kind == .struct_ or sym.kind == .interface) {
                try buf.print("```fun\n{s} {s}\n```\n", .{ if (sym.kind == .struct_) "compound" else "quirk", symbol_name });
            } else {
                try buf.print("_{s}_\n", .{@tagName(sym.kind)});
            }

            _ = try appendDocCommentAboveLine(self.allocator, &buf, doc.text, sym.decl_range.start.line);

            const hover: Hover = .{ .contents = .{ .value = buf.items }, .range = idx.tokens[tok_i].range };
            const json = try jsonStringifyAlloc(self.allocator, hover);
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return true;
        }

        // Hover over a module/directory segment.
        const selected_path_no_ext = try PathBuild.moduleNoExt(self.allocator, root, idx, ids.items, selected_idx);
        defer self.allocator.free(selected_path_no_ext);

        // Prefer README hover for directory segments.
        const readme_path = try std.fs.path.join(self.allocator, &[_][]const u8{ selected_path_no_ext, "README.md" });
        defer self.allocator.free(readme_path);
        if (self.tryOpenExistingFile(readme_path)) {
            const readme_text = blk: {
                if (std.fs.path.isAbsolute(readme_path)) {
                    var f = std.Io.Dir.openFileAbsolute(globalIo(), readme_path, .{}) catch return false;
                    defer f.close(globalIo());
                    break :blk fileReadAlloc(self.allocator, f, 128 * 1024) catch return false;
                }
                break :blk std.Io.Dir.cwd().readFileAlloc(globalIo(), readme_path, self.allocator, .limited(128 * 1024)) catch return false;
            };
            defer self.allocator.free(readme_text);

            const hover: Hover = .{ .contents = .{ .value = readme_text }, .range = idx.tokens[tok_i].range };
            const json = try jsonStringifyAlloc(self.allocator, hover);
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return true;
        }

        // Otherwise, show a minimal module hint if the module file exists.
        const module_file = try std.mem.concat(self.allocator, u8, &[_][]const u8{ selected_path_no_ext, ".fn" });
        defer self.allocator.free(module_file);
        if (!self.tryOpenExistingFile(module_file)) return false;

        // For module files, prefer showing the leading `//` doc block.
        const module_text = blk: {
            if (std.fs.path.isAbsolute(module_file)) {
                var f = std.Io.Dir.openFileAbsolute(globalIo(), module_file, .{}) catch return false;
                defer f.close(globalIo());
                break :blk fileReadAlloc(self.allocator, f, 128 * 1024) catch return false;
            }
            break :blk std.Io.Dir.cwd().readFileAlloc(globalIo(), module_file, self.allocator, .limited(128 * 1024)) catch return false;
        };
        defer self.allocator.free(module_text);

        // Extract the leading line-comment block and render it as markdown.
        var wrote_doc: bool = false;
        var i: usize = 0;
        while (i < module_text.len) {
            // Find line end.
            const line_start = i;
            while (i < module_text.len and module_text[i] != '\n') : (i += 1) {}
            const line = std.mem.trimEnd(u8, module_text[line_start..@min(i, module_text.len)], "\r");
            if (line.len < 2 or line[0] != '/' or line[1] != '/') break;
            var content = line[2..];
            if (content.len != 0 and content[0] == ' ') content = content[1..];
            try buf.appendSlice(content);
            try buf.append('\n');
            wrote_doc = true;
            if (i < module_text.len and module_text[i] == '\n') i += 1;
        }

        if (!wrote_doc) {
            try buf.print("_module_\n", .{});
        }

        const hover: Hover = .{ .contents = .{ .value = buf.items }, .range = idx.tokens[tok_i].range };
        const json = try jsonStringifyAlloc(self.allocator, hover);
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
        return true;
    }

    fn tryGuessStdNamespaceCallSignature(
        self: *LspServer,
        current_uri: []const u8,
        idx: *const Index,
        callee_i: usize,
        active_param: i64,
    ) ?GuessedCallSignature {
        if (idx.tokens[callee_i].kind != .identifier) return null;

        var ids = ArrayList(usize).init(self.allocator);
        defer ids.deinit();
        if (!(self.collectDotChainIdentifiersAround(idx, callee_i, &ids) catch false)) return null;
        if (ids.items.len == 0) return null;
        if (!std.mem.eql(u8, idx.tokens[ids.items[0]].text, "std")) return null;

        if (ids.items.len < 3) return null;

        // We only handle `std.<module>.<fn>(...)` style calls here.
        const symbol_name = idx.tokens[ids.items[ids.items.len - 1]].text;
        if (!std.mem.eql(u8, symbol_name, idx.tokens[callee_i].text)) return null;

        const module_last_inclusive: usize = ids.items.len - 2;
        const module_file = (self.buildStdModuleFilePathFromIds(current_uri, idx, ids.items, module_last_inclusive) catch null) orelse return null;
        defer self.allocator.free(module_file);
        if (!self.tryOpenExistingFile(module_file)) return null;

        const module_uri = pathToUri(self.allocator, module_file) catch return null;
        defer self.allocator.free(module_uri);
        self.ensureDocIndexedFromDisk(module_uri) catch {};
        const doc = self.docs.get(module_uri) orelse return null;
        const didx = doc.index orelse return null;

        const sym = findTopLevelSymbol(didx, symbol_name) orelse return null;
        const label = if (sym.detail) |d| d else symbol_name;
        return .{ .label = label, .active_param = active_param };
    }

    fn parseImportSpecFromTokens(self: *LspServer, idx: *const Index, imp_i: usize) !?[]u8 {
        // Parses:
        // - `imp a.b.c;` into "a.b.c"
        // - `imp ..defs.user;` into "..defs.user"
        // - `imp ....parent.child;` into "....parent.child"
        if (imp_i + 1 >= idx.tokens.len) return null;
        var i = imp_i + 1;

        var buf = ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        const parsed = struct {
            fn isAllDots(s: []const u8) bool {
                if (s.len == 0) return false;
                for (s) |c| if (c != '.') return false;
                return true;
            }
        };

        // ident / dot-runs until ';'
        while (i < idx.tokens.len) : (i += 1) {
            const t = idx.tokens[i];
            if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, ";")) break;
            if (t.kind == .keyword and std.mem.eql(u8, t.text, "as")) break;
            if (t.kind == .identifier) {
                if (buf.items.len != 0) {
                    // ensure previous char is '.' if this is not the first segment
                    // (we only append '.' when we see a dot token)
                }
                try buf.appendSlice(t.text);
                continue;
            }
            if (isDotToken(t)) {
                try buf.append('.');
                continue;
            }
            if ((t.kind == .symbol or t.kind == .operator) and parsed.isAllDots(t.text)) {
                // Supports dot-run tokens like ".." / "....".
                try buf.appendSlice(t.text);
                continue;
            }
            // Stop if we hit something unexpected.
            break;
        }

        if (buf.items.len == 0) {
            buf.deinit();
            return null;
        }
        return try buf.toOwnedSlice();
    }

    fn collectDirectImportUris(self: *LspServer, out: *ArrayList([]u8), current_uri: []const u8, idx: *const Index) !void {
        for (idx.tokens, 0..) |t, i| {
            if (t.kind != .keyword or !std.mem.eql(u8, t.text, "imp")) continue;
            const spec = try self.parseImportSpecFromTokens(idx, i) orelse continue;
            defer self.allocator.free(spec);
            const maybe_target_uri = self.resolveImportUri(current_uri, spec) catch continue;
            if (maybe_target_uri) |target_uri| {
                defer self.allocator.free(target_uri);
                try out.append(try self.allocator.dupe(u8, target_uri));
            }
        }
    }

    const GlobalDefHit = struct { uri: []const u8, sym: SymbolLite };

    fn findAnyGlobalDefinitionInDirectImports(self: *LspServer, current_uri: []const u8, name: []const u8) ?GlobalDefHit {
        const doc = self.docs.get(current_uri) orelse return null;
        const idx = doc.index orelse return null;

        var import_uris = ArrayList([]u8).init(self.allocator);
        defer {
            for (import_uris.items) |u| self.allocator.free(u);
            import_uris.deinit();
        }
        self.collectDirectImportUris(&import_uris, current_uri, idx) catch return null;

        for (import_uris.items) |iu| {
            self.ensureDocIndexedFromDisk(iu) catch {};
            const imported = self.docs.get(iu) orelse continue;
            const didx = imported.index orelse continue;
            if (findAnyGlobalDefinition(didx.symbols, name)) |s| {
                if (!self.isSymbolVisibleFromUri(current_uri, imported.uri, s)) continue;
                // Note: `iu` is freed by our defer; return the stable doc-owned URI.
                return .{ .uri = imported.uri, .sym = s };
            }
        }
        return null;
    }

    fn findBestDefinitionInDirectImports(self: *LspServer, current_uri: []const u8, name: []const u8) ?SymbolLite {
        if (self.findAnyGlobalDefinitionInDirectImports(current_uri, name)) |hit| return hit.sym;
        return null;
    }

    fn trySendImportCompletions(self: *LspServer, id_val: ?std.json.Value, current_uri: []const u8, text: []const u8, pos: Position) !bool {
        // Line-based import completion for `imp a.b.c;`
        const cursor = byteIndexForPosition(text, pos);
        var line_start: usize = cursor;
        while (line_start > 0 and text[line_start - 1] != '\n') : (line_start -= 1) {}
        var line_end: usize = cursor;
        while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}

        var line = text[line_start..line_end];
        // Trim leading spaces
        while (line.len != 0 and (line[0] == ' ' or line[0] == '\t' or line[0] == '\r')) line = line[1..];
        if (!std.mem.startsWith(u8, line, "imp")) return false;

        // Require `imp` followed by whitespace
        if (line.len < 3) return false;
        if (line.len > 3 and !(line[3] == ' ' or line[3] == '\t')) return false;

        const rel_cursor = cursor - line_start;
        if (rel_cursor < 3) return false;

        // Extract what user has typed after `imp` up to cursor.
        var after_imp = line[3..@min(rel_cursor, line.len)];
        while (after_imp.len != 0 and (after_imp[0] == ' ' or after_imp[0] == '\t')) after_imp = after_imp[1..];
        // Cut at ';' if present
        if (std.mem.indexOfScalar(u8, after_imp, ';')) |semi| after_imp = after_imp[0..semi];

        // Parse segments; treat dot-runs as parent traversal steps.
        const parsed = struct {
            fn addSegments(out: *ArrayList([]const u8), s: []const u8) !void {
                var start: usize = 0;
                var i: usize = 0;
                while (i < s.len) {
                    if (s[i] != '.') {
                        i += 1;
                        continue;
                    }

                    // Flush preceding identifier segment.
                    if (i > start) {
                        const seg = std.mem.trim(u8, s[start..i], " \t\r\n\"");
                        if (seg.len != 0) try out.append(seg);
                    }

                    // Consume dot run.
                    var j = i;
                    while (j < s.len and s[j] == '.') : (j += 1) {}
                    const run_len = j - i;
                    const parents = run_len / 2;
                    var p: usize = 0;
                    while (p < parents) : (p += 1) {
                        try out.append("..");
                    }

                    i = j;
                    start = i;
                }

                if (s.len > start) {
                    const seg = std.mem.trim(u8, s[start..], " \t\r\n\"");
                    if (seg.len != 0) try out.append(seg);
                }
            }
        };

        var parts = ArrayList([]const u8).init(self.allocator);
        defer parts.deinit();
        try parsed.addSegments(&parts, after_imp);
        if (parts.items.len == 0) return false;

        const ends_with_dot = after_imp.len != 0 and after_imp[after_imp.len - 1] == '.';
        const partial: []const u8 = if (ends_with_dot) "" else parts.items[parts.items.len - 1];
        const parent_count: usize = if (ends_with_dot) parts.items.len else (if (parts.items.len >= 1) parts.items.len - 1 else 0);
        var items = ArrayList(CompletionItem).init(self.allocator);
        defer {
            for (items.items) |ci| {
                self.allocator.free(ci.label);
                if (ci.detail) |d| self.allocator.free(d);
                if (ci.insertText) |ins| self.allocator.free(ins);
                if (ci.filterText) |ft| self.allocator.free(ft);
            }
            items.deinit();
        }

        // Always suggest `std` at top-level after `imp`.
        if (parent_count == 0 and std.mem.startsWith(u8, "std", partial)) {
            try items.append(.{ .label = try self.allocator.dupe(u8, "std"), .kind = 19 }); // Folder
        }

        // Determine base dir for filesystem-backed completion.
        var base_dir_path_opt: ?[]u8 = null;
        if (parts.items.len != 0 and std.mem.eql(u8, parts.items[0], "std")) {
            var stdlib_root = self.getStdlibRootPath() orelse null;
            if (stdlib_root == null) {
                self.tryStdlibRootFromCurrentDoc(current_uri);
                stdlib_root = self.getStdlibRootPath() orelse null;
            }
            if (stdlib_root) |root| {
                var segs = ArrayList([]const u8).init(self.allocator);
                defer segs.deinit();
                try segs.append(root);
                try segs.append("std");

                var si: usize = 1;
                while (si < parent_count) : (si += 1) {
                    if (parts.items[si].len != 0) try segs.append(parts.items[si]);
                }
                base_dir_path_opt = try std.fs.path.join(self.allocator, segs.items);
            }
        } else {
            const current_path = uriToPath(self.allocator, current_uri) catch null;
            if (current_path) |cp| {
                defer self.allocator.free(cp);
                const current_dir = std.fs.path.dirname(cp) orelse null;
                if (current_dir) |cd| {
                    var segs = ArrayList([]const u8).init(self.allocator);
                    defer segs.deinit();
                    try segs.append(cd);
                    var si: usize = 0;
                    while (si < parent_count) : (si += 1) {
                        if (parts.items[si].len != 0) try segs.append(parts.items[si]);
                    }
                    base_dir_path_opt = try std.fs.path.join(self.allocator, segs.items);
                }
            }
        }
        defer if (base_dir_path_opt) |p| self.allocator.free(p);

        if (base_dir_path_opt) |base_dir_path| {
            if (std.Io.Dir.openDirAbsolute(globalIo(), base_dir_path, .{ .iterate = true }) catch null) |dir| {
                var dir_mut = dir;
                defer dir_mut.close(globalIo());

                var iter = dir_mut.iterate();
                var saw_c_dir: bool = false;
                var saw_any_fn: bool = false;
                while (iter.next(globalIo()) catch null) |entry| {
                    if (entry.kind == .directory) {
                        if (partial.len != 0 and !std.mem.startsWith(u8, entry.name, partial)) continue;
                        try items.append(.{ .label = try self.allocator.dupe(u8, entry.name), .kind = 19 });
                        if (parent_count == 1 and std.mem.eql(u8, parts.items[0], "std") and std.mem.eql(u8, entry.name, "c")) saw_c_dir = true;
                    } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".fn")) {
                        const base = entry.name[0 .. entry.name.len - 3];
                        if (partial.len != 0 and !std.mem.startsWith(u8, base, partial)) continue;
                        try items.append(.{ .label = try self.allocator.dupe(u8, base), .kind = 17 });
                        saw_any_fn = true;
                    }
                }

                // Convenience: completing `imp std.;` should surface common leaf modules like `io`
                // even when the repo stdlib layout places them under `std/c/*`.
                if (parent_count == 1 and std.mem.eql(u8, parts.items[0], "std") and saw_c_dir and !saw_any_fn) {
                    const c_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ base_dir_path, "c" });
                    defer self.allocator.free(c_dir);
                    if (std.Io.Dir.openDirAbsolute(globalIo(), c_dir, .{ .iterate = true }) catch null) |cdir| {
                        var cdir_mut = cdir;
                        defer cdir_mut.close(globalIo());
                        var it2 = cdir_mut.iterate();
                        while (it2.next(globalIo()) catch null) |e2| {
                            if (e2.kind != .file) continue;
                            if (!std.mem.endsWith(u8, e2.name, ".fn")) continue;
                            const base_name = e2.name[0 .. e2.name.len - 3];
                            if (partial.len != 0 and !std.mem.startsWith(u8, base_name, partial)) continue;
                            try items.append(.{ .label = try self.allocator.dupe(u8, base_name), .kind = 17 });
                        }
                    }
                }
            }
        }

        const list: CompletionList = .{ .items = items.items };
        const json = try jsonStringifyAlloc(self.allocator, list);
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
        return true;
    }

    fn trySendWarningIdCompletions(self: *LspServer, id_val: ?std.json.Value, text: []const u8, pos: Position, prefix: []const u8) !bool {
        const cursor = byteIndexForPosition(text, pos);
        var line_start: usize = cursor;
        while (line_start > 0 and text[line_start - 1] != '\n') : (line_start -= 1) {}

        var line = text[line_start..cursor];
        while (line.len != 0 and (line[0] == ' ' or line[0] == '\t' or line[0] == '\r')) line = line[1..];

        var after_kw: []const u8 = undefined;
        if (std.mem.startsWith(u8, line, "allow") and (line.len == "allow".len or line["allow".len] == ' ' or line["allow".len] == '\t')) {
            after_kw = line["allow".len..];
        } else if (std.mem.startsWith(u8, line, "expect") and (line.len == "expect".len or line["expect".len] == ' ' or line["expect".len] == '\t')) {
            after_kw = line["expect".len..];
        } else return false;

        while (after_kw.len != 0 and (after_kw[0] == ' ' or after_kw[0] == '\t')) after_kw = after_kw[1..];

        // Warning id completion is only for the first argument (before comma/reason).
        if (std.mem.indexOfScalar(u8, after_kw, ',') != null) return false;
        if (std.mem.indexOfScalar(u8, after_kw, ';') != null) return false;
        if (std.mem.indexOfScalar(u8, after_kw, '"') != null) return false;

        const is_ident_char = struct {
            fn call(ch: u8) bool {
                return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
            }
        }.call;

        for (after_kw) |ch| {
            if (ch == ' ' or ch == '\t') continue;
            if (!is_ident_char(ch)) return false;
        }

        var items = ArrayList(CompletionItem).init(self.allocator);
        defer {
            for (items.items) |it| self.allocator.free(it.label);
            items.deinit();
        }

        const warning_ids = [_][]const u8{
            "return_local_ptr",
            "fit_non_exhaustive",
            "fit_unreachable_branch",
            "unreachable_code",
            "assert_constant",
            "unused_variable",
            "unused_import",
            "unused_function",
            "unused_compound",
        };
        _ = prefix;
        for (warning_ids) |wid| {
            try items.append(.{ .label = try self.allocator.dupe(u8, wid), .kind = 21 }); // CompletionItemKind.Constant
        }

        const list: CompletionList = .{ .items = items.items };
        const json = try jsonStringifyAlloc(self.allocator, list);
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
        return true;
    }

    fn trySendImportNamespaceHoverLineBased(self: *LspServer, id_val: ?std.json.Value, current_uri: []const u8, text: []const u8, pos: Position) !bool {
        // Best-effort import hover for custom modules using line parsing.
        // This is intentionally more tolerant than the token-based version.
        const cursor = byteIndexForPosition(text, pos);
        var line_start: usize = cursor;
        while (line_start > 0 and text[line_start - 1] != '\n') : (line_start -= 1) {}
        var line_end: usize = cursor;
        while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}

        var line = text[line_start..line_end];
        while (line.len != 0 and (line[0] == ' ' or line[0] == '\t' or line[0] == '\r')) line = line[1..];
        if (!std.mem.startsWith(u8, line, "imp")) return false;
        if (line.len < 3) return false;
        if (line.len > 3 and !(line[3] == ' ' or line[3] == '\t')) return false;

        const rel_cursor = cursor - line_start;
        if (rel_cursor < 3) return false;

        // Find start of spec after `imp` whitespace.
        var spec_start: usize = 3;
        while (spec_start < line.len and (line[spec_start] == ' ' or line[spec_start] == '\t')) : (spec_start += 1) {}
        if (spec_start >= line.len) return false;
        if (rel_cursor < spec_start) return false;

        var spec = line[spec_start..];
        if (std.mem.indexOfScalar(u8, spec, ';')) |semi| spec = spec[0..semi];
        spec = std.mem.trim(u8, spec, " \t\r\n\"");
        if (spec.len == 0) return false;

        // Only handle non-stdlib here; std namespace hover has its own handler.
        if (std.mem.startsWith(u8, spec, "std") and (spec.len == 3 or spec[3] == '.')) return false;

        // Figure out the first segment and whether cursor is within it.
        const dot_i = std.mem.indexOfScalar(u8, spec, '.') orelse spec.len;
        const first_seg = std.mem.trim(u8, spec[0..dot_i], " \t\r\n\"");
        if (first_seg.len == 0) return false;

        const off_in_spec: usize = @intCast(rel_cursor - spec_start);
        if (off_in_spec >= dot_i) return false; // cursor isn't in first segment

        const current_path = uriToPath(self.allocator, current_uri) catch return false;
        defer self.allocator.free(current_path);
        const current_dir = std.fs.path.dirname(current_path) orelse return false;
        const base_dir = if (self.root_path) |rp| rp else current_dir;

        const seg_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ base_dir, first_seg });
        defer self.allocator.free(seg_dir);
        const readme_path = try std.fs.path.join(self.allocator, &[_][]const u8{ seg_dir, "README.md" });
        defer self.allocator.free(readme_path);
        if (!self.tryOpenExistingFile(readme_path)) return false;

        const readme_text = blk: {
            if (std.fs.path.isAbsolute(readme_path)) {
                var f = std.Io.Dir.openFileAbsolute(globalIo(), readme_path, .{}) catch return false;
                defer f.close(globalIo());
                break :blk fileReadAlloc(self.allocator, f, 128 * 1024) catch return false;
            }
            break :blk std.Io.Dir.cwd().readFileAlloc(globalIo(), readme_path, self.allocator, .limited(128 * 1024)) catch return false;
        };
        defer self.allocator.free(readme_text);

        const hover: Hover = .{ .contents = .{ .value = readme_text }, .range = .{ .start = pos, .end = pos } };
        const json = try jsonStringifyAlloc(self.allocator, hover);
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
        return true;
    }

    fn guessCallSignatureAt(self: *LspServer, uri: []const u8, idx: *const Index, p: Position) ?GuessedCallSignature {
        // Find the closest '(' before cursor, then resolve the callee.
        var tok_index: ?usize = null;
        for (idx.tokens, 0..) |t, ti| {
            if (t.range.start.line > p.line) break;
            if (t.range.start.line == p.line and t.range.start.character > p.character) break;
            tok_index = ti;
        }
        if (tok_index == null) return null;

        const resolveCallCallee = struct {
            const Resolved = struct {
                callee_i: usize,
                explicit_generic_start_i: ?usize,
            };

            fn prevNonComment(tokens: []const TokenLite, start_i: isize) ?usize {
                var j = start_i;
                while (j >= 0) : (j -= 1) {
                    const t = tokens[@intCast(j)];
                    if (t.kind == .comment) continue;
                    return @intCast(j);
                }
                return null;
            }

            fn tokenHasChar(text: []const u8, ch: u8) bool {
                return std.mem.indexOfScalar(u8, text, ch) != null;
            }

            fn call(tokens: []const TokenLite, lparen_i: usize) ?Resolved {
                const prev_i = prevNonComment(tokens, @as(isize, @intCast(lparen_i)) - 1) orelse return null;

                var j: isize = @intCast(prev_i);
                var explicit_start: ?usize = null;

                if (tokenHasChar(tokens[prev_i].text, '>')) {
                    var depth: i64 = 0;
                    var found_lt: ?usize = null;
                    while (j >= 0) : (j -= 1) {
                        const t = tokens[@intCast(j)];
                        if (t.kind == .comment) continue;
                        const ts = t.text;
                        var k: isize = @intCast(ts.len);
                        while (k > 0) {
                            k -= 1;
                            const ch = ts[@intCast(k)];
                            if (ch == '>') {
                                depth += 1;
                                continue;
                            }
                            if (ch == '<') {
                                if (depth > 0) depth -= 1;
                                if (depth == 0) {
                                    found_lt = @intCast(j);
                                    break;
                                }
                            }
                        }
                        if (found_lt != null) break;
                    }
                    if (found_lt == null) return null;
                    explicit_start = found_lt;
                    j = @as(isize, @intCast(found_lt.?)) - 1;
                    const before_generic_i = prevNonComment(tokens, j) orelse return null;
                    j = @intCast(before_generic_i);
                }

                if (j < 0) return null;
                const callee_i: usize = @intCast(j);
                if (tokens[callee_i].kind != .identifier) return null;

                return .{ .callee_i = callee_i, .explicit_generic_start_i = explicit_start };
            }
        }.call;

        var i: isize = @intCast(tok_index.?);
        var paren_depth: i64 = 0;
        var active_param: i64 = 0;
        while (i >= 0) : (i -= 1) {
            const t = idx.tokens[@intCast(i)];
            if (t.kind == .symbol or t.kind == .operator) {
                if (std.mem.eql(u8, t.text, ")")) {
                    paren_depth += 1;
                    continue;
                }
                if (std.mem.eql(u8, t.text, "(")) {
                    if (paren_depth == 0) {
                        const lparen_i: usize = @intCast(i);
                        const callee_res = resolveCallCallee(idx.tokens, lparen_i) orelse return null;
                        const callee_i = callee_res.callee_i;
                        const callee = idx.tokens[callee_i];

                        // Member call: `recv.method(`
                        if (callee_i >= 2 and isDotToken(idx.tokens[callee_i - 1]) and idx.tokens[callee_i - 2].kind == .identifier) {
                            // stdlib namespace call: `std.<module>.<fn>(...)`
                            if (self.tryGuessStdNamespaceCallSignature(uri, idx, callee_i, active_param)) |sig| {
                                return .{
                                    .label = sig.label,
                                    .active_param = sig.active_param,
                                    .callee_i = callee_i,
                                    .lparen_i = lparen_i,
                                    .cursor_tok_i = tok_index.?,
                                    .explicit_generic_start_i = callee_res.explicit_generic_start_i,
                                };
                            }
                            const recv_type = self.resolveTypeOfChainUpTo(idx, uri, p, callee_i - 2);
                            if (self.debug_definitions) {
                                self.dbg(true, "defs", "sig member callee={s} recv_ident={s} recv_type={s}", .{
                                    callee.text,
                                    idx.tokens[callee_i - 2].text,
                                    recv_type orelse "",
                                });
                            }
                            if (recv_type) |resolved_recv_type| {
                                const hit = self.findMemberByContainer(uri, resolved_recv_type, callee.text, .method);
                                if (self.debug_definitions) {
                                    self.dbg(true, "defs", "sig member lookup callee={s} recv_type={s} hit_detail={s} hit_container={s}", .{
                                        callee.text,
                                        resolved_recv_type,
                                        if (hit) |h| h.sym.detail orelse "" else "",
                                        if (hit) |h| h.sym.container_type orelse "" else "",
                                    });
                                }
                                if (hit) |h| {
                                    var label = if (h.sym.detail) |d| d else callee.text;
                                    if (h.sym.container_type) |declared_container| {
                                        if (self.specializeMemberLabelForReceiver(@constCast(&idx.arena).allocator(), declared_container, resolved_recv_type, label) catch null) |specialized| {
                                            label = specialized;
                                        }
                                    }
                                    return .{
                                        .label = label,
                                        .active_param = active_param,
                                        .callee_i = callee_i,
                                        .lparen_i = lparen_i,
                                        .cursor_tok_i = tok_index.?,
                                        .explicit_generic_start_i = callee_res.explicit_generic_start_i,
                                    };
                                }
                            }
                        }

                        // Plain function call.
                        if (std.mem.eql(u8, callee.text, "sizeof")) {
                            return .{
                                .label = "sizeof(Type) num",
                                .active_param = active_param,
                                .callee_i = callee_i,
                                .lparen_i = lparen_i,
                                .cursor_tok_i = tok_index.?,
                                .explicit_generic_start_i = callee_res.explicit_generic_start_i,
                            };
                        }

                        const def_local = findBestDefinition(idx.symbols, callee.text, p) orelse null;
                        const def_import = if (def_local == null) self.findAnyGlobalDefinitionInDirectImports(uri, callee.text) else null;
                        const label = blk: {
                            if (def_local) |d| {
                                if (d.detail) |det| break :blk det;
                            }
                            if (def_import) |hit| {
                                if (hit.sym.detail) |det| break :blk det;
                            }
                            break :blk callee.text;
                        };
                        return .{
                            .label = label,
                            .active_param = active_param,
                            .callee_i = callee_i,
                            .lparen_i = lparen_i,
                            .cursor_tok_i = tok_index.?,
                            .explicit_generic_start_i = callee_res.explicit_generic_start_i,
                        };
                    }
                    paren_depth -= 1;
                    continue;
                }
                if (paren_depth == 0 and std.mem.eql(u8, t.text, ",")) {
                    active_param += 1;
                    continue;
                }
            }
        }
        return null;
    }

    fn handleSignatureHelp(self: *LspServer, id_val: ?std.json.Value, params_val: ?std.json.Value) !void {
        const parsed = try parseTextDocPosition(params_val);
        if (parsed == null) {
            try self.sendResponseJson(id_val, "null");
            return;
        }
        const uri = parsed.?.uri;
        const doc = self.docs.get(uri) orelse {
            try self.sendResponseJson(id_val, "null");
            return;
        };
        const pos = normalizePositionToByteColumns(doc.text, parsed.?.pos);
        const idx = doc.index orelse {
            try self.sendResponseJson(id_val, "null");
            return;
        };

        const sig = self.guessCallSignatureAt(uri, idx, pos) orelse {
            try self.sendResponseJson(id_val, "null");
            return;
        };

        var sig_label = sig.label;
        var specialized_owned: ?[]u8 = null;
        defer if (specialized_owned) |s| self.allocator.free(s);

        if (try self.specializeGenericSignatureHelpLabel(uri, idx, pos, sig)) |specialized| {
            specialized_owned = specialized;
            sig_label = specialized;
        }

        const parsed_params = try self.parseParamsFromSignatureLabel(sig_label);
        defer {
            for (parsed_params.items) |p| self.allocator.free(p.label);
            parsed_params.deinit();
        }

        const variadic = self.signatureLabelHasVariadic(sig_label);
        var active_param = sig.active_param;
        if (parsed_params.items.len != 0) {
            const max_param: i64 = @intCast(parsed_params.items.len - 1);
            if (!variadic and active_param > max_param) active_param = max_param;
        } else {
            active_param = 0;
        }

        const infos = [_]SignatureInformation{.{ .label = sig_label, .parameters = parsed_params.items }};
        const help: SignatureHelp = .{ .signatures = &infos, .activeParameter = active_param };
        const json = try jsonStringifyAlloc(self.allocator, help);
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
    }

    fn signatureLabelHasVariadic(self: *LspServer, label: []const u8) bool {
        _ = self;
        return std.mem.indexOf(u8, label, "...") != null;
    }

    fn parseParamsFromSignatureLabel(self: *LspServer, label: []const u8) !ArrayList(ParameterInformation) {
        var out = ArrayList(ParameterInformation).init(self.allocator);

        const open_i = std.mem.indexOfScalar(u8, label, '(') orelse return out;
        const close_i = std.mem.lastIndexOfScalar(u8, label, ')') orelse return out;
        if (close_i <= open_i + 1) return out;

        const inner = std.mem.trim(u8, label[open_i + 1 .. close_i], " \t\r\n");
        if (inner.len == 0) return out;

        // Split by top-level commas (no nested types exist today, but keep it safe).
        var depth: usize = 0;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= inner.len) : (i += 1) {
            const at_end = i == inner.len;
            const c = if (!at_end) inner[i] else 0;
            if (!at_end) {
                if (c == '(') depth += 1;
                if (c == ')') depth -|= 1;
            }
            if (at_end or (c == ',' and depth == 0)) {
                var seg = inner[start..i];
                seg = std.mem.trim(u8, seg, " \t\r\n");
                if (seg.len != 0) {
                    try out.append(.{ .label = try self.allocator.dupe(u8, seg) });
                }
                start = i + 1;
            }
        }

        return out;
    }

    fn specializeGenericSignatureHelpLabel(self: *LspServer, uri: []const u8, idx: *const Index, at: Position, sig: GuessedCallSignature) !?[]u8 {
        const lparen_i = sig.lparen_i orelse return null;
        const cursor_tok_i = sig.cursor_tok_i orelse return null;
        _ = sig.callee_i orelse return null;

        if (sig.callee_i) |callee_i| {
            if (callee_i >= 2 and isDotToken(idx.tokens[callee_i - 1]) and idx.tokens[callee_i - 2].kind == .identifier) {
                if (self.resolveTypeOfChainUpTo(idx, uri, at, callee_i - 2)) |recv_type| {
                    if (self.findMemberByContainer(uri, recv_type, idx.tokens[callee_i].text, .method)) |hit| {
                        if (hit.sym.container_type) |declared_container| {
                            if (try self.specializeMemberLabelForReceiver(self.allocator, declared_container, recv_type, sig.label)) |specialized| {
                                return specialized;
                            }
                        }
                    }
                }
            }
        }

        const TypeBinding = struct {
            param: []const u8,
            arg: []const u8,
        };

        const ArgRange = struct {
            start: usize,
            end: usize,
        };

        const GenericCore = struct {
            base: []const u8,
            inner: []const u8,
        };

        const findSignatureParenBounds = struct {
            const Bounds = struct { open: usize, close: usize };

            fn call(label: []const u8) ?Bounds {
                const open_i = std.mem.indexOfScalar(u8, label, '(') orelse return null;
                var depth: i64 = 0;
                var i = open_i;
                while (i < label.len) : (i += 1) {
                    const ch = label[i];
                    if (ch == '(') {
                        depth += 1;
                        continue;
                    }
                    if (ch == ')') {
                        depth -= 1;
                        if (depth == 0) return .{ .open = open_i, .close = i };
                    }
                }
                return null;
            }
        }.call;

        const splitTopLevelCsv = struct {
            fn call(text: []const u8, out: *ArrayList([]const u8)) !void {
                var angle_depth: i64 = 0;
                var paren_depth: i64 = 0;
                var brack_depth: i64 = 0;
                var brace_depth: i64 = 0;
                var start: usize = 0;

                var i: usize = 0;
                while (i <= text.len) : (i += 1) {
                    const at_end = i == text.len;
                    const ch: u8 = if (!at_end) text[i] else 0;

                    if (!at_end) {
                        switch (ch) {
                            '<' => angle_depth += 1,
                            '>' => {
                                if (angle_depth > 0) angle_depth -= 1;
                            },
                            '(' => paren_depth += 1,
                            ')' => {
                                if (paren_depth > 0) paren_depth -= 1;
                            },
                            '[' => brack_depth += 1,
                            ']' => {
                                if (brack_depth > 0) brack_depth -= 1;
                            },
                            '{' => brace_depth += 1,
                            '}' => {
                                if (brace_depth > 0) brace_depth -= 1;
                            },
                            else => {},
                        }
                    }

                    if (at_end or (ch == ',' and angle_depth == 0 and paren_depth == 0 and brack_depth == 0 and brace_depth == 0)) {
                        var seg = text[start..i];
                        seg = std.mem.trim(u8, seg, " \t\r\n");
                        if (seg.len != 0) try out.append(seg);
                        start = i + 1;
                    }
                }
            }
        }.call;

        const parseGenericParamNamesFromLabel = struct {
            fn call(label: []const u8, out: *ArrayList([]const u8)) !void {
                const bounds = findSignatureParenBounds(label) orelse return;
                const head = label[0..bounds.open];

                var depth: i64 = 0;
                var lt_i: ?usize = null;
                var gt_i: ?usize = null;
                var i: usize = 0;
                while (i < head.len) : (i += 1) {
                    const ch = head[i];
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

                var raw = ArrayList([]const u8).init(std.heap.page_allocator);
                defer raw.deinit();
                splitTopLevelCsv(head[lt_i.? + 1 .. gt_i.?], &raw) catch return;

                for (raw.items) |it| {
                    var p = std.mem.trim(u8, it, " \t\r\n");
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
                    try out.append(p);
                }
            }
        }.call;

        const normalizeGenericParamName = struct {
            fn call(param_raw: []const u8) []const u8 {
                var p = std.mem.trim(u8, param_raw, " \t\r\n");
                if (p.len == 0) return p;
                var cut = p.len;
                var j: usize = 0;
                while (j < p.len) : (j += 1) {
                    const ch = p[j];
                    if (ch == ':' or ch == '=' or ch == ' ' or ch == '\t') {
                        cut = j;
                        break;
                    }
                }
                return std.mem.trim(u8, p[0..cut], " \t\r\n");
            }
        }.call;

        const appendGenericParamNamesFromType = struct {
            fn call(type_name_raw: []const u8, out: *ArrayList([]const u8)) !void {
                const tname = std.mem.trim(u8, type_name_raw, " \t\r\n");
                const lt = std.mem.indexOfScalar(u8, tname, '<') orelse return;

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
                    }
                }
                if (gt == null or gt.? <= lt) return;

                var raw = ArrayList([]const u8).init(std.heap.page_allocator);
                defer raw.deinit();
                splitTopLevelCsv(tname[lt + 1 .. gt.?], &raw) catch return;

                for (raw.items) |it| {
                    const p = normalizeGenericParamName(it);
                    if (p.len == 0) continue;
                    try out.append(p);
                }
            }
        }.call;

        const parseParamTypesFromLabel = struct {
            fn call(label: []const u8, out: *ArrayList([]const u8)) !void {
                const bounds = findSignatureParenBounds(label) orelse return;
                if (bounds.close <= bounds.open + 1) return;
                const inner = std.mem.trim(u8, label[bounds.open + 1 .. bounds.close], " \t\r\n");
                if (inner.len == 0) return;

                var raw = ArrayList([]const u8).init(std.heap.page_allocator);
                defer raw.deinit();
                splitTopLevelCsv(inner, &raw) catch return;

                for (raw.items) |seg0| {
                    var seg = std.mem.trim(u8, seg0, " \t\r\n");
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
                        const maybe_t = std.mem.trim(u8, seg[0..s], " \t\r\n");
                        if (maybe_t.len != 0) tname = maybe_t;
                    }
                    try out.append(tname);
                }
            }
        }.call;

        const lookupBinding = struct {
            fn call(bindings: []const TypeBinding, name: []const u8) ?[]const u8 {
                for (bindings) |b| {
                    if (std.mem.eql(u8, b.param, name)) return b.arg;
                }
                return null;
            }
        }.call;

        const bindIfMissing = struct {
            fn call(bindings: *ArrayList(TypeBinding), param: []const u8, arg: []const u8) !void {
                if (lookupBinding(bindings.items, param) != null) return;
                try bindings.append(.{ .param = param, .arg = arg });
            }
        }.call;

        const parseGenericCore = struct {
            fn call(type_name_raw: []const u8) ?GenericCore {
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
                    }
                }
                if (gt == null or gt.? <= lt) return null;
                if (std.mem.trim(u8, tname[gt.? + 1 ..], " \t\r\n").len != 0) return null;
                return .{
                    .base = std.mem.trim(u8, tname[0..lt], " \t\r\n"),
                    .inner = tname[lt + 1 .. gt.?],
                };
            }
        }.call;

        const isGenericParam = struct {
            fn call(gparams: []const []const u8, name: []const u8) bool {
                for (gparams) |gp| {
                    if (std.mem.eql(u8, gp, name)) return true;
                }
                return false;
            }
        }.call;

        const bindFromParamType = struct {
            fn call(gparams: []const []const u8, bindings: *ArrayList(TypeBinding), ptype_raw: []const u8, atype_raw: []const u8) !void {
                const ptype = std.mem.trim(u8, ptype_raw, " \t\r\n");
                const atype = std.mem.trim(u8, atype_raw, " \t\r\n");
                if (ptype.len == 0 or atype.len == 0) return;

                if (isGenericParam(gparams, ptype)) {
                    try bindIfMissing(bindings, ptype, atype);
                    return;
                }

                if (std.mem.endsWith(u8, ptype, "[]") and std.mem.endsWith(u8, atype, "[]")) {
                    try call(gparams, bindings, ptype[0 .. ptype.len - 2], atype[0 .. atype.len - 2]);
                    return;
                }

                if (parseGenericCore(ptype)) |pc| {
                    if (parseGenericCore(atype)) |ac| {
                        if (!std.mem.eql(u8, pc.base, ac.base)) return;

                        var pinner = ArrayList([]const u8).init(std.heap.page_allocator);
                        defer pinner.deinit();
                        var ainner = ArrayList([]const u8).init(std.heap.page_allocator);
                        defer ainner.deinit();

                        splitTopLevelCsv(pc.inner, &pinner) catch return;
                        splitTopLevelCsv(ac.inner, &ainner) catch return;

                        const n = @min(pinner.items.len, ainner.items.len);
                        var i: usize = 0;
                        while (i < n) : (i += 1) {
                            try call(gparams, bindings, pinner.items[i], ainner.items[i]);
                        }
                    }
                }
            }
        }.call;

        const parseCallExplicitTypeArgsLite = struct {
            fn call(allocator_: Allocator, tokens: []const TokenLite, l_angle_i: usize, out: *ArrayList([]u8)) !void {
                var depth: i64 = 0;
                var cur = ArrayList(u8).init(allocator_);
                defer cur.deinit();

                const flush = struct {
                    fn call2(allocator2: Allocator, cur_buf: *ArrayList(u8), out_buf: *ArrayList([]u8)) !void {
                        const seg = std.mem.trim(u8, cur_buf.items, " \t\r\n");
                        if (seg.len != 0) {
                            try out_buf.append(try allocator2.dupe(u8, seg));
                        }
                        cur_buf.clearRetainingCapacity();
                    }
                }.call2;

                var i = l_angle_i;
                while (i < tokens.len) : (i += 1) {
                    const t = tokens[i];
                    if (t.kind == .comment) continue;
                    const ts = t.text;

                    var j: usize = 0;
                    while (j < ts.len) : (j += 1) {
                        const ch = ts[j];
                        if (ch == '<') {
                            depth += 1;
                            if (depth == 1) continue;
                            try cur.append('<');
                            continue;
                        }
                        if (ch == '>') {
                            if (depth > 0) depth -= 1;
                            if (depth == 0) {
                                try flush(allocator_, &cur, out);
                                return;
                            }
                            try cur.append('>');
                            continue;
                        }
                        if (depth <= 0) return;

                        if (ch == ',' and depth == 1) {
                            try flush(allocator_, &cur, out);
                            continue;
                        }

                        try cur.append(ch);
                    }
                }
            }
        }.call;

        const nextNonComment = struct {
            fn call(tokens: []const TokenLite, start_i: usize) ?usize {
                var i = start_i;
                while (i < tokens.len) : (i += 1) {
                    if (tokens[i].kind == .comment) continue;
                    return i;
                }
                return null;
            }
        }.call;

        const findMatchingRParenSig = struct {
            fn call(tokens: []const TokenLite, lparen_i2: usize) ?usize {
                var depth: i64 = 0;
                var i = lparen_i2;
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
        }.call;

        const trimArgRange = struct {
            fn call(tokens: []const TokenLite, s0: usize, e0: usize) ?ArgRange {
                var s = s0;
                var e = e0;
                while (s < e and tokens[s].kind == .comment) : (s += 1) {}
                while (e > s and tokens[e - 1].kind == .comment) : (e -= 1) {}
                if (s >= e) return null;
                return .{ .start = s, .end = e };
            }
        }.call;

        const collectCallArgRangesLite = struct {
            fn call(tokens: []const TokenLite, lparen_i2: usize, end_excl: usize, out: *ArrayList(ArgRange)) !void {
                var seg_start = nextNonComment(tokens, lparen_i2 + 1) orelse return;
                if (seg_start >= end_excl) return;

                var p_depth: i64 = 0;
                var b_depth: i64 = 0;
                var c_depth: i64 = 0;
                var g_depth: i64 = 0;

                var i = lparen_i2 + 1;
                while (i < end_excl) : (i += 1) {
                    const t = tokens[i];
                    if (t.kind == .comment) continue;

                    var saw_top_comma = false;
                    for (t.text) |ch| {
                        switch (ch) {
                            '(' => p_depth += 1,
                            ')' => {
                                if (p_depth > 0) p_depth -= 1;
                            },
                            '[' => b_depth += 1,
                            ']' => {
                                if (b_depth > 0) b_depth -= 1;
                            },
                            '{' => c_depth += 1,
                            '}' => {
                                if (c_depth > 0) c_depth -= 1;
                            },
                            '<' => g_depth += 1,
                            '>' => {
                                if (g_depth > 0) g_depth -= 1;
                            },
                            ',' => {
                                if (p_depth == 0 and b_depth == 0 and c_depth == 0 and g_depth == 0) {
                                    saw_top_comma = true;
                                }
                            },
                            else => {},
                        }
                    }

                    if (saw_top_comma) {
                        if (trimArgRange(tokens, seg_start, i)) |rg| try out.append(rg);
                        seg_start = nextNonComment(tokens, i + 1) orelse end_excl;
                    }
                }

                if (seg_start < end_excl) {
                    if (trimArgRange(tokens, seg_start, end_excl)) |rg| try out.append(rg);
                }
            }
        }.call;

        const inferArgTypeFromRange = struct {
            fn call(self_: *LspServer, uri_: []const u8, idx_: *const Index, at_: Position, tokens: []const TokenLite, start_i: usize, end_i: usize) ?[]const u8 {
                const rg = trimArgRange(tokens, start_i, end_i) orelse return null;
                const s = rg.start;
                const e = rg.end;
                if (s >= e) return null;

                if (e == s + 1) {
                    const t = tokens[s];
                    return switch (t.kind) {
                        .string => "str",
                        .boolean => "bin",
                        .number => blk: {
                            if (t.text.len >= 2 and t.text[0] == '\'' and t.text[t.text.len - 1] == '\'') break :blk "chr";
                            if (std.mem.indexOfScalar(u8, t.text, '.') != null) break :blk "dec";
                            break :blk "num";
                        },
                        .identifier => self_.guessVariableType(idx_, uri_, t.text, at_) orelse if (self_.isKnownTypeName(uri_, t.text)) t.text else null,
                        else => null,
                    };
                }

                // Simple dot-chain `a.b.c`.
                var expect_ident = true;
                var last_ident_i: ?usize = null;
                var i = s;
                while (i < e) : (i += 1) {
                    const t = tokens[i];
                    if (t.kind == .comment) continue;
                    if (expect_ident) {
                        if (t.kind != .identifier) {
                            last_ident_i = null;
                            break;
                        }
                        last_ident_i = i;
                        expect_ident = false;
                    } else {
                        if (!isDotToken(t)) {
                            last_ident_i = null;
                            break;
                        }
                        expect_ident = true;
                    }
                }
                if (last_ident_i != null and !expect_ident and last_ident_i.? > s) {
                    return self_.resolveTypeOfChainUpTo(idx_, uri_, at_, last_ident_i.?);
                }

                return null;
            }
        }.call;

        const substituteLabelTypeParams = struct {
            fn isIdentStart(ch: u8) bool {
                return std.ascii.isAlphabetic(ch) or ch == '_';
            }

            fn isIdentChar(ch: u8) bool {
                return std.ascii.isAlphanumeric(ch) or ch == '_';
            }

            fn call(allocator_: Allocator, label: []const u8, bindings: []const TypeBinding) ?[]u8 {
                if (bindings.len == 0) return null;

                var out = ArrayList(u8).init(allocator_);
                defer out.deinit();

                var changed = false;
                var i: usize = 0;
                while (i < label.len) {
                    const ch = label[i];
                    if (!isIdentStart(ch)) {
                        out.append(ch) catch return null;
                        i += 1;
                        continue;
                    }

                    const start = i;
                    i += 1;
                    while (i < label.len and isIdentChar(label[i])) : (i += 1) {}
                    const ident = label[start..i];
                    if (lookupBinding(bindings, ident)) |mapped| {
                        out.appendSlice(mapped) catch return null;
                        changed = true;
                    } else {
                        out.appendSlice(ident) catch return null;
                    }
                }

                if (!changed) return null;
                return out.toOwnedSlice() catch null;
            }
        }.call;

        var generic_params = ArrayList([]const u8).init(self.allocator);
        defer generic_params.deinit();
        try parseGenericParamNamesFromLabel(sig.label, &generic_params);

        var receiver_declared_container: ?[]const u8 = null;
        var receiver_type_for_bindings: ?[]const u8 = null;
        if (generic_params.items.len == 0) {
            if (sig.callee_i) |callee_i| {
                if (callee_i >= 2 and isDotToken(idx.tokens[callee_i - 1]) and idx.tokens[callee_i - 2].kind == .identifier) {
                    if (self.resolveTypeOfChainUpTo(idx, uri, at, callee_i - 2)) |recv_type| {
                        if (self.findMemberByContainer(uri, recv_type, idx.tokens[callee_i].text, .method)) |hit| {
                            if (hit.sym.container_type) |declared_container| {
                                try appendGenericParamNamesFromType(declared_container, &generic_params);
                                if (generic_params.items.len != 0) {
                                    receiver_declared_container = declared_container;
                                    receiver_type_for_bindings = recv_type;
                                }
                            }
                        }
                    }
                }
            }
        }

        if (generic_params.items.len == 0) return null;

        var bindings = ArrayList(TypeBinding).init(self.allocator);
        defer bindings.deinit();

        var explicit_args = ArrayList([]u8).init(self.allocator);
        defer {
            for (explicit_args.items) |a| self.allocator.free(a);
            explicit_args.deinit();
        }

        if (sig.explicit_generic_start_i) |gstart| {
            try parseCallExplicitTypeArgsLite(self.allocator, idx.tokens, gstart, &explicit_args);
            const map_n = @min(explicit_args.items.len, generic_params.items.len);
            var bi: usize = 0;
            while (bi < map_n) : (bi += 1) {
                try bindIfMissing(&bindings, generic_params.items[bi], explicit_args.items[bi]);
            }
        }

        if (receiver_declared_container) |declared_container| {
            if (receiver_type_for_bindings) |recv_type| {
                if (parseGenericCore(declared_container)) |declared_core| {
                    if (parseGenericCore(recv_type)) |receiver_core| {
                        if (std.mem.eql(u8, baseTypeNameForLookup(declared_core.base), baseTypeNameForLookup(receiver_core.base))) {
                            var declared_params = ArrayList([]const u8).init(std.heap.page_allocator);
                            defer declared_params.deinit();
                            var receiver_args = ArrayList([]const u8).init(std.heap.page_allocator);
                            defer receiver_args.deinit();

                            try splitTopLevelCsv(declared_core.inner, &declared_params);
                            try splitTopLevelCsv(receiver_core.inner, &receiver_args);

                            const map_n = @min(declared_params.items.len, receiver_args.items.len);
                            var bi: usize = 0;
                            while (bi < map_n) : (bi += 1) {
                                const param = normalizeGenericParamName(declared_params.items[bi]);
                                const arg = std.mem.trim(u8, receiver_args.items[bi], " \t\r\n");
                                if (param.len == 0 or arg.len == 0) continue;
                                try bindIfMissing(&bindings, param, arg);
                            }
                        }
                    }
                }
            }
        }

        var param_types = ArrayList([]const u8).init(self.allocator);
        defer param_types.deinit();
        try parseParamTypesFromLabel(sig.label, &param_types);

        var arg_ranges = ArrayList(ArgRange).init(self.allocator);
        defer arg_ranges.deinit();

        const cursor_end = @min(cursor_tok_i + 1, idx.tokens.len);
        var end_excl = cursor_end;
        if (findMatchingRParenSig(idx.tokens, lparen_i)) |rp| {
            if (rp < end_excl) end_excl = rp;
        }
        if (end_excl > lparen_i + 1) {
            try collectCallArgRangesLite(idx.tokens, lparen_i, end_excl, &arg_ranges);
        }

        const pair_n = @min(param_types.items.len, arg_ranges.items.len);
        var pi: usize = 0;
        while (pi < pair_n) : (pi += 1) {
            const rg = arg_ranges.items[pi];
            const arg_t = inferArgTypeFromRange(self, uri, idx, at, idx.tokens, rg.start, rg.end) orelse continue;
            try bindFromParamType(generic_params.items, &bindings, param_types.items[pi], arg_t);
        }

        return substituteLabelTypeParams(self.allocator, sig.label, bindings.items);
    }

    /// Resolves a callee identifier to its signature detail string (e.g.
    /// `fun add(num a, num b) num`), searching the current document first and
    /// then direct imports. Returns null if no signature is known.
    fn calleeSignatureDetail(self: *LspServer, uri: []const u8, idx: *const Index, callee_i: usize) ?[]const u8 {
        const callee = idx.tokens[callee_i];
        if (callee.kind != .identifier) return null;
        const name = callee.text;
        const at = callee.range.start;

        // Method call (`recv.method(`): resolve via the receiver type.
        if (callee_i >= 2 and isDotToken(idx.tokens[callee_i - 1]) and idx.tokens[callee_i - 2].kind == .identifier) {
            if (self.resolveTypeOfChainUpTo(idx, uri, at, callee_i - 2)) |recv_type| {
                if (self.findMemberByContainer(uri, recv_type, name, .method)) |hit| {
                    return hit.sym.detail;
                }
            }
        }

        if (findBestDefinition(idx.symbols, name, at)) |d| {
            if (d.kind == .function or d.kind == .method) return d.detail;
        }
        if (self.findAnyGlobalDefinitionInDirectImports(uri, name)) |hit| {
            if (hit.sym.kind == .function or hit.sym.kind == .method) return hit.sym.detail;
        }
        return null;
    }

    /// Parameter-name inlay hints (gopls/rust-analyzer style): renders the
    /// parameter name before each argument at a call site, e.g. `f(x: 1, y: 2)`.
    /// Only emits hints within the client-requested range and only when the
    /// callee's parameter names are known. A hint is suppressed when the argument
    /// is already a bare identifier equal to the parameter name (it would be
    /// redundant), matching what mature language servers do.
    fn handleInlayHint(self: *LspServer, id_val: ?std.json.Value, params_val: ?std.json.Value) !void {
        const empty = "[]";
        const params = params_val orelse return self.sendResponseJson(id_val, empty);
        if (params != .object) return self.sendResponseJson(id_val, empty);
        const text_document = params.object.get("textDocument") orelse return self.sendResponseJson(id_val, empty);
        if (text_document != .object) return self.sendResponseJson(id_val, empty);
        const uri = (text_document.object.get("uri") orelse return self.sendResponseJson(id_val, empty)).string;

        // Requested range (hints outside it are skipped for performance).
        var want = Range{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 1_000_000_000, .character = 0 } };
        if (params.object.get("range")) |rv| {
            if (rv == .object) {
                if (rv.object.get("start")) |sv| {
                    if (sv == .object) {
                        want.start.line = (sv.object.get("line") orelse std.json.Value{ .integer = 0 }).integer;
                        want.start.character = (sv.object.get("character") orelse std.json.Value{ .integer = 0 }).integer;
                    }
                }
                if (rv.object.get("end")) |ev| {
                    if (ev == .object) {
                        want.end.line = (ev.object.get("line") orelse std.json.Value{ .integer = 1_000_000_000 }).integer;
                        want.end.character = (ev.object.get("character") orelse std.json.Value{ .integer = 0 }).integer;
                    }
                }
            }
        }

        const doc = self.docs.get(uri) orelse return self.sendResponseJson(id_val, empty);
        const idx = doc.index orelse return self.sendResponseJson(id_val, empty);

        var hints = ArrayList(InlayHint).init(self.allocator);
        defer hints.deinit();

        const toks = idx.tokens;
        var i: usize = 0;
        while (i + 1 < toks.len) : (i += 1) {
            // Detect a call: identifier immediately followed by `(`.
            if (toks[i].kind != .identifier) continue;
            if (!isOpenParen(toks[i + 1])) continue;
            // Skip function/method *declarations* (incl. `impl` methods written
            // `pub name(...)` with no `fun` keyword) — their parameter names are
            // already written, so inlay hints there are noise.
            if (callParenIsDeclaration(toks, i, i + 1)) continue;

            const detail = self.calleeSignatureDetail(uri, idx, i) orelse continue;
            var params_list = self.parseParamsFromSignatureLabel(detail) catch continue;
            defer {
                for (params_list.items) |p| self.allocator.free(p.label);
                params_list.deinit();
            }
            if (params_list.items.len == 0) continue;

            // Walk arguments: top-level (depth-aware) comma-separated groups
            // between the matching parens. Emit a hint at each argument's first token.
            var depth: i32 = 0;
            var arg_index: usize = 0;
            var expecting_arg = true; // next significant token starts an argument
            var j = i + 1; // at '('
            while (j < toks.len) : (j += 1) {
                const t = toks[j];
                if (isOpenParen(t) or isOpenBracket(t)) {
                    depth += 1;
                    if (depth == 1) continue; // the call's own '('
                }
                if (isCloseParen(t) or isCloseBracket(t)) {
                    depth -= 1;
                    if (depth == 0) break; // end of this call
                    continue;
                }
                if (depth == 1 and isCommaToken(t)) {
                    arg_index += 1;
                    expecting_arg = true;
                    continue;
                }
                if (depth == 1 and expecting_arg and t.kind != .comment) {
                    expecting_arg = false;
                    if (arg_index < params_list.items.len) {
                        const pname = paramNameFromLabel(params_list.items[arg_index].label);
                        if (pname.len != 0 and posInRange(t.range.start, want)) {
                            // Suppress redundant hint when the arg is the same identifier.
                            const redundant = t.kind == .identifier and std.mem.eql(u8, t.text, pname);
                            if (!redundant) {
                                const label = try std.fmt.allocPrint(self.allocator, "{s}:", .{pname});
                                try hints.append(.{
                                    .position = t.range.start,
                                    .label = label,
                                    .kind = 2,
                                    .paddingRight = true,
                                });
                            }
                        }
                    }
                }
            }
        }

        const json = try jsonStringifyAlloc(self.allocator, hints.items);
        defer self.allocator.free(json);
        defer for (hints.items) |h| self.allocator.free(h.label);
        try self.sendResponseJson(id_val, json);
    }

    fn handleDocumentSymbols(self: *LspServer, id_val: ?std.json.Value, params_val: ?std.json.Value) !void {
        const uri = (try parseTextDocUri(params_val)) orelse {
            try self.sendResponseJson(id_val, "[]");
            return;
        };
        const doc = self.docs.get(uri) orelse {
            try self.sendResponseJson(id_val, "[]");
            return;
        };
        const idx = doc.index orelse {
            try self.sendResponseJson(id_val, "[]");
            return;
        };

        // Return flat `SymbolInformation[]` (LSP allows either SymbolInformation[] or DocumentSymbol[]).
        // Some clients/modes will interpret the response as SymbolInformation[]; if we return
        // DocumentSymbol[] without `location`, those clients can crash during protocol conversion.
        var syms = ArrayList(SymbolInformation).init(self.allocator);
        defer {
            for (syms.items) |s| self.allocator.free(s.name);
            syms.deinit();
        }

        for (idx.symbols) |s| {
            // Only top-level (no container).
            if (s.container_fn_range != null) continue;
            if (s.kind == .variable) continue;
            try syms.append(.{
                .name = try self.allocator.dupe(u8, s.name),
                .kind = @intFromEnum(s.kind),
                .location = .{ .uri = uri, .range = s.selection_range },
            });
        }

        const json = try jsonStringifyAlloc(self.allocator, syms.items);
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
    }

    fn handleWorkspaceSymbols(self: *LspServer, id_val: ?std.json.Value, params_val: ?std.json.Value) !void {
        const query = (try parseWorkspaceSymbolQuery(self.allocator, params_val)) orelse "";
        defer if (query.len != 0) self.allocator.free(query);

        var out = ArrayList(SymbolInformation).init(self.allocator);
        defer {
            for (out.items) |s| self.allocator.free(s.name);
            out.deinit();
        }

        var it = self.docs.iterator();
        while (it.next()) |entry| {
            const uri = entry.value_ptr.uri;
            const idx = entry.value_ptr.index orelse continue;
            for (idx.symbols) |s| {
                if (s.container_fn_range != null) continue;
                if (query.len != 0 and std.mem.indexOf(u8, s.name, query) == null) continue;
                try out.append(.{
                    .name = try self.allocator.dupe(u8, s.name),
                    .kind = @intFromEnum(s.kind),
                    .location = .{ .uri = uri, .range = s.selection_range },
                });
            }
        }

        const json = try jsonStringifyAlloc(self.allocator, out.items);
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
    }

    fn handleSemanticTokensFull(self: *LspServer, id_val: ?std.json.Value, params_val: ?std.json.Value) !void {
        const uri = (try parseTextDocUri(params_val)) orelse {
            try self.sendResponseJson(id_val, "null");
            return;
        };
        const doc = self.docs.get(uri) orelse {
            try self.sendResponseJson(id_val, "null");
            return;
        };
        const idx = doc.index orelse {
            try self.sendResponseJson(id_val, "null");
            return;
        };

        const data = try buildSemanticTokens(self.allocator, idx);
        defer self.allocator.free(data);
        const st = SemanticTokens{ .data = data };
        const json = try jsonStringifyAlloc(self.allocator, st);
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
    }

    fn upsertDoc(self: *LspServer, uri: []const u8, version: i64, text: []const u8) !void {
        const text_copy = try self.allocator.dupe(u8, text);
        if (self.docs.getPtr(uri)) |doc| {
            // IMPORTANT: the hash map key memory is the same allocation as `doc.uri`.
            // Never free/replace it on updates, or lookups become undefined.
            self.allocator.free(doc.text);
            doc.version = version;
            doc.text = text_copy;
        } else {
            const uri_copy = try self.allocator.dupe(u8, uri);
            try self.docs.put(uri_copy, .{ .uri = uri_copy, .version = version, .text = text_copy });
        }
    }

    fn maybePublishDiagnostics(self: *LspServer, uri: []const u8, text: []const u8, force: bool) !void {
        const now = nowMs();
        const doc_ptr = self.docs.getPtr(uri) orelse return;

        if (!force and doc_ptr.last_diag_ms != 0) {
            const dt = now - doc_ptr.last_diag_ms;
            // Avoid spawning `fun` too often while typing; it can make the LSP feel "buggy"/stalled.
            if (dt >= 0 and dt < 400) return;
        }

        // Update timestamp before the subprocess so that a failure doesn't cause
        // an immediate tight retry loop on the next didChange.
        doc_ptr.last_diag_ms = now;
        try self.publishDiagnostics(uri, text);
        // Reset to actual completion time after a (potentially slow) subprocess.
        // Without this, all didChange messages that piled up in the OS pipe buffer
        // while the subprocess ran see dt = subprocess_duration >> 400 ms and
        // immediately fire another subprocess — a thundering herd.
        if (self.docs.getPtr(uri)) |dp| dp.last_diag_ms = nowMs();
    }

    fn rebuildIndex(self: *LspServer, uri: []const u8) !void {
        const doc_ptr = self.docs.getPtr(uri) orelse return;
        const scope: IndexBuildScope = if (doc_ptr.version > 0) .open_document else .background;

        // Build the new index first; if it fails, keep the old one so completion doesn't "die" mid-edit.
        const new_idx = buildIndexFromTextAt(self.allocator, doc_ptr.text, null, scope) catch |err| {
            self.log("[fls] rebuildIndex failed (keeping old index): {s}\n", .{@errorName(err)});
            return;
        };

        if (doc_ptr.index) |idx| idx.deinit();
        doc_ptr.index = new_idx;
        self.ensureImportsIndexed(uri);
        self.refineLetVariableTypesFromDirectImports(uri);
    }

    /// Heuristic: does a type spelling still carry an UNBOUND generic type parameter?
    /// (e.g. `Option<T>`, `Result<T>`, `Map<K, V>`.) These are index-time best-effort
    /// let-inference results where the compiler couldn't substitute the concrete arg;
    /// they should be re-refined by the query-time call-return engine so hover shows
    /// the concrete instantiation (`Option<str>`). Fun's generic type params follow the
    /// single-uppercase-letter convention (T, U, K, V, E, ...), so a generic ARGUMENT
    /// that is a lone uppercase letter and not a builtin is treated as unbound.
    fn typeSpellingHasUnboundParam(type_str: []const u8) bool {
        const lt = std.mem.indexOfScalar(u8, type_str, '<') orelse return false;
        const gt = std.mem.lastIndexOfScalar(u8, type_str, '>') orelse return false;
        if (gt <= lt + 1) return false;
        const inner = type_str[lt + 1 .. gt];

        var i: usize = 0;
        while (i < inner.len) {
            const c = inner[i];
            const is_ident = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
            if (!is_ident) {
                i += 1;
                continue;
            }
            const start = i;
            while (i < inner.len) : (i += 1) {
                const ch = inner[i];
                const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
                    (ch >= '0' and ch <= '9') or ch == '_' or ch == '.';
                if (!ok) break;
            }
            const name = inner[start..i];
            if (name.len == 1 and name[0] >= 'A' and name[0] <= 'Z' and !isBuiltinTypeName(name)) return true;
        }
        return false;
    }

    fn refineLetVariableTypesFromDirectImports(self: *LspServer, uri: []const u8) void {
        const doc_ptr = self.docs.getPtr(uri) orelse return;
        const idx = doc_ptr.index orelse return;
        const has_imports = blk: {
            for (idx.tokens) |t| {
                if (t.kind == .keyword and std.mem.eql(u8, t.text, "imp")) break :blk true;
            }
            break :blk false;
        };
        if (!has_imports) return;
        const arena_alloc = idx.arena.allocator();

        var pass: usize = 0;
        while (pass < 3) : (pass += 1) {
            var changed = false;

            for (idx.symbols) |*s| {
                if (s.kind != .variable) continue;

                const existing_vt_opt = s.value_type;
                if (existing_vt_opt) |existing_vt| {
                    if (!isLetInferTypeName(existing_vt) and !isBuiltinTypeName(existing_vt) and !typeSpellingHasUnboundParam(existing_vt)) continue;
                }

                const inferred = self.tryInferLetInitializerCallReturnType(idx, uri, s, arena_alloc) orelse continue;
                if (isLetInferTypeName(inferred)) continue;
                if (existing_vt_opt) |existing_vt| {
                    if (std.mem.eql(u8, inferred, existing_vt)) continue;
                    if (isBuiltinTypeName(existing_vt) and isBuiltinTypeName(inferred) and !self.letInitializerEndsWithCall(idx, s)) continue;
                }

                s.value_type = inferred;

                var det_buf = ArrayList(u8).init(arena_alloc);
                defer det_buf.deinit();
                det_buf.print("{s} {s}", .{ inferred, s.name }) catch continue;
                s.detail = det_buf.toOwnedSlice() catch continue;
                changed = true;
            }

            if (!changed) break;
        }
    }

    fn letInitializerEndsWithCall(self: *LspServer, idx: *const Index, sym: *const SymbolLite) bool {
        _ = self;

        const tokenHasChar = struct {
            fn call(text: []const u8, ch: u8) bool {
                return std.mem.indexOfScalar(u8, text, ch) != null;
            }
        }.call;

        const isDelimiterOnlyToken = struct {
            fn call(text: []const u8) bool {
                if (text.len == 0) return false;
                for (text) |ch| {
                    if (ch != ';' and ch != ',') return false;
                }
                return true;
            }
        }.call;

        const findExprEnd = struct {
            fn call(tokens: []const TokenLite, start_i: usize) usize {
                var paren_depth: i64 = 0;
                var brack_depth: i64 = 0;
                var brace_depth: i64 = 0;

                var i = start_i;
                while (i < tokens.len) : (i += 1) {
                    const t = tokens[i];
                    if (t.kind == .comment) continue;

                    var saw_end = false;
                    for (t.text) |ch| {
                        switch (ch) {
                            '(' => paren_depth += 1,
                            ')' => {
                                if (paren_depth > 0) paren_depth -= 1;
                            },
                            '[' => brack_depth += 1,
                            ']' => {
                                if (brack_depth > 0) brack_depth -= 1;
                            },
                            '{' => brace_depth += 1,
                            '}' => {
                                if (brace_depth > 0) brace_depth -= 1;
                            },
                            ';', ',' => {
                                if (paren_depth == 0 and brack_depth == 0 and brace_depth == 0) saw_end = true;
                            },
                            else => {},
                        }
                    }

                    if (saw_end) return i;
                }

                return tokens.len;
            }
        }.call;

        var name_i_opt: ?usize = null;
        for (idx.tokens, 0..) |t, i| {
            if (t.kind != .identifier) continue;
            if (!std.mem.eql(u8, t.text, sym.name)) continue;
            if (!rangeEqual(t.range, sym.selection_range)) continue;
            name_i_opt = i;
            break;
        }
        const name_i = name_i_opt orelse return false;

        const let_kw_i = prevNonTrivialTokenLite(idx.tokens, name_i) orelse return false;
        if (idx.tokens[let_kw_i].kind != .keyword or !std.mem.eql(u8, idx.tokens[let_kw_i].text, "let")) return false;

        const eq_i = nextNonTrivialTokenLite(idx.tokens, name_i + 1) orelse return false;
        if (!(idx.tokens[eq_i].kind == .operator or idx.tokens[eq_i].kind == .symbol) or !std.mem.eql(u8, idx.tokens[eq_i].text, "=")) return false;

        var expr_i = nextNonTrivialTokenLite(idx.tokens, eq_i + 1) orelse return false;
        if (idx.tokens[expr_i].kind == .keyword and std.mem.eql(u8, idx.tokens[expr_i].text, "await")) {
            expr_i = nextNonTrivialTokenLite(idx.tokens, expr_i + 1) orelse return false;
        }

        const expr_end_i = findExprEnd(idx.tokens, expr_i);
        if (expr_end_i <= expr_i) return false;

        const expr_last_i = blk: {
            if (expr_end_i >= idx.tokens.len) {
                break :blk prevNonTrivialTokenLite(idx.tokens, idx.tokens.len) orelse return false;
            }
            if (isDelimiterOnlyToken(idx.tokens[expr_end_i].text)) {
                break :blk prevNonTrivialTokenLite(idx.tokens, expr_end_i) orelse return false;
            }
            break :blk expr_end_i;
        };
        if (expr_last_i < expr_i) return false;
        if (!tokenHasChar(idx.tokens[expr_last_i].text, ')')) return false;

        const lparen_i = findMatchingLParenLite(idx.tokens, expr_last_i) orelse return false;
        return lparen_i >= expr_i;
    }

    fn tryInferLetInitializerCallReturnType(self: *LspServer, idx: *const Index, uri: []const u8, sym: *const SymbolLite, arena_alloc: Allocator) ?[]const u8 {
        const tokenHasChar = struct {
            fn call(text: []const u8, ch: u8) bool {
                return std.mem.indexOfScalar(u8, text, ch) != null;
            }
        }.call;

        const isDelimiterOnlyToken = struct {
            fn call(text: []const u8) bool {
                if (text.len == 0) return false;
                for (text) |ch| {
                    if (ch != ';' and ch != ',') return false;
                }
                return true;
            }
        }.call;

        const findExprEnd = struct {
            fn call(tokens: []const TokenLite, start_i: usize) usize {
                var paren_depth: i64 = 0;
                var brack_depth: i64 = 0;
                var brace_depth: i64 = 0;

                var i = start_i;
                while (i < tokens.len) : (i += 1) {
                    const t = tokens[i];
                    if (t.kind == .comment) continue;

                    var saw_end = false;
                    for (t.text) |ch| {
                        switch (ch) {
                            '(' => paren_depth += 1,
                            ')' => {
                                if (paren_depth > 0) paren_depth -= 1;
                            },
                            '[' => brack_depth += 1,
                            ']' => {
                                if (brack_depth > 0) brack_depth -= 1;
                            },
                            '{' => brace_depth += 1,
                            '}' => {
                                if (brace_depth > 0) brace_depth -= 1;
                            },
                            ';', ',' => {
                                if (paren_depth == 0 and brack_depth == 0 and brace_depth == 0) {
                                    saw_end = true;
                                }
                            },
                            else => {},
                        }
                    }

                    if (saw_end) return i;
                }

                return tokens.len;
            }
        }.call;

        const inferFromTerminalCall = struct {
            fn call(self_: *LspServer, idx_: *const Index, uri_: []const u8, expr_start_i: usize, expr_last_i: usize, arena_alloc_: Allocator) ?[]const u8 {
                const last_i = expr_last_i;
                if (last_i < expr_start_i) return null;
                if (!tokenHasChar(idx_.tokens[last_i].text, ')')) return null;

                const lparen_i = findMatchingLParenLite(idx_.tokens, last_i) orelse return null;
                if (lparen_i < expr_start_i) return null;

                const before_rparen_i = prevNonTrivialTokenLite(idx_.tokens, last_i) orelse lparen_i;
                const sig_pos = if (before_rparen_i == lparen_i)
                    idx_.tokens[lparen_i].range.start
                else
                    idx_.tokens[before_rparen_i].range.start;

                // Prefer the query-time call-return engine: it specializes generic FREE
                // functions against their concrete argument types (e.g. `some("hi")` ->
                // `Option<str>`), which the signatureHelp label path does not do for a bare
                // free call. Only accept it when it produced a fully-bound type (no leftover
                // `<T>`); otherwise fall through to the signatureHelp-derived return type.
                if (self_.resolveCallReturnType(idx_, uri_, sig_pos, last_i)) |crt| {
                    if (crt.len != 0 and !typeSpellingHasUnboundParam(crt)) {
                        return arena_alloc_.dupe(u8, crt) catch null;
                    }
                }

                const sig = self_.guessCallSignatureAt(uri_, idx_, sig_pos) orelse return null;

                var label = sig.label;
                var specialized_owned: ?[]u8 = null;
                defer if (specialized_owned) |s| self_.allocator.free(s);

                if (self_.specializeGenericSignatureHelpLabel(uri_, idx_, sig_pos, sig) catch null) |specialized| {
                    specialized_owned = specialized;
                    label = specialized;
                }

                const rt = self_.parseReturnTypeFromSignatureLabel(label) orelse return null;
                return arena_alloc_.dupe(u8, rt) catch null;
            }
        }.call;

        var name_i_opt: ?usize = null;
        for (idx.tokens, 0..) |t, i| {
            if (t.kind != .identifier) continue;
            if (!std.mem.eql(u8, t.text, sym.name)) continue;
            if (!rangeEqual(t.range, sym.selection_range)) continue;
            name_i_opt = i;
            break;
        }
        const name_i = name_i_opt orelse return null;

        const let_kw_i = prevNonTrivialTokenLite(idx.tokens, name_i) orelse return null;
        if (idx.tokens[let_kw_i].kind != .keyword or !std.mem.eql(u8, idx.tokens[let_kw_i].text, "let")) return null;

        const eq_i = nextNonTrivialTokenLite(idx.tokens, name_i + 1) orelse return null;
        if (!(idx.tokens[eq_i].kind == .operator or idx.tokens[eq_i].kind == .symbol) or !std.mem.eql(u8, idx.tokens[eq_i].text, "=")) return null;

        var expr_i = nextNonTrivialTokenLite(idx.tokens, eq_i + 1) orelse return null;
        if (idx.tokens[expr_i].kind == .keyword and std.mem.eql(u8, idx.tokens[expr_i].text, "await")) {
            expr_i = nextNonTrivialTokenLite(idx.tokens, expr_i + 1) orelse return null;
        }

        const expr_end_i = findExprEnd(idx.tokens, expr_i);
        if (expr_end_i <= expr_i) return null;

        const expr_last_i = blk: {
            if (expr_end_i >= idx.tokens.len) {
                break :blk prevNonTrivialTokenLite(idx.tokens, idx.tokens.len) orelse return null;
            }
            if (isDelimiterOnlyToken(idx.tokens[expr_end_i].text)) {
                break :blk prevNonTrivialTokenLite(idx.tokens, expr_end_i) orelse return null;
            }
            break :blk expr_end_i;
        };
        if (expr_last_i < expr_i) return null;

        if (inferFromTerminalCall(self, idx, uri, expr_i, expr_last_i, arena_alloc)) |rt| {
            if (rt.len != 0) return rt;
        }

        const last_i = expr_last_i;
        if (last_i >= expr_i and idx.tokens[last_i].kind == .identifier) {
            // Chain/field expression ending with an identifier.
            var saw_dot = false;
            var i = expr_i;
            while (i <= last_i) : (i += 1) {
                if (isDotToken(idx.tokens[i])) {
                    saw_dot = true;
                    break;
                }
            }

            if (saw_dot) {
                if (self.resolveTypeOfChainUpTo(idx, uri, idx.tokens[last_i].range.start, last_i)) |tname| {
                    if (tname.len != 0) return arena_alloc.dupe(u8, tname) catch null;
                }
            } else {
                // Only treat plain single-identifier initializers (`let y = x;`) as variable references.
                // For compound expressions, this fallback can pick unrelated symbols by name.
                if (last_i == expr_i) {
                    if (self.guessVariableType(idx, uri, idx.tokens[last_i].text, idx.tokens[last_i].range.start)) |vt| {
                        if (vt.len != 0) return arena_alloc.dupe(u8, vt) catch null;
                    }
                }
            }
        }

        // Compound initializer: `Type{...}` or `Type<...>{...}`.
        if (idx.tokens[expr_i].kind == .identifier) {
            var probe_i = nextNonTrivialTokenLite(idx.tokens, expr_i + 1) orelse idx.tokens.len;
            if (probe_i < idx.tokens.len and (idx.tokens[probe_i].kind == .symbol or idx.tokens[probe_i].kind == .operator) and std.mem.eql(u8, idx.tokens[probe_i].text, "<")) {
                const after_generic = skipGenericArgsLite(idx.tokens, probe_i);
                if (after_generic < idx.tokens.len and (idx.tokens[after_generic].kind == .symbol or idx.tokens[after_generic].kind == .operator) and std.mem.eql(u8, idx.tokens[after_generic].text, "{")) {
                    if (concreteGenericTypeAtToken(arena_alloc, idx.tokens, expr_i) catch null) |gt| return gt;
                }
                probe_i = after_generic;
            }

            if (probe_i < idx.tokens.len and (idx.tokens[probe_i].kind == .symbol or idx.tokens[probe_i].kind == .operator) and std.mem.eql(u8, idx.tokens[probe_i].text, "{")) {
                return arena_alloc.dupe(u8, idx.tokens[expr_i].text) catch null;
            }
        }

        return null;
    }

    fn ensureImportsIndexed(self: *LspServer, uri: []const u8) void {
        const doc = self.docs.get(uri) orelse return;
        const idx = doc.index orelse return;
        for (idx.tokens, 0..) |t, i| {
            if (t.kind != .keyword) continue;
            if (!std.mem.eql(u8, t.text, "imp")) continue;
            if (i + 1 >= idx.tokens.len) continue;
            const spec = self.parseImportSpecFromTokens(idx, i) catch null;
            if (spec) |s| {
                defer self.allocator.free(s);
                if (self.debug_imports) self.dbg(true, "imports", "found import in {s}: '{s}'", .{ uri, s });
                const maybe_target_uri = self.resolveImportUri(uri, s) catch null;
                if (maybe_target_uri) |target_uri| {
                    defer self.allocator.free(target_uri);
                    if (self.debug_imports) self.dbg(true, "imports", "resolved import '{s}' => {s}", .{ s, target_uri });
                    self.ensureDocIndexedFromDisk(target_uri) catch {};
                } else {
                    if (self.debug_imports) self.dbg(true, "imports", "failed to resolve import '{s}'", .{s});
                }
            }
        }
    }

    /// On-disk last-modified time (ns since epoch) for a `file:` URI, or null if the
    /// file can't be stat'd. Cheap (metadata only, no read). Used as a staleness key
    /// so we re-index a library doc only when it actually changed on disk.
    fn fileMtimeNs(self: *LspServer, uri: []const u8) ?i128 {
        const path = uriToPath(self.allocator, uri) catch return null;
        defer self.allocator.free(path);
        var f = blk: {
            if (std.fs.path.isAbsolute(path)) {
                break :blk std.Io.Dir.openFileAbsolute(globalIo(), path, .{}) catch return null;
            }
            break :blk std.Io.Dir.cwd().openFile(globalIo(), path, .{}) catch return null;
        };
        defer f.close(globalIo());
        const st = f.stat(globalIo()) catch return null;
        return st.mtime.nanoseconds;
    }

    /// Re-read + re-index a doc from disk even if it is already cached — but ONLY when
    /// it was FLS-loaded (version 0), never when the editor is actively editing it
    /// (clobbering an unsaved buffer would be wrong). Used to recover from a stale or
    /// method-less cached index of a library file (e.g. `option.fn` indexed token-only
    /// or before a fix), which otherwise silently fails a member lookup.
    ///
    /// Staleness is detected via the file's on-disk mtime: if the cached index was
    /// built from the same mtime the file currently has, the index is already current
    /// and we skip the re-read entirely. This keeps the cost of a *genuine* member
    /// miss (e.g. a typo'd method name) to one cheap stat — no full re-read/re-parse —
    /// while still self-healing when the library file truly changed since indexing.
    fn refreshLibraryDocFromDisk(self: *LspServer, uri: []const u8) void {
        if (self.docs.get(uri)) |doc| {
            if (doc.version != 0) return; // editor-owned; don't clobber
        }
        const disk_mtime = self.fileMtimeNs(uri);
        // If we already indexed this exact on-disk version, the cached index is
        // current — re-reading would be pure waste (the member legitimately isn't there).
        if (self.docs.get(uri)) |doc| {
            if (doc.index != null and disk_mtime != null and doc.index_mtime == disk_mtime.?) return;
        }
        const path = uriToPath(self.allocator, uri) catch return;
        defer self.allocator.free(path);
        const text = blk: {
            if (std.fs.path.isAbsolute(path)) {
                var f = std.Io.Dir.openFileAbsolute(globalIo(), path, .{}) catch return;
                defer f.close(globalIo());
                break :blk fileReadAlloc(self.allocator, f, 25 * 1024 * 1024) catch return;
            }
            break :blk std.Io.Dir.cwd().readFileAlloc(globalIo(), path, self.allocator, .limited(25 * 1024 * 1024)) catch return;
        };
        defer self.allocator.free(text);
        self.upsertDoc(uri, 0, text) catch return;
        self.rebuildIndex(uri) catch return;
        // Stamp the mtime we just indexed so a later miss on the same file is a no-op.
        if (disk_mtime) |m| {
            if (self.docs.getPtr(uri)) |dp| dp.index_mtime = m;
        }
    }

    /// Member lookup with a self-healing retry: if the first lookup misses, locate the
    /// receiver type's declaring doc, refresh its index from disk (if FLS-loaded), and
    /// retry once. Recovers go-to-def/hover on a transitively-imported type whose
    /// declaring doc had a stale/method-less cached index.
    fn findMemberByContainerFresh(self: *LspServer, preferred_uri: []const u8, container_type: []const u8, name: []const u8, kind: SymbolKind) ?MemberHit {
        if (self.findMemberByContainer(preferred_uri, container_type, name, kind)) |hit| return hit;
        if (self.findTypeDefinitionAnyDoc(preferred_uri, container_type)) |type_def| {
            self.refreshLibraryDocFromDisk(type_def.uri);
            if (self.findMemberByContainer(preferred_uri, container_type, name, kind)) |hit| return hit;
        }
        return null;
    }

    fn ensureDocIndexedFromDisk(self: *LspServer, uri: []const u8) !void {
        if (self.docs.get(uri) != null) return;
        const path = try uriToPath(self.allocator, uri);
        defer self.allocator.free(path);

        // `uriToPath()` yields an absolute path for `file:` URIs.
        // On Windows, using `readFileAlloc_DONE` with an absolute path can fail,
        // which breaks stdlib indexing when the stdlib lives outside the workspace.
        const text = blk: {
            if (std.fs.path.isAbsolute(path)) {
                var f = try std.Io.Dir.openFileAbsolute(globalIo(), path, .{});
                defer f.close(globalIo());
                break :blk try fileReadAlloc(self.allocator, f, 25 * 1024 * 1024);
            }
            break :blk try std.Io.Dir.cwd().readFileAlloc(globalIo(), path, self.allocator, .limited(25 * 1024 * 1024));
        };
        defer self.allocator.free(text);

        try self.upsertDoc(uri, 0, text);
        try self.rebuildIndex(uri);
        // Baseline the staleness key so a later member miss on this unchanged file
        // is a cheap stat-and-skip rather than a full re-read (see refreshLibraryDocFromDisk).
        if (self.fileMtimeNs(uri)) |m| {
            if (self.docs.getPtr(uri)) |dp| dp.index_mtime = m;
        }
    }

    fn resolveImportUri(self: *LspServer, current_uri: []const u8, raw_import: []const u8) !?[]u8 {
        // Supports:
        // - `imp std.c.io;` => <workspace>/stdlib/std/c/io.fn
        // - `imp relative.parent;` => <current_dir>/relative/parent.fn
        // - `imp child;` => <current_dir>/child.fn
        // - `imp ..defs.user;` => <current_dir>/../defs/user.fn
        const spec = std.mem.trim(u8, raw_import, " \t\r\n\"");
        if (spec.len == 0) return null;

        if (self.debug_imports) self.dbg(true, "imports", "resolveImportUri current_uri={s} raw='{s}' spec='{s}'", .{ current_uri, raw_import, spec });

        const current_path = uriToPath(self.allocator, current_uri) catch return null;
        defer self.allocator.free(current_path);
        const current_dir = std.fs.path.dirname(current_path) orelse return null;

        const parsed = struct {
            fn addSegments(out: *ArrayList([]const u8), s: []const u8) !void {
                var start: usize = 0;
                var i: usize = 0;
                while (i < s.len) {
                    if (s[i] != '.') {
                        i += 1;
                        continue;
                    }

                    // Flush preceding identifier segment.
                    if (i > start) {
                        const seg = std.mem.trim(u8, s[start..i], " \t\r\n\"");
                        if (seg.len != 0) try out.append(seg);
                    }

                    // Consume dot run.
                    var j = i;
                    while (j < s.len and s[j] == '.') : (j += 1) {}
                    const run_len = j - i;
                    const parents = run_len / 2;
                    // If there's an odd dot, it's just a separator.
                    var p: usize = 0;
                    while (p < parents) : (p += 1) {
                        try out.append("..");
                    }

                    i = j;
                    start = i;
                }

                if (s.len > start) {
                    const seg = std.mem.trim(u8, s[start..], " \t\r\n\"");
                    if (seg.len != 0) try out.append(seg);
                }
            }
        };

        var parts = ArrayList([]const u8).init(self.allocator);
        defer parts.deinit();
        try parsed.addSegments(&parts, spec);
        if (parts.items.len == 0) return null;

        var segs = ArrayList([]const u8).init(self.allocator);
        defer segs.deinit();

        if (std.mem.eql(u8, parts.items[0], "std")) {
            var stdlib_root = self.getStdlibRootPath() orelse null;
            if (stdlib_root == null) {
                self.tryStdlibRootFromCurrentDoc(current_uri);
                stdlib_root = self.getStdlibRootPath() orelse null;
            }
            const root = stdlib_root orelse return null;
            if (self.debug_imports) self.dbg(true, "imports", "stdlib root used={s}", .{root});
            try segs.append(root);
            try segs.append("std");

            if (parts.items.len == 1) return null;
            for (parts.items[1..]) |p| try segs.append(p);
        } else {
            try segs.append(current_dir);
            for (parts.items) |p| try segs.append(p);
        }

        // Append .fn
        const joined = try std.fs.path.join(self.allocator, segs.items);
        defer self.allocator.free(joined);

        const full = try std.mem.concat(self.allocator, u8, &[_][]const u8{ joined, ".fn" });
        defer self.allocator.free(full);

        if (self.debug_imports) self.dbg(true, "imports", "candidate path={s}", .{full});

        // `full` is typically absolute (current file dir is absolute or stdlib root is absolute).
        // Use absolute file APIs so installed stdlib works on Windows.
        const full_exists = blk: {
            if (std.fs.path.isAbsolute(full)) {
                var f = std.Io.Dir.openFileAbsolute(globalIo(), full, .{}) catch break :blk false;
                f.close(globalIo());
                break :blk true;
            } else {
                std.Io.Dir.cwd().access(globalIo(), full, .{}) catch break :blk false;
                break :blk true;
            }
        };
        if (full_exists) {
            return try pathToUri(self.allocator, full);
        }

        // Fallback for editor temp buffers (e.g. files opened under `.zig-cache`):
        // resolve relative imports from the workspace root when current-dir relative
        // lookup fails.
        if (!std.mem.eql(u8, parts.items[0], "std")) {
            if (self.root_path) |root| {
                var segs_root = ArrayList([]const u8).init(self.allocator);
                defer segs_root.deinit();
                try segs_root.append(root);
                for (parts.items) |p| try segs_root.append(p);

                const joined_root = try std.fs.path.join(self.allocator, segs_root.items);
                defer self.allocator.free(joined_root);
                const full_root = try std.mem.concat(self.allocator, u8, &[_][]const u8{ joined_root, ".fn" });
                defer self.allocator.free(full_root);

                const root_exists = blk: {
                    if (std.fs.path.isAbsolute(full_root)) {
                        var f = std.Io.Dir.openFileAbsolute(globalIo(), full_root, .{}) catch break :blk false;
                        f.close(globalIo());
                        break :blk true;
                    } else {
                        std.Io.Dir.cwd().access(globalIo(), full_root, .{}) catch break :blk false;
                        break :blk true;
                    }
                };
                if (root_exists) {
                    return try pathToUri(self.allocator, full_root);
                }
            }
        }

        return null;
    }

    fn publishDiagnostics(self: *LspServer, uri: []const u8, text: []const u8) !void {
        const diags_owned = try self.computeDiagnostics(uri, text);
        defer {
            for (diags_owned) |d| {
                self.allocator.free(d.uri);
                self.allocator.free(d.diag.message);
                if (d.diag.code) |c| self.allocator.free(c);
            }
            self.allocator.free(diags_owned);
        }

        var new_uris = std.StringHashMap(void).init(self.allocator);
        defer new_uris.deinit();

        var grouped = std.StringHashMap(ArrayList(Diagnostic)).init(self.allocator);
        defer {
            var git = grouped.iterator();
            while (git.next()) |e| {
                e.value_ptr.deinit();
            }
            grouped.deinit();
        }

        for (diags_owned) |d| {
            try new_uris.put(d.uri, {});
            if (grouped.getPtr(d.uri)) |list| {
                try list.append(d.diag);
            } else {
                var list = ArrayList(Diagnostic).init(self.allocator);
                try list.append(d.diag);
                try grouped.put(d.uri, list);
            }
        }

        // Clear stale diagnostics.
        var pit = self.published_diag_uris.iterator();
        while (pit.next()) |entry| {
            if (!new_uris.contains(entry.key_ptr.*)) {
                self.sendPublishDiagnostics(entry.key_ptr.*, &[_]Diagnostic{}) catch {};
            }
        }

        // Publish new diagnostics.
        var git2 = grouped.iterator();
        while (git2.next()) |e| {
            try self.sendPublishDiagnostics(e.key_ptr.*, e.value_ptr.items);
        }

        // Refresh published set (keys are owned by this map).
        var dit = self.published_diag_uris.iterator();
        while (dit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.published_diag_uris.clearRetainingCapacity();

        var nit = new_uris.iterator();
        while (nit.next()) |entry| {
            try self.published_diag_uris.put(try self.allocator.dupe(u8, entry.key_ptr.*), {});
        }
    }

    fn computeDiagnostics(self: *LspServer, current_uri: []const u8, text: []const u8) ![]DiagnosticWithUri {
        // Fast path: skip the subprocess if the content hasn't changed.
        // Also hit the cache when called with already-formatted text (the
        // format-on-save flow: format runs, updates doc text, then didSave fires).
        const input_hash = std.hash.Wyhash.hash(0, text);
        if (self.diag_cache.get(current_uri)) |entry| {
            if (entry.content_hash == input_hash or
                (entry.formatted_hash != 0 and entry.formatted_hash == input_hash))
            {
                return try dupeDiags(self.allocator, entry.diags);
            }
        }

        // Create the temp file next to the current document, so relative `imp "..."` resolution
        // and diagnostic file paths match the user's project layout.
        // Use a stable name derived from the URI so the file never flickers in the editor explorer.
        var tmp_name_buf: [80]u8 = undefined;
        const tmp_name = try std.fmt.bufPrint(&tmp_name_buf, ".__fls_{x:0>6}.fn", .{std.hash.Wyhash.hash(0, current_uri) & 0xFFFFFF});

        const current_path_opt = uriToPath(self.allocator, current_uri) catch null;
        defer if (current_path_opt) |p| self.allocator.free(p);
        const current_dir_opt = if (current_path_opt) |p| std.fs.path.dirname(p) else null;

        var base_dir = if (current_dir_opt) |d| try std.Io.Dir.openDirAbsolute(globalIo(), d, .{}) else std.Io.Dir.cwd();
        defer if (current_dir_opt != null) base_dir.close(globalIo());

        {
            const f = try base_dir.createFile(globalIo(), tmp_name, .{ .read = true, .truncate = true });
            defer f.close(globalIo());
            try f.writeStreamingAll(globalIo(), text);
        }
        defer base_dir.deleteFile(globalIo(), tmp_name) catch {};

        const tmp_path_for_fun = blk: {
            if (current_dir_opt) |d| {
                break :blk try std.fs.path.join(self.allocator, &[_][]const u8{ d, tmp_name });
            }
            break :blk try self.allocator.dupe(u8, tmp_name);
        };
        defer self.allocator.free(tmp_path_for_fun);

        var stderr_buf = ArrayList(u8).init(self.allocator);
        defer stderr_buf.deinit();

        // Use -fmt-diag instead of -no-exec so we warm the format cache for free.
        // The subprocess cost is identical (~40 ms); by storing the formatted result
        // now, any subsequent formatting request on the same content is a cache hit
        // with no subprocess needed.
        const argv = [_][]const u8{ self.fun_exe_path, "-in", tmp_path_for_fun, "-fmt-diag", "-no-exec", "-warn-unused-lenient" };
        _ = try runCaptureStderr(self.allocator, &argv, &stderr_buf);

        // Read back the (possibly reformatted) temp file so we can cache it.
        const formatted_text: ?[]u8 = blk: {
            const out = base_dir.readFileAlloc(globalIo(), tmp_name, self.allocator, .limited(10 * 1024 * 1024)) catch break :blk null;
            if (out.len == 0 and text.len != 0) {
                self.allocator.free(out);
                break :blk null;
            }
            break :blk out;
        };
        defer if (formatted_text) |f| self.allocator.free(f);

        const diags = try parseFunDiagnosticsByUri(self.allocator, stderr_buf.items, current_uri, tmp_name);

        // Cache both the diagnostics and the formatted text so formatAndComputeDiagnostics
        // gets a cache hit (no second subprocess) when the user saves.
        self.updateDiagCache(current_uri, input_hash, diags, formatted_text) catch {};

        return diags;
    }

    const FormatDiagResult = struct {
        /// Formatted source text; null means formatting failed (no edit should be sent).
        /// Owned by caller.
        formatted: ?[]u8,
        /// Diagnostics collected from the same subprocess run.  Owned by caller —
        /// caller must free each .uri, .diag.message, .diag.code, and the slice.
        diags: []DiagnosticWithUri,
    };

    /// Run `fun -fmt-diag -no-exec` once to both format and collect diagnostics.
    /// This replaces the previous two-subprocess approach (one for formatting,
    /// one for diagnostics) with a single subprocess invocation.
    ///
    /// Results are cached by a Wyhash of the raw source text.  On a cache hit
    /// (same content as last time) no subprocess is spawned.
    fn formatAndComputeDiagnostics(self: *LspServer, current_uri: []const u8, text: []const u8) !FormatDiagResult {
        // Fast path: if the content hasn't changed since the last compile, return
        // the cached result without spawning any subprocess.
        const input_hash = std.hash.Wyhash.hash(0, text);
        if (try self.checkDiagCache(current_uri, input_hash)) |cached| return cached;

        // Write the temp file next to the document so that relative imports resolve
        // the same way as they do in the normal diagnostics path.
        // Use a stable name derived from the URI so the file never flickers in the editor explorer.
        var tmp_name_buf: [80]u8 = undefined;
        const tmp_name = try std.fmt.bufPrint(&tmp_name_buf, ".__fls_{x:0>6}.fn", .{std.hash.Wyhash.hash(0, current_uri) & 0xFFFFFF});

        const current_path_opt = uriToPath(self.allocator, current_uri) catch null;
        defer if (current_path_opt) |p| self.allocator.free(p);
        const current_dir_opt = if (current_path_opt) |p| std.fs.path.dirname(p) else null;

        var base_dir = if (current_dir_opt) |d|
            try std.Io.Dir.openDirAbsolute(globalIo(), d, .{})
        else
            std.Io.Dir.cwd();
        defer if (current_dir_opt != null) base_dir.close(globalIo());

        {
            const f = try base_dir.createFile(globalIo(), tmp_name, .{ .read = true, .truncate = true });
            defer f.close(globalIo());
            try f.writeStreamingAll(globalIo(), text);
        }
        defer base_dir.deleteFile(globalIo(), tmp_name) catch {};

        const tmp_abs_path = blk: {
            if (current_dir_opt) |d|
                break :blk try std.fs.path.join(self.allocator, &[_][]const u8{ d, tmp_name });
            break :blk try self.allocator.dupe(u8, tmp_name);
        };
        defer self.allocator.free(tmp_abs_path);

        var stderr_buf = ArrayList(u8).init(self.allocator);
        defer stderr_buf.deinit();

        // Single subprocess: format in-place AND get diagnostics from stderr.
        const argv = [_][]const u8{ self.fun_exe_path, "-in", tmp_abs_path, "-fmt-diag", "-no-exec", "-warn-unused-lenient" };
        _ = try runCaptureStderr(self.allocator, &argv, &stderr_buf);

        // Read the (possibly-formatted) result.
        const formatted: ?[]u8 = blk: {
            const out = base_dir.readFileAlloc(globalIo(), tmp_name, self.allocator, .limited(10 * 1024 * 1024)) catch break :blk null;
            // Defensive: never send an edit that wipes the doc unless the input was empty.
            if (out.len == 0 and text.len != 0) {
                self.allocator.free(out);
                break :blk null;
            }
            break :blk out;
        };

        const diags = try parseFunDiagnosticsByUri(self.allocator, stderr_buf.items, current_uri, tmp_name);

        // Store a deep copy of the result in the cache keyed by the raw input hash.
        // Errors here are non-fatal — we still return the fresh result to the caller.
        self.updateDiagCache(current_uri, input_hash, diags, formatted) catch {};

        return .{ .formatted = formatted, .diags = diags };
    }

    /// Check the diagnostic cache for `current_uri`.  Returns a `FormatDiagResult`
    /// on a cache hit (no subprocess needed), or null on a miss.
    ///
    /// `content_hash` must be `Wyhash(raw_text)` — the same hash used when the
    /// entry was stored by `updateDiagCache`.
    ///
    /// Only returns a hit when the cached entry has a non-null `formatted` value.
    /// Entries written by `computeDiagnostics` (which never formats) are ignored
    /// so that the next `formatAndComputeDiagnostics` call always runs the formatter.
    fn checkDiagCache(self: *LspServer, current_uri: []const u8, content_hash: u64) !?FormatDiagResult {
        const entry = self.diag_cache.get(current_uri) orelse return null;
        // Only serve cache hits that have a real formatted result.
        if (entry.formatted == null) return null;
        // Primary hit: content matches the unformatted input from the last subprocess.
        // Secondary hit: content matches the formatted output — the file is already
        // formatted so the formatter would produce the same text (deterministic).
        const is_hit = content_hash == entry.content_hash or
            (entry.formatted_hash != 0 and content_hash == entry.formatted_hash);
        if (!is_hit) return null;

        // Cache hit — return deep copies so the caller can take ownership.
        const diags_copy = try dupeDiags(self.allocator, entry.diags);
        const fmt_copy: ?[]u8 = if (entry.formatted) |f|
            try self.allocator.dupe(u8, f)
        else
            null;
        return .{ .formatted = fmt_copy, .diags = diags_copy };
    }

    /// Update or insert a diagnostic cache entry for `current_uri`.
    ///
    /// `content_hash` must be `Wyhash(raw_text)`.
    /// `diags` and `formatted` are deep-copied into the cache; the originals
    /// remain owned by the caller.
    fn updateDiagCache(self: *LspServer, current_uri: []const u8, content_hash: u64, diags: []const DiagnosticWithUri, formatted: ?[]const u8) !void {
        const diags_copy = try dupeDiags(self.allocator, diags);
        errdefer freeDiags(self.allocator, diags_copy);
        const fmt_copy: ?[]u8 = if (formatted) |f| try self.allocator.dupe(u8, f) else null;
        errdefer if (fmt_copy) |f| self.allocator.free(f);

        const gop = try self.diag_cache.getOrPut(current_uri);
        if (gop.found_existing) {
            // Free old cached data.
            freeDiags(self.allocator, gop.value_ptr.diags);
            if (gop.value_ptr.formatted) |old_f| self.allocator.free(old_f);
        } else {
            // New entry: duplicate the key.
            gop.key_ptr.* = try self.allocator.dupe(u8, current_uri);
        }
        gop.value_ptr.* = .{
            .content_hash = content_hash,
            .formatted_hash = if (fmt_copy) |f| std.hash.Wyhash.hash(0, f) else 0,
            .diags = diags_copy,
            .formatted = fmt_copy,
        };
    }

    /// Publish pre-computed diagnostics (already owned/allocated by caller — this
    /// function takes ownership and frees them).
    fn publishDiagsFromOwned(self: *LspServer, diags_owned: []const DiagnosticWithUri) !void {
        defer {
            for (diags_owned) |d| {
                self.allocator.free(d.uri);
                self.allocator.free(d.diag.message);
                if (d.diag.code) |c| self.allocator.free(c);
            }
            self.allocator.free(diags_owned);
        }

        var new_uris = std.StringHashMap(void).init(self.allocator);
        defer new_uris.deinit();

        var grouped = std.StringHashMap(ArrayList(Diagnostic)).init(self.allocator);
        defer {
            var git = grouped.iterator();
            while (git.next()) |e| e.value_ptr.deinit();
            grouped.deinit();
        }

        for (diags_owned) |d| {
            try new_uris.put(d.uri, {});
            if (grouped.getPtr(d.uri)) |list| {
                try list.append(d.diag);
            } else {
                var list = ArrayList(Diagnostic).init(self.allocator);
                try list.append(d.diag);
                try grouped.put(d.uri, list);
            }
        }

        var pit = self.published_diag_uris.iterator();
        while (pit.next()) |entry| {
            if (!new_uris.contains(entry.key_ptr.*))
                self.sendPublishDiagnostics(entry.key_ptr.*, &[_]Diagnostic{}) catch {};
        }

        var git2 = grouped.iterator();
        while (git2.next()) |e|
            try self.sendPublishDiagnostics(e.key_ptr.*, e.value_ptr.items);

        var dit = self.published_diag_uris.iterator();
        while (dit.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.published_diag_uris.clearRetainingCapacity();

        var nit = new_uris.iterator();
        while (nit.next()) |entry|
            try self.published_diag_uris.put(try self.allocator.dupe(u8, entry.key_ptr.*), {});
    }

    fn sendPublishDiagnostics(self: *LspServer, uri: []const u8, diagnostics: []const Diagnostic) !void {
        const Params = struct {
            uri: []const u8,
            diagnostics: []const Diagnostic,
        };

        const params: Params = .{ .uri = uri, .diagnostics = diagnostics };
        const params_json = try jsonStringifyAlloc(self.allocator, params);
        defer self.allocator.free(params_json);
        try self.sendNotificationJson("textDocument/publishDiagnostics", params_json);
    }

    fn sendResponseJson(self: *LspServer, id_val: ?std.json.Value, result_json: []const u8) !void {
        const id_json = try stringifyId(self.allocator, id_val);
        defer self.allocator.free(id_json);

        var msg = ArrayList(u8).init(self.allocator);
        defer msg.deinit();
        try msg.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_json, result_json });
        try writeLspMessageRaw(self.stdout, self.io, msg.items);
    }

    fn sendNotificationJson(self: *LspServer, method: []const u8, params_json: []const u8) !void {
        var msg = ArrayList(u8).init(self.allocator);
        defer msg.deinit();
        try msg.print("{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}", .{ method, params_json });
        try writeLspMessageRaw(self.stdout, self.io, msg.items);
    }
};
const ParsedTextDocPosition = struct { uri: []const u8, pos: Position };

const ParsedCodeActionParams = struct {
    uri: []const u8,
    diagnostics: []const std.json.Value,
};

fn parseTextDocPosition(params_val: ?std.json.Value) !?ParsedTextDocPosition {
    const params = params_val orelse return null;
    if (params != .object) return null;
    const td = params.object.get("textDocument") orelse return null;
    if (td != .object) return null;
    const uri = (td.object.get("uri") orelse return null).string;

    const pv = params.object.get("position") orelse return null;
    if (pv != .object) return null;
    const line = (pv.object.get("line") orelse return null).integer;
    const character = (pv.object.get("character") orelse return null).integer;

    return .{ .uri = uri, .pos = .{ .line = line, .character = character } };
}

fn parseCodeActionParams(params_val: ?std.json.Value) !?ParsedCodeActionParams {
    const params = params_val orelse return null;
    if (params != .object) return null;

    const td = params.object.get("textDocument") orelse return null;
    if (td != .object) return null;
    const uri_val = td.object.get("uri") orelse return null;
    if (uri_val != .string) return null;

    var diagnostics: []const std.json.Value = &[_]std.json.Value{};
    if (params.object.get("context")) |ctx_val| {
        if (ctx_val == .object) {
            if (ctx_val.object.get("diagnostics")) |diags_val| {
                if (diags_val == .array) diagnostics = diags_val.array.items;
            }
        }
    }

    return .{ .uri = uri_val.string, .diagnostics = diagnostics };
}

fn parseJsonRange(v: std.json.Value) ?Range {
    if (v != .object) return null;
    const start_val = v.object.get("start") orelse return null;
    const end_val = v.object.get("end") orelse return null;
    if (start_val != .object or end_val != .object) return null;

    const sl = start_val.object.get("line") orelse return null;
    const sc = start_val.object.get("character") orelse return null;
    const el = end_val.object.get("line") orelse return null;
    const ec = end_val.object.get("character") orelse return null;
    if (sl != .integer or sc != .integer or el != .integer or ec != .integer) return null;

    return .{
        .start = .{ .line = sl.integer, .character = sc.integer },
        .end = .{ .line = el.integer, .character = ec.integer },
    };
}

fn parseDiagnosticCodeValue(v_opt: ?std.json.Value) ?[]const u8 {
    const v = v_opt orelse return null;
    return switch (v) {
        .string => v.string,
        .integer => null,
        .float => null,
        else => null,
    };
}

fn parseTextDocUri(params_val: ?std.json.Value) !?[]const u8 {
    const params = params_val orelse return null;
    if (params != .object) return null;
    const td = params.object.get("textDocument") orelse return null;
    if (td != .object) return null;
    return (td.object.get("uri") orelse return null).string;
}

const ParsedRenameParams = struct { uri: []const u8, pos: Position, new_name: []const u8 };

fn parseRenameParams(params_val: ?std.json.Value) !?ParsedRenameParams {
    const params = params_val orelse return null;
    if (params != .object) return null;
    const td = params.object.get("textDocument") orelse return null;
    if (td != .object) return null;
    const uri = (td.object.get("uri") orelse return null).string;

    const pv = params.object.get("position") orelse return null;
    if (pv != .object) return null;
    const line = (pv.object.get("line") orelse return null).integer;
    const character = (pv.object.get("character") orelse return null).integer;

    const new_name = (params.object.get("newName") orelse return null).string;
    return .{ .uri = uri, .pos = .{ .line = line, .character = character }, .new_name = new_name };
}

fn parseWorkspaceSymbolQuery(allocator: Allocator, params_val: ?std.json.Value) !?[]u8 {
    const params = params_val orelse return null;
    if (params != .object) return null;
    const qv = params.object.get("query") orelse return null;
    if (qv != .string) return null;
    return try allocator.dupe(u8, qv.string);
}
test "fls: parse import spec from tokens" {
    const allocator = std.testing.allocator;
    const src = "imp std.c.io;\n";
    const idx = try buildIndexFromText(allocator, src);
    defer idx.deinit();

    var server: LspServer = .{
        .allocator = allocator,
        .io = globalIo(),
        .docs = std.StringHashMap(Doc).init(allocator),
        .stdin = std.Io.File.stdin(),
        .stdout = std.Io.File.stdout(),
        .fun_exe_path = try allocator.dupe(u8, "fun"),
        .published_diag_uris = std.StringHashMap(void).init(allocator),
        .diag_cache = std.StringHashMap(DiagCacheEntry).init(allocator),
        .root_uri = null,
        .root_path = null,
    };
    defer server.deinit();

    var imp_i: ?usize = null;
    for (idx.tokens, 0..) |t, i| {
        if (t.kind == .keyword and std.mem.eql(u8, t.text, "imp")) {
            imp_i = i;
            break;
        }
    }
    try std.testing.expect(imp_i != null);
    const spec = (try server.parseImportSpecFromTokens(idx, imp_i.?)) orelse return error.TestUnexpectedResult;
    defer allocator.free(spec);
    try std.testing.expect(std.mem.eql(u8, spec, "std.c.io"));
}

// Exclude LSP-related tests in CI (GitHub Actions)
const _skip_lsp_tests_in_ci = blk: {
    if (@hasDecl(@import("std").process, "getEnvVar")) {
        if (@import("std").process.getEnvVar("CI", null)) |ci| {
            if (ci.len > 0) break :blk true;
        }
    }
    break :blk false;
};

test "fls: resolve std import to stdlib" {
    if (_skip_lsp_tests_in_ci) return;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create: <root>/stdlib/std/c/io.fn
    try tmp.dir.createDirPath(std.testing.io, "stdlib/std/c");
    {
        var f = try tmp.dir.createFile(std.testing.io, "stdlib/std/c/io.fn", .{ .read = true, .truncate = true });
        defer f.close(globalIo());
        try f.writeStreamingAll(globalIo(), "// std io\n");
    }

    // Create: <root>/examples/main.fn
    try tmp.dir.createDirPath(std.testing.io, "examples");
    {
        var f2 = try tmp.dir.createFile(std.testing.io, "examples/main.fn", .{ .read = true, .truncate = true });
        defer f2.close(globalIo());
        try f2.writeStreamingAll(globalIo(), "imp std.c.io;\n");
    }

    const root_abs = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root_abs);
    const current_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "examples/main.fn", allocator);
    defer allocator.free(current_abs);
    const std_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "stdlib/std/c/io.fn", allocator);
    defer allocator.free(std_abs);

    const current_uri = try pathToUri(allocator, current_abs);
    defer allocator.free(current_uri);
    const expected_uri = try pathToUri(allocator, std_abs);
    defer allocator.free(expected_uri);

    var server: LspServer = .{
        .allocator = allocator,
        .io = globalIo(),
        .docs = std.StringHashMap(Doc).init(allocator),
        .stdin = std.Io.File.stdin(),
        .stdout = std.Io.File.stdout(),
        .fun_exe_path = try allocator.dupe(u8, "fun"),
        .published_diag_uris = std.StringHashMap(void).init(allocator),
        .diag_cache = std.StringHashMap(DiagCacheEntry).init(allocator),
        .root_uri = null,
        .root_path = try allocator.dupe(u8, root_abs),
    };
    defer server.deinit();

    const resolved = (try server.resolveImportUri(current_uri, "std.c.io")) orelse return error.TestUnexpectedResult;
    defer allocator.free(resolved);
    try std.testing.expect(std.mem.eql(u8, resolved, expected_uri));
}
test "fls: resolveImportUri relative imports" {
    if (_skip_lsp_tests_in_ci) return;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sep = std.fs.path.sep;
    const examples_dir = try std.fmt.allocPrint(allocator, "examples{c}utils", .{sep});
    defer allocator.free(examples_dir);
    try tmp.dir.createDirPath(std.testing.io, examples_dir);
    const main_fn = try std.fmt.allocPrint(allocator, "examples{c}main.fn", .{sep});
    defer allocator.free(main_fn);
    const math_fn = try std.fmt.allocPrint(allocator, "examples{c}utils{c}math.fn", .{ sep, sep });
    defer allocator.free(math_fn);
    {
        var f = try tmp.dir.createFile(std.testing.io, main_fn, .{ .read = true, .truncate = true });
        defer f.close(globalIo());
        try f.writeStreamingAll(globalIo(), "imp utils.math;\n");
    }
    {
        var f2 = try tmp.dir.createFile(std.testing.io, math_fn, .{ .read = true, .truncate = true });
        defer f2.close(globalIo());
        try f2.writeStreamingAll(globalIo(), "// math\n");
    }
    const root_abs = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root_abs);
    const current_abs = try tmp.dir.realPathFileAlloc(std.testing.io, main_fn, allocator);
    defer allocator.free(current_abs);
    const expected_abs = try tmp.dir.realPathFileAlloc(std.testing.io, math_fn, allocator);
    defer allocator.free(expected_abs);

    const current_uri = try pathToUri(allocator, current_abs);
    defer allocator.free(current_uri);
    const expected_uri = try pathToUri(allocator, expected_abs);
    defer allocator.free(expected_uri);

    var server: LspServer = .{
        .allocator = allocator,
        .io = globalIo(),
        .docs = std.StringHashMap(Doc).init(allocator),
        .stdin = std.Io.File.stdin(),
        .stdout = std.Io.File.stdout(),
        .fun_exe_path = try allocator.dupe(u8, "fun"),
        .published_diag_uris = std.StringHashMap(void).init(allocator),
        .diag_cache = std.StringHashMap(DiagCacheEntry).init(allocator),
        .root_uri = null,
        .root_path = try allocator.dupe(u8, root_abs),
    };
    defer server.deinit();

    const resolved = (try server.resolveImportUri(current_uri, "utils.math")) orelse return error.TestUnexpectedResult;
    defer allocator.free(resolved);
    // Normalize both URIs to forward slashes for cross-platform comparison
    const norm_resolved = blk: {
        const buf = try allocator.dupe(u8, resolved);
        defer allocator.free(buf);
        for (buf) |*c| {
            if (c.* == '\\') {
                c.* = '/';
            }
        }
        break :blk buf;
    };
    const norm_expected = blk: {
        const buf = try allocator.dupe(u8, expected_uri);
        defer allocator.free(buf);
        for (buf) |*c| {
            if (c.* == '\\') {
                c.* = '/';
            }
        }
        break :blk buf;
    };
    try std.testing.expect(std.mem.eql(u8, norm_resolved, norm_expected));
}

test "fls: resolveImportUri std fails without stdlib" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a dummy current document.
    try tmp.dir.createDirPath(std.testing.io, "src");
    {
        var f = try tmp.dir.createFile(std.testing.io, "src/main.fn", .{ .read = true, .truncate = true });
        defer f.close(globalIo());
        try f.writeStreamingAll(globalIo(), "imp std.c.io;\n");
    }
    const current_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "src/main.fn", allocator);
    defer allocator.free(current_abs);
    const current_uri = try pathToUri(allocator, current_abs);
    defer allocator.free(current_uri);

    // Seed an invalid stdlib root so resolution can't succeed via env/workspace/cwd.
    const tmp_root_abs = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(tmp_root_abs);
    const bogus_stdlib = try std.fs.path.join(allocator, &.{ tmp_root_abs, "__not_a_stdlib__" });
    defer allocator.free(bogus_stdlib);

    var server: LspServer = .{
        .allocator = allocator,
        .io = globalIo(),
        .docs = std.StringHashMap(Doc).init(allocator),
        .stdin = std.Io.File.stdin(),
        .stdout = std.Io.File.stdout(),
        .fun_exe_path = try allocator.dupe(u8, "fun"),
        .published_diag_uris = std.StringHashMap(void).init(allocator),
        .diag_cache = std.StringHashMap(DiagCacheEntry).init(allocator),
        .root_uri = null,
        .root_path = null,
        .stdlib_root_path = try allocator.dupe(u8, bogus_stdlib),
    };
    defer server.deinit();

    const resolved = try server.resolveImportUri(current_uri, "std.c.io");
    defer if (resolved) |r| allocator.free(r);
    try std.testing.expect(resolved == null);
}

test "fls: member call signature uses receiver specialization" {
    const allocator = std.testing.allocator;
    const src =
        "compound Option<T> {\n" ++
        "  T value;\n" ++
        "}\n\n" ++
        "impl Option<T> {\n" ++
        "  unwrap_or(T default_value) T {\n" ++
        "    ret default_value;\n" ++
        "  }\n" ++
        "}\n\n" ++
        "compound Person<T> {\n" ++
        "  Option<str> nickname;\n" ++
        "}\n\n" ++
        "fun main() {\n" ++
        "  Person<str> p;\n" ++
        "  p.nickname.unwrap_or(\"Alias\"\n" ++
        "}\n";

    const idx = try buildIndexFromText(allocator, src);

    var server: LspServer = .{
        .allocator = allocator,
        .io = globalIo(),
        .docs = std.StringHashMap(Doc).init(allocator),
        .stdin = std.Io.File.stdin(),
        .stdout = std.Io.File.stdout(),
        .fun_exe_path = try allocator.dupe(u8, "fun"),
        .published_diag_uris = std.StringHashMap(void).init(allocator),
        .diag_cache = std.StringHashMap(DiagCacheEntry).init(allocator),
        .root_uri = null,
        .root_path = null,
    };
    defer server.deinit();

    const uri = try allocator.dupe(u8, "file:///tmp/fls-member-sig.fn");
    errdefer allocator.free(uri);
    const text_owned = try allocator.dupe(u8, src);
    errdefer allocator.free(text_owned);
    try server.docs.put(uri, .{ .uri = uri, .version = 1, .text = text_owned, .index = idx });

    const findPositionInText = struct {
        fn call(text: []const u8, needle: []const u8, char_offset: usize) !Position {
            const start = std.mem.indexOf(u8, text, needle) orelse return error.TestUnexpectedResult;
            var line: i64 = 0;
            var col: i64 = 0;
            var i: usize = 0;
            while (i < start) : (i += 1) {
                if (text[i] == '\n') {
                    line += 1;
                    col = 0;
                } else {
                    col += 1;
                }
            }
            return .{ .line = line, .character = col + @as(i64, @intCast(char_offset)) };
        }
    }.call;

    const pos = try findPositionInText(src, "  p.nickname.unwrap_or(\"Alias\"", "  p.nickname.unwrap_or(".len + 1);
    const sig = server.guessCallSignatureAt(uri, idx, pos) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("unwrap_or(str default_value) str", sig.label);
}

test "fls: build index infers indexed field access local type" {
    const allocator = std.testing.allocator;
    const src =
        "compound Point {\n" ++
        "  num x;\n" ++
        "  num y;\n" ++
        "}\n" ++
        "fun make_point(num x, num y) Point { ret Point{x = x, y = y}; }\n" ++
        "fun main() {\n" ++
        "  let n = 42;\n" ++
        "  let n2 = 17;\n" ++
        "  let mix_points = [make_point(n, n + 1), make_point(n2, n2 + 1)];\n" ++
        "  let mp_x = mix_points[0].x;\n" ++
        "}\n";

    const idx = try buildIndexFromText(allocator, src);
    defer idx.deinit();

    var mix_points_type: ?[]const u8 = null;
    var mp_x_type: ?[]const u8 = null;
    for (idx.symbols) |s| {
        if (s.kind != .variable) continue;
        if (std.mem.eql(u8, s.name, "mix_points")) mix_points_type = s.value_type;
        if (std.mem.eql(u8, s.name, "mp_x")) mp_x_type = s.value_type;
    }

    try std.testing.expect(mix_points_type != null);
    try std.testing.expect(mp_x_type != null);
    try std.testing.expectEqualStrings("Point[]", mix_points_type.?);
    try std.testing.expectEqualStrings("num", mp_x_type.?);
}

test "fls: rebuildIndexFromDoc preserves indexed field access local type" {
    const allocator = std.testing.allocator;
    const src =
        "compound Point {\n" ++
        "  num x;\n" ++
        "  num y;\n" ++
        "}\n" ++
        "fun make_point(num x, num y) Point { ret Point{x = x, y = y}; }\n" ++
        "fun main() {\n" ++
        "  let n = 42;\n" ++
        "  let n2 = 17;\n" ++
        "  let mix_points = [make_point(n, n + 1), make_point(n2, n2 + 1)];\n" ++
        "  let mp_x = mix_points[0].x;\n" ++
        "}\n";

    var server: LspServer = .{
        .allocator = allocator,
        .io = globalIo(),
        .docs = std.StringHashMap(Doc).init(allocator),
        .stdin = std.Io.File.stdin(),
        .stdout = std.Io.File.stdout(),
        .fun_exe_path = try allocator.dupe(u8, "fun"),
        .published_diag_uris = std.StringHashMap(void).init(allocator),
        .diag_cache = std.StringHashMap(DiagCacheEntry).init(allocator),
        .root_uri = null,
        .root_path = null,
    };
    defer server.deinit();

    const uri = try allocator.dupe(u8, "file:///tmp/fls-rebuild-index-mp-x.fn");
    errdefer allocator.free(uri);
    const text_owned = try allocator.dupe(u8, src);
    errdefer allocator.free(text_owned);
    try server.docs.put(uri, .{ .uri = uri, .version = 1, .text = text_owned, .index = null });

    try server.rebuildIndex(uri);

    const idx = server.docs.get(uri).?.index orelse return error.TestUnexpectedResult;
    var mp_x_type: ?[]const u8 = null;
    for (idx.symbols) |s| {
        if (s.kind != .variable) continue;
        if (std.mem.eql(u8, s.name, "mp_x")) {
            mp_x_type = s.value_type;
            break;
        }
    }

    try std.testing.expect(mp_x_type != null);
    try std.testing.expectEqualStrings("num", mp_x_type.?);
}

test "fls: rebuildIndexFromDoc preserves indexed field access in mixed let doc" {
    const allocator = std.testing.allocator;
    const src =
        "enum Color { Red, Green, Blue }\n" ++
        "enum Status { Ok, Err }\n" ++
        "compound Point {\n" ++
        "  num x;\n" ++
        "  num y;\n" ++
        "}\n" ++
        "fun make_point(num x, num y) Point { ret Point{x = x, y = y}; }\n" ++
        "fun min_num(num left, num right) num { if left < right { ret left; } ret right; }\n" ++
        "fun max_num(num left, num right) num { if left > right { ret left; } ret right; }\n" ++
        "fun abs_dec(dec x) dec { if x < 0 { ret -x; } ret x; }\n" ++
        "fun lerp_dec(num a, num b, dec t) dec { ret (a + b) + t; }\n" ++
        "fun main() {\n" ++
        "  let n = 42;\n" ++
        "  let d = 3.5;\n" ++
        "  let p = Point{x = 1, y = 2};\n" ++
        "  let color = Color.Red;\n" ++
        "  let status = Status.Ok;\n" ++
        "  let points = [Point{x = 0, y = 1}, Point{x = 2, y = 3}];\n" ++
        "  let n2 = (n + 5) * (n - 3);\n" ++
        "  let arr2 = [n, n + 1, n + 2];\n" ++
        "  let idx = (n - 40) / 2;\n" ++
        "  let pick = arr2[idx];\n" ++
        "  let p3 = Point{x = n + 1, y = (n - 2) * 3};\n" ++
        "  let psum = (p.x + p.y) * 2;\n" ++
        "  let neg = -(n - 5);\n" ++
        "  let dec_expr = (d * d) + (d / 2);\n" ++
        "  let nested = make_point(n + 1, n - 1);\n" ++
        "  let nested_sum = (nested.x + nested.y) / 2;\n" ++
        "  let dec_mix = lerp_dec(n, n + 2, d) + abs_dec(d / 2);\n" ++
        "  let dec_mix2 = lerp_dec(n2, n2 + n, (d + 1)) / 2;\n" ++
        "  let mix_point = make_point(min_num(n, n2), max_num(n, n2));\n" ++
        "  let mix_points = [make_point(n, n + 1), make_point(n2, n2 + 1)];\n" ++
        "  let mp_x = mix_points[0].x;\n" ++
        "}\n";

    var server: LspServer = .{
        .allocator = allocator,
        .io = globalIo(),
        .docs = std.StringHashMap(Doc).init(allocator),
        .stdin = std.Io.File.stdin(),
        .stdout = std.Io.File.stdout(),
        .fun_exe_path = try allocator.dupe(u8, "fun"),
        .published_diag_uris = std.StringHashMap(void).init(allocator),
        .diag_cache = std.StringHashMap(DiagCacheEntry).init(allocator),
        .root_uri = null,
        .root_path = null,
    };
    defer server.deinit();

    const uri = try allocator.dupe(u8, "file:///tmp/fls-rebuild-index-mixed-mp-x.fn");
    errdefer allocator.free(uri);
    const text_owned = try allocator.dupe(u8, src);
    errdefer allocator.free(text_owned);
    try server.docs.put(uri, .{ .uri = uri, .version = 1, .text = text_owned, .index = null });

    try server.rebuildIndex(uri);

    const idx = server.docs.get(uri).?.index orelse return error.TestUnexpectedResult;
    var mix_points_type: ?[]const u8 = null;
    var mp_x_type: ?[]const u8 = null;
    for (idx.symbols) |s| {
        if (s.kind != .variable) continue;
        if (std.mem.eql(u8, s.name, "mix_points")) mix_points_type = s.value_type;
        if (std.mem.eql(u8, s.name, "mp_x")) mp_x_type = s.value_type;
    }

    try std.testing.expect(mix_points_type != null);
    try std.testing.expect(mp_x_type != null);
    try std.testing.expectEqualStrings("Point[]", mix_points_type.?);
    try std.testing.expectEqualStrings("num", mp_x_type.?);
}

test "fls: imported member call signature uses receiver specialization" {
    const allocator = std.testing.allocator;
    const option_src =
        "pub compound Option<T> {\n" ++
        "  T value;\n" ++
        "}\n\n" ++
        "impl Option<T> {\n" ++
        "  pub unwrap_or(T default_value) T {\n" ++
        "    ret default_value;\n" ++
        "  }\n" ++
        "}\n";
    const main_src =
        "imp option_mod;\n\n" ++
        "compound Person<T> {\n" ++
        "  Option<str> nickname;\n" ++
        "}\n\n" ++
        "fun main() {\n" ++
        "  Person<str> p;\n" ++
        "  p.nickname.unwrap_or(\"Alias\"\n" ++
        "}\n";

    const option_idx = try buildIndexFromText(allocator, option_src);
    const main_idx = try buildIndexFromText(allocator, main_src);

    var server: LspServer = .{
        .allocator = allocator,
        .io = globalIo(),
        .docs = std.StringHashMap(Doc).init(allocator),
        .stdin = std.Io.File.stdin(),
        .stdout = std.Io.File.stdout(),
        .fun_exe_path = try allocator.dupe(u8, "fun"),
        .published_diag_uris = std.StringHashMap(void).init(allocator),
        .diag_cache = std.StringHashMap(DiagCacheEntry).init(allocator),
        .root_uri = null,
        .root_path = null,
    };
    defer server.deinit();

    const option_uri = try allocator.dupe(u8, "file:///tmp/option_mod.fn");
    errdefer allocator.free(option_uri);
    const option_text = try allocator.dupe(u8, option_src);
    errdefer allocator.free(option_text);
    try server.docs.put(option_uri, .{ .uri = option_uri, .version = 1, .text = option_text, .index = option_idx });

    const main_uri = try allocator.dupe(u8, "file:///tmp/main.fn");
    errdefer allocator.free(main_uri);
    const main_text = try allocator.dupe(u8, main_src);
    errdefer allocator.free(main_text);
    try server.docs.put(main_uri, .{ .uri = main_uri, .version = 1, .text = main_text, .index = main_idx });

    const findPositionInText = struct {
        fn call(text: []const u8, needle: []const u8, char_offset: usize) !Position {
            const start = std.mem.indexOf(u8, text, needle) orelse return error.TestUnexpectedResult;
            var line: i64 = 0;
            var col: i64 = 0;
            var i: usize = 0;
            while (i < start) : (i += 1) {
                if (text[i] == '\n') {
                    line += 1;
                    col = 0;
                } else {
                    col += 1;
                }
            }
            return .{ .line = line, .character = col + @as(i64, @intCast(char_offset)) };
        }
    }.call;

    const pos = try findPositionInText(main_src, "  p.nickname.unwrap_or(\"Alias\"", "  p.nickname.unwrap_or(".len + 1);
    const sig = server.guessCallSignatureAt(main_uri, main_idx, pos) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("unwrap_or(str default_value) str", sig.label);
}
