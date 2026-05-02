const std = @import("std");
const ast = @import("ast");
const codegen = @import("codegen");
const parser = @import("parser");
const lexer = @import("lexer");
const utils = @import("utils");
const build_options = @import("build_options");
const token = lexer.token;

const Allocator = std.mem.Allocator;

pub fn main() !void {
    // CLI helpers (used by installers / debugging PATH mismatches).
    // Note: fls is normally launched by the VS Code extension with no args (stdio mode).
    const argv = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, argv);

    if (argv.len >= 2) {
        if (std.mem.eql(u8, argv[1], "--version") or std.mem.eql(u8, argv[1], "-v")) {
            const out = std.io.getStdOut().writer();
            try out.print("fls {s}\n", .{build_options.version});
            return;
        }
        if (std.mem.eql(u8, argv[1], "--help") or std.mem.eql(u8, argv[1], "-h")) {
            const out = std.io.getStdOut().writer();
            try out.writeAll(
                "Fun Language Server (fls)\n\n" ++
                    "Usage:\n" ++
                    "  fls            Run language server over stdio (LSP)\n" ++
                    "  fls --version  Print version\n" ++
                    "  fls --help     Show this help\n",
            );
            return;
        }
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try LspServer.init(allocator);
    defer server.deinit();
    try server.run();
}

const Doc = struct {
    uri: []const u8,
    version: i64,
    text: []u8,
    index: ?*Index = null,
    last_diag_ms: i64 = 0,
};

const Position = struct { line: i64, character: i64 };
const Range = struct { start: Position, end: Position };

const Diagnostic = struct {
    range: Range,
    severity: i64,
    message: []const u8,
    code: ?[]const u8 = null,
};

const DiagnosticWithUri = struct {
    uri: []u8,
    diag: Diagnostic,
};

const TextEdit = struct {
    range: Range,
    newText: []const u8,
};

const CompletionItem = struct {
    label: []const u8,
    kind: ?i64 = null,
    detail: ?[]const u8 = null,
    insertText: ?[]const u8 = null,
    filterText: ?[]const u8 = null,
};

const CompletionList = struct {
    isIncomplete: bool = false,
    items: []const CompletionItem,
};

const MarkupContent = struct {
    kind: []const u8 = "markdown",
    value: []const u8,
};

const Hover = struct {
    contents: MarkupContent,
    range: ?Range = null,
};

const Location = struct {
    uri: []const u8,
    range: Range,
};

const SymbolInformation = struct {
    name: []const u8,
    kind: i64,
    location: Location,
};

const DocumentSymbol = struct {
    name: []const u8,
    kind: i64,
    range: Range,
    selectionRange: Range,
    children: ?[]const DocumentSymbol = null,
};

const ParameterInformation = struct {
    label: []const u8,
};

const SignatureInformation = struct {
    label: []const u8,
    parameters: ?[]const ParameterInformation = null,
};

const SignatureHelp = struct {
    signatures: []const SignatureInformation,
    activeSignature: i64 = 0,
    activeParameter: i64 = 0,
};

const SemanticTokens = struct {
    data: []const u32,
};

const TokenLiteKind = enum {
    identifier,
    keyword,
    number,
    string,
    boolean,
    comment,
    operator,
    symbol,
};

const TokenLite = struct {
    kind: TokenLiteKind,
    text: []const u8,
    range: Range,
};

const SymbolKind = enum(i64) {
    file = 1,
    module = 2,
    namespace = 3,
    package = 4,
    class = 5,
    method = 6,
    property = 7,
    field = 8,
    constructor = 9,
    enum_ = 10,
    interface = 11,
    function = 12,
    variable = 13,
    constant = 14,
    string = 15,
    number = 16,
    boolean = 17,
    array = 18,
    object = 19,
    key = 20,
    null_ = 21,
    enumMember = 22,
    struct_ = 23,
    event = 24,
    operator = 25,
    typeParameter = 26,
};

const SymbolLite = struct {
    name: []const u8,
    kind: SymbolKind,
    decl_range: Range,
    selection_range: Range,
    is_public: bool = true,
    // For local symbols: function range that contains it.
    container_fn_range: ?Range = null,
    // For members: owning type name (compound/quirk).
    container_type: ?[]const u8 = null,
    // For fields/properties: declared type name.
    value_type: ?[]const u8 = null,
    // Optional detail shown in completion/hover.
    detail: ?[]const u8 = null,
};

const Index = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    tokens: []TokenLite,
    symbols: []SymbolLite,

    fn deinit(self: *Index) void {
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

const LspServer = struct {
    allocator: Allocator,
    docs: std.StringHashMap(Doc),
    stdin: std.fs.File,
    stdout: std.fs.File,
    fun_exe_path: []const u8,
    fls_exe_path: ?[]u8 = null,
    published_diag_uris: std.StringHashMap(void),
    root_uri: ?[]u8 = null,
    root_path: ?[]u8 = null,
    stdlib_root_path: ?[]u8 = null,
    debug_enabled: bool = false,
    debug_imports: bool = false,
    debug_definitions: bool = false,
    did_log_stdlib_root_resolution: bool = false,

    fn envFlag(allocator: Allocator, name: []const u8) bool {
        const v = std.process.getEnvVarOwned(allocator, name) catch return false;
        defer allocator.free(v);
        const s = std.mem.trim(u8, v, " \t\r\n");
        if (s.len == 0) return false;
        if (std.ascii.eqlIgnoreCase(s, "0")) return false;
        if (std.ascii.eqlIgnoreCase(s, "false")) return false;
        if (std.ascii.eqlIgnoreCase(s, "no")) return false;
        if (std.ascii.eqlIgnoreCase(s, "off")) return false;
        return true;
    }

    fn dbg(enabled: bool, comptime category: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (!enabled) return;
        std.debug.print("[fls:{s}] ", .{category});
        std.debug.print(fmt, args);
        std.debug.print("\n", .{});
    }

    fn init(allocator: Allocator) !LspServer {
        const dbg_all = envFlag(allocator, "FLS_DEBUG");
        const dbg_imports = dbg_all or envFlag(allocator, "FLS_DEBUG_IMPORTS");
        const dbg_defs = dbg_all or envFlag(allocator, "FLS_DEBUG_DEFINITIONS");
        return .{
            .allocator = allocator,
            .docs = std.StringHashMap(Doc).init(allocator),
            .stdin = std.io.getStdIn(),
            .stdout = std.io.getStdOut(),
            .fun_exe_path = try findSiblingOrPathExe(allocator, "fun"),
            .fls_exe_path = std.fs.selfExePathAlloc(allocator) catch null,
            .published_diag_uris = std.StringHashMap(void).init(allocator),
            .root_uri = null,
            .root_path = null,
            .stdlib_root_path = null,
            .debug_enabled = dbg_all or dbg_imports or dbg_defs,
            .debug_imports = dbg_imports,
            .debug_definitions = dbg_defs,
            .did_log_stdlib_root_resolution = false,
        };
    }

    fn deinit(self: *LspServer) void {
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
            dbg(true, "imports", "resolving stdlib root (env/exe/workspace/cwd)", .{});
            if (self.root_path) |rp| dbg(true, "imports", "root_path={s}", .{rp});
            dbg(true, "imports", "fun_exe_path={s}", .{self.fun_exe_path});
            if (self.fls_exe_path) |fp| dbg(true, "imports", "fls_exe_path={s}", .{fp});
        }

        // Prefer repo/workspace checkout layout when available.
        // This keeps fls working correctly when developing in a fun checkout even if
        // the machine also has a global install (or FUN_STDLIB_DIR) configured.
        if (self.tryStdlibRootFromWorkspace()) {
            if (self.debug_imports) dbg(true, "imports", "stdlib root from workspace => {s}", .{self.stdlib_root_path.?});
            return self.stdlib_root_path.?;
        }

        // Optional override for custom installs.
        if (self.tryStdlibRootFromEnv("FUN_STDLIB_DIR")) {
            if (self.debug_imports) dbg(true, "imports", "stdlib root from FUN_STDLIB_DIR => {s}", .{self.stdlib_root_path.?});
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
            if (self.debug_imports) dbg(true, "imports", "stdlib root from workspace => {s}", .{self.stdlib_root_path.?});
            return self.stdlib_root_path.?;
        }

        // Final fallback: try resolving relative to the server's current working directory.
        // VS Code launches `fls` with `cwd` set to the workspace root, but some clients/flows
        // don't provide a usable `rootUri` or the document may be `untitled:`.
        if (self.trySetStdlibRoot("stdlib")) {
            if (self.debug_imports) dbg(true, "imports", "stdlib root from cwd relative 'stdlib' => {s}", .{self.stdlib_root_path.?});
            return self.stdlib_root_path.?;
        }
        if (self.trySetStdlibRoot("zig-out/share/fun/stdlib")) {
            if (self.debug_imports) dbg(true, "imports", "stdlib root from cwd relative 'zig-out/share/fun/stdlib' => {s}", .{self.stdlib_root_path.?});
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

        var d = std.fs.openDirAbsolute(std_dir, .{}) catch return false;
        d.close();
        return true;
    }

    fn checkStdlibRootAbsolute(self: *LspServer, root_abs: []const u8) bool {
        if (!std.fs.path.isAbsolute(root_abs)) return false;

        const std_dir = std.fs.path.join(std.heap.page_allocator, &.{ root_abs, "std" }) catch return false;
        defer std.heap.page_allocator.free(std_dir);

        if (!std.fs.path.isAbsolute(std_dir)) return false;
        var d = std.fs.openDirAbsolute(std_dir, .{}) catch |err| {
            if (self.debug_imports) dbg(true, "imports", "stdlib root check failed: root={s} std_dir={s} err={s}", .{ root_abs, std_dir, @errorName(err) });
            return false;
        };
        d.close();
        return true;
    }

    fn trySetStdlibRoot(self: *LspServer, path: []const u8) bool {
        if (self.debug_imports) dbg(true, "imports", "trySetStdlibRoot candidate={s}", .{path});
        // Ensure we store an absolute path and never pass a non-absolute string to
        // `openDirAbsolute` (which asserts in Zig stdlib).
        var abs = if (std.fs.path.isAbsolute(path))
            (self.allocator.dupe(u8, path) catch return false)
        else
            (std.fs.cwd().realpathAlloc(self.allocator, path) catch return false);

        // Normalize/derive: accept a variety of installed layouts.
        // We ultimately store `<root>` such that `<root>/std/...` exists.
        if (!self.checkStdlibRootAbsolute(abs)) {
            const base = std.fs.path.basename(abs);

            // Common: caller points at `<root>/std`.
            if (std.ascii.eqlIgnoreCase(base, "std")) {
                const parent = std.fs.path.dirname(abs) orelse null;
                if (parent) |p| {
                    if (self.checkStdlibRootAbsolute(p)) {
                        if (self.debug_imports) dbg(true, "imports", "normalized stdlib root from .../std => {s}", .{p});
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
                        if (self.debug_imports) dbg(true, "imports", "normalized stdlib root from .../stdlib => {s}", .{p});
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
                    if (self.debug_imports) dbg(true, "imports", "trySetStdlibRoot derived(suffix stdlib)={s}", .{p});
                    if (self.checkStdlibRootAbsolute(p)) {
                        if (self.debug_imports) dbg(true, "imports", "accepted derived stdlib root => {s}", .{p});
                        self.allocator.free(abs);
                        abs = self.allocator.dupe(u8, p) catch return false;
                    }
                }

                // Current installer layout: `<prefix>/share/fun/std/...` (no `stdlib/` directory).
                if (!self.checkStdlibRootAbsolute(abs)) {
                    const derived_share_fun = std.fs.path.join(self.allocator, &.{ abs, "share", "fun" }) catch null;
                    if (derived_share_fun) |p| {
                        defer self.allocator.free(p);
                        if (self.debug_imports) dbg(true, "imports", "trySetStdlibRoot derived(suffix share/fun)={s}", .{p});
                        if (self.checkStdlibRootAbsolute(p)) {
                            if (self.debug_imports) dbg(true, "imports", "accepted derived stdlib root => {s}", .{p});
                            self.allocator.free(abs);
                            abs = self.allocator.dupe(u8, p) catch return false;
                        }
                    }
                }

                if (!self.checkStdlibRootAbsolute(abs)) {
                    const derived2 = std.fs.path.join(self.allocator, &.{ abs, "share", "fun", "stdlib" }) catch null;
                    if (derived2) |p| {
                        defer self.allocator.free(p);
                        if (self.debug_imports) dbg(true, "imports", "trySetStdlibRoot derived(suffix share/fun/stdlib)={s}", .{p});
                        if (self.checkStdlibRootAbsolute(p)) {
                            if (self.debug_imports) dbg(true, "imports", "accepted derived stdlib root => {s}", .{p});
                            self.allocator.free(abs);
                            abs = self.allocator.dupe(u8, p) catch return false;
                        }
                    }
                }

                if (!self.checkStdlibRootAbsolute(abs)) {
                    const derived3 = std.fs.path.join(self.allocator, &.{ abs, "fun", "stdlib" }) catch null;
                    if (derived3) |p| {
                        defer self.allocator.free(p);
                        if (self.debug_imports) dbg(true, "imports", "trySetStdlibRoot derived(suffix fun/stdlib)={s}", .{p});
                        if (self.checkStdlibRootAbsolute(p)) {
                            if (self.debug_imports) dbg(true, "imports", "accepted derived stdlib root => {s}", .{p});
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
            if (self.debug_imports) dbg(true, "imports", "reject stdlib root (unable to open 'std/'?) abs={s}", .{abs});
            return false;
        }

        if (self.stdlib_root_path) |p| self.allocator.free(p);
        self.stdlib_root_path = abs;
        keep = true;
        if (self.debug_imports) dbg(true, "imports", "accepted stdlib root abs={s}", .{abs});
        return true;
    }

    fn tryStdlibRootFromEnv(self: *LspServer, name: []const u8) bool {
        const v = std.process.getEnvVarOwned(self.allocator, name) catch return false;
        defer self.allocator.free(v);
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

    fn run(self: *LspServer) !void {
        var br = std.io.bufferedReader(self.stdin.reader());
        const inr = br.reader();

        while (true) {
            const msg_bytes = readLspMessage(self.allocator, inr) catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            defer self.allocator.free(msg_bytes);

            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, msg_bytes, .{}) catch |err| {
                // Bad JSON should not kill the server; VS Code will keep going.
                std.debug.print("[fls] json parse failed: {s}\n", .{@errorName(err)});
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
                    std.debug.print("[fls] initialize failed: {s}\n", .{@errorName(err)});
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
                    std.debug.print("[fls] didOpen failed: {s}\n", .{@errorName(err)});
                };
                continue;
            }
            if (std.mem.eql(u8, method, "textDocument/didChange")) {
                self.handleDidChange(obj.get("params") orelse null) catch |err| {
                    std.debug.print("[fls] didChange failed: {s}\n", .{@errorName(err)});
                };
                continue;
            }
            if (std.mem.eql(u8, method, "textDocument/didSave")) {
                self.handleDidSave(obj.get("params") orelse null) catch |err| {
                    std.debug.print("[fls] didSave failed: {s}\n", .{@errorName(err)});
                };
                continue;
            }
            if (std.mem.eql(u8, method, "textDocument/didClose")) {
                self.handleDidClose(obj.get("params") orelse null) catch |err| {
                    std.debug.print("[fls] didClose failed: {s}\n", .{@errorName(err)});
                };
                continue;
            }

            if (std.mem.eql(u8, method, "textDocument/formatting")) {
                self.handleFormatting(id_val, obj.get("params") orelse null) catch |err| {
                    std.debug.print("[fls] formatting request failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "[]") catch {};
                };
                continue;
            }

            if (std.mem.eql(u8, method, "textDocument/hover")) {
                self.handleHover(id_val, obj.get("params") orelse null) catch |err| {
                    std.debug.print("[fls] hover failed: {s}\n", .{@errorName(err)});
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
                    std.debug.print("[fls] definition-like request failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "[]") catch {};
                };
                continue;
            }
            if (std.mem.eql(u8, method, "textDocument/references")) {
                self.handleReferences(id_val, obj.get("params") orelse null) catch |err| {
                    std.debug.print("[fls] references failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "[]") catch {};
                };
                continue;
            }
            if (std.mem.eql(u8, method, "textDocument/rename")) {
                self.handleRename(id_val, obj.get("params") orelse null) catch |err| {
                    std.debug.print("[fls] rename failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "null") catch {};
                };
                continue;
            }
            if (std.mem.eql(u8, method, "textDocument/codeAction")) {
                self.handleCodeAction(id_val, obj.get("params") orelse null) catch |err| {
                    std.debug.print("[fls] codeAction failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "[]") catch {};
                };
                continue;
            }
            if (std.mem.eql(u8, method, "textDocument/completion")) {
                self.handleCompletion(id_val, obj.get("params") orelse null) catch |err| {
                    std.debug.print("[fls] completion failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "{\"isIncomplete\":false,\"items\":[]}") catch {};
                };
                continue;
            }
            if (std.mem.eql(u8, method, "textDocument/signatureHelp")) {
                self.handleSignatureHelp(id_val, obj.get("params") orelse null) catch |err| {
                    std.debug.print("[fls] signatureHelp failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "null") catch {};
                };
                continue;
            }
            if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
                self.handleDocumentSymbols(id_val, obj.get("params") orelse null) catch |err| {
                    std.debug.print("[fls] documentSymbol failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "[]") catch {};
                };
                continue;
            }
            if (std.mem.eql(u8, method, "workspace/symbol")) {
                self.handleWorkspaceSymbols(id_val, obj.get("params") orelse null) catch |err| {
                    std.debug.print("[fls] workspace/symbol failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "[]") catch {};
                };
                continue;
            }
            if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
                self.handleSemanticTokensFull(id_val, obj.get("params") orelse null) catch |err| {
                    std.debug.print("[fls] semanticTokens failed: {s}\n", .{@errorName(err)});
                    if (is_request) self.sendResponseJson(id_val, "null") catch {};
                };
                continue;
            }

            if (is_request) {
                self.sendResponseJson(id_val, "null") catch {};
            }
        }
    }

    fn handleInitialize(self: *LspServer, id_val: ?std.json.Value, params_val: ?std.json.Value) !void {
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
                },
                signatureHelpProvider: struct {
                    triggerCharacters: []const []const u8 = &[_][]const u8{ "(", "," },
                },
                documentSymbolProvider: bool,
                workspaceSymbolProvider: bool,
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

        const json = try std.json.stringifyAlloc(self.allocator, res, .{});
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
            dbg(true, "imports", "initialize captured root_uri={s}", .{self.root_uri.?});
            dbg(true, "imports", "initialize captured root_path={s}", .{self.root_path.?});
        }
    }

    fn indexWorkspace(self: *LspServer) !void {
        const root_path = self.root_path orelse return;
        var dir = try std.fs.openDirAbsolute(root_path, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
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
            std.debug.print("[fls] publishDiagnostics failed on didOpen: {s}\n", .{@errorName(err)});
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
            std.debug.print("[fls] publishDiagnostics failed on didChange: {s}\n", .{@errorName(err)});
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
        self.maybePublishDiagnostics(uri, doc.text, true) catch |err| {
            std.debug.print("[fls] publishDiagnostics failed on didSave: {s}\n", .{@errorName(err)});
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

        const formatted = self.formatText(doc.text) catch |err| {
            std.debug.print("[fls] formatting failed: {s}\n", .{@errorName(err)});
            try self.sendResponseJson(id_val, empty);
            return;
        };
        defer self.allocator.free(formatted);

        const edits = [_]TextEdit{.{
            .range = .{
                .start = .{ .line = 0, .character = 0 },
                .end = .{ .line = 1_000_000, .character = 0 },
            },
            .newText = formatted,
        }};

        const json = try std.json.stringifyAlloc(self.allocator, edits, .{});
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
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
            var buf = std.ArrayList(u8).init(self.allocator);
            defer buf.deinit();

            if (std.mem.eql(u8, tok.text, "async")) {
                try buf.writer().writeAll(
                    "**async**\n\n" ++
                        "```fun\n" ++
                        "async fun name(...) Type { ... }\n" ++
                        "```\n" ++
                        "Marks a function or method as asynchronous.\n" ++
                        "Calls to async functions must use `await`.\n",
                );
            } else if (std.mem.eql(u8, tok.text, "await")) {
                try buf.writer().writeAll(
                    "**await**\n\n" ++
                        "```fun\n" ++
                        "await some_async_call();\n" ++
                        "```\n" ++
                        "Waits for an async call and yields its result.\n" ++
                        "`await` is only valid inside `async` functions.\n",
                );
            } else {
                try self.sendResponseJson(id_val, "null");
                return;
            }

            const hover: Hover = .{ .contents = .{ .value = buf.items }, .range = tok.range };
            const json = try std.json.stringifyAlloc(self.allocator, hover, .{});
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
            var buf = std.ArrayList(u8).init(self.allocator);
            defer buf.deinit();
            try buf.writer().writeAll(
                "**sizeof**\n\n" ++
                    "```fun\n" ++
                    "sizeof(Type) num\n" ++
                    "```\n" ++
                    "Returns the size in bytes of `Type`.\n" ++
                    "The argument must be a type name.\n",
            );

            const hover: Hover = .{ .contents = .{ .value = buf.items }, .range = tok.range };
            const json = try std.json.stringifyAlloc(self.allocator, hover, .{});
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
                        var buf = std.ArrayList(u8).init(self.allocator);
                        defer buf.deinit();
                        try buf.writer().print("**{s}**\n\n", .{variant_name});
                        try buf.writer().print("```fun\n{s}.{s}\n```\n", .{ enum_name, variant_name });
                        if (self.docs.get(h.uri)) |hdoc| {
                            _ = try appendDocCommentAboveLine(self.allocator, &buf, hdoc.text, h.sym.decl_range.start.line);
                        }
                        const hover: Hover = .{ .contents = .{ .value = buf.items }, .range = tok.range };
                        const json = try std.json.stringifyAlloc(self.allocator, hover, .{});
                        defer self.allocator.free(json);
                        try self.sendResponseJson(id_val, json);
                        return;
                    }
                }
            }
        }

        // Member hover: show info for `a.b` / `a.b.c` by resolving receiver type.
        if (findTokenIndexAt(idx.tokens, pos)) |tok_i| {
            if (tok_i > 0 and isDotToken(idx.tokens[tok_i - 1])) {
                if (tok_i >= 2 and idx.tokens[tok_i - 2].kind == .identifier) {
                    if (self.resolveTypeOfChainUpTo(idx, uri, pos, tok_i - 2)) |recv_type| {
                        const name = tok.text;
                        const hit = self.findMemberByContainer(uri, recv_type, name, .field) orelse
                            self.findMemberByContainer(uri, recv_type, name, .property) orelse
                            self.findMemberByContainer(uri, recv_type, name, .enumMember) orelse
                            self.findMemberByContainer(uri, recv_type, name, .method);
                        if (hit) |h| {
                            var buf = std.ArrayList(u8).init(self.allocator);
                            defer buf.deinit();
                            try buf.writer().print("**{s}**\n\n", .{name});
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

                                        try buf.writer().print("```fun\n{s} {s}\n```\n", .{ shown_vt, name });
                                    } else {
                                        try buf.writer().print("_field_\n", .{});
                                    }
                                },
                                .enumMember => {
                                    try buf.writer().print("```fun\n{s}.{s}\n```\n", .{ recv_type, name });
                                },
                                .method => {
                                    if (h.sym.detail) |det| {
                                        try buf.writer().print("```fun\n{s}\n```\n", .{det});
                                    } else {
                                        try buf.writer().print("_method on {s}_\n", .{recv_type});
                                    }
                                },
                                else => {
                                    try buf.writer().print("_{s}_\n", .{@tagName(h.sym.kind)});
                                },
                            }

                            if (self.docs.get(h.uri)) |hdoc| {
                                _ = try appendDocCommentAboveLine(self.allocator, &buf, hdoc.text, h.sym.decl_range.start.line);
                            }

                            const hover: Hover = .{ .contents = .{ .value = buf.items }, .range = tok.range };
                            const json = try std.json.stringifyAlloc(self.allocator, hover, .{});
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

        var buf = std.ArrayList(u8).init(self.allocator);
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
            dbg(true, "defs", "hover pick name={s} detail={s} value_type={s} decl=({d},{d}) sel=({d},{d})", .{
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
            try buf.writer().print("**{s}**\n\n", .{tok.text});
            const let_infer_detail = d.kind == .variable and ((d.value_type != null and isLetInferTypeName(d.value_type.?)) or
                (d.detail != null and std.mem.startsWith(u8, d.detail.?, "__let_infer__")));
            if (d.detail) |det| {
                if (let_infer_detail) {
                    // Skip placeholder let inference details; fall back to value_type/guess.
                } else {
                    if (d.kind == .struct_ or d.kind == .interface or d.kind == .enum_) {
                        // Render type symbols in the kind-specific branch below so we can
                        // include concrete generic arguments from the hover site.
                    } else if (d.kind == .function and d.value_type != null) {
                        const det_trim = std.mem.trimRight(u8, det, " \t\r\n");
                        if (det_trim.len != 0 and det_trim[det_trim.len - 1] == ')') {
                            try buf.writer().print("```fun\n{s} {s}\n```\n", .{ det_trim, d.value_type.? });
                        } else {
                            try buf.writer().print("```fun\n{s}\n```\n", .{det});
                        }
                    } else {
                        try buf.writer().print("```fun\n{s}\n```\n", .{det});
                    }
                }
            }
            if (d.kind == .variable and (d.detail == null or let_infer_detail)) {
                const vt = d.value_type orelse self.guessVariableType(idx, uri, tok.text, pos);
                if (vt) |vts| {
                    if (!isLetInferTypeName(vts)) {
                        try buf.writer().print("```fun\n{s} {s}\n```\n", .{ vts, tok.text });
                    }
                } else {
                    try buf.writer().print("_{s}_\n", .{@tagName(d.kind)});
                }
            } else if (d.kind == .enumMember) {
                const recv_type = d.container_type orelse d.value_type orelse "";
                if (recv_type.len != 0) {
                    try buf.writer().print("```fun\n{s}.{s}\n```\n", .{ recv_type, tok.text });
                } else {
                    try buf.writer().print("_{s}_\n", .{@tagName(d.kind)});
                }
            } else if ((d.kind == .struct_ or d.kind == .interface or d.kind == .enum_)) {
                const kw = if (d.kind == .struct_) "compound" else if (d.kind == .interface) "quirk" else "enum";
                if (concrete_hover_type) |concrete| {
                    try buf.writer().print("```fun\n{s} {s}\n```\n", .{ kw, concrete });
                } else if (d.detail) |det| {
                    try buf.writer().print("```fun\n{s}\n```\n", .{det});
                } else {
                    try buf.writer().print("```fun\n{s} {s}\n```\n", .{ kw, tok.text });
                }
            } else {
                try buf.writer().print("_{s}_\n", .{@tagName(d.kind)});
            }
            _ = try appendDocCommentAboveLine(self.allocator, &buf, doc.text, d.decl_range.start.line);
        } else if (def_import) |hit| {
            const d = hit.sym;
            try buf.writer().print("**{s}**\n\n", .{tok.text});

            var printed_detail = false;
            if (d.detail) |det| {
                if (!(d.kind == .struct_ or d.kind == .interface or d.kind == .enum_)) {
                    if (d.kind == .function and d.value_type != null) {
                        const det_trim = std.mem.trimRight(u8, det, " \t\r\n");
                        if (det_trim.len != 0 and det_trim[det_trim.len - 1] == ')') {
                            try buf.writer().print("```fun\n{s} {s}\n```\n", .{ det_trim, d.value_type.? });
                        } else {
                            try buf.writer().print("```fun\n{s}\n```\n", .{det});
                        }
                    } else {
                        try buf.writer().print("```fun\n{s}\n```\n", .{det});
                    }
                    printed_detail = true;
                }
            }
            if (!printed_detail) {
                if (d.kind == .variable) {
                    const vt = d.value_type orelse self.guessVariableType(idx, uri, tok.text, pos);
                    if (vt) |vts| {
                        try buf.writer().print("```fun\n{s} {s}\n```\n", .{ vts, tok.text });
                    } else {
                        try buf.writer().print("_{s}_\n", .{@tagName(d.kind)});
                    }
                } else if (d.kind == .enumMember) {
                    const recv_type = d.container_type orelse d.value_type orelse "";
                    if (recv_type.len != 0) {
                        try buf.writer().print("```fun\n{s}.{s}\n```\n", .{ recv_type, tok.text });
                    } else {
                        try buf.writer().print("_{s}_\n", .{@tagName(d.kind)});
                    }
                } else if ((d.kind == .struct_ or d.kind == .interface or d.kind == .enum_)) {
                    const kw = if (d.kind == .struct_) "compound" else if (d.kind == .interface) "quirk" else "enum";
                    if (concrete_hover_type) |concrete| {
                        try buf.writer().print("```fun\n{s} {s}\n```\n", .{ kw, concrete });
                    } else if (d.detail) |det| {
                        try buf.writer().print("```fun\n{s}\n```\n", .{det});
                    } else {
                        try buf.writer().print("```fun\n{s} {s}\n```\n", .{ kw, tok.text });
                    }
                } else {
                    try buf.writer().print("_{s}_\n", .{@tagName(d.kind)});
                }
            }
            if (self.docs.get(hit.uri)) |idoc| {
                _ = try appendDocCommentAboveLine(self.allocator, &buf, idoc.text, d.decl_range.start.line);
            }
        } else {
            try buf.writer().print("**{s}**\n\n", .{tok.text});
            if (self.guessVariableType(idx, uri, tok.text, pos)) |vt| {
                try buf.writer().print("```fun\n{s} {s}\n```\n", .{ vt, tok.text });
            }
        }

        const hover: Hover = .{
            .contents = .{ .value = buf.items },
            .range = tok.range,
        };
        const json = try std.json.stringifyAlloc(self.allocator, hover, .{});
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
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
            if (isDotToken(dot) and left.kind == .identifier) {
                start_i -= 2;
                continue;
            }
            break;
        }

        // Collect identifier indices from start_i to last_ident_i.
        var ids = std.ArrayList(usize).init(self.allocator);
        defer ids.deinit();
        var j: usize = start_i;
        while (j <= last_ident_i) {
            if (idx.tokens[j].kind != .identifier) return null;
            ids.append(j) catch return null;
            if (j == last_ident_i) break;
            if (j + 2 > last_ident_i) return null;
            if (!isDotToken(idx.tokens[j + 1])) return null;
            j += 2;
        }
        if (ids.items.len == 0) return null;

        const base_name = idx.tokens[ids.items[0]].text;
        var current_type: ?[]const u8 = null;

        if (std.mem.eql(u8, base_name, "self")) {
            current_type = self.guessEnclosingImplType(idx, at);
        } else if (self.isKnownTypeName(uri, base_name)) {
            current_type = base_name;
        } else {
            current_type = self.guessVariableType(idx, uri, base_name, at);
        }
        if (current_type == null) return null;

        if (ids.items.len == 1) return current_type.?;

        // Walk remaining segments as fields/properties.
        var si: usize = 1;
        while (si < ids.items.len) : (si += 1) {
            const seg = idx.tokens[ids.items[si]].text;
            const field = self.findMemberByContainer(uri, current_type.?, seg, .field) orelse
                self.findMemberByContainer(uri, current_type.?, seg, .property) orelse return null;
            if (field.sym.value_type) |vt| {
                current_type = vt;
            } else {
                return null;
            }
        }

        return current_type.?;
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
            fn call(text: []const u8, out_list: *std.ArrayList([]const u8)) !void {
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
            fn call(template_params: []const []const u8, concrete_args: []const []const u8, needle_raw: []const u8) ?[]const u8 {
                const needle = std.mem.trim(u8, needle_raw, " \t\r\n");
                if (needle.len == 0) return null;

                const n = @min(template_params.len, concrete_args.len);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const p = std.mem.trim(u8, template_params[i], " \t\r\n");
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

            var receiver_args_only = std.ArrayList([]const u8).init(self.allocator);
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

        var declared_params = std.ArrayList([]const u8).init(self.allocator);
        defer declared_params.deinit();
        var receiver_args = std.ArrayList([]const u8).init(self.allocator);
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
            var member_args = std.ArrayList([]const u8).init(self.allocator);
            defer member_args.deinit();
            try splitTopLevelCsv(member_core.inner, &member_args);
            if (member_args.items.len == 0) return null;

            var changed = false;
            var out = std.ArrayList(u8).init(self.allocator);
            errdefer out.deinit();

            try out.writer().print("{s}<", .{member_core.base});
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
            if (std.mem.eql(u8, idx.tokens[j].text, type_name)) return true;
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
        items: *std.ArrayList(CompletionItem),
        seen: *std.StringHashMap(void),
        preferred_uri: []const u8,
        container_type: []const u8,
        prefix: []const u8,
    ) !void {
        const container_base = baseTypeNameForLookup(container_type);

        // If this document declares the type, do not merge same-name members
        // from other docs.
        if (self.hasTypeDeclarationInDoc(preferred_uri, container_base)) {
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

                    var key_buf = std.ArrayList(u8).init(self.allocator);
                    defer key_buf.deinit();
                    try key_buf.writer().print("method:{s}", .{s.name});
                    const key = try self.allocator.dupe(u8, key_buf.items);
                    if (seen.contains(key)) {
                        self.allocator.free(key);
                        continue;
                    }
                    try seen.put(key, {});

                    const detail: ?[]u8 = if (s.detail) |d|
                        try self.allocator.dupe(u8, d)
                    else blk: {
                        var db = std.ArrayList(u8).init(self.allocator);
                        defer db.deinit();
                        try db.writer().print("{s}.{s}", .{ container_type, s.name });
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
        items: *std.ArrayList(CompletionItem),
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
            var key_buf = std.ArrayList(u8).init(self.allocator);
            defer key_buf.deinit();
            try key_buf.writer().print("{s}:{s}", .{ @tagName(s.kind), s.name });
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
                    var db = std.ArrayList(u8).init(self.allocator);
                    defer db.deinit();
                    try db.writer().print("{s}.{s}", .{ container_type, s.name });
                    break :blk try self.allocator.dupe(u8, db.items);
                }
                if (s.kind == .method) {
                    if (s.detail) |d| break :blk try self.allocator.dupe(u8, d);
                    var db = std.ArrayList(u8).init(self.allocator);
                    defer db.deinit();
                    try db.writer().print("{s}.{s}", .{ container_type, s.name });
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
        items: *std.ArrayList(CompletionItem),
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
            if (!std.mem.eql(u8, idx.tokens[name_i].text, target_type)) continue;

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

                    const field_name_i = nextNonComment(idx.tokens, k + 1) orelse continue;
                    if (!isIdentLite(idx.tokens[field_name_i])) continue;
                    const after_name_i = nextNonComment(idx.tokens, field_name_i + 1) orelse continue;
                    if (!isSymbolLite(idx.tokens[after_name_i], ';')) continue;

                    const fname = idx.tokens[field_name_i].text;
                    if (prefix.len != 0 and !std.mem.startsWith(u8, fname, prefix)) {
                        k = after_name_i;
                        continue;
                    }

                    var key_buf = std.ArrayList(u8).init(self.allocator);
                    defer key_buf.deinit();
                    try key_buf.writer().print("field:{s}", .{fname});
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
            if (!std.mem.eql(u8, idx.tokens[name_i].text, target_type)) continue;

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

                    var key_buf = std.ArrayList(u8).init(self.allocator);
                    defer key_buf.deinit();
                    try key_buf.writer().print("enumMember:{s}", .{vname});
                    const key = try self.allocator.dupe(u8, key_buf.items);
                    if (seen.contains(key)) {
                        self.allocator.free(key);
                        continue;
                    }
                    try seen.put(key, {});

                    var db = std.ArrayList(u8).init(self.allocator);
                    defer db.deinit();
                    try db.writer().print("{s}.{s}", .{ container_type, vname });

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

                    var key_buf = std.ArrayList(u8).init(self.allocator);
                    defer key_buf.deinit();
                    try key_buf.writer().print("method:{s}", .{mname});
                    const key = try self.allocator.dupe(u8, key_buf.items);
                    if (seen.contains(key)) {
                        self.allocator.free(key);
                        continue;
                    }
                    try seen.put(key, {});

                    var db = std.ArrayList(u8).init(self.allocator);
                    defer db.deinit();
                    try db.writer().print("{s}.{s}", .{ container_type, mname });

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
        items: *std.ArrayList(CompletionItem),
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
            if (!std.mem.eql(u8, idx.tokens[name_i].text, target_type)) continue;

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

                    const field_name_i = nextNonComment(idx.tokens, k + 1) orelse continue;
                    if (!isIdentLite(idx.tokens[field_name_i])) continue;
                    const after_name_i = nextNonComment(idx.tokens, field_name_i + 1) orelse continue;
                    if (!isSymbolLite(idx.tokens[after_name_i], ';')) continue;

                    const key = try self.allocator.dupe(u8, idx.tokens[field_name_i].text);
                    try allowed.put(key, {});
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
            if (!std.mem.eql(u8, idx.tokens[name_i].text, target_type)) continue;

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
                    try allowed.put(key, {});
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
                    try allowed.put(key, {});
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
        const pos = parsed.?.pos;
        const doc = self.docs.get(uri) orelse {
            try self.sendResponseJson(id_val, "[]");
            return;
        };
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
            dbg(true, "defs", "definition request uri={s} pos=({d},{d}) tok='{s}' kind={s}", .{ uri, pos.line, pos.character, tok.text, @tagName(tok.kind) });
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
                    const json = try std.json.stringifyAlloc(self.allocator, locs, .{});
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
                        const json = try std.json.stringifyAlloc(self.allocator, locs, .{});
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
                        const json = try std.json.stringifyAlloc(self.allocator, locs, .{});
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
            const json = try std.json.stringifyAlloc(self.allocator, locs, .{});
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return;
        }

        // Fall back to global definition in direct imports.
        if (self.findAnyGlobalDefinitionInDirectImports(uri, tok.text)) |hit| {
            const locs = [_]Location{.{ .uri = hit.uri, .range = hit.sym.selection_range }};
            const json = try std.json.stringifyAlloc(self.allocator, locs, .{});
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return;
        }

        // Final fallback for types: if the identifier is a known type name anywhere in the workspace,
        // jump to its declaration even if the current file forgot to import it.
        if (self.isKnownTypeName(uri, tok.text)) {
            if (self.findTypeDefinitionAnyDoc(uri, tok.text)) |hit| {
                const locs = [_]Location{.{ .uri = hit.uri, .range = hit.sym.selection_range }};
                const json = try std.json.stringifyAlloc(self.allocator, locs, .{});
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
        var segs = std.ArrayList(struct { name: []const u8, tok_i: usize }).init(self.allocator);
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
                        var f = std.fs.openFileAbsolute(readme_path_fast, .{}) catch return false;
                        defer f.close();
                        break :blk f.readToEndAlloc(self.allocator, 128 * 1024) catch return false;
                    }
                    break :blk std.fs.cwd().readFileAlloc(self.allocator, readme_path_fast, 128 * 1024) catch return false;
                };
                defer self.allocator.free(readme_text);

                const hover: Hover = .{ .contents = .{ .value = readme_text }, .range = idx.tokens[tok_i].range };
                const json = try std.json.stringifyAlloc(self.allocator, hover, .{});
                defer self.allocator.free(json);
                try self.sendResponseJson(id_val, json);
                return true;
            }
        }

        // Resolve filesystem base and relative segments.
        var base_segs = std.ArrayList([]const u8).init(self.allocator);
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
                    var f = std.fs.openFileAbsolute(readme_path, .{}) catch return false;
                    f.close();
                } else {
                    std.fs.cwd().access(readme_path, .{}) catch return false;
                }
                const target_uri = try pathToUri(self.allocator, readme_path);
                defer self.allocator.free(target_uri);
                const locs = [_]Location{.{
                    .uri = target_uri,
                    .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
                }};
                const json = try std.json.stringifyAlloc(self.allocator, locs, .{});
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
        var sel_path_segs = std.ArrayList([]const u8).init(self.allocator);
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
                const json = try std.json.stringifyAlloc(self.allocator, locs, .{});
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
            const json = try std.json.stringifyAlloc(self.allocator, locs, .{});
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return true;
        }

        // Directory segment: return a list of modules in this directory.
        var dir = if (std.fs.path.isAbsolute(sel_joined))
            (std.fs.openDirAbsolute(sel_joined, .{ .iterate = true }) catch return false)
        else
            (std.fs.cwd().openDir(sel_joined, .{ .iterate = true }) catch return false);
        defer dir.close();

        var locs_list = std.ArrayList(Location).init(self.allocator);
        defer {
            for (locs_list.items) |l| self.allocator.free(l.uri);
            locs_list.deinit();
        }

        var it = dir.iterate();
        while (try it.next()) |entry| {
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

        const json = try std.json.stringifyAlloc(self.allocator, locs_list.items, .{});
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
        return true;
    }

    fn trySendAliasDefinition(self: *LspServer, id_val: ?std.json.Value, current_uri: []const u8, idx: *const Index, tok_i: usize) !bool {
        if (idx.tokens[tok_i].kind != .identifier) return false;

        const alias_name = idx.tokens[tok_i].text;
        const info = self.findAliasedImportSpecAndRange(idx, alias_name) orelse return false;
        defer self.allocator.free(info.spec);

        var locs = std.ArrayList(Location).init(self.allocator);
        defer locs.deinit();

        try locs.append(.{ .uri = current_uri, .range = info.range });

        var resolved_uri: ?[]u8 = null;
        if (self.resolveImportUri(current_uri, info.spec) catch null) |target_uri| {
            resolved_uri = target_uri;
            self.ensureDocIndexedFromDisk(target_uri) catch {};
            try locs.append(.{ .uri = target_uri, .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } } });
        }

        const json = try std.json.stringifyAlloc(self.allocator, locs.items, .{});
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
            fn addSegments(out: *std.ArrayList([]const u8), s: []const u8) !void {
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

        var parts = std.ArrayList([]const u8).init(self.allocator);
        defer parts.deinit();
        try parsed.addSegments(&parts, spec);
        if (parts.items.len == 0) return false;

        // Collect identifier tokens in the import statement and locate which one is hovered.
        var ident_toks = std.ArrayList(usize).init(self.allocator);
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
        var non_parent_part_indices = std.ArrayList(usize).init(self.allocator);
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
        var path_segs = std.ArrayList([]const u8).init(self.allocator);
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
                    var f = std.fs.openFileAbsolute(readme_path, .{}) catch return false;
                    defer f.close();
                    break :blk f.readToEndAlloc(self.allocator, 128 * 1024) catch return false;
                }
                break :blk std.fs.cwd().readFileAlloc(self.allocator, readme_path, 128 * 1024) catch return false;
            };
            defer self.allocator.free(readme_text);

            const hover: Hover = .{ .contents = .{ .value = readme_text }, .range = idx.tokens[tok_i].range };
            const json = try std.json.stringifyAlloc(self.allocator, hover, .{});
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
                var f = std.fs.openFileAbsolute(module_file, .{}) catch return false;
                defer f.close();
                break :blk f.readToEndAlloc(self.allocator, 128 * 1024) catch return false;
            }
            break :blk std.fs.cwd().readFileAlloc(self.allocator, module_file, 128 * 1024) catch return false;
        };
        defer self.allocator.free(module_text);

        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        const name = idx.tokens[tok_i].text;
        try buf.writer().print("**{s}**\n\n", .{name});

        var wrote_doc: bool = false;
        var li: usize = 0;
        while (li < module_text.len) {
            const line_start = li;
            while (li < module_text.len and module_text[li] != '\n') : (li += 1) {}
            const line = std.mem.trimRight(u8, module_text[line_start..@min(li, module_text.len)], "\r");
            if (line.len < 2 or line[0] != '/' or line[1] != '/') break;
            var content = line[2..];
            if (content.len != 0 and content[0] == ' ') content = content[1..];
            try buf.appendSlice(content);
            try buf.append('\n');
            wrote_doc = true;
            if (li < module_text.len and module_text[li] == '\n') li += 1;
        }
        if (!wrote_doc) {
            try buf.writer().print("_module_\n", .{});
        }

        const hover: Hover = .{ .contents = .{ .value = buf.items }, .range = idx.tokens[tok_i].range };
        const json = try std.json.stringifyAlloc(self.allocator, hover, .{});
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
        return true;
    }

    fn tryHandleMemberChainDefinition(self: *LspServer, id_val: ?std.json.Value, uri: []const u8, pos: Position, idx: *const Index, tok_i: usize) !bool {
        // Find chain start by scanning left through `. <ident>` pairs.
        if (tok_i == 0) return false;
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
        var ids = std.ArrayList(usize).init(self.allocator);
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
            const json = try std.json.stringifyAlloc(self.allocator, locs, .{});
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
            if (doc.index) |idx| {
                for (idx.symbols) |s| {
                    if (s.container_fn_range != null) continue;
                    if (s.kind != kind) continue;
                    if (s.container_type == null) continue;
                    if (!std.mem.eql(u8, baseTypeNameForLookup(s.container_type.?), container_base)) continue;
                    if (!std.mem.eql(u8, s.name, name)) continue;
                    return .{ .uri = preferred_uri, .sym = s };
                }
            }
        }

        var it = self.docs.iterator();
        while (it.next()) |entry| {
            const uri = entry.value_ptr.uri;
            if (std.mem.eql(u8, uri, preferred_uri)) continue;
            const idx = entry.value_ptr.index orelse continue;
            for (idx.symbols) |s| {
                if (s.container_fn_range != null) continue;
                if (s.kind != kind) continue;
                if (s.container_type == null) continue;
                if (!std.mem.eql(u8, baseTypeNameForLookup(s.container_type.?), container_base)) continue;
                if (!std.mem.eql(u8, s.name, name)) continue;
                if (!self.isSymbolVisibleFromUri(preferred_uri, uri, s)) continue;
                return .{ .uri = uri, .sym = s };
            }
        }
        return null;
    }

    fn findMemberByContainerInUri(self: *LspServer, uri: []const u8, container_base: []const u8, name: []const u8, kind: SymbolKind) ?SymbolLite {
        const doc = self.docs.get(uri) orelse return null;
        const idx = doc.index orelse return null;
        for (idx.symbols) |s| {
            if (s.container_fn_range != null) continue;
            if (s.kind != kind) continue;
            if (s.container_type == null) continue;
            if (!std.mem.eql(u8, baseTypeNameForLookup(s.container_type.?), container_base)) continue;
            if (!std.mem.eql(u8, s.name, name)) continue;
            return s;
        }
        return null;
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
        if (self.findAnyGlobalDefinitionInDirectImports(preferred_uri, type_name)) |hit| {
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
        _ = self;
        _ = preferred_uri;
        // Prefer symbol table (locals + globals) when available.
        if (findBestDefinition(idx.symbols, var_name, at)) |d| {
            if (d.kind == .variable) {
                if (d.value_type) |vt| {
                    if (!isLetInferTypeName(vt)) return vt;
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

        // 3) Fit context: `fit <enum_expr> { .Variant -> ... }`.
        var f: isize = @as(isize, @intCast(dot_i)) - 1;
        while (f >= 0) : (f -= 1) {
            const t = idx.tokens[@intCast(f)];
            if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, ";")) break;
            if (t.kind == .keyword and std.mem.eql(u8, t.text, "fit")) {
                const after_i = nextNonTrivialTokenLite(idx.tokens, @as(usize, @intCast(f + 1))) orelse return null;
                if (idx.tokens[after_i].kind != .identifier) return null;
                const name = idx.tokens[after_i].text;
                if (self.isEnumTypeName(uri, name)) return name;
                if (self.guessVariableType(idx, uri, name, dot_pos)) |vt| {
                    if (self.isEnumTypeName(uri, vt)) return vt;
                }
                return null;
            }
        }

        return null;
    }

    fn guessEnclosingImplType(self: *LspServer, idx: *const Index, at: Position) ?[]const u8 {
        _ = self;
        // Track brace depth and active `impl <Type> {` blocks.
        const Ctx = struct { type_name: []const u8, depth_at_start: i64 };
        var stack = std.ArrayList(Ctx).init(std.heap.page_allocator);
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
        const pos = parsed.?.pos;
        const doc = self.docs.get(uri) orelse {
            try self.sendResponseJson(id_val, "[]");
            return;
        };
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

        var out = std.ArrayList(Location).init(self.allocator);
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

        const json = try std.json.stringifyAlloc(self.allocator, out.items, .{});
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
        const pos = parsed.?.pos;
        const new_name = parsed.?.new_name;
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
        if (tok.kind != .identifier) {
            try self.sendResponseJson(id_val, "null");
            return;
        }

        // WorkspaceEdit needs dynamic map keys (URIs), so we build JSON manually.
        // Best-effort rename across all indexed documents.
        var json_buf = std.ArrayList(u8).init(self.allocator);
        defer json_buf.deinit();
        var w = json_buf.writer();

        try w.writeAll("{\"changes\":{");
        var first: bool = true;

        var it = self.docs.iterator();
        while (it.next()) |entry| {
            const this_uri = entry.value_ptr.uri;
            const this_idx = entry.value_ptr.index orelse continue;

            var edits = std.ArrayList(TextEdit).init(self.allocator);
            defer edits.deinit();
            for (this_idx.tokens) |t| {
                if (t.kind == .identifier and std.mem.eql(u8, t.text, tok.text)) {
                    try edits.append(.{ .range = t.range, .newText = new_name });
                }
            }
            if (edits.items.len == 0) continue;

            if (!first) try w.writeAll(",");
            first = false;
            try writeJsonString(w, this_uri);
            try w.writeAll(":");
            const edits_json = try std.json.stringifyAlloc(self.allocator, edits.items, .{});
            defer self.allocator.free(edits_json);
            try w.writeAll(edits_json);
        }
        try w.writeAll("}}");

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

        var fixes = std.ArrayList(CodeActionFix).init(self.allocator);
        defer fixes.deinit();

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
        }

        if (fixes.items.len == 0) {
            try self.sendResponseJson(id_val, "[]");
            return;
        }

        var json_buf = std.ArrayList(u8).init(self.allocator);
        defer json_buf.deinit();
        var w = json_buf.writer();

        try w.writeByte('[');
        for (fixes.items, 0..) |fix, i| {
            if (i != 0) try w.writeByte(',');

            try w.writeAll("{\"title\":");
            try writeJsonString(w, fix.title);
            try w.writeAll(",\"kind\":\"quickfix\",\"isPreferred\":");
            try w.writeAll(if (fix.is_preferred) "true" else "false");
            try w.writeAll(",\"edit\":{\"changes\":{");
            try writeJsonString(w, uri);
            try w.writeAll(":[{\"range\":");
            try writeRangeJson(w, fix.range);
            try w.writeAll(",\"newText\":");
            try writeJsonString(w, fix.new_text);
            try w.writeAll("}]}}}");
        }
        try w.writeByte(']');

        try self.sendResponseJson(id_val, json_buf.items);
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
            var items = std.ArrayList(CompletionItem).init(self.allocator);
            defer {
                for (items.items) |it| {
                    self.allocator.free(it.label);
                    if (it.detail) |d| self.allocator.free(d);
                }
                items.deinit();
            }

            const keywords = [_][]const u8{
                "imp",    "as",   "pub", "async", "fun",   "compound", "quirk", "impl", "enum", "asm", "volatile", "arch", "defer", "await", "ret",   "if",
                "elif",   "else", "for", "fit",   "break", "continue", "void",  "raw",  "num",  "dec", "str",      "bin",  "chr",   "true",  "false", "allow",
                "expect",
            };
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
                try items.append(.{ .label = try self.allocator.dupe(u8, "sizeof"), .kind = 3 });
            }

            const list: CompletionList = .{ .items = items.items };
            const json = try std.json.stringifyAlloc(self.allocator, list, .{});
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return;
        };

        var items = std.ArrayList(CompletionItem).init(self.allocator);
        defer {
            for (items.items) |it| {
                self.allocator.free(it.label);
                if (it.detail) |d| self.allocator.free(d);
                if (it.insertText) |ins| self.allocator.free(ins);
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
                try self.appendMemberCompletionsForType(&items, &seen, uri, rt, prefix);
                try self.appendMemberFieldCompletionsFromTokens(&items, &seen, idx, rt, prefix);
                try self.filterMemberCompletionItemsToLocalType(&items, idx, doc.text, rt);
                if (items.items.len != 0) {
                    const list: CompletionList = .{ .items = items.items };
                    const json = try std.json.stringifyAlloc(self.allocator, list, .{});
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

                        try self.appendMemberCompletionsForType(&items, &seen, uri, rt, prefix);
                        try self.appendMemberFieldCompletionsFromTokens(&items, &seen, idx, rt, prefix);
                        try self.filterMemberCompletionItemsToLocalType(&items, idx, doc.text, rt);
                        if (items.items.len != 0) {
                            const list: CompletionList = .{ .items = items.items };
                            const json = try std.json.stringifyAlloc(self.allocator, list, .{});
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
                                try self.appendMemberCompletionsForType(&items, &seen, uri, rt, prefix);
                                try self.appendMemberFieldCompletionsFromTokens(&items, &seen, idx, rt, prefix);
                                try self.filterMemberCompletionItemsToLocalType(&items, idx, doc.text, rt);
                                if (items.items.len != 0) {
                                    const list: CompletionList = .{ .items = items.items };
                                    const json = try std.json.stringifyAlloc(self.allocator, list, .{});
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
                    try self.appendMemberCompletionsForType(&items, &seen, uri, recv_type, prefix);
                    try self.appendMemberFieldCompletionsFromTokens(&items, &seen, idx, recv_type, prefix);
                    try self.filterMemberCompletionItemsToLocalType(&items, idx, doc.text, recv_type);
                    if (items.items.len != 0) {
                        const list: CompletionList = .{ .items = items.items };
                        const json = try std.json.stringifyAlloc(self.allocator, list, .{});
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
                        try self.appendMemberCompletionsForType(&items, &seen, uri, rt, prefix);
                        try self.appendMemberFieldCompletionsFromTokens(&items, &seen, idx, rt, prefix);
                        try self.filterMemberCompletionItemsToLocalType(&items, idx, doc.text, rt);
                        if (items.items.len != 0) {
                            const list: CompletionList = .{ .items = items.items };
                            const json = try std.json.stringifyAlloc(self.allocator, list, .{});
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
                        try self.appendMemberCompletionsForType(&items, &seen, uri, rt, prefix);
                        try self.appendMemberFieldCompletionsFromTokens(&items, &seen, idx, rt, prefix);
                        try self.filterMemberCompletionItemsToLocalType(&items, idx, doc.text, rt);
                        if (items.items.len != 0) {
                            const list: CompletionList = .{ .items = items.items };
                            const json = try std.json.stringifyAlloc(self.allocator, list, .{});
                            defer self.allocator.free(json);
                            try self.sendResponseJson(id_val, json);
                            return;
                        }
                    }
                }
            }
        }

        // Keywords.
        const keywords = [_][]const u8{
            "imp",    "as",   "pub", "async", "fun",   "compound", "quirk", "impl", "enum", "asm", "volatile", "arch", "defer", "await", "ret",   "if",
            "elif",   "else", "for", "fit",   "break", "continue", "void",  "raw",  "num",  "dec", "str",      "bin",  "chr",   "true",  "false", "allow",
            "expect",
        };
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
                    // Not shorthand when receiver exists: `Type.Member`
                    if (ti >= 2 and idx.tokens[ti - 2].kind == .identifier) break :blk false;
                    break :blk true;
                }
                if (isDotToken(t)) {
                    // Not shorthand when receiver exists: `Type.`
                    if (ti >= 1 and idx.tokens[ti - 1].kind == .identifier) break :blk false;
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
            var j: usize = dot_i_opt.?;
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
            break :blk recv_name.len == 0;
        };

        if ((prefix.len == 1 and prefix[0] == '.') or dot_shorthand_active) {
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
                        try items.append(.{
                            .label = try self.allocator.dupe(u8, s.name),
                            .kind = 20,
                            .detail = try self.allocator.dupe(u8, enum_name),
                            .insertText = try self.allocator.dupe(u8, s.name),
                            .filterText = ft,
                        });
                    }

                    // Direct imports.
                    var import_uris = std.ArrayList([]u8).init(self.allocator);
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
                            try items.append(.{
                                .label = try self.allocator.dupe(u8, s.name),
                                .kind = 20,
                                .detail = try self.allocator.dupe(u8, enum_name),
                                .insertText = try self.allocator.dupe(u8, s.name),
                                .filterText = ft,
                            });
                        }
                    }

                    const list: CompletionList = .{ .items = items.items };
                    const json = try std.json.stringifyAlloc(self.allocator, list, .{});
                    defer self.allocator.free(json);
                    try self.sendResponseJson(id_val, json);
                    return;
                }
            }
            // Fallback: offer members of all enums in scope.
            var enums = std.ArrayList(struct { name: []const u8, uri: []const u8 }).init(self.allocator);
            defer {
                for (enums.items) |e| self.allocator.free(e.name);
                enums.deinit();
            }
            for (idx.symbols) |s| {
                if (s.kind == .enum_ and s.container_type == null) {
                    try enums.append(.{ .name = try self.allocator.dupe(u8, s.name), .uri = uri });
                }
            }
            var import_uris = std.ArrayList([]u8).init(self.allocator);
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
                    try items.append(.{
                        .label = try self.allocator.dupe(u8, s.name),
                        .kind = 20,
                        .detail = try self.allocator.dupe(u8, e.name),
                        .insertText = try self.allocator.dupe(u8, s.name),
                        .filterText = ft,
                    });
                }
            }
            const list: CompletionList = .{ .items = items.items };
            const json = try std.json.stringifyAlloc(self.allocator, list, .{});
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

            const kind: i64 = switch (s.kind) {
                .function => 3,
                .method => 2,
                .struct_ => 7,
                .interface => 8,
                .variable => 6,
                else => 6,
            };

            const key = try self.allocator.dupe(u8, s.name);
            if (seen.contains(key)) {
                self.allocator.free(key);
                continue;
            }
            try seen.put(key, {});

            const insert_text = try self.completionInsertTextForSymbol(s);
            try items.append(.{
                .label = try self.allocator.dupe(u8, s.name),
                .kind = kind,
                .detail = blk: {
                    if (s.detail) |d| break :blk try self.allocator.dupe(u8, d);
                    if (s.kind == .variable) {
                        if (s.value_type) |vt| break :blk try self.allocator.dupe(u8, vt);
                    }
                    break :blk null;
                },
                .insertText = insert_text,
            });
        }

        // 2) Current-document globals/types/functions.
        for (idx.symbols) |s| {
            if (s.container_type != null) continue;
            if (s.container_fn_range != null) continue;
            if (prefix.len != 0 and !std.mem.startsWith(u8, s.name, prefix)) continue;

            const kind: i64 = switch (s.kind) {
                .function => 3,
                .method => 2,
                .struct_ => 7,
                .interface => 8,
                .variable => 6,
                else => 6,
            };

            const key = try self.allocator.dupe(u8, s.name);
            if (seen.contains(key)) {
                self.allocator.free(key);
                continue;
            }
            try seen.put(key, {});

            const insert_text = try self.completionInsertTextForSymbol(s);
            try items.append(.{
                .label = try self.allocator.dupe(u8, s.name),
                .kind = kind,
                .detail = blk: {
                    if (s.detail) |d| break :blk try self.allocator.dupe(u8, d);
                    if (s.kind == .variable) {
                        if (s.value_type) |vt| break :blk try self.allocator.dupe(u8, vt);
                    }
                    break :blk null;
                },
                .insertText = insert_text,
            });
        }

        // Direct imports.
        var import_uris = std.ArrayList([]u8).init(self.allocator);
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

                const kind: i64 = switch (s.kind) {
                    .function => 3,
                    .method => 2,
                    .struct_ => 7,
                    .interface => 8,
                    .variable => 6,
                    else => 6,
                };

                const key = try self.allocator.dupe(u8, s.name);
                if (seen.contains(key)) {
                    self.allocator.free(key);
                    continue;
                }
                try seen.put(key, {});

                const insert_text = try self.completionInsertTextForSymbol(s);
                try items.append(.{
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
                    .insertText = insert_text,
                });
            }
        }

        const list: CompletionList = .{ .items = items.items };
        const json = try std.json.stringifyAlloc(self.allocator, list, .{});
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
    }

    fn trySendAliasHover(self: *LspServer, id_val: ?std.json.Value, current_uri: []const u8, idx: *const Index, alias_name: []const u8, range: Range) !bool {
        const info = self.findAliasedImportSpecAndRange(idx, alias_name) orelse return false;
        defer self.allocator.free(info.spec);

        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        try buf.writer().print("**{s}**\n\n", .{alias_name});
        try buf.writer().print("_alias for `{s}`_\n", .{info.spec});

        if (self.resolveImportUri(current_uri, info.spec) catch null) |target_uri| {
            defer self.allocator.free(target_uri);
            if (uriToPath(self.allocator, target_uri) catch null) |target_path| {
                defer self.allocator.free(target_path);
                try buf.writer().print("\n`{s}`\n", .{target_path});
            }
        }

        const hover: Hover = .{ .contents = .{ .value = buf.items }, .range = range };
        const json = try std.json.stringifyAlloc(self.allocator, hover, .{});
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
        items: *std.ArrayList(CompletionItem),
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

                var insert_buf = std.ArrayList(u8).init(self.allocator);
                defer insert_buf.deinit();
                try insert_buf.writer().print("{s} = ", .{s.name});

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
        items: *std.ArrayList(CompletionItem),
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

                    const field_name_i = nextNonComment(idx.tokens, k + 1) orelse continue;
                    if (!isIdentLite(idx.tokens[field_name_i])) continue;
                    const after_name_i = nextNonComment(idx.tokens, field_name_i + 1) orelse continue;
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

                    var insert_buf = std.ArrayList(u8).init(self.allocator);
                    defer insert_buf.deinit();
                    try insert_buf.writer().print("{s} = ", .{fname});

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
        items: *std.ArrayList(CompletionItem),
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

                    const sp = std.mem.lastIndexOfScalar(u8, decl, ' ') orelse continue;
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

                    var insert_buf = std.ArrayList(u8).init(self.allocator);
                    defer insert_buf.deinit();
                    try insert_buf.writer().print("{s} = ", .{field_name});

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

        var items = std.ArrayList(CompletionItem).init(self.allocator);
        defer {
            for (items.items) |it| {
                self.allocator.free(it.label);
                if (it.detail) |d| self.allocator.free(d);
                if (it.insertText) |ins| self.allocator.free(ins);
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
        const json = try std.json.stringifyAlloc(self.allocator, list, .{});
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

        var items = std.ArrayList(CompletionItem).init(self.allocator);
        defer {
            for (items.items) |it| {
                self.allocator.free(it.label);
                if (it.detail) |d| self.allocator.free(d);
                if (it.insertText) |ins| self.allocator.free(ins);
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

                var key_buf = std.ArrayList(u8).init(self.allocator);
                defer key_buf.deinit();
                try key_buf.writer().print("{s}:{d}", .{ s.name, ck });
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
                    (std.fs.openFileAbsolute(p, .{}) catch null)
                else
                    (std.fs.cwd().openFile(p, .{}) catch null);

                if (module_text) |f| {
                    defer f.close();
                    const text = f.readToEndAlloc(self.allocator, 512 * 1024) catch null;
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
        const json = try std.json.stringifyAlloc(self.allocator, list, .{});
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
        return true;
    }

    fn appendCMacroCompletionsForImports(self: *LspServer, items: *std.ArrayList(CompletionItem), idx: *const Index, prefix: []const u8) !void {
        // Avoid noisy global completion: only suggest macros when user is typing an
        // ALL_CAPS-ish prefix.
        if (prefix.len == 0) return;
        const c0 = prefix[0];
        const is_macro_prefix = (c0 >= 'A' and c0 <= 'Z') or c0 == '_';
        if (!is_macro_prefix) return;

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

        const stddef_macros = [_]Macro{
            .{ .name = "NULL", .detail = "stddef.h macro" },
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

            // Often available via related headers; still useful to offer when the user
            // opts into `limits`.
            .{ .name = "SIZE_MAX", .detail = "limits.h-related macro" },
            .{ .name = "RSIZE_MAX", .detail = "limits.h-related macro" },
            .{ .name = "PTRDIFF_MIN", .detail = "limits.h-related macro" },
            .{ .name = "PTRDIFF_MAX", .detail = "limits.h-related macro" },
            .{ .name = "WCHAR_MIN", .detail = "limits.h-related macro" },
            .{ .name = "WCHAR_MAX", .detail = "limits.h-related macro" },
            .{ .name = "WINT_MIN", .detail = "limits.h-related macro" },
            .{ .name = "WINT_MAX", .detail = "limits.h-related macro" },
        };

        if (has_stddef) {
            for (stddef_macros) |m| {
                if (!std.mem.startsWith(u8, m.name, prefix)) continue;
                try items.append(.{
                    .label = try self.allocator.dupe(u8, m.name),
                    .kind = 21, // CompletionItemKind.Constant
                    .detail = try self.allocator.dupe(u8, m.detail),
                });
            }
        }

        if (has_limits) {
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
        var ids = std.ArrayList(usize).init(self.allocator);
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

        var items = std.ArrayList(CompletionItem).init(self.allocator);
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
        var segs = std.ArrayList([]const u8).init(self.allocator);
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
            if (std.fs.openFileAbsolute(receiver_file, .{}) catch null) |f| {
                f.close();
                is_file = true;
            }
        } else {
            if (std.fs.cwd().openFile(receiver_file, .{}) catch null) |f| {
                f.close();
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
            const json = try std.json.stringifyAlloc(self.allocator, list, .{});
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return true;
        }

        // 2) Otherwise treat receiver as a directory and list modules/subfolders.
        if (std.fs.path.isAbsolute(receiver_path_no_ext)) {
            if (std.fs.openDirAbsolute(receiver_path_no_ext, .{ .iterate = true }) catch null) |dir| {
                var dir_mut = dir;
                defer dir_mut.close();
                var it = dir_mut.iterate();

                var saw_c_dir: bool = false;
                var saw_any_fn: bool = false;
                while (it.next() catch null) |entry| {
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
                    if (std.fs.openDirAbsolute(c_dir, .{ .iterate = true }) catch null) |cdir| {
                        var cdir_mut = cdir;
                        defer cdir_mut.close();
                        var it2 = cdir_mut.iterate();
                        while (it2.next() catch null) |e2| {
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
        const json = try std.json.stringifyAlloc(self.allocator, list, .{});
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
        ids: *std.ArrayList(usize),
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

        var segs = std.ArrayList([]const u8).init(self.allocator);
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
            if (std.fs.openFileAbsolute(abs_or_rel_path, .{}) catch null) |f| {
                f.close();
                return true;
            }
            return false;
        }

        if (std.fs.cwd().openFile(abs_or_rel_path, .{}) catch null) |f| {
            f.close();
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

        var ids = std.ArrayList(usize).init(self.allocator);
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
            const json = try std.json.stringifyAlloc(self.allocator, locs, .{});
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
                const json = try std.json.stringifyAlloc(self.allocator, locs, .{});
                defer self.allocator.free(json);
                try self.sendResponseJson(id_val, json);
                return true;
            }

            const locs = [_]Location{.{
                .uri = module_uri,
                .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
            }};
            const json = try std.json.stringifyAlloc(self.allocator, locs, .{});
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return true;
        }

        // Otherwise treat the selected identifier as a module/directory segment.
        const root = self.getStdlibRootForNamespace(current_uri) orelse return false;

        var segs = std.ArrayList([]const u8).init(self.allocator);
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
            const json = try std.json.stringifyAlloc(self.allocator, locs, .{});
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
            const json = try std.json.stringifyAlloc(self.allocator, locs, .{});
            defer self.allocator.free(json);
            try self.sendResponseJson(id_val, json);
            return true;
        }

        // If it's a directory, return definitions for contained modules.
        var dir = if (std.fs.path.isAbsolute(selected_path_no_ext))
            (std.fs.openDirAbsolute(selected_path_no_ext, .{ .iterate = true }) catch return false)
        else
            (std.fs.cwd().openDir(selected_path_no_ext, .{ .iterate = true }) catch return false);
        defer dir.close();

        var locs_list = std.ArrayList(Location).init(self.allocator);
        defer {
            for (locs_list.items) |l| self.allocator.free(l.uri);
            locs_list.deinit();
        }

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".fn")) continue;
            const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ selected_path_no_ext, entry.name });
            defer self.allocator.free(full_path);
            const u = try pathToUri(self.allocator, full_path);
            try locs_list.append(.{ .uri = u, .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } } });
        }

        if (locs_list.items.len == 0) return false;
        const json = try std.json.stringifyAlloc(self.allocator, locs_list.items, .{});
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

        var ids = std.ArrayList(usize).init(self.allocator);
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
                var segs = std.ArrayList([]const u8).init(allocator);
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
                    var f = std.fs.openFileAbsolute(readme_path, .{}) catch return false;
                    defer f.close();
                    break :blk f.readToEndAlloc(self.allocator, 128 * 1024) catch return false;
                }
                break :blk std.fs.cwd().readFileAlloc(self.allocator, readme_path, 128 * 1024) catch return false;
            };
            defer self.allocator.free(readme_text);

            const hover: Hover = .{ .contents = .{ .value = readme_text }, .range = idx.tokens[tok_i].range };
            const json = try std.json.stringifyAlloc(self.allocator, hover, .{});
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

        var buf = std.ArrayList(u8).init(self.allocator);
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

            try buf.writer().print("**{s}**\n\n", .{symbol_name});
            if (sym.detail) |det| {
                try buf.writer().print("```fun\n{s}\n```\n", .{det});
            } else if (sym.kind == .variable) {
                if (sym.value_type) |vt| {
                    try buf.writer().print("```fun\n{s} {s}\n```\n", .{ vt, symbol_name });
                } else {
                    try buf.writer().print("_{s}_\n", .{@tagName(sym.kind)});
                }
            } else if (sym.kind == .struct_ or sym.kind == .interface) {
                try buf.writer().print("```fun\n{s} {s}\n```\n", .{ if (sym.kind == .struct_) "compound" else "quirk", symbol_name });
            } else {
                try buf.writer().print("_{s}_\n", .{@tagName(sym.kind)});
            }

            _ = try appendDocCommentAboveLine(self.allocator, &buf, doc.text, sym.decl_range.start.line);

            const hover: Hover = .{ .contents = .{ .value = buf.items }, .range = idx.tokens[tok_i].range };
            const json = try std.json.stringifyAlloc(self.allocator, hover, .{});
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
                    var f = std.fs.openFileAbsolute(readme_path, .{}) catch return false;
                    defer f.close();
                    break :blk f.readToEndAlloc(self.allocator, 128 * 1024) catch return false;
                }
                break :blk std.fs.cwd().readFileAlloc(self.allocator, readme_path, 128 * 1024) catch return false;
            };
            defer self.allocator.free(readme_text);

            const hover: Hover = .{ .contents = .{ .value = readme_text }, .range = idx.tokens[tok_i].range };
            const json = try std.json.stringifyAlloc(self.allocator, hover, .{});
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
                var f = std.fs.openFileAbsolute(module_file, .{}) catch return false;
                defer f.close();
                break :blk f.readToEndAlloc(self.allocator, 128 * 1024) catch return false;
            }
            break :blk std.fs.cwd().readFileAlloc(self.allocator, module_file, 128 * 1024) catch return false;
        };
        defer self.allocator.free(module_text);

        const name = idx.tokens[tok_i].text;
        try buf.writer().print("**{s}**\n\n", .{name});

        // Extract the leading line-comment block and render it as markdown.
        var wrote_doc: bool = false;
        var i: usize = 0;
        while (i < module_text.len) {
            // Find line end.
            const line_start = i;
            while (i < module_text.len and module_text[i] != '\n') : (i += 1) {}
            const line = std.mem.trimRight(u8, module_text[line_start..@min(i, module_text.len)], "\r");
            if (line.len < 2 or line[0] != '/' or line[1] != '/') break;
            var content = line[2..];
            if (content.len != 0 and content[0] == ' ') content = content[1..];
            try buf.appendSlice(content);
            try buf.append('\n');
            wrote_doc = true;
            if (i < module_text.len and module_text[i] == '\n') i += 1;
        }

        if (!wrote_doc) {
            try buf.writer().print("_module_\n", .{});
        }

        const hover: Hover = .{ .contents = .{ .value = buf.items }, .range = idx.tokens[tok_i].range };
        const json = try std.json.stringifyAlloc(self.allocator, hover, .{});
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

        var ids = std.ArrayList(usize).init(self.allocator);
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

        var buf = std.ArrayList(u8).init(self.allocator);
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

    fn collectDirectImportUris(self: *LspServer, out: *std.ArrayList([]u8), current_uri: []const u8, idx: *const Index) !void {
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

        var import_uris = std.ArrayList([]u8).init(self.allocator);
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
            fn addSegments(out: *std.ArrayList([]const u8), s: []const u8) !void {
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

        var parts = std.ArrayList([]const u8).init(self.allocator);
        defer parts.deinit();
        try parsed.addSegments(&parts, after_imp);
        if (parts.items.len == 0) return false;

        const ends_with_dot = after_imp.len != 0 and after_imp[after_imp.len - 1] == '.';
        const partial: []const u8 = if (ends_with_dot) "" else parts.items[parts.items.len - 1];
        const parent_count: usize = if (ends_with_dot) parts.items.len else (if (parts.items.len >= 1) parts.items.len - 1 else 0);
        var items = std.ArrayList(CompletionItem).init(self.allocator);
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
                var segs = std.ArrayList([]const u8).init(self.allocator);
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
                    var segs = std.ArrayList([]const u8).init(self.allocator);
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
            if (std.fs.openDirAbsolute(base_dir_path, .{ .iterate = true }) catch null) |dir| {
                var dir_mut = dir;
                defer dir_mut.close();

                var iter = dir_mut.iterate();
                var saw_c_dir: bool = false;
                var saw_any_fn: bool = false;
                while (iter.next() catch null) |entry| {
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
                    if (std.fs.openDirAbsolute(c_dir, .{ .iterate = true }) catch null) |cdir| {
                        var cdir_mut = cdir;
                        defer cdir_mut.close();
                        var it2 = cdir_mut.iterate();
                        while (it2.next() catch null) |e2| {
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
        const json = try std.json.stringifyAlloc(self.allocator, list, .{});
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
        } else {
            return false;
        }

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

        var items = std.ArrayList(CompletionItem).init(self.allocator);
        defer {
            for (items.items) |it| self.allocator.free(it.label);
            items.deinit();
        }

        const warning_ids = [_][]const u8{
            "return_local_ptr",
            "fit_non_exhaustive",
        };
        for (warning_ids) |wid| {
            if (prefix.len == 0 or std.mem.startsWith(u8, wid, prefix)) {
                try items.append(.{ .label = try self.allocator.dupe(u8, wid), .kind = 21 }); // CompletionItemKind.Constant
            }
        }

        const list: CompletionList = .{ .items = items.items };
        const json = try std.json.stringifyAlloc(self.allocator, list, .{});
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
                var f = std.fs.openFileAbsolute(readme_path, .{}) catch return false;
                defer f.close();
                break :blk f.readToEndAlloc(self.allocator, 128 * 1024) catch return false;
            }
            break :blk std.fs.cwd().readFileAlloc(self.allocator, readme_path, 128 * 1024) catch return false;
        };
        defer self.allocator.free(readme_text);

        const hover: Hover = .{ .contents = .{ .value = readme_text }, .range = .{ .start = pos, .end = pos } };
        const json = try std.json.stringifyAlloc(self.allocator, hover, .{});
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
                            if (self.resolveTypeOfChainUpTo(idx, uri, p, callee_i - 2)) |recv_type| {
                                const hit = self.findMemberByContainer(uri, recv_type, callee.text, .method);
                                if (hit) |h| {
                                    const label = if (h.sym.detail) |d| d else callee.text;
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
        const pos = parsed.?.pos;
        const doc = self.docs.get(uri) orelse {
            try self.sendResponseJson(id_val, "null");
            return;
        };
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
        const json = try std.json.stringifyAlloc(self.allocator, help, .{});
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
    }

    fn signatureLabelHasVariadic(self: *LspServer, label: []const u8) bool {
        _ = self;
        return std.mem.indexOf(u8, label, "...") != null;
    }

    fn parseParamsFromSignatureLabel(self: *LspServer, label: []const u8) !std.ArrayList(ParameterInformation) {
        var out = std.ArrayList(ParameterInformation).init(self.allocator);

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
            fn call(text: []const u8, out: *std.ArrayList([]const u8)) !void {
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
            fn call(label: []const u8, out: *std.ArrayList([]const u8)) !void {
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

                var raw = std.ArrayList([]const u8).init(std.heap.page_allocator);
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

        const parseParamTypesFromLabel = struct {
            fn call(label: []const u8, out: *std.ArrayList([]const u8)) !void {
                const bounds = findSignatureParenBounds(label) orelse return;
                if (bounds.close <= bounds.open + 1) return;
                const inner = std.mem.trim(u8, label[bounds.open + 1 .. bounds.close], " \t\r\n");
                if (inner.len == 0) return;

                var raw = std.ArrayList([]const u8).init(std.heap.page_allocator);
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
            fn call(bindings: *std.ArrayList(TypeBinding), param: []const u8, arg: []const u8) !void {
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
            fn call(gparams: []const []const u8, bindings: *std.ArrayList(TypeBinding), ptype_raw: []const u8, atype_raw: []const u8) !void {
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

                        var pinner = std.ArrayList([]const u8).init(std.heap.page_allocator);
                        defer pinner.deinit();
                        var ainner = std.ArrayList([]const u8).init(std.heap.page_allocator);
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
            fn call(allocator_: Allocator, tokens: []const TokenLite, l_angle_i: usize, out: *std.ArrayList([]u8)) !void {
                var depth: i64 = 0;
                var cur = std.ArrayList(u8).init(allocator_);
                defer cur.deinit();

                const flush = struct {
                    fn call2(allocator2: Allocator, cur_buf: *std.ArrayList(u8), out_buf: *std.ArrayList([]u8)) !void {
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
            fn call(tokens: []const TokenLite, lparen_i2: usize, end_excl: usize, out: *std.ArrayList(ArgRange)) !void {
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

                var out = std.ArrayList(u8).init(allocator_);
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

        var generic_params = std.ArrayList([]const u8).init(self.allocator);
        defer generic_params.deinit();
        try parseGenericParamNamesFromLabel(sig.label, &generic_params);
        if (generic_params.items.len == 0) return null;

        var bindings = std.ArrayList(TypeBinding).init(self.allocator);
        defer bindings.deinit();

        var explicit_args = std.ArrayList([]u8).init(self.allocator);
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

        var param_types = std.ArrayList([]const u8).init(self.allocator);
        defer param_types.deinit();
        try parseParamTypesFromLabel(sig.label, &param_types);

        var arg_ranges = std.ArrayList(ArgRange).init(self.allocator);
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
        var syms = std.ArrayList(SymbolInformation).init(self.allocator);
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

        const json = try std.json.stringifyAlloc(self.allocator, syms.items, .{});
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
    }

    fn handleWorkspaceSymbols(self: *LspServer, id_val: ?std.json.Value, params_val: ?std.json.Value) !void {
        const query = (try parseWorkspaceSymbolQuery(self.allocator, params_val)) orelse "";
        defer if (query.len != 0) self.allocator.free(query);

        var out = std.ArrayList(SymbolInformation).init(self.allocator);
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

        const json = try std.json.stringifyAlloc(self.allocator, out.items, .{});
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
        const json = try std.json.stringifyAlloc(self.allocator, st, .{});
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
        const now = std.time.milliTimestamp();
        const doc_ptr = self.docs.getPtr(uri) orelse return;

        if (!force and doc_ptr.last_diag_ms != 0) {
            const dt = now - doc_ptr.last_diag_ms;
            // Avoid spawning `fun` too often while typing; it can make the LSP feel "buggy"/stalled.
            if (dt >= 0 and dt < 400) return;
        }

        // Update timestamp even if diagnostics fail, to avoid tight retry loops.
        doc_ptr.last_diag_ms = now;
        try self.publishDiagnostics(uri, text);
    }

    fn rebuildIndex(self: *LspServer, uri: []const u8) !void {
        const doc_ptr = self.docs.getPtr(uri) orelse return;
        const scope: IndexBuildScope = if (doc_ptr.version > 0) .open_document else .background;

        // Build the new index first; if it fails, keep the old one so completion doesn't "die" mid-edit.
        const new_idx = buildIndexFromTextAt(self.allocator, doc_ptr.text, null, scope) catch |err| {
            std.debug.print("[fls] rebuildIndex failed (keeping old index): {s}\n", .{@errorName(err)});
            return;
        };

        if (doc_ptr.index) |idx| idx.deinit();
        doc_ptr.index = new_idx;
        self.ensureImportsIndexed(uri);
        self.refineLetVariableTypesFromDirectImports(uri);
    }

    fn refineLetVariableTypesFromDirectImports(self: *LspServer, uri: []const u8) void {
        const doc_ptr = self.docs.getPtr(uri) orelse return;
        const idx = doc_ptr.index orelse return;
        const arena_alloc = idx.arena.allocator();

        var pass: usize = 0;
        while (pass < 3) : (pass += 1) {
            var changed = false;

            for (idx.symbols) |*s| {
                if (s.kind != .variable) continue;

                const existing_vt_opt = s.value_type;
                if (existing_vt_opt) |existing_vt| {
                    if (!isLetInferTypeName(existing_vt) and !isBuiltinTypeName(existing_vt)) continue;
                }

                const inferred = self.tryInferLetInitializerCallReturnType(idx, uri, s, arena_alloc) orelse continue;
                if (isLetInferTypeName(inferred)) continue;
                if (existing_vt_opt) |existing_vt| {
                    if (std.mem.eql(u8, inferred, existing_vt)) continue;
                    if (isBuiltinTypeName(existing_vt) and isBuiltinTypeName(inferred)) continue;
                }

                s.value_type = inferred;

                var det_buf = std.ArrayList(u8).init(arena_alloc);
                defer det_buf.deinit();
                det_buf.writer().print("{s} {s}", .{ inferred, s.name }) catch continue;
                s.detail = det_buf.toOwnedSlice() catch continue;
                changed = true;
            }

            if (!changed) break;
        }
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
                if (self.debug_imports) dbg(true, "imports", "found import in {s}: '{s}'", .{ uri, s });
                const maybe_target_uri = self.resolveImportUri(uri, s) catch null;
                if (maybe_target_uri) |target_uri| {
                    defer self.allocator.free(target_uri);
                    if (self.debug_imports) dbg(true, "imports", "resolved import '{s}' => {s}", .{ s, target_uri });
                    self.ensureDocIndexedFromDisk(target_uri) catch {};
                } else {
                    if (self.debug_imports) dbg(true, "imports", "failed to resolve import '{s}'", .{s});
                }
            }
        }
    }

    fn ensureDocIndexedFromDisk(self: *LspServer, uri: []const u8) !void {
        if (self.docs.get(uri) != null) return;
        const path = try uriToPath(self.allocator, uri);
        defer self.allocator.free(path);

        // `uriToPath()` yields an absolute path for `file:` URIs.
        // On Windows, using `std.fs.cwd().readFileAlloc()` with an absolute path can fail,
        // which breaks stdlib indexing when the stdlib lives outside the workspace.
        const text = blk: {
            if (std.fs.path.isAbsolute(path)) {
                var f = try std.fs.openFileAbsolute(path, .{});
                defer f.close();
                break :blk try f.readToEndAlloc(self.allocator, 25 * 1024 * 1024);
            }
            break :blk try std.fs.cwd().readFileAlloc(self.allocator, path, 25 * 1024 * 1024);
        };
        defer self.allocator.free(text);

        try self.upsertDoc(uri, 0, text);
        try self.rebuildIndex(uri);
    }

    fn resolveImportUri(self: *LspServer, current_uri: []const u8, raw_import: []const u8) !?[]u8 {
        // Supports:
        // - `imp std.c.io;` => <workspace>/stdlib/std/c/io.fn
        // - `imp relative.parent;` => <current_dir>/relative/parent.fn
        // - `imp child;` => <current_dir>/child.fn
        // - `imp ..defs.user;` => <current_dir>/../defs/user.fn
        const spec = std.mem.trim(u8, raw_import, " \t\r\n\"");
        if (spec.len == 0) return null;

        if (self.debug_imports) dbg(true, "imports", "resolveImportUri current_uri={s} raw='{s}' spec='{s}'", .{ current_uri, raw_import, spec });

        const current_path = uriToPath(self.allocator, current_uri) catch return null;
        defer self.allocator.free(current_path);
        const current_dir = std.fs.path.dirname(current_path) orelse return null;

        const parsed = struct {
            fn addSegments(out: *std.ArrayList([]const u8), s: []const u8) !void {
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

        var parts = std.ArrayList([]const u8).init(self.allocator);
        defer parts.deinit();
        try parsed.addSegments(&parts, spec);
        if (parts.items.len == 0) return null;

        var segs = std.ArrayList([]const u8).init(self.allocator);
        defer segs.deinit();

        if (std.mem.eql(u8, parts.items[0], "std")) {
            var stdlib_root = self.getStdlibRootPath() orelse null;
            if (stdlib_root == null) {
                self.tryStdlibRootFromCurrentDoc(current_uri);
                stdlib_root = self.getStdlibRootPath() orelse null;
            }
            const root = stdlib_root orelse return null;
            if (self.debug_imports) dbg(true, "imports", "stdlib root used={s}", .{root});
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

        if (self.debug_imports) dbg(true, "imports", "candidate path={s}", .{full});

        // `full` is typically absolute (current file dir is absolute or stdlib root is absolute).
        // Use absolute file APIs so installed stdlib works on Windows.
        const full_exists = blk: {
            if (std.fs.path.isAbsolute(full)) {
                var f = std.fs.openFileAbsolute(full, .{}) catch break :blk false;
                f.close();
                break :blk true;
            } else {
                std.fs.cwd().access(full, .{}) catch break :blk false;
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
                var segs_root = std.ArrayList([]const u8).init(self.allocator);
                defer segs_root.deinit();
                try segs_root.append(root);
                for (parts.items) |p| try segs_root.append(p);

                const joined_root = try std.fs.path.join(self.allocator, segs_root.items);
                defer self.allocator.free(joined_root);
                const full_root = try std.mem.concat(self.allocator, u8, &[_][]const u8{ joined_root, ".fn" });
                defer self.allocator.free(full_root);

                const root_exists = blk: {
                    if (std.fs.path.isAbsolute(full_root)) {
                        var f = std.fs.openFileAbsolute(full_root, .{}) catch break :blk false;
                        f.close();
                        break :blk true;
                    } else {
                        std.fs.cwd().access(full_root, .{}) catch break :blk false;
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

        var grouped = std.StringHashMap(std.ArrayList(Diagnostic)).init(self.allocator);
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
                var list = std.ArrayList(Diagnostic).init(self.allocator);
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
        // Create the temp file next to the current document, so relative `imp "..."` resolution
        // and diagnostic file paths match the user's project layout.
        var tmp_name_buf: [80]u8 = undefined;
        const tmp_name = try std.fmt.bufPrint(&tmp_name_buf, ".__fls_{d}_{d}.fn", .{ std.time.milliTimestamp(), std.time.nanoTimestamp() });

        const current_path_opt = uriToPath(self.allocator, current_uri) catch null;
        defer if (current_path_opt) |p| self.allocator.free(p);
        const current_dir_opt = if (current_path_opt) |p| std.fs.path.dirname(p) else null;

        var base_dir = if (current_dir_opt) |d| try std.fs.openDirAbsolute(d, .{}) else std.fs.cwd();
        defer if (current_dir_opt != null) base_dir.close();

        {
            const f = try base_dir.createFile(tmp_name, .{ .read = true, .truncate = true });
            defer f.close();
            try f.writeAll(text);
        }
        defer base_dir.deleteFile(tmp_name) catch {};

        const tmp_path_for_fun = blk: {
            if (current_dir_opt) |d| {
                break :blk try std.fs.path.join(self.allocator, &[_][]const u8{ d, tmp_name });
            }
            break :blk try self.allocator.dupe(u8, tmp_name);
        };
        defer self.allocator.free(tmp_path_for_fun);

        var stderr_buf = std.ArrayList(u8).init(self.allocator);
        defer stderr_buf.deinit();

        const argv = [_][]const u8{ self.fun_exe_path, "-in", tmp_path_for_fun, "-no-exec" };
        _ = try runCaptureStderr(self.allocator, &argv, &stderr_buf);

        return try parseFunDiagnosticsByUri(self.allocator, stderr_buf.items, current_uri, tmp_name);
    }

    fn formatText(self: *LspServer, text: []const u8) ![]u8 {
        var tmp_dir = std.fs.cwd();
        var tmp_abs_path: ?[]u8 = null;
        defer if (tmp_abs_path) |p| self.allocator.free(p);

        if (getOrInitFlsTempDirCached()) |res| {
            tmp_dir = res.dir;
        }

        var tmp_name_buf: [64]u8 = undefined;
        const tmp_name = try std.fmt.bufPrint(&tmp_name_buf, ".__fls_fmt_{d}.fn", .{std.time.milliTimestamp()});

        if (getOrInitFlsTempDirCached()) |res2| {
            tmp_abs_path = try std.fs.path.join(self.allocator, &[_][]const u8{ res2.abs_path, tmp_name });
        }

        {
            const f = try tmp_dir.createFile(tmp_name, .{ .read = true, .truncate = true });
            defer f.close();
            try f.writeAll(text);
        }
        defer tmp_dir.deleteFile(tmp_name) catch {};

        var stderr_buf = std.ArrayList(u8).init(self.allocator);
        defer stderr_buf.deinit();

        const in_path = if (tmp_abs_path) |p| p else tmp_name;
        const argv = [_][]const u8{ self.fun_exe_path, "-in", in_path, "-fmt", "-no-exec" };
        const code = try runCaptureStderr(self.allocator, &argv, &stderr_buf);
        if (code != 0) return error.FormatFailed;

        const out = try tmp_dir.readFileAlloc(self.allocator, tmp_name, 10 * 1024 * 1024);
        // Defensive: never send an edit that wipes the doc unless the input was empty.
        if (out.len == 0 and text.len != 0) {
            self.allocator.free(out);
            return error.FormatFailed;
        }
        return out;
    }

    fn sendPublishDiagnostics(self: *LspServer, uri: []const u8, diagnostics: []const Diagnostic) !void {
        const Params = struct {
            uri: []const u8,
            diagnostics: []const Diagnostic,
        };

        const params: Params = .{ .uri = uri, .diagnostics = diagnostics };
        const params_json = try std.json.stringifyAlloc(self.allocator, params, .{});
        defer self.allocator.free(params_json);
        try self.sendNotificationJson("textDocument/publishDiagnostics", params_json);
    }

    fn sendResponseJson(self: *LspServer, id_val: ?std.json.Value, result_json: []const u8) !void {
        const id_json = try stringifyId(self.allocator, id_val);
        defer self.allocator.free(id_json);

        var msg = std.ArrayList(u8).init(self.allocator);
        defer msg.deinit();
        try msg.writer().print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_json, result_json });
        try writeLspMessageRaw(self.stdout.writer(), msg.items);
    }

    fn sendNotificationJson(self: *LspServer, method: []const u8, params_json: []const u8) !void {
        var msg = std.ArrayList(u8).init(self.allocator);
        defer msg.deinit();
        try msg.writer().print("{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}", .{ method, params_json });
        try writeLspMessageRaw(self.stdout.writer(), msg.items);
    }
};

fn stringifyId(allocator: Allocator, id_val: ?std.json.Value) ![]u8 {
    if (id_val == null) return allocator.dupe(u8, "null");
    return std.json.stringifyAlloc(allocator, id_val.?, .{});
}

fn writeLspMessageRaw(w: anytype, json: []const u8) !void {
    try w.print("Content-Length: {d}\r\n\r\n", .{json.len});
    try w.writeAll(json);
}

fn readLspMessage(allocator: Allocator, r: anytype) ![]u8 {
    var content_length: ?usize = null;
    while (true) {
        const line_opt = try r.readUntilDelimiterOrEofAlloc(allocator, '\n', 16 * 1024);
        if (line_opt == null) return error.EndOfStream;
        defer allocator.free(line_opt.?);
        const line = std.mem.trim(u8, line_opt.?, "\r\n");
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
            const rest = std.mem.trim(u8, line["Content-Length:".len..], " ");
            content_length = try std.fmt.parseInt(usize, rest, 10);
        }
    }

    const len = content_length orelse return error.MissingContentLength;
    const msg = try allocator.alloc(u8, len);
    errdefer allocator.free(msg);
    try r.readNoEof(msg);
    return msg;
}

fn runCaptureStderr(allocator: Allocator, argv: []const []const u8, stderr_out: *std.ArrayList(u8)) !u8 {
    const res = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 10 * 1024 * 1024,
    });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    // Fun diagnostics historically used stderr, but some paths print to stdout;
    // merge both so we never lose messages.
    try stderr_out.appendSlice(res.stderr);
    try stderr_out.appendSlice(res.stdout);

    return switch (res.term) {
        .Exited => |code| @intCast(code),
        else => 1,
    };
}

const ParsedDiagnosticTag = struct {
    severity: i64,
    code: ?[]const u8 = null,
};

fn parseDiagnosticTag(line: []const u8) ?ParsedDiagnosticTag {
    if (line.len < 3) return null;
    if (line[0] != '[' or line[line.len - 1] != ']') return null;

    const inner = line[1 .. line.len - 1];
    var severity: i64 = 0;

    if (std.mem.startsWith(u8, inner, "Warning")) {
        severity = 2;
    } else if (std.mem.startsWith(u8, inner, "Error") or std.mem.startsWith(u8, inner, "TypeError")) {
        severity = 1;
    } else {
        return null;
    }

    var code: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, inner, ':')) |colon| {
        const raw = std.mem.trim(u8, inner[colon + 1 ..], " \t\r\n");
        if (raw.len != 0) code = raw;
    }

    return .{ .severity = severity, .code = code };
}

fn inferDiagnosticCodeFromMessage(message: []const u8) ?[]const u8 {
    if (isMissingAwaitDiagnosticMessage(message)) return "async_call_requires_await";
    if (isAwaitOutsideAsyncDiagnosticMessage(message)) return "await_outside_async_function";
    return null;
}

fn parseFunDiagnosticsByUri(allocator: Allocator, stderr_text: []const u8, current_uri: []const u8, tmp_name: []const u8) ![]DiagnosticWithUri {
    const current_path_opt = uriToPath(allocator, current_uri) catch null;
    defer if (current_path_opt) |p| allocator.free(p);
    const current_dir_opt = if (current_path_opt) |p| std.fs.path.dirname(p) else null;

    var diags = std.ArrayList(DiagnosticWithUri).init(allocator);
    errdefer {
        for (diags.items) |d| {
            allocator.free(d.uri);
            allocator.free(d.diag.message);
            if (d.diag.code) |c| allocator.free(c);
        }
        diags.deinit();
    }

    var it = std.mem.splitScalar(u8, stderr_text, '\n');
    var pending_severity: ?i64 = null;
    var pending_message: ?std.ArrayList(u8) = null;
    var pending_code: ?[]u8 = null;
    errdefer if (pending_message) |*m| m.deinit();
    errdefer if (pending_code) |c| allocator.free(c);

    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r\n");
        if (line.len == 0) continue;

        if (parseDiagnosticTag(line)) |tag| {
            pending_severity = tag.severity;
            if (pending_message) |*m| m.deinit();
            pending_message = null;
            if (pending_code) |c| allocator.free(c);
            pending_code = null;
            if (tag.code) |c| {
                pending_code = try allocator.dupe(u8, c);
            }
            continue;
        }

        if (pending_severity != null and pending_message == null and !std.mem.startsWith(u8, line, "Location:")) {
            var msg = std.ArrayList(u8).init(allocator);
            errdefer msg.deinit();
            try msg.appendSlice(line);
            pending_message = msg;
            continue;
        }

        if (pending_severity != null and pending_message != null and !std.mem.startsWith(u8, line, "Location:")) {
            try pending_message.?.append('\n');
            try pending_message.?.appendSlice(line);
            continue;
        }

        if (pending_severity != null and std.mem.startsWith(u8, line, "Location:")) {
            var loc = std.mem.trim(u8, line["Location:".len..], " ");
            if (loc.len == 0) {
                // Some diagnostics print `Location:` on its own line then the path on the next line.
                if (it.next()) |raw2| {
                    loc = std.mem.trim(u8, raw2, " \t\r\n");
                }
            }
            var file_part: []const u8 = "";
            var sl: i64 = 0;
            var sc: i64 = 0;
            var el: i64 = 0;
            var ec: i64 = 0;

            if (parseLocationWithFile(loc, &file_part, &sl, &sc, &el, &ec)) {
                const msg = if (pending_message) |*m| blk: {
                    const owned = try allocator.dupe(u8, m.items);
                    m.deinit();
                    pending_message = null;
                    break :blk owned;
                } else try allocator.dupe(u8, "diagnostic");

                const code = blk: {
                    if (pending_code) |c| {
                        pending_code = null;
                        break :blk @as(?[]u8, c);
                    }
                    if (inferDiagnosticCodeFromMessage(msg)) |inferred| {
                        break :blk try allocator.dupe(u8, inferred);
                    }
                    break :blk null;
                };

                const target_uri: []u8 = blk: {
                    if (std.mem.endsWith(u8, file_part, tmp_name)) break :blk try allocator.dupe(u8, current_uri);

                    // Absolute path? Convert directly.
                    if (std.fs.path.isAbsolute(file_part) or (file_part.len >= 2 and file_part[1] == ':')) {
                        const ap = std.fs.cwd().realpathAlloc(allocator, file_part) catch null;
                        if (ap) |abs_real| {
                            defer allocator.free(abs_real);
                            break :blk pathToUri(allocator, abs_real) catch try allocator.dupe(u8, current_uri);
                        }
                        break :blk pathToUri(allocator, file_part) catch try allocator.dupe(u8, current_uri);
                    }

                    // Relative path: resolve against current document directory.
                    if (current_dir_opt) |d| {
                        const joined = std.fs.path.join(allocator, &[_][]const u8{ d, file_part }) catch null;
                        if (joined) |j| {
                            defer allocator.free(j);
                            const ap2 = std.fs.cwd().realpathAlloc(allocator, j) catch null;
                            if (ap2) |abs_real2| {
                                defer allocator.free(abs_real2);
                                break :blk pathToUri(allocator, abs_real2) catch try allocator.dupe(u8, current_uri);
                            }
                            break :blk pathToUri(allocator, j) catch try allocator.dupe(u8, current_uri);
                        }
                    }

                    break :blk try allocator.dupe(u8, current_uri);
                };

                try diags.append(.{
                    .uri = target_uri,
                    .diag = .{
                        .range = .{
                            .start = .{ .line = sl - 1, .character = sc - 1 },
                            .end = .{ .line = el - 1, .character = ec - 1 },
                        },
                        .severity = pending_severity.?,
                        .message = msg,
                        .code = code,
                    },
                });
            }

            pending_severity = null;
            if (pending_message) |*m| m.deinit();
            pending_message = null;
            if (pending_code) |c| allocator.free(c);
            pending_code = null;
        }
    }

    if (pending_message) |*m| m.deinit();
    if (pending_code) |c| allocator.free(c);
    return diags.toOwnedSlice();
}

fn parseLocationWithFile(loc: []const u8, file_part: *[]const u8, start_line: *i64, start_col: *i64, end_line: *i64, end_col: *i64) bool {
    // Formats observed:
    // - <file>:<line>:<col>
    // - <file>:<line>:<start>-<end>
    // - <file>:<line>:<start>-<endLine>:<endCol>
    // Windows paths can contain ':' (drive letters), so we try split points from the right.

    var colons: [16]usize = undefined;
    var colon_len: usize = 0;
    for (loc, 0..) |ch, i| {
        if (ch != ':') continue;
        if (colon_len < colons.len) {
            colons[colon_len] = i;
            colon_len += 1;
        }
    }
    if (colon_len < 2) return false;

    // Choose a (file_end_colon, line_end_colon) pair that yields valid numbers.
    var j_idx: usize = colon_len;
    while (j_idx > 0) : (j_idx -= 1) {
        const j = colons[j_idx - 1]; // candidate separator between <file>:<line> and <rest>
        var i_idx: usize = j_idx - 1;
        while (i_idx > 0) : (i_idx -= 1) {
            const i = colons[i_idx - 1]; // candidate separator between <file> and <line>
            const file_candidate = std.mem.trim(u8, loc[0..i], " \t\r\n");
            if (file_candidate.len == 0) continue;

            const line_str = std.mem.trim(u8, loc[i + 1 .. j], " \t\r\n");
            const line = std.fmt.parseInt(i64, line_str, 10) catch continue;

            const rest = std.mem.trim(u8, loc[j + 1 ..], " \t\r\n");
            if (rest.len == 0) continue;

            // rest: <col> OR <start>-<end> OR <start>-<endLine>:<endCol>
            if (std.mem.indexOfScalar(u8, rest, '-')) |dash| {
                const start_str = std.mem.trim(u8, rest[0..dash], " \t\r\n");
                const end_str = std.mem.trim(u8, rest[dash + 1 ..], " \t\r\n");

                const s_col = std.fmt.parseInt(i64, start_str, 10) catch continue;

                // end_str could be "<end>" or "<endLine>:<endCol>"
                if (std.mem.indexOfScalar(u8, end_str, ':')) |cidx| {
                    const end_line_str = std.mem.trim(u8, end_str[0..cidx], " \t\r\n");
                    const end_col_str = std.mem.trim(u8, end_str[cidx + 1 ..], " \t\r\n");
                    const el = std.fmt.parseInt(i64, end_line_str, 10) catch continue;
                    const ec = std.fmt.parseInt(i64, end_col_str, 10) catch continue;

                    file_part.* = file_candidate;
                    start_line.* = line;
                    start_col.* = s_col;
                    end_line.* = el;
                    end_col.* = ec;
                    return true;
                }

                const e_col = std.fmt.parseInt(i64, end_str, 10) catch continue;
                file_part.* = file_candidate;
                start_line.* = line;
                start_col.* = s_col;
                end_line.* = line;
                end_col.* = e_col;
                return true;
            }

            // Single-point location.
            const col = std.fmt.parseInt(i64, rest, 10) catch continue;
            file_part.* = file_candidate;
            start_line.* = line;
            start_col.* = col;
            end_line.* = line;
            end_col.* = col + 1;
            return true;
        }
    }

    return false;
}

fn tryApplyRangedEdit(allocator: Allocator, text: []const u8, start_pos: Position, end_pos: Position, new_text: []const u8) !?[]u8 {
    const start_b = byteIndexForPosition(text, start_pos);
    const end_b = byteIndexForPosition(text, end_pos);
    if (start_b > end_b or end_b > text.len) return null;

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice(text[0..start_b]);
    try out.appendSlice(new_text);
    try out.appendSlice(text[end_b..]);
    return try out.toOwnedSlice();
}

test "fls: byteIndexForPosition handles CRLF" {
    const text = "a\r\nb\r\nc";

    try std.testing.expectEqual(@as(usize, 0), byteIndexForPosition(text, .{ .line = 0, .character = 0 }));
    try std.testing.expectEqual(@as(usize, 1), byteIndexForPosition(text, .{ .line = 0, .character = 1 }));

    // Start of line 1 is after "a\r\n".
    try std.testing.expectEqual(@as(usize, 3), byteIndexForPosition(text, .{ .line = 1, .character = 0 }));
    try std.testing.expectEqual(@as(usize, 4), byteIndexForPosition(text, .{ .line = 1, .character = 1 }));
}

test "fls: apply ranged edit (multi-line)" {
    const allocator = std.testing.allocator;
    const text = "hello\r\nworld\r\n";
    const start: Position = .{ .line = 0, .character = 5 };
    const end: Position = .{ .line = 1, .character = 5 };
    const updated = (try tryApplyRangedEdit(allocator, text, start, end, "!\r\nFUN")) orelse return error.TestUnexpectedResult;
    defer allocator.free(updated);

    try std.testing.expect(std.mem.eql(u8, updated, "hello!\r\nFUN\r\n"));
}

test "fls: parse import spec from tokens" {
    const allocator = std.testing.allocator;
    const src = "imp std.c.io;\n";
    const idx = try buildIndexFromText(allocator, src);
    defer idx.deinit();

    var server: LspServer = .{
        .allocator = allocator,
        .docs = std.StringHashMap(Doc).init(allocator),
        .stdin = std.io.getStdIn(),
        .stdout = std.io.getStdOut(),
        .fun_exe_path = try allocator.dupe(u8, "fun"),
        .published_diag_uris = std.StringHashMap(void).init(allocator),
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
    try tmp.dir.makePath("stdlib/std/c");
    {
        var f = try tmp.dir.createFile("stdlib/std/c/io.fn", .{ .read = true, .truncate = true });
        defer f.close();
        try f.writeAll("// std io\n");
    }

    // Create: <root>/examples/main.fn
    try tmp.dir.makePath("examples");
    {
        var f2 = try tmp.dir.createFile("examples/main.fn", .{ .read = true, .truncate = true });
        defer f2.close();
        try f2.writeAll("imp std.c.io;\n");
    }

    const root_abs = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root_abs);
    const current_abs = try tmp.dir.realpathAlloc(allocator, "examples/main.fn");
    defer allocator.free(current_abs);
    const std_abs = try tmp.dir.realpathAlloc(allocator, "stdlib/std/c/io.fn");
    defer allocator.free(std_abs);

    const current_uri = try pathToUri(allocator, current_abs);
    defer allocator.free(current_uri);
    const expected_uri = try pathToUri(allocator, std_abs);
    defer allocator.free(expected_uri);

    var server: LspServer = .{
        .allocator = allocator,
        .docs = std.StringHashMap(Doc).init(allocator),
        .stdin = std.io.getStdIn(),
        .stdout = std.io.getStdOut(),
        .fun_exe_path = try allocator.dupe(u8, "fun"),
        .published_diag_uris = std.StringHashMap(void).init(allocator),
        .root_uri = null,
        .root_path = try allocator.dupe(u8, root_abs),
    };
    defer server.deinit();

    const resolved = (try server.resolveImportUri(current_uri, "std.c.io")) orelse return error.TestUnexpectedResult;
    defer allocator.free(resolved);
    try std.testing.expect(std.mem.eql(u8, resolved, expected_uri));
}

test "fls: parseFunDiagnosticsByUri maps tmp file to current uri" {
    if (_skip_lsp_tests_in_ci) return;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    {
        var f = try tmp.dir.createFile("src/main.fn", .{ .read = true, .truncate = true });
        defer f.close();
        try f.writeAll("// file\n");
    }

    const current_abs = try tmp.dir.realpathAlloc(allocator, "src/main.fn");
    defer allocator.free(current_abs);
    const current_uri = try pathToUri(allocator, current_abs);
    defer allocator.free(current_uri);

    const stderr_text = "[TypeError]\nboom\nLocation: _fls_tmp.fn:2:1-2\n";
    const diags = try parseFunDiagnosticsByUri(allocator, stderr_text, current_uri, "_fls_tmp.fn");
    defer {
        for (diags) |d| {
            allocator.free(d.uri);
            allocator.free(d.diag.message);
            if (d.diag.code) |c| allocator.free(c);
        }
        allocator.free(diags);
    }

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expect(std.mem.eql(u8, diags[0].uri, current_uri));
    try std.testing.expect(std.mem.eql(u8, diags[0].diag.message, "boom"));
    try std.testing.expectEqual(@as(i64, 1), diags[0].diag.severity);
    try std.testing.expect(diags[0].diag.code == null);
    try std.testing.expectEqual(@as(i64, 1), diags[0].diag.range.start.line);
    try std.testing.expectEqual(@as(i64, 0), diags[0].diag.range.start.character);
}

test "fls: parseFunDiagnosticsByUri supports warning IDs" {
    if (_skip_lsp_tests_in_ci) return;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    {
        var f = try tmp.dir.createFile("src/main.fn", .{ .read = true, .truncate = true });
        defer f.close();
        try f.writeAll("// file\n");
    }

    const current_abs = try tmp.dir.realpathAlloc(allocator, "src/main.fn");
    defer allocator.free(current_abs);
    const current_uri = try pathToUri(allocator, current_abs);
    defer allocator.free(current_uri);

    const stderr_text = "[Warning:return_local_ptr]\nboom\nLocation: _fls_tmp.fn:2:1-2\n";
    const diags = try parseFunDiagnosticsByUri(allocator, stderr_text, current_uri, "_fls_tmp.fn");
    defer {
        for (diags) |d| {
            allocator.free(d.uri);
            allocator.free(d.diag.message);
            if (d.diag.code) |c| allocator.free(c);
        }
        allocator.free(diags);
    }

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expect(std.mem.eql(u8, diags[0].uri, current_uri));
    try std.testing.expect(std.mem.eql(u8, diags[0].diag.message, "boom"));
    try std.testing.expectEqual(@as(i64, 2), diags[0].diag.severity);
    try std.testing.expect(diags[0].diag.code != null);
    try std.testing.expect(std.mem.eql(u8, diags[0].diag.code.?, "return_local_ptr"));
    try std.testing.expectEqual(@as(i64, 1), diags[0].diag.range.start.line);
    try std.testing.expectEqual(@as(i64, 0), diags[0].diag.range.start.character);
}

test "fls: parseFunDiagnosticsByUri infers async diagnostic code" {
    if (_skip_lsp_tests_in_ci) return;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    {
        var f = try tmp.dir.createFile("src/main.fn", .{ .read = true, .truncate = true });
        defer f.close();
        try f.writeAll("// file\n");
    }

    const current_abs = try tmp.dir.realpathAlloc(allocator, "src/main.fn");
    defer allocator.free(current_abs);
    const current_uri = try pathToUri(allocator, current_abs);
    defer allocator.free(current_uri);

    const stderr_text = "[TypeError]\ncall to async function 'inc' must be awaited\nLocation: _fls_tmp.fn:2:1-2\n";
    const diags = try parseFunDiagnosticsByUri(allocator, stderr_text, current_uri, "_fls_tmp.fn");
    defer {
        for (diags) |d| {
            allocator.free(d.uri);
            allocator.free(d.diag.message);
            if (d.diag.code) |c| allocator.free(c);
        }
        allocator.free(diags);
    }

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expect(diags[0].diag.code != null);
    try std.testing.expect(std.mem.eql(u8, diags[0].diag.code.?, "async_call_requires_await"));
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

test "fls: tryApplyRangedEdit rejects invalid ranges" {
    if (_skip_lsp_tests_in_ci) return;
    const allocator = std.testing.allocator;
    const text = "abc\n";
    // start after end -> null
    const bad = try tryApplyRangedEdit(allocator, text, .{ .line = 1, .character = 0 }, .{ .line = 0, .character = 0 }, "x");
    try std.testing.expect(bad == null);
}

test "fls: parseLocationWithFile handles Windows drive letters" {
    if (_skip_lsp_tests_in_ci) return;
    var file_part: []const u8 = "";
    var sl: i64 = 0;
    var sc: i64 = 0;
    var el: i64 = 0;
    var ec: i64 = 0;

    const ok = parseLocationWithFile("C:\\proj\\src\\main.fn:12:3-13:5", &file_part, &sl, &sc, &el, &ec);
    try std.testing.expect(ok);
    try std.testing.expect(std.mem.eql(u8, file_part, "C:\\proj\\src\\main.fn"));
    try std.testing.expectEqual(@as(i64, 12), sl);
    try std.testing.expectEqual(@as(i64, 3), sc);
    try std.testing.expectEqual(@as(i64, 13), el);
    try std.testing.expectEqual(@as(i64, 5), ec);
}

test "fls: parseFunDiagnosticsByUri supports multiline messages and Location split line" {
    if (_skip_lsp_tests_in_ci) return;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    {
        var f = try tmp.dir.createFile("src/main.fn", .{ .read = true, .truncate = true });
        defer f.close();
        try f.writeAll("// file\n");
    }
    {
        var f2 = try tmp.dir.createFile("src/other.fn", .{ .read = true, .truncate = true });
        defer f2.close();
        try f2.writeAll("// other\n");
    }

    const current_abs = try tmp.dir.realpathAlloc(allocator, "src/main.fn");
    defer allocator.free(current_abs);
    const current_uri = try pathToUri(allocator, current_abs);
    defer allocator.free(current_uri);

    const stderr_text =
        "[Error]\n" ++
        "first line\n" ++
        "second line\n" ++
        "Location:\n" ++
        "other.fn:1:1-1:2\n";

    const diags = try parseFunDiagnosticsByUri(allocator, stderr_text, current_uri, "_fls_any.fn");
    defer {
        for (diags) |d| {
            allocator.free(d.uri);
            allocator.free(d.diag.message);
            if (d.diag.code) |c| allocator.free(c);
        }
        allocator.free(diags);
    }

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    // Work with a real filesystem path (URIs include a scheme and aren't suitable for std.fs.path helpers).
    const diag_path = try uriToPath(allocator, diags[0].uri);
    defer allocator.free(diag_path);

    // Normalize all slashes to '/'
    const slash_buf = try allocator.dupe(u8, diag_path);
    defer allocator.free(slash_buf);
    for (slash_buf) |*c| {
        if (c.* == '\\') {
            c.* = '/';
        }
    }
    // removed unused last_slash
    // Removed unused 'last2' variable
    const filename = std.fs.path.basename(slash_buf);
    const parent = std.fs.path.dirname(slash_buf) orelse "";
    const parent_name = std.fs.path.basename(parent);
    const last2_joined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent_name, filename });
    defer allocator.free(last2_joined);
    try std.testing.expect(std.mem.eql(u8, last2_joined, "src/other.fn"));
    try std.testing.expect(std.mem.eql(u8, diags[0].diag.message, "first line\nsecond line"));
}

test "fls: resolveImportUri relative imports" {
    if (_skip_lsp_tests_in_ci) return;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sep = std.fs.path.sep;
    const examples_dir = try std.fmt.allocPrint(allocator, "examples{c}utils", .{sep});
    defer allocator.free(examples_dir);
    try tmp.dir.makePath(examples_dir);
    const main_fn = try std.fmt.allocPrint(allocator, "examples{c}main.fn", .{sep});
    defer allocator.free(main_fn);
    const math_fn = try std.fmt.allocPrint(allocator, "examples{c}utils{c}math.fn", .{ sep, sep });
    defer allocator.free(math_fn);
    {
        var f = try tmp.dir.createFile(main_fn, .{ .read = true, .truncate = true });
        defer f.close();
        try f.writeAll("imp utils.math;\n");
    }
    {
        var f2 = try tmp.dir.createFile(math_fn, .{ .read = true, .truncate = true });
        defer f2.close();
        try f2.writeAll("// math\n");
    }
    const root_abs = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root_abs);
    const current_abs = try tmp.dir.realpathAlloc(allocator, main_fn);
    defer allocator.free(current_abs);
    const expected_abs = try tmp.dir.realpathAlloc(allocator, math_fn);
    defer allocator.free(expected_abs);

    const current_uri = try pathToUri(allocator, current_abs);
    defer allocator.free(current_uri);
    const expected_uri = try pathToUri(allocator, expected_abs);
    defer allocator.free(expected_uri);

    var server: LspServer = .{
        .allocator = allocator,
        .docs = std.StringHashMap(Doc).init(allocator),
        .stdin = std.io.getStdIn(),
        .stdout = std.io.getStdOut(),
        .fun_exe_path = try allocator.dupe(u8, "fun"),
        .published_diag_uris = std.StringHashMap(void).init(allocator),
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
    try tmp.dir.makePath("src");
    {
        var f = try tmp.dir.createFile("src/main.fn", .{ .read = true, .truncate = true });
        defer f.close();
        try f.writeAll("imp std.c.io;\n");
    }
    const current_abs = try tmp.dir.realpathAlloc(allocator, "src/main.fn");
    defer allocator.free(current_abs);
    const current_uri = try pathToUri(allocator, current_abs);
    defer allocator.free(current_uri);

    // Seed an invalid stdlib root so resolution can't succeed via env/workspace/cwd.
    const tmp_root_abs = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_root_abs);
    const bogus_stdlib = try std.fs.path.join(allocator, &.{ tmp_root_abs, "__not_a_stdlib__" });
    defer allocator.free(bogus_stdlib);

    var server: LspServer = .{
        .allocator = allocator,
        .docs = std.StringHashMap(Doc).init(allocator),
        .stdin = std.io.getStdIn(),
        .stdout = std.io.getStdOut(),
        .fun_exe_path = try allocator.dupe(u8, "fun"),
        .published_diag_uris = std.StringHashMap(void).init(allocator),
        .root_uri = null,
        .root_path = null,
        .stdlib_root_path = try allocator.dupe(u8, bogus_stdlib),
    };
    defer server.deinit();

    const resolved = try server.resolveImportUri(current_uri, "std.c.io");
    defer if (resolved) |r| allocator.free(r);
    try std.testing.expect(resolved == null);
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

fn findSiblingOrPathExe(allocator: Allocator, base_name: []const u8) ![]u8 {
    // 1) If `FLS_FUN_PATH` is set, use that.
    if (std.process.getEnvVarOwned(allocator, "FLS_FUN_PATH")) |p| {
        return p;
    } else |_| {}

    // 2) Try sibling next to fls exe.
    const exe_dir = std.fs.selfExeDirPathAlloc(allocator) catch null;
    if (exe_dir) |dir| {
        defer allocator.free(dir);

        const name = if (@import("builtin").target.os.tag == .windows)
            try std.fmt.allocPrint(allocator, "{s}.exe", .{base_name})
        else
            try allocator.dupe(u8, base_name);
        defer allocator.free(name);

        const full = try std.fs.path.join(allocator, &[_][]const u8{ dir, name });
        errdefer allocator.free(full);

        sibling_check: {
            std.fs.cwd().access(full, .{}) catch {
                allocator.free(full);
                break :sibling_check;
            };
            return full;
        }
    }

    // 3) Fall back to PATH lookup.
    return try findOnPath(allocator, base_name);
}

fn findOnPath(allocator: Allocator, base_name: []const u8) ![]u8 {
    const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch return error.FileNotFound;
    defer allocator.free(path_env);

    const exe_name = if (@import("builtin").target.os.tag == .windows)
        try std.fmt.allocPrint(allocator, "{s}.exe", .{base_name})
    else
        try allocator.dupe(u8, base_name);
    defer allocator.free(exe_name);

    const sep: u8 = if (@import("builtin").target.os.tag == .windows) ';' else ':';
    var it = std.mem.splitScalar(u8, path_env, sep);
    while (it.next()) |dir_raw| {
        const dir = std.mem.trim(u8, dir_raw, " \t\r\n\"");
        if (dir.len == 0) continue;

        const full = try std.fs.path.join(allocator, &[_][]const u8{ dir, exe_name });
        errdefer allocator.free(full);

        std.fs.cwd().access(full, .{}) catch {
            allocator.free(full);
            continue;
        };
        return full;
    }

    return error.FileNotFound;
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try std.json.stringify(s, .{}, w);
}

fn writeRangeJson(w: anytype, r: Range) !void {
    try w.print(
        "{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ r.start.line, r.start.character, r.end.line, r.end.character },
    );
}

fn isUriUnreserved(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or
        ch == '-' or ch == '_' or ch == '.' or ch == '~' or ch == '/' or ch == ':';
}

fn pathToUri(allocator: Allocator, path_raw: []const u8) ![]u8 {
    // Cross-platform file:// URI builder.
    // We percent-encode non-unreserved bytes (spaces, etc.) to keep editors happy.
    //
    // Windows absolute paths:  C:\Users\me\x  -> file:///C:/Users/me/x
    // POSIX absolute paths:    /home/me/x      -> file:///home/me/x
    const builtin = @import("builtin");

    const tmp = try allocator.dupe(u8, path_raw);
    defer allocator.free(tmp);
    for (tmp) |*c| {
        if (c.* == '\\') c.* = '/';
    }

    const is_windows_drive = tmp.len >= 3 and
        ((tmp[0] >= 'A' and tmp[0] <= 'Z') or (tmp[0] >= 'a' and tmp[0] <= 'z')) and
        tmp[1] == ':' and tmp[2] == '/';

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice("file:///");

    const path_part: []const u8 = if (is_windows_drive)
        tmp
    else if (builtin.os.tag == .windows)
        // On Windows, treat non-drive absolute paths as-is.
        tmp
    else if (tmp.len != 0 and tmp[0] == '/')
        // Avoid emitting file:////... on POSIX.
        tmp[1..]
    else
        tmp;

    for (path_part) |ch| {
        if (isUriUnreserved(ch)) {
            try out.append(ch);
        } else {
            try out.writer().print("%{X:0>2}", .{ch});
        }
    }

    return out.toOwnedSlice();
}

fn hexValue(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => 10 + (ch - 'a'),
        'A'...'F' => 10 + (ch - 'A'),
        else => null,
    };
}

fn uriToPath(allocator: Allocator, uri: []const u8) ![]u8 {
    // Cross-platform file:// URI parser.
    // Accepts file:///... (no authority) and file://localhost/... .
    const builtin = @import("builtin");

    if (!std.mem.startsWith(u8, uri, "file://")) return error.UnsupportedUri;

    var rest = uri["file://".len..];
    if (std.mem.startsWith(u8, rest, "localhost/")) {
        rest = rest["localhost/".len..];
    }
    // We expect an absolute-path form with a leading '/'. If it's missing, treat as unsupported.
    if (rest.len == 0 or rest[0] != '/') return error.UnsupportedUri;

    // Strip the leading '/' from the URI path component for decoding.
    const path_no_leading = rest[1..];

    // Detect Windows drive in the URI path: /C:/...
    const is_windows_drive = path_no_leading.len >= 3 and
        ((path_no_leading[0] >= 'A' and path_no_leading[0] <= 'Z') or (path_no_leading[0] >= 'a' and path_no_leading[0] <= 'z')) and
        path_no_leading[1] == ':' and path_no_leading[2] == '/';

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    if (!is_windows_drive and builtin.os.tag != .windows) {
        // POSIX absolute path.
        try out.append('/');
    }

    var i: usize = 0;
    while (i < path_no_leading.len) : (i += 1) {
        const ch = path_no_leading[i];
        if (ch == '%' and i + 2 < path_no_leading.len) {
            const hi = hexValue(path_no_leading[i + 1]);
            const lo = hexValue(path_no_leading[i + 2]);
            if (hi != null and lo != null) {
                const decoded = (hi.? << 4) | lo.?;
                try out.append(if (builtin.os.tag == .windows and decoded == '/') '\\' else decoded);
                i += 2;
                continue;
            }
        }

        if (builtin.os.tag == .windows and ch == '/') {
            try out.append('\\');
        } else {
            try out.append(ch);
        }
    }

    return out.toOwnedSlice();
}

fn posInRange(p: Position, r: Range) bool {
    if (p.line < r.start.line or p.line > r.end.line) return false;
    if (p.line == r.start.line and p.character < r.start.character) return false;
    // LSP ranges are end-exclusive.
    if (p.line == r.end.line and p.character >= r.end.character) return false;
    return true;
}

fn findTokenAt(tokens: []const TokenLite, p: Position) ?TokenLite {
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

fn findTokenIndexAt(tokens: []const TokenLite, p: Position) ?usize {
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

fn isDotToken(t: TokenLite) bool {
    return (t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, ".");
}

fn nextNonTrivialTokenLite(tokens: []const TokenLite, start_index: usize) ?usize {
    var i = start_index;
    while (i < tokens.len) : (i += 1) {
        const t = tokens[i];
        if (t.kind == .comment) continue;
        return i;
    }
    return null;
}

fn prevNonTrivialTokenLite(tokens: []const TokenLite, start_index: usize) ?usize {
    if (start_index == 0) return null;
    var i: isize = @as(isize, @intCast(start_index)) - 1;
    while (i >= 0) : (i -= 1) {
        const t = tokens[@intCast(i)];
        if (t.kind == .comment) continue;
        return @intCast(i);
    }
    return null;
}

fn findMatchingRParenLite(tokens: []const TokenLite, lparen_i: usize) ?usize {
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

fn findMatchingLParenLite(tokens: []const TokenLite, rparen_i: usize) ?usize {
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

fn skipGenericArgsLite(tokens: []const TokenLite, start_index: usize) usize {
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

fn concreteGenericTypeAtToken(allocator: Allocator, tokens: []const TokenLite, tok_i: usize) !?[]u8 {
    if (tok_i >= tokens.len) return null;
    const base_tok = tokens[tok_i];
    if (base_tok.kind != .identifier) return null;

    const lt_i = nextNonTrivialTokenLite(tokens, tok_i + 1) orelse return null;
    const lt_tok = tokens[lt_i];
    if (!((lt_tok.kind == .symbol or lt_tok.kind == .operator) and std.mem.eql(u8, lt_tok.text, "<"))) {
        return null;
    }

    var out = std.ArrayList(u8).init(allocator);
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

fn concreteGenericTypeSliceAtPosition(text: []const u8, p: Position) ?[]const u8 {
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

fn findLastTokenIndexBeforeOrAt(tokens: []const TokenLite, p: Position) ?usize {
    var last: ?usize = null;
    for (tokens, 0..) |t, i| {
        if (t.range.start.line > p.line) break;
        if (t.range.start.line == p.line and t.range.start.character > p.character) break;
        last = i;
    }
    return last;
}

fn rangeFromTokenPos(p: token.Pos) Range {
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

fn rangeStartLessOrEqual(a: Range, p: Position) bool {
    if (a.start.line < p.line) return true;
    if (a.start.line > p.line) return false;
    return a.start.character <= p.character;
}

fn rangeStartGreater(a: Range, b: Range) bool {
    if (a.start.line != b.start.line) return a.start.line > b.start.line;
    return a.start.character > b.start.character;
}

fn rangeStartEqual(a: Range, b: Range) bool {
    return a.start.line == b.start.line and a.start.character == b.start.character;
}

fn rangeEqual(a: Range, b: Range) bool {
    return a.start.line == b.start.line and a.start.character == b.start.character and
        a.end.line == b.end.line and a.end.character == b.end.character;
}

fn findEnclosingFunctionAsyncInsertPosFromTokens(tokens: []const TokenLite, target_line: i64) ?Position {
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

fn isBuiltinTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "void") or std.mem.eql(u8, name, "raw") or std.mem.eql(u8, name, "num") or
        std.mem.eql(u8, name, "dec") or std.mem.eql(u8, name, "str") or std.mem.eql(u8, name, "bin") or
        std.mem.eql(u8, name, "chr") or std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "f64") or
        std.mem.eql(u8, name, "i8") or std.mem.eql(u8, name, "i16") or std.mem.eql(u8, name, "i32") or
        std.mem.eql(u8, name, "i64") or std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "u16") or
        std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "u64");
}

fn isLetInferTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "__let_infer__");
}

fn preferDetailedSymbol(a: SymbolLite, b: SymbolLite) bool {
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

fn hasNonBuiltinValueType(s: SymbolLite) bool {
    if (s.value_type == null) return false;
    const vt = s.value_type.?;
    if (isLetInferTypeName(vt)) return false;
    return !isBuiltinTypeName(vt);
}

fn numericBuiltinRank(name: []const u8) u8 {
    if (std.mem.eql(u8, name, "dec")) return 2;
    if (std.mem.eql(u8, name, "num")) return 1;
    return 0;
}

fn findBestDefinition(symbols: []const SymbolLite, name: []const u8, at: Position) ?SymbolLite {
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

fn findAnyGlobalDefinition(symbols: []const SymbolLite, name: []const u8) ?SymbolLite {
    for (symbols) |s| {
        if (s.container_fn_range != null) continue;
        if (!std.mem.eql(u8, s.name, name)) continue;
        return s;
    }
    return null;
}

fn byteIndexForPosition(text: []const u8, p: Position) usize {
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

fn guessIdentifierPrefix(text: []const u8, p: Position) []const u8 {
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

fn guessTypeFromTextFallback(text: []const u8, name: []const u8, at: Position) ?[]const u8 {
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

fn guessReceiverNameBeforeCursor(text: []const u8, p: Position) ?[]const u8 {
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

fn guessReceiverNameAtCursor(text: []const u8, p: Position) ?[]const u8 {
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

const ReceiverGuess = struct {
    name: []const u8,
    indexed: bool,
};

fn guessReceiverAtCursorWithIndex(text: []const u8, p: Position) ?ReceiverGuess {
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

fn isMissingAwaitDiagnosticCode(code_opt: ?[]const u8) bool {
    const code = code_opt orelse return false;
    return std.mem.eql(u8, code, "async_call_requires_await");
}

fn isAwaitOutsideAsyncDiagnosticCode(code_opt: ?[]const u8) bool {
    const code = code_opt orelse return false;
    return std.mem.eql(u8, code, "await_outside_async_function");
}

fn isMissingAwaitDiagnosticMessage(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "must be awaited") != null and
        std.mem.indexOf(u8, message, "async function") != null;
}

fn isAwaitOutsideAsyncDiagnosticMessage(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "await is only allowed inside async functions") != null;
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

var fls_temp_cleanup_done: bool = false;
var fls_temp_dir_warned: bool = false;
var fls_temp_dir_announced: bool = false;
var fls_temp_dir_cache_init_done: bool = false;
var fls_temp_dir_cache: ?FlsTempDir = null;

const FlsTempDir = struct {
    dir: std.fs.Dir,
    abs_path: []const u8,
};

fn tryOpenFlsTempDir(alloc: Allocator) !?FlsTempDir {
    const is_windows = @import("builtin").target.os.tag == .windows;

    const Try = struct {
        fn openSub(alloc_inner: Allocator, root_path: []const u8) !?FlsTempDir {
            const base_dir_opt = std.fs.openDirAbsolute(root_path, .{}) catch null;
            if (base_dir_opt) |bd| {
                var bd_mut = bd;
                defer bd_mut.close();

                bd_mut.makeDir("fun-fls") catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => return null,
                };

                const abs_path = try std.fs.path.join(alloc_inner, &.{ root_path, "fun-fls" });
                const d = std.fs.openDirAbsolute(abs_path, .{ .iterate = true }) catch return null;
                return .{ .dir = d, .abs_path = abs_path };
            }
            return null;
        }
    };

    const env_try = struct {
        fn get(alloc_inner: Allocator, name: []const u8) ?[]const u8 {
            return std.process.getEnvVarOwned(alloc_inner, name) catch null;
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

fn getOrInitFlsTempDirCached() ?FlsTempDir {
    if (fls_temp_dir_cache_init_done) return fls_temp_dir_cache;
    fls_temp_dir_cache_init_done = true;

    // Cache allocations live for the lifetime of the process.
    // This avoids reallocating/joining paths and reopening the directory on every keystroke.
    const cache_alloc = std.heap.page_allocator;
    fls_temp_dir_cache = tryOpenFlsTempDir(cache_alloc) catch null;

    const debug_env = std.process.getEnvVarOwned(cache_alloc, "FUN_FLS_DEBUG") catch null;
    const debug_on = if (debug_env) |v| std.mem.eql(u8, v, "1") else false;

    if (fls_temp_dir_cache) |res| {
        if (debug_on and !fls_temp_dir_announced) {
            fls_temp_dir_announced = true;
            std.debug.print("[fls] temp dir: {s}\n", .{res.abs_path});
        }
        // One-time best-effort cleanup of stale leftovers.
        var d = res.dir;
        maybeCleanupFlsTempDir(&d);
    } else if (debug_on and !fls_temp_dir_warned) {
        fls_temp_dir_warned = true;
        std.debug.print("[fls] warning: could not open OS temp dir; using process CWD for temp files\n", .{});
    }

    return fls_temp_dir_cache;
}

fn maybeCleanupFlsTempDir(dir: *std.fs.Dir) void {
    if (fls_temp_cleanup_done) return;
    fls_temp_cleanup_done = true;

    const now_ns: i128 = std.time.nanoTimestamp();
    // Delete only sufficiently old leftovers to avoid interfering with another running instance.
    // Files are normally deleted immediately; these are only meant to catch crash/kill residue.
    const max_age_ns: i128 = 30 * std.time.ns_per_min;

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
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
            dir.deleteFile(name) catch {};
        }
    }
}

fn buildIndexFromText(allocator: Allocator, text: []const u8) !*Index {
    return buildIndexFromTextAt(allocator, text, null, .open_document);
}

const IndexBuildScope = enum {
    open_document,
    background,
};

fn buildIndexFromTextAt(allocator: Allocator, text: []const u8, tmp_dir_path_opt: ?[]const u8, scope: IndexBuildScope) !*Index {
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
    var tmp_dir = std.fs.cwd();
    var tmp_dir_path: ?[]const u8 = null;

    if (tmp_dir_path_opt) |p| {
        if (std.fs.path.isAbsolute(p)) {
            tmp_dir = try std.fs.openDirAbsolute(p, .{});
            defer tmp_dir.close();
            tmp_dir_path = p;
        }
    } else if (getOrInitFlsTempDirCached()) |res| {
        tmp_dir = res.dir;
        tmp_dir_path = res.abs_path;
    }
    var tmp_name_buf: [96]u8 = undefined;
    const stamp = std.time.nanoTimestamp();
    const nonce: u64 = std.crypto.random.int(u64);
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
        const f = try tmp_dir.createFile(tmp_name, .{ .read = true, .truncate = true });
        defer f.close();
        try f.writeAll(text);
    }
    defer tmp_dir.deleteFile(tmp_name) catch {};
    defer tmp_dir.deleteFile(out_name) catch {};

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

    var tokens_out = std.ArrayList(TokenLite).init(tmp_alloc);
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

        if (std.process.getEnvVarOwned(tmp_alloc, "FLS_ENABLE_INPROC_PARSE")) |raw_global| {
            defer tmp_alloc.free(raw_global);
            break :blk isTruthy(raw_global);
        } else |_| {}

        if (std.process.getEnvVarOwned(tmp_alloc, "FLS_PARSE_SCOPE")) |raw_scope| {
            defer tmp_alloc.free(raw_scope);
            const s = std.mem.trim(u8, raw_scope, " \t\r\n");
            if (s.len == 0) break :blk false;
            if (std.ascii.eqlIgnoreCase(s, "none")) break :blk false;
            if (std.ascii.eqlIgnoreCase(s, "all")) break :blk true;
            if (std.ascii.eqlIgnoreCase(s, "open")) break :blk scope == .open_document;
        } else |_| {}

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

    var symbols_out = std.ArrayList(SymbolLite).init(tmp_alloc);

    // Always do lexer-driven indexing first (robust while typing), then optionally
    // overlay/replace globals+locals with AST-backed symbols.
    var symbols_token = std.ArrayList(SymbolLite).init(tmp_alloc);
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

fn fixAstVariableRanges(tokens: []const TokenLite, symbols: *std.ArrayList(SymbolLite)) void {
    for (symbols.items) |*s| {
        if (s.kind != .variable) continue;

        var best: ?Range = null;
        for (tokens) |t| {
            if (t.kind != .identifier) continue;
            if (!std.mem.eql(u8, t.text, s.name)) continue;

            if (s.container_fn_range) |cr| {
                if (!posInRange(t.range.start, cr)) continue;
            }

            if (t.range.start.line < s.decl_range.start.line) continue;
            if (t.range.start.line == s.decl_range.start.line and t.range.start.character < s.decl_range.start.character) continue;

            if (best == null or rangeStartGreater(best.?, t.range)) {
                best = t.range;
            }
        }

        if (best) |r| {
            s.selection_range = r;
            s.decl_range = r;
        }
    }
}

const AstEnrichment = struct {
    fn_sig_by_name: std.StringHashMap([]const u8),
    fn_rtype_by_name: std.StringHashMap([]const u8),
    member_sig_by_key: std.StringHashMap([]const u8),
    member_rtype_by_key: std.StringHashMap([]const u8),
    field_type_by_key: std.StringHashMap([]const u8),

    fn init(allocator: Allocator) AstEnrichment {
        return .{
            .fn_sig_by_name = std.StringHashMap([]const u8).init(allocator),
            .fn_rtype_by_name = std.StringHashMap([]const u8).init(allocator),
            .member_sig_by_key = std.StringHashMap([]const u8).init(allocator),
            .member_rtype_by_key = std.StringHashMap([]const u8).init(allocator),
            .field_type_by_key = std.StringHashMap([]const u8).init(allocator),
        };
    }
};

fn appendDTypeFull(buf: *std.ArrayList(u8), dt: anytype) !void {
    const dtype = if (@typeInfo(@TypeOf(dt)) == .pointer) dt.* else dt;
    try buf.appendSlice(dtype.type_str.items);
    if (@hasField(@TypeOf(dtype), "generic_args")) {
        if (dtype.generic_args) |gargs| {
            try buf.append('<');
            for (gargs.items(), 0..) |ga, i| {
                if (i != 0) try buf.appendSlice(", ");
                try appendDTypeFull(buf, ga.*);
            }
            try buf.append('>');
        }
    }
    var i: usize = 0;
    while (i < dtype.pointer_depth) : (i += 1) {
        try buf.append('*');
    }
    if (@hasField(@TypeOf(dtype), "flags")) {
        if (dtype.flags) |flags| {
            if (flags.is_array) {
                if (@hasField(@TypeOf(dtype), "array")) {
                    if (dtype.array) |arr| {
                        const count: usize = if (arr.brackets.is_empty()) 1 else arr.brackets.count;
                        var j: usize = 0;
                        while (j < count) : (j += 1) {
                            try buf.appendSlice("[]");
                        }
                        return;
                    }
                }
                try buf.appendSlice("[]");
            }
        }
    }
}

fn enrichSymbolsFromAst(allocator: Allocator, symbols: *std.ArrayList(SymbolLite), tp: *codegen.TranspileProcess) !void {
    var enrich = AstEnrichment.init(allocator);

    const dtypeStringOwned = struct {
        fn build(a: Allocator, dt: anytype) ![]u8 {
            var buf = std.ArrayList(u8).init(a);
            errdefer buf.deinit();
            try appendDTypeFull(&buf, dt);
            return try buf.toOwnedSlice();
        }
    };

    // Build lookup tables from the parsed AST.
    for (tp.nodes.items()) |*n| {
        if (n.node_variant == null) continue;
        switch (n.type) {
            .Function => {
                const fnv = n.node_variant.?.function;
                const name_al = fnv.name orelse continue;
                const fn_name = name_al.items;

                if (!enrich.fn_sig_by_name.contains(fn_name)) {
                    const sig = try buildSignatureFromAst(allocator, fn_name, fnv, true);
                    try enrich.fn_sig_by_name.put(fn_name, sig);
                }

                if (fnv.rtype) |rt| {
                    if (!enrich.fn_rtype_by_name.contains(fn_name)) {
                        const rts = try dtypeStringOwned.build(allocator, rt);
                        try enrich.fn_rtype_by_name.put(fn_name, rts);
                    }
                }
            },
            .Compound => {
                const cv = n.node_variant.?.compound;
                const type_name = cv.name.items;

                for (cv.fields.items()) |f| {
                    const field_name = f.name.items;
                    const key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, field_name });
                    if (!enrich.field_type_by_key.contains(key)) {
                        const fts = try dtypeStringOwned.build(allocator, f.dtype.*);
                        try enrich.field_type_by_key.put(key, fts);
                    }
                }
            },
            .Quirk => {
                const qv = n.node_variant.?.quirk;
                const quirk_name = qv.name.items;

                for (qv.methods.items()) |m| {
                    const mname = m.name.items;
                    const key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ quirk_name, mname });
                    if (!enrich.member_sig_by_key.contains(key)) {
                        const sig = try buildQuirkMethodSignatureFromAst(allocator, m);
                        try enrich.member_sig_by_key.put(key, sig);
                    }
                    if (!enrich.member_rtype_by_key.contains(key)) {
                        const rts = try dtypeStringOwned.build(allocator, m.rtype);
                        try enrich.member_rtype_by_key.put(key, rts);
                    }
                }
            },
            .Impl => {
                const iv = n.node_variant.?.impl;
                const type_name = iv.type_name.items;

                for (iv.methods.items()) |mnode| {
                    if (mnode.type != .Function or mnode.node_variant == null) continue;
                    const mf = mnode.node_variant.?.function;
                    const name_al = mf.name orelse continue;
                    // Impl method names are stored as generated names:
                    // - Plain: `<Type>__<method>`
                    // - Quirk: `<Type>__<Quirk>__<method>`
                    // For LSP UX we key by `<Type>.<method>`.
                    const gen = name_al.items;
                    const mname = if (std.mem.lastIndexOf(u8, gen, "__")) |cut| gen[cut + 2 ..] else gen;

                    const key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, mname });
                    if (!enrich.member_sig_by_key.contains(key)) {
                        const sig = try buildSignatureFromAst(allocator, mname, mf, false);
                        try enrich.member_sig_by_key.put(key, sig);
                    }
                    if (mf.rtype) |rt| {
                        if (!enrich.member_rtype_by_key.contains(key)) {
                            const rts = try dtypeStringOwned.build(allocator, rt);
                            try enrich.member_rtype_by_key.put(key, rts);
                        }
                    }
                }
            },
            else => {},
        }
    }

    // Apply enrichment to the token-derived symbols.
    for (symbols.items) |*s| {
        if (s.kind == .function) {
            if (s.detail == null) {
                if (enrich.fn_sig_by_name.get(s.name)) |sig| s.detail = sig;
            }
            if (s.value_type == null) {
                if (enrich.fn_rtype_by_name.get(s.name)) |rt| s.value_type = rt;
            }
            continue;
        }

        if (s.container_type) |ct| {
            // Field/property type.
            if (s.value_type == null and (s.kind == .field or s.kind == .property)) {
                var buf: [256]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "{s}.{s}", .{ ct, s.name }) catch null;
                if (key) |k| {
                    if (enrich.field_type_by_key.get(k)) |ft| s.value_type = ft;
                }
            }

            // Method signature/return type.
            if (s.detail == null and (s.kind == .method or s.kind == .function)) {
                var buf: [256]u8 = undefined;
                const key = std.fmt.bufPrint(&buf, "{s}.{s}", .{ ct, s.name }) catch null;
                if (key) |k| {
                    if (enrich.member_sig_by_key.get(k)) |ms| s.detail = ms;
                    if (s.value_type == null) {
                        if (enrich.member_rtype_by_key.get(k)) |rt| s.value_type = rt;
                    }
                }
            }
        }

        if (s.container_fn_range) |fr| {
            _ = fr;
        }
    }
}

fn buildSignatureFromAst(
    allocator: Allocator,
    name: []const u8,
    fnv: anytype,
    include_fun_prefix: bool,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    const is_async_fn = @hasField(@TypeOf(fnv), "is_async") and fnv.is_async;
    if (is_async_fn) {
        try buf.appendSlice("async ");
    }

    if (include_fun_prefix) {
        try buf.writer().print("fun {s}", .{name});
    } else {
        try buf.writer().print("{s}", .{name});
    }
    if (@hasField(@TypeOf(fnv), "type_params")) {
        if (fnv.type_params) |params| {
            try buf.append('<');
            for (params.items(), 0..) |p, i| {
                if (i != 0) try buf.appendSlice(", ");
                try buf.appendSlice(p.items);
            }
            try buf.append('>');
        }
    }

    try buf.append('(');

    if (fnv.args) |args| {
        var first: bool = true;
        for (args.items()) |a| {
            if (a.type != .Variable or a.node_variant == null) continue;
            const av = a.node_variant.?.variable;
            if (!first) try buf.appendSlice(", ");
            first = false;
            try appendDTypeFull(&buf, av.type);
            try buf.writer().print(" {s}", .{av.name.items});
        }
    }

    if (@hasField(@TypeOf(fnv), "is_variadic") and fnv.is_variadic) {
        if (fnv.args) |args| {
            if (args.items().len != 0) try buf.appendSlice(", ");
        }
        try buf.appendSlice("...");
    }

    try buf.append(')');
    if (fnv.rtype) |rt| {
        try buf.append(' ');
        try appendDTypeFull(&buf, rt);
    }
    return try buf.toOwnedSlice();
}

fn buildQuirkMethodSignatureFromAst(allocator: Allocator, m: ast.QuirkMethodSig) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    if (m.is_async) {
        try buf.appendSlice("async ");
    }
    try buf.writer().print("{s}(", .{m.name.items});
    var first: bool = true;
    for (m.args.items()) |a| {
        if (!first) try buf.appendSlice(", ");
        first = false;
        try appendDTypeFull(&buf, a.dtype);
        try buf.writer().print(" {s}", .{a.name.items});
    }
    try buf.append(')');
    try buf.append(' ');
    try appendDTypeFull(&buf, m.rtype);
    return try buf.toOwnedSlice();
}

fn makeGenericTypeInsertText(allocator: Allocator, name: []const u8, detail_opt: ?[]const u8) !?[]const u8 {
    const det = detail_opt orelse return null;
    const open_opt = std.mem.indexOfScalar(u8, det, '<') orelse return null;
    const close_rel_opt = std.mem.indexOfScalar(u8, det[open_opt + 1 ..], '>') orelse return null;
    const close_idx = open_opt + 1 + close_rel_opt;
    if (close_idx <= open_opt + 1) return null;

    const params = std.mem.trim(u8, det[open_opt + 1 .. close_idx], " \t\r\n");
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    try buf.appendSlice(name);
    try buf.append('<');
    if (params.len != 0) try buf.appendSlice(params);
    try buf.append('>');
    return try buf.toOwnedSlice();
}

test "fls hover: signatures include custom return types" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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

test "fls index: locals are indexed inside fun bodies" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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

test "fls completion: generic insert text helper" {
    const allocator = std.testing.allocator;

    const ins = try makeGenericTypeInsertText(allocator, "Option", "compound Option<T>");
    defer if (ins) |s| allocator.free(s);
    try std.testing.expect(ins != null);
    try std.testing.expect(std.mem.eql(u8, ins.?, "Option<T>"));

    const ins_multi = try makeGenericTypeInsertText(allocator, "Pair", "compound Pair<A, B>");
    defer if (ins_multi) |s| allocator.free(s);
    try std.testing.expect(ins_multi != null);
    try std.testing.expect(std.mem.eql(u8, ins_multi.?, "Pair<A, B>"));

    const ins2 = try makeGenericTypeInsertText(allocator, "Point", "compound Point");
    defer if (ins2) |s| allocator.free(s);
    try std.testing.expect(ins2 == null);
}

test "fls index: impl methods include self, params, locals" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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

fn trimLeftSpace(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    return s[i..];
}

fn trimRightCR(s: []const u8) []const u8 {
    if (s.len != 0 and s[s.len - 1] == '\r') return s[0 .. s.len - 1];
    return s;
}

fn appendDocCommentAboveLine(allocator: Allocator, out: *std.ArrayList(u8), text: []const u8, decl_line: i64) !bool {
    // Collect contiguous `//...` lines immediately above `decl_line`.
    // Stop on the first blank or non-comment line.
    if (decl_line <= 0) return false;

    const decl_start = byteIndexForPosition(text, .{ .line = decl_line, .character = 0 });
    var cur_start: usize = decl_start;
    if (cur_start == 0) return false;

    var lines = std.ArrayList([]const u8).init(allocator);
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
        try out.writer().print("{s}\n", .{l});
    }
    try out.appendSlice("\n");
    return true;
}

fn tokenString(t: token.Token) []const u8 {
    return switch (t.data) {
        .sval => |sv| sv.items,
        else => "",
    };
}

fn isKeyword(t: token.Token, kw: []const u8) bool {
    return t.type == .Keyword and std.mem.eql(u8, tokenString(t), kw);
}

fn isIdent(t: token.Token) bool {
    return t.type == .Identifier;
}

fn isSymbolChar(t: token.Token, c: u8) bool {
    return t.type == .Symbol and t.data == .cval and t.data.cval == c;
}

fn isPunctChar(t: token.Token, c: u8) bool {
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

fn isPrimitiveTypeKeywordName(s: []const u8) bool {
    // Fun primitive datatypes.
    return std.mem.eql(u8, s, "void") or std.mem.eql(u8, s, "raw") or std.mem.eql(u8, s, "num") or std.mem.eql(u8, s, "dec") or
        std.mem.eql(u8, s, "str") or std.mem.eql(u8, s, "bin") or std.mem.eql(u8, s, "chr");
}

fn isArrayTypeName(name: []const u8) bool {
    return name.len >= 2 and name[name.len - 2] == '[' and name[name.len - 1] == ']';
}

fn isTypeToken(t: token.Token) bool {
    if (t.type == .Identifier) return true;
    if (t.type == .Keyword and isPrimitiveTypeKeywordName(tokenString(t))) return true;
    return false;
}

fn nextNonTrivialToken(tokens: []const token.Token, start_index: usize) ?usize {
    var i = start_index;
    while (i < tokens.len) : (i += 1) {
        const t = tokens[i];
        if (t.type == .NewLine or t.type == .Comment) continue;
        return i;
    }
    return null;
}

fn prevNonTrivialToken(tokens: []const token.Token, start_index: usize) ?usize {
    if (start_index == 0) return null;
    var i: isize = @intCast(start_index);
    while (i > 0) : (i -= 1) {
        const t = tokens[@intCast(i - 1)];
        if (t.type == .NewLine or t.type == .Comment) continue;
        return @intCast(i - 1);
    }
    return null;
}

fn skipGenericArgsForward(tokens: []const token.Token, start_index: usize) usize {
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

fn rangeFromTokenSpan(start_t: token.Token, end_t: token.Token) Range {
    const sr = rangeFromTokenPos(start_t.pos);
    const er = rangeFromTokenPos(end_t.pos);
    return .{ .start = sr.start, .end = er.end };
}

fn buildSignatureFromTokens(
    allocator: Allocator,
    tokens: []const token.Token,
    name_i: usize,
    include_fun_prefix: bool,
) !struct { detail: ?[]u8, return_type: ?[]u8 } {
    if (name_i >= tokens.len) return .{ .detail = null, .return_type = null };
    if (!isIdent(tokens[name_i])) return .{ .detail = null, .return_type = null };

    var after_name_i = nextNonTrivialToken(tokens, name_i + 1) orelse return .{ .detail = null, .return_type = null };

    var name_buf = std.ArrayList(u8).init(allocator);
    errdefer name_buf.deinit();
    try name_buf.appendSlice(tokenString(tokens[name_i]));

    // Optional generic params between name and '(' (e.g., `fun id<T>(...)`).
    if (isPunctChar(tokens[after_name_i], '<')) {
        var depth: i64 = 0;
        var i: usize = after_name_i;
        var first_param = true;
        var params_buf = std.ArrayList(u8).init(allocator);
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

    var buf = std.ArrayList(u8).init(allocator);
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
        try buf.writer().print("fun {s}(", .{name_buf.items});
    } else {
        try buf.writer().print("{s}(", .{name_buf.items});
    }

    const parsed = struct {
        fn isStarToken(t: token.Token) bool {
            if (t.type == .Operator and t.data == .sval and std.mem.eql(u8, t.data.sval.items, "*")) return true;
            if (t.type == .Symbol and t.data == .cval and t.data.cval == '*') return true;
            return false;
        }

        fn appendGenericSuffix(out_buf: *std.ArrayList(u8), all_tokens: []const token.Token, start_i: usize) !usize {
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

        fn appendPointerSuffix(out_buf: *std.ArrayList(u8), all_tokens: []const token.Token, start_i: usize) !usize {
            var i = start_i;
            while (i < all_tokens.len and isStarToken(all_tokens[i])) : (i += 1) {
                try out_buf.append('*');
            }
            return i;
        }

        fn pointerSuffixLen(all_tokens: []const token.Token, start_i: usize) usize {
            var i = start_i;
            while (i < all_tokens.len and isStarToken(all_tokens[i])) : (i += 1) {}
            return i - start_i;
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
        var ptype_buf = std.ArrayList(u8).init(allocator);
        defer ptype_buf.deinit();
        try ptype_buf.appendSlice(ptype);
        var after_type_i = nextNonTrivialToken(tokens, pi + 1) orelse break;
        after_type_i = try parsed.appendGenericSuffix(&ptype_buf, tokens, after_type_i);
        const after_ptr_i = try parsed.appendPointerSuffix(&ptype_buf, tokens, after_type_i);

        const pname_i = nextNonTrivialToken(tokens, after_ptr_i) orelse break;
        if (!isIdent(tokens[pname_i])) {
            pi += 1;
            continue;
        }
        const pname_raw = tokenString(tokens[pname_i]);
        const pname = allocator.dupe(u8, pname_raw) catch pname_raw;
        if (!first) try buf.appendSlice(", ");
        first = false;
        try buf.writer().print("{s} {s}", .{ ptype_buf.items, pname });
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

            var rt_buf = std.ArrayList(u8).init(allocator);
            errdefer rt_buf.deinit();
            try rt_buf.appendSlice(rts);

            var after_type_i = nextNonTrivialToken(tokens, ri + 1) orelse (ri + 1);
            after_type_i = try parsed.appendGenericSuffix(&rt_buf, tokens, after_type_i);

            const suffix_len = parsed.pointerSuffixLen(tokens, after_type_i);
            var si: usize = 0;
            while (si < suffix_len) : (si += 1) {
                try rt_buf.append('*');
            }
            rtype_owned = try rt_buf.toOwnedSlice();
            try buf.writer().print(" {s}", .{rtype_owned.?});
        }
    }

    return .{ .detail = try buf.toOwnedSlice(), .return_type = rtype_owned };
}

fn collectSymbolsFromTokens(allocator: Allocator, out: *std.ArrayList(SymbolLite), tokens: []const token.Token) !void {
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
    var pending_params = std.ArrayList(ParamLite).init(allocator);
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
        fn call(kind: *PendingBodyKind, params: *std.ArrayList(ParamLite), owner: *?[]const u8, is_variadic: *bool) void {
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

            const tokenHasChar = struct {
                fn callTok(t: token.Token, ch: u8) bool {
                    const s = tokenString(t);
                    var i: usize = 0;
                    while (i < s.len) : (i += 1) {
                        if (s[i] == ch) return true;
                    }
                    return false;
                }
            }.callTok;

            var saw_str = false;
            var saw_bin = false;
            var saw_chr = false;
            var saw_dec = false;
            var saw_num = false;
            var saw_array_literal = false;
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
                        trimmed = std.mem.trimRight(u8, trimmed, " \t\r\n");
                        if (trimmed.len == 0 or trimmed[trimmed.len - 1] != '*') return null;
                        trimmed = trimmed[0 .. trimmed.len - 1];
                    }
                    trimmed = std.mem.trimRight(u8, trimmed, " \t\r\n");
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

                fn splitTopLevelCsv(allocator_a: Allocator, text: []const u8, out_list: *std.ArrayList([]const u8)) void {
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

                fn parseFunctionGenericParams(allocator_a: Allocator, detail: []const u8, out_params: *std.ArrayList([]const u8)) void {
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

                    var raw_params = std.ArrayList([]const u8).init(allocator_a);
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

                fn parseFunctionParamTypes(allocator_a: Allocator, detail: []const u8, out_types: *std.ArrayList([]const u8)) void {
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

                    var raw_params = std.ArrayList([]const u8).init(allocator_a);
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

                fn parseCallExplicitTypeArgs(allocator_a: Allocator, tokens_a: []const token.Token, l_angle_i: usize, out_args: *std.ArrayList([]const u8)) void {
                    var depth: i64 = 0;
                    var cur = std.ArrayList(u8).init(allocator_a);
                    defer cur.deinit();

                    const flush = struct {
                        fn call(allocator_b: Allocator, cur_buf: *std.ArrayList(u8), out_buf: *std.ArrayList([]const u8)) void {
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

                fn collectCallArgRanges(tokens_a: []const token.Token, lparen_i: usize, rparen_i: usize, out_ranges: *std.ArrayList(CallArgRange)) void {
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

                fn collectInitArgRanges(tokens_a: []const token.Token, lbrace_i: usize, rbrace_i: usize, out_ranges: *std.ArrayList(CallArgRange)) void {
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
                    var tname = std.mem.trimRight(u8, type_name_raw, " \t\r\n");
                    var n: usize = 0;
                    while (tname.len != 0) {
                        const ch = tname[tname.len - 1];
                        if (ch == '*' or ch == '&') {
                            n += 1;
                            tname = std.mem.trimRight(u8, tname[0 .. tname.len - 1], " \t\r\n");
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
                            const p_core = std.mem.trimRight(u8, param_type[0 .. param_type.len - p_ptr], " \t\r\n");
                            const a_core = std.mem.trimRight(u8, arg_type[0 .. arg_type.len - p_ptr], " \t\r\n");
                            inferGenericBindings(allocator_a, p_core, a_core, generic_params, map);
                            return;
                        }
                    }

                    if (parseGenericCore(param_type)) |pg| {
                        if (parseGenericCore(arg_type)) |ag| {
                            if (!std.mem.eql(u8, pg.base, ag.base)) return;

                            var p_args = std.ArrayList([]const u8).init(allocator_a);
                            defer p_args.deinit();
                            var a_args = std.ArrayList([]const u8).init(allocator_a);
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

                    var out_buf = std.ArrayList(u8).init(allocator_a);
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
                        var explicit_args = std.ArrayList([]const u8).init(allocator_a);
                        defer explicit_args.deinit();
                        parseCallExplicitTypeArgs(allocator_a, tokens_a, gi, &explicit_args);
                        if (explicit_args.items.len == 0) return allocator_a.dupe(u8, ident_name) catch ident_name;
                        return buildSpecializedTypeName(allocator_a, ident_name, explicit_args.items);
                    }

                    var fields = std.ArrayList(CompoundFieldInfo).init(allocator_a);
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

                    var generic_params = std.ArrayList([]const u8).init(allocator_a);
                    defer generic_params.deinit();
                    splitTopLevelCsv(allocator_a, generic_core.inner, &generic_params);
                    if (generic_params.items.len == 0) return allocator_a.dupe(u8, ident_name) catch ident_name;

                    var bindings = std.StringHashMap([]const u8).init(allocator_a);
                    defer bindings.deinit();

                    var arg_ranges = std.ArrayList(CallArgRange).init(allocator_a);
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

                    var specialized_args = std.ArrayList([]const u8).init(allocator_a);
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
                    var out_buf = std.ArrayList(u8).init(allocator_a);
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

                    var generic_params = std.ArrayList([]const u8).init(allocator_a);
                    defer generic_params.deinit();
                    parseFunctionGenericParams(allocator_a, sig_detail, &generic_params);
                    if (generic_params.items.len == 0) return base_rt;

                    var bindings = std.StringHashMap([]const u8).init(allocator_a);
                    defer bindings.deinit();

                    if (explicit_generic_start_i) |gi| {
                        var explicit_args = std.ArrayList([]const u8).init(allocator_a);
                        defer explicit_args.deinit();
                        parseCallExplicitTypeArgs(allocator_a, tokens_a, gi, &explicit_args);
                        const map_n = @min(explicit_args.items.len, generic_params.items.len);
                        var idx: usize = 0;
                        while (idx < map_n) : (idx += 1) {
                            bindGenericParam(allocator_a, &bindings, generic_params.items[idx], explicit_args.items[idx]);
                        }
                    }

                    var param_types = std.ArrayList([]const u8).init(allocator_a);
                    defer param_types.deinit();
                    parseFunctionParamTypes(allocator_a, sig_detail, &param_types);

                    var arg_ranges = std.ArrayList(CallArgRange).init(allocator_a);
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
                if (isPunctChar(tokens_[fi], '(')) {
                    const next_after = nextNonTrivialToken(tokens_, fi + 1) orelse fi;
                    if (tokenHasChar(tokens_[next_after], '[')) saw_array_literal = true;
                } else if (tokenHasChar(tokens_[fi], '[')) {
                    saw_array_literal = true;
                }
            }

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

            if (exact_terminal_type) |et| {
                if (!isLetInferTypeName(et)) {
                    return allocator_.dupe(u8, et) catch et;
                }
            }

            if (candidate) |cand| {
                if (!isLetInferTypeName(cand) and !isBuiltinTypeName(cand)) {
                    if (saw_array_literal and !isArrayTypeName(cand)) {
                        const arr_name = std.mem.concat(allocator_, u8, &[_][]const u8{ cand, "[]" }) catch cand;
                        return arr_name;
                    }
                    return allocator_.dupe(u8, cand) catch cand;
                }
            }
            if (saw_str) {
                const base = "str";
                if (saw_array_literal) return std.mem.concat(allocator_, u8, &[_][]const u8{ base, "[]" }) catch base;
                return allocator_.dupe(u8, base) catch base;
            }
            if (saw_bin) {
                const base = "bin";
                if (saw_array_literal) return std.mem.concat(allocator_, u8, &[_][]const u8{ base, "[]" }) catch base;
                return allocator_.dupe(u8, base) catch base;
            }
            if (saw_chr) {
                const base = "chr";
                if (saw_array_literal) return std.mem.concat(allocator_, u8, &[_][]const u8{ base, "[]" }) catch base;
                return allocator_.dupe(u8, base) catch base;
            }
            if (saw_dec or (candidate != null and std.mem.eql(u8, candidate.?, "dec"))) {
                const base = "dec";
                if (saw_array_literal) return std.mem.concat(allocator_, u8, &[_][]const u8{ base, "[]" }) catch base;
                return allocator_.dupe(u8, base) catch base;
            }
            if (saw_num or (candidate != null and std.mem.eql(u8, candidate.?, "num"))) {
                const base = "num";
                if (saw_array_literal) return std.mem.concat(allocator_, u8, &[_][]const u8{ base, "[]" }) catch base;
                return allocator_.dupe(u8, base) catch base;
            }
            if (candidate) |cand2| {
                if (!isLetInferTypeName(cand2)) {
                    if (saw_array_literal and !isArrayTypeName(cand2)) {
                        return std.mem.concat(allocator_, u8, &[_][]const u8{ cand2, "[]" }) catch cand2;
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
        fn call(allocator_: Allocator, tokens_: []const token.Token, lparen_i: usize, params: *std.ArrayList(ParamLite), is_variadic: *bool) void {
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

                var ptype_buf = std.ArrayList(u8).init(allocator_);
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

                // Allow pointer/reference markers between type and name: `Type* name` / `Type & name`.
                var markers = std.ArrayList(u8).init(allocator_);
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
                        var det_buf = std.ArrayList(u8).init(allocator);
                        defer det_buf.deinit();
                        try det_buf.writer().print("{s} {s}", .{ pinfo.dtype_display, pinfo.name });
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
            var owner_name_buf = std.ArrayList(u8).init(allocator);
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
                        var ftype_buf = std.ArrayList(u8).init(allocator);
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

                        var markers = std.ArrayList(u8).init(allocator);
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
            var owner_buf = std.ArrayList(u8).init(allocator);
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
                        var det_buf = std.ArrayList(u8).init(allocator);
                        defer det_buf.deinit();
                        try det_buf.writer().print("num {s}", .{idx_name});
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
                var det_buf = std.ArrayList(u8).init(allocator);
                defer det_buf.deinit();
                try det_buf.writer().print("{s} {s}", .{ it, item_name });
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
                var det_buf = std.ArrayList(u8).init(allocator);
                defer det_buf.deinit();
                try det_buf.writer().print("{s} {s}", .{ tname, vname });
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
            var vtype_buf = std.ArrayList(u8).init(allocator);
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
            var markers = std.ArrayList(u8).init(allocator);
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

                var det_buf = std.ArrayList(u8).init(allocator);
                defer det_buf.deinit();
                try det_buf.writer().print("{s} {s}", .{ vtype_display, vname });

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
            var vtype_buf = std.ArrayList(u8).init(allocator);
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

            var markers = std.ArrayList(u8).init(allocator);
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

            var det_buf = std.ArrayList(u8).init(allocator);
            defer det_buf.deinit();
            try det_buf.writer().print("{s} {s}", .{ vtype, vname });

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

fn collectSymbolsFromTopLevel(allocator: Allocator, out: *std.ArrayList(SymbolLite), n: ast.Node) !void {
    if (n.node_variant == null) return;
    switch (n.type) {
        .Variable => {
            const v = n.node_variant.?.variable;
            const name = v.name.items;
            const r = if (n.pos) |p| rangeFromTokenPos(p) else return;

            var detail_buf = std.ArrayList(u8).init(allocator);
            errdefer detail_buf.deinit();
            try appendDTypeFull(&detail_buf, v.type);
            try detail_buf.writer().print(" {s}", .{name});

            var vtype_buf = std.ArrayList(u8).init(allocator);
            defer vtype_buf.deinit();
            try appendDTypeFull(&vtype_buf, v.type);

            try out.append(.{
                .name = try allocator.dupe(u8, name),
                .kind = .variable,
                .decl_range = r,
                .selection_range = r,
                .is_public = if (n.flags) |f| f.is_public else false,
                .container_type = null,
                .value_type = try allocator.dupe(u8, vtype_buf.items),
                .detail = try detail_buf.toOwnedSlice(),
            });
        },
        .Function => {
            const fnv = n.node_variant.?.function;
            if (fnv.name == null) return;
            const name = fnv.name.?.items;
            const decl_range = if (n.pos) |p| rangeFromTokenPos(p) else Range{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };

            const detail = try formatFunctionSignature(allocator, name, fnv);
            try out.append(.{
                .name = try allocator.dupe(u8, name),
                .kind = .function,
                .decl_range = decl_range,
                .selection_range = decl_range,
                .is_public = if (n.flags) |f| f.is_public else false,
                .container_type = null,
                .value_type = null,
                .detail = detail,
            });

            const container = if (fnv.body) |b| if (b.pos) |bp| rangeFromTokenPos(bp) else decl_range else decl_range;
            if (fnv.body) |b| {
                try collectLocalVars(allocator, out, b, container);
            }
        },
        .Compound => {
            const c = n.node_variant.?.compound;
            const name = c.name.items;
            const r = if (n.pos) |p| rangeFromTokenPos(p) else Range{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };
            var detail_buf = std.ArrayList(u8).init(allocator);
            errdefer detail_buf.deinit();
            try detail_buf.writer().print("compound {s}", .{name});
            if (c.type_params) |params| {
                try detail_buf.append('<');
                for (params.items(), 0..) |p, i| {
                    if (i != 0) try detail_buf.appendSlice(", ");
                    try detail_buf.appendSlice(p.items);
                }
                try detail_buf.append('>');
            }
            try out.append(.{
                .name = try allocator.dupe(u8, name),
                .kind = .struct_,
                .decl_range = r,
                .selection_range = r,
                .is_public = if (n.flags) |f| f.is_public else false,
                .container_type = null,
                .value_type = null,
                .detail = try detail_buf.toOwnedSlice(),
            });
        },
        .Quirk => {
            const q = n.node_variant.?.quirk;
            const name = q.name.items;
            const r = if (n.pos) |p| rangeFromTokenPos(p) else Range{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };
            var detail_buf = std.ArrayList(u8).init(allocator);
            errdefer detail_buf.deinit();
            try detail_buf.writer().print("quirk {s}", .{name});
            try out.append(.{
                .name = try allocator.dupe(u8, name),
                .kind = .interface,
                .decl_range = r,
                .selection_range = r,
                .is_public = if (n.flags) |f| f.is_public else false,
                .container_type = null,
                .value_type = null,
                .detail = try detail_buf.toOwnedSlice(),
            });
        },
        .Impl => {
            // Skip impl methods here: the AST stores generated method names
            // (`Type__method` / `Type__Quirk__method`), while the lexer scan has
            // the user-facing method name and better positioning.
        },
        else => {},
    }
}

fn formatFunctionSignature(allocator: Allocator, name: []const u8, fnv: anytype) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    if (@hasField(@TypeOf(fnv), "is_async") and fnv.is_async) {
        try buf.appendSlice("async ");
    }
    try buf.writer().print("fun {s}", .{name});

    if (@hasField(@TypeOf(fnv), "type_params")) {
        if (fnv.type_params) |params| {
            try buf.append('<');
            for (params.items(), 0..) |p, i| {
                if (i != 0) try buf.appendSlice(", ");
                try buf.appendSlice(p.items);
            }
            try buf.append('>');
        }
    }

    try buf.append('(');

    if (fnv.args) |args| {
        var first = true;
        for (args.items()) |a| {
            if (a.type != .Variable or a.node_variant == null) continue;
            const vv = a.node_variant.?.variable;
            const arg_name = vv.name.items;
            const dt = vv.type.*;
            if (!first) try buf.appendSlice(", ");
            first = false;
            try appendDTypeFull(&buf, dt);
            try buf.writer().print(" {s}", .{arg_name});
        }
    }
    if (fnv.is_variadic) {
        if (fnv.args != null and fnv.args.?.items().len != 0) try buf.appendSlice(", ");
        try buf.appendSlice("...");
    }
    try buf.append(')');
    if (fnv.rtype) |rt| {
        try buf.append(' ');
        try appendDTypeFull(&buf, rt);
    }
    return buf.toOwnedSlice();
}

fn collectLocalVars(allocator: Allocator, out: *std.ArrayList(SymbolLite), n: *ast.Node, container_fn_range: Range) Allocator.Error!void {
    if (n.node_variant == null) return;
    switch (n.type) {
        .Variable => {
            const v = n.node_variant.?.variable;
            const name = v.name.items;
            const r = if (n.pos) |p| rangeFromTokenPos(p) else return;
            var detail_buf = std.ArrayList(u8).init(allocator);
            errdefer detail_buf.deinit();
            try appendDTypeFull(&detail_buf, v.type);
            try detail_buf.writer().print(" {s}", .{name});

            var vtype_buf = std.ArrayList(u8).init(allocator);
            defer vtype_buf.deinit();
            try appendDTypeFull(&vtype_buf, v.type);

            const det = try detail_buf.toOwnedSlice();
            try out.append(.{
                .name = try allocator.dupe(u8, name),
                .kind = .variable,
                .decl_range = r,
                .selection_range = r,
                .container_fn_range = container_fn_range,
                .container_type = null,
                .value_type = try allocator.dupe(u8, vtype_buf.items),
                .detail = det,
            });
        },
        .Body => {
            const b = n.node_variant.?.body;
            for (b.statements.items()) |s| {
                try collectLocalVars(allocator, out, s, container_fn_range);
            }
        },
        .StatementIf, .StatementElseIf, .StatementElse, .StatementFor, .StatementFit, .StatementCase, .StatementDefault, .StatementReturn => {
            // Walk common statement subtrees.
            // We only need locals; a best-effort recursion is fine.
            try collectLocalVarsFromStatement(allocator, out, n, container_fn_range);
        },
        .Expression, .ExpressionParenthesis, .Unary, .Tenary, .Bracket => {
            try collectLocalVarsFromExpression(allocator, out, n, container_fn_range);
        },
        else => {},
    }
}

fn collectLocalVarsFromStatement(allocator: Allocator, out: *std.ArrayList(SymbolLite), n: *ast.Node, container_fn_range: Range) Allocator.Error!void {
    if (n.node_variant == null) return;
    switch (n.type) {
        .StatementReturn => try collectLocalVars(allocator, out, n.node_variant.?.statement.return_stmt, container_fn_range),
        .StatementDefer => {
            const st = n.node_variant.?.statement.defer_stmt;
            try collectLocalVars(allocator, out, st.body, container_fn_range);
        },
        .StatementIf => {
            const st = n.node_variant.?.statement;
            _ = st;
        },
        .StatementElseIf, .StatementElse, .StatementFor, .StatementFit, .StatementCase, .StatementDefault => {
            // For now, rely on expression/body recursion below if these nodes contain bodies.
        },
        else => {},
    }
    // Generic recursion: attempt to walk known child pointers if present.
    if (n.node_variant) |v| {
        switch (v) {
            .statement => |st| {
                switch (st) {
                    .return_stmt => |rn| try collectLocalVars(allocator, out, rn, container_fn_range),
                    .defer_stmt => |dn| try collectLocalVars(allocator, out, dn.body, container_fn_range),
                    .for_stmt => |fs| switch (fs) {
                        .cond => |c| {
                            if (c.condition) |cond| try collectLocalVars(allocator, out, cond, container_fn_range);
                            try collectLocalVars(allocator, out, c.body, container_fn_range);
                        },
                        .range => |r| {
                            try collectLocalVars(allocator, out, r.range, container_fn_range);
                            try collectLocalVars(allocator, out, r.body, container_fn_range);
                        },
                        .iter => |it| {
                            try collectLocalVars(allocator, out, it.iterable, container_fn_range);
                            try collectLocalVars(allocator, out, it.body, container_fn_range);
                        },
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

fn collectLocalVarsFromExpression(allocator: Allocator, out: *std.ArrayList(SymbolLite), n: *ast.Node, container_fn_range: Range) Allocator.Error!void {
    if (n.node_variant == null) return;
    switch (n.node_variant.?) {
        .exp => |e| {
            if (e.left) |l| try collectLocalVars(allocator, out, l, container_fn_range);
            if (e.right) |r| try collectLocalVars(allocator, out, r, container_fn_range);
        },
        .paren => |p| try collectLocalVars(allocator, out, p.exp, container_fn_range),
        .unary => |u| try collectLocalVars(allocator, out, u.operand, container_fn_range),
        .tenary => |t| {
            try collectLocalVars(allocator, out, t.condition, container_fn_range);
            try collectLocalVars(allocator, out, t.true, container_fn_range);
            try collectLocalVars(allocator, out, t.false, container_fn_range);
        },
        .bracket => |b| try collectLocalVars(allocator, out, b.inner, container_fn_range),
        else => {},
    }
}

const GuessedCallSignature = struct {
    label: []const u8,
    active_param: i64,
    callee_i: ?usize = null,
    lparen_i: ?usize = null,
    cursor_tok_i: ?usize = null,
    explicit_generic_start_i: ?usize = null,
};

fn guessCallSignature(idx: *const Index, p: Position) ?GuessedCallSignature {
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

fn classifyIdentifierTokenType(idx: *const Index, name: []const u8) u32 {
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

fn isAllUpperTypeLikeName(name: []const u8) bool {
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

fn isDefaultLibraryTypeName(name: []const u8) bool {
    if (utils.keyword_is_datatype(name)) return true;
    if (utils.get_c_typedef_alias_datatype_type(name) != null) {
        // Keep all-caps C object-like types (for example FILE) on custom-type color.
        if (isAllUpperTypeLikeName(name)) return false;
        return true;
    }
    return false;
}

fn buildSemanticTokens(allocator: Allocator, idx: *const Index) ![]u32 {
    var data = std.ArrayList(u32).init(allocator);
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
