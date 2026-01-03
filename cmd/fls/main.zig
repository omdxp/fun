const std = @import("std");
const ast = @import("ast");
const codegen = @import("codegen");
const parser = @import("parser");
const lexer = @import("lexer");
const utils = @import("utils");
const token = lexer.token;

const Allocator = std.mem.Allocator;

pub fn main() !void {
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

const SignatureInformation = struct {
    label: []const u8,
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

    fn init(allocator: Allocator) !LspServer {
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

        // Optional override for custom installs.
        if (self.tryStdlibRootFromEnv("FUN_STDLIB_DIR")) return self.stdlib_root_path.?;

        // Prefer installed layout next to the running binaries (matches transpiler behavior).
        if (self.fls_exe_path) |p| {
            if (self.tryStdlibRootFromExe(p)) return self.stdlib_root_path.?;
        }
        if (self.tryStdlibRootFromExe(self.fun_exe_path)) return self.stdlib_root_path.?;

        // Repo/workspace checkout layout (fallback).
        if (self.tryStdlibRootFromWorkspace()) return self.stdlib_root_path.?;

        // Final fallback: try resolving relative to the server's current working directory.
        // VS Code launches `fls` with `cwd` set to the workspace root, but some clients/flows
        // don't provide a usable `rootUri` or the document may be `untitled:`.
        if (self.trySetStdlibRoot("stdlib")) return self.stdlib_root_path.?;
        if (self.trySetStdlibRoot("zig-out/share/fun/stdlib")) return self.stdlib_root_path.?;

        return null;
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

    fn trySetStdlibRoot(self: *LspServer, path: []const u8) bool {
        // Ensure we store an absolute path and never pass a non-absolute string to
        // `openDirAbsolute` (which asserts in Zig stdlib).
        const abs = if (std.fs.path.isAbsolute(path))
            (self.allocator.dupe(u8, path) catch return false)
        else
            (std.fs.cwd().realpathAlloc(self.allocator, path) catch return false);

        var keep: bool = false;
        defer if (!keep) self.allocator.free(abs);

        if (!isStdlibRootAbsolute(abs)) return false;

        if (self.stdlib_root_path) |p| self.allocator.free(p);
        self.stdlib_root_path = abs;
        keep = true;
        return true;
    }

    fn tryStdlibRootFromEnv(self: *LspServer, name: []const u8) bool {
        const v = std.process.getEnvVarOwned(self.allocator, name) catch return false;
        defer self.allocator.free(v);
        return self.trySetStdlibRoot(v);
    }

    fn tryStdlibRootFromWorkspace(self: *LspServer) bool {
        const root = self.root_path orelse return false;
        const p = std.fs.path.join(self.allocator, &.{ root, "stdlib" }) catch return false;
        defer self.allocator.free(p);
        return self.trySetStdlibRoot(p);
    }

    fn tryStdlibRootFromExe(self: *LspServer, exe_path: []const u8) bool {
        const bin_dir = std.fs.path.dirname(exe_path) orelse return false;
        const prefix = std.fs.path.dirname(bin_dir) orelse return false;

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
                .completionProvider = .{},
                .signatureHelpProvider = .{},
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
                        },
                        .tokenModifiers = &[_][]const u8{},
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
        if (tok.kind != .identifier) {
            try self.sendResponseJson(id_val, "null");
            return;
        }

        // Member hover: show info for `a.b` / `a.b.c` by resolving receiver type.
        if (findTokenIndexAt(idx.tokens, pos)) |tok_i| {
            if (tok_i > 0 and isDotToken(idx.tokens[tok_i - 1])) {
                if (tok_i >= 2 and idx.tokens[tok_i - 2].kind == .identifier) {
                    if (self.resolveTypeOfChainUpTo(idx, uri, pos, tok_i - 2)) |recv_type| {
                        const name = tok.text;
                        const hit = self.findMemberByContainer(uri, recv_type, name, .field) orelse
                            self.findMemberByContainer(uri, recv_type, name, .property) orelse
                            self.findMemberByContainer(uri, recv_type, name, .method);
                        if (hit) |h| {
                            var buf = std.ArrayList(u8).init(self.allocator);
                            defer buf.deinit();
                            try buf.writer().print("**{s}**\n\n", .{name});
                            switch (h.sym.kind) {
                                .field, .property => {
                                    if (h.sym.value_type) |vt| {
                                        try buf.writer().print("```\n{s} {s}\n```\n", .{ vt, name });
                                    } else {
                                        try buf.writer().print("_field_\n", .{});
                                    }
                                },
                                .method => {
                                    if (h.sym.detail) |det| {
                                        try buf.writer().print("```\n{s}\n```\n", .{det});
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
        const def_local = findBestDefinition(idx.symbols, tok.text, pos) orelse null;
        const def_import = if (def_local == null) self.findAnyGlobalDefinitionInDirectImports(uri, tok.text) else null;
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        if (def_local) |d| {
            try buf.writer().print("**{s}**\n\n", .{tok.text});
            if (d.detail) |det| {
                try buf.writer().print("```\n{s}\n```\n", .{det});
            } else if (d.kind == .variable) {
                const vt = d.value_type orelse self.guessVariableType(idx, tok.text, pos);
                if (vt) |vts| {
                    try buf.writer().print("```\n{s} {s}\n```\n", .{ vts, tok.text });
                } else {
                    try buf.writer().print("_{s}_\n", .{@tagName(d.kind)});
                }
            } else if ((d.kind == .struct_ or d.kind == .interface)) {
                try buf.writer().print("```\n{s} {s}\n```\n", .{ if (d.kind == .struct_) "compound" else "quirk", tok.text });
            } else {
                try buf.writer().print("_{s}_\n", .{@tagName(d.kind)});
            }
            _ = try appendDocCommentAboveLine(self.allocator, &buf, doc.text, d.decl_range.start.line);
        } else if (def_import) |hit| {
            const d = hit.sym;
            try buf.writer().print("**{s}**\n\n", .{tok.text});
            if (d.detail) |det| {
                try buf.writer().print("```\n{s}\n```\n", .{det});
            } else if (d.kind == .variable) {
                const vt = d.value_type orelse self.guessVariableType(idx, tok.text, pos);
                if (vt) |vts| {
                    try buf.writer().print("```\n{s} {s}\n```\n", .{ vts, tok.text });
                } else {
                    try buf.writer().print("_{s}_\n", .{@tagName(d.kind)});
                }
            } else if ((d.kind == .struct_ or d.kind == .interface)) {
                try buf.writer().print("```\n{s} {s}\n```\n", .{ if (d.kind == .struct_) "compound" else "quirk", tok.text });
            } else {
                try buf.writer().print("_{s}_\n", .{@tagName(d.kind)});
            }
            if (self.docs.get(hit.uri)) |idoc| {
                _ = try appendDocCommentAboveLine(self.allocator, &buf, idoc.text, d.decl_range.start.line);
            }
        } else {
            try buf.writer().print("**{s}**\n\n", .{tok.text});
            if (self.guessVariableType(idx, tok.text, pos)) |vt| {
                try buf.writer().print("```\n{s} {s}\n```\n", .{ vt, tok.text });
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
        } else if (self.isKnownTypeName(base_name)) {
            current_type = base_name;
        } else {
            current_type = self.guessVariableType(idx, base_name, at);
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

    fn appendMemberCompletionsForType(
        self: *LspServer,
        items: *std.ArrayList(CompletionItem),
        seen: *std.StringHashMap(void),
        container_type: []const u8,
        prefix: []const u8,
    ) !void {
        var it = self.docs.iterator();
        while (it.next()) |entry| {
            const didx = entry.value_ptr.index orelse continue;
            for (didx.symbols) |s| {
                if (s.container_fn_range != null) continue;
                if (s.container_type == null) continue;
                if (!std.mem.eql(u8, s.container_type.?, container_type)) continue;
                if (!(s.kind == .field or s.kind == .property or s.kind == .method)) continue;
                if (prefix.len != 0 and !std.mem.startsWith(u8, s.name, prefix)) continue;

                const kind: i64 = switch (s.kind) {
                    .method => 2,
                    .field, .property => 5,
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
                            break :blk try self.allocator.dupe(u8, vt);
                        }
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

        if (mode == .type_definition) {
            // Best-effort: resolve the declared type for an identifier, then jump to that type's definition.
            if (tok.kind != .identifier) {
                try self.sendResponseJson(id_val, "[]");
                return;
            }

            // 1) If the identifier itself is a known type name, go to its declaration.
            if (self.isKnownTypeName(tok.text)) {
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
            const var_type = self.guessVariableType(idx, tok.text, pos);
            if (var_type) |vt| {
                if (self.isKnownTypeName(vt)) {
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
                std.fs.cwd().access(readme_path, .{}) catch return false;
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

            // Treat `std.<module>` as an alias for `std.c.<module>`.
            const has_explicit_c = segs.items.len >= 2 and std.mem.eql(u8, segs.items[1].name, "c");
            if (!has_explicit_c) {
                try base_segs.append("c");
            }

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
            // Final segment: open the module file.
            const file_path = try std.mem.concat(self.allocator, u8, &[_][]const u8{ sel_joined, ".fn" });
            defer self.allocator.free(file_path);
            std.fs.cwd().access(file_path, .{}) catch return false;
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

        // Directory segment: return a list of modules in this directory.
        var dir = std.fs.cwd().openDir(sel_joined, .{ .iterate = true }) catch return false;
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
        } else if (self.isKnownTypeName(base_name)) {
            current_type = base_name;
        } else {
            current_type = self.guessVariableType(idx, base_name, pos);
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
                self.findMemberByContainer(uri, current_type.?, member_name, .property))
        else
            (self.findMemberByContainer(uri, current_type.?, member_name, .field) orelse
                self.findMemberByContainer(uri, current_type.?, member_name, .property) orelse
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

    fn findMemberByContainer(self: *LspServer, preferred_uri: []const u8, container_type: []const u8, name: []const u8, kind: SymbolKind) ?MemberHit {
        // Prefer current document first.
        if (self.docs.get(preferred_uri)) |doc| {
            if (doc.index) |idx| {
                for (idx.symbols) |s| {
                    if (s.container_fn_range != null) continue;
                    if (s.kind != kind) continue;
                    if (s.container_type == null) continue;
                    if (!std.mem.eql(u8, s.container_type.?, container_type)) continue;
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
                if (!std.mem.eql(u8, s.container_type.?, container_type)) continue;
                if (!std.mem.eql(u8, s.name, name)) continue;
                return .{ .uri = uri, .sym = s };
            }
        }
        return null;
    }

    fn isKnownTypeName(self: *LspServer, name: []const u8) bool {
        var it = self.docs.iterator();
        while (it.next()) |entry| {
            const idx = entry.value_ptr.index orelse continue;
            for (idx.symbols) |s| {
                if (s.container_fn_range != null) continue;
                if (!std.mem.eql(u8, s.name, name)) continue;
                switch (s.kind) {
                    .struct_, .interface => return true,
                    else => {},
                }
            }
        }
        return false;
    }

    fn findTypeDefinitionAnyDoc(self: *LspServer, preferred_uri: []const u8, type_name: []const u8) ?GlobalDefHit {
        // Prefer current document first.
        if (self.docs.get(preferred_uri)) |doc| {
            if (doc.index) |idx| {
                for (idx.symbols) |s| {
                    if (s.container_fn_range != null) continue;
                    if (!std.mem.eql(u8, s.name, type_name)) continue;
                    if (s.kind != .struct_ and s.kind != .interface) continue;
                    return .{ .uri = preferred_uri, .sym = s };
                }
            }
        }

        // Prefer direct imports of the current doc next.
        if (self.findAnyGlobalDefinitionInDirectImports(preferred_uri, type_name)) |hit| {
            if (hit.sym.kind == .struct_ or hit.sym.kind == .interface) return hit;
        }

        // Finally, scan all indexed docs.
        var it = self.docs.iterator();
        while (it.next()) |entry| {
            const uri = entry.value_ptr.uri;
            if (std.mem.eql(u8, uri, preferred_uri)) continue;
            const idx = entry.value_ptr.index orelse continue;
            for (idx.symbols) |s| {
                if (s.container_fn_range != null) continue;
                if (!std.mem.eql(u8, s.name, type_name)) continue;
                if (s.kind != .struct_ and s.kind != .interface) continue;
                return .{ .uri = uri, .sym = s };
            }
        }
        return null;
    }

    fn guessVariableType(self: *LspServer, idx: *const Index, var_name: []const u8, at: Position) ?[]const u8 {
        // Prefer symbol table (locals + globals) when available.
        if (findBestDefinition(idx.symbols, var_name, at)) |d| {
            if (d.kind == .variable) {
                if (d.value_type) |vt| return vt;
            }
        }

        // Scan for simple declarations like: `Type name;` or `Type name = ...;`
        // (best-effort fallback)
        var best: ?[]const u8 = null;

        var i: usize = 0;
        while (i + 1 < idx.tokens.len) : (i += 1) {
            const t_type = idx.tokens[i];
            if (!rangeStartLessOrEqual(t_type.range, at)) break;

            const is_type_tok = (t_type.kind == .keyword and utils.keyword_is_datatype(t_type.text)) or
                (t_type.kind == .identifier and self.isKnownTypeName(t_type.text));
            if (!is_type_tok) continue;

            // Skip type identifiers that are part of declarations like `compound T`, `quirk Q`, `impl T`, `fun f`.
            if (i > 0 and idx.tokens[i - 1].kind == .keyword) {
                const kw = idx.tokens[i - 1].text;
                if (std.mem.eql(u8, kw, "compound") or std.mem.eql(u8, kw, "quirk") or std.mem.eql(u8, kw, "impl") or std.mem.eql(u8, kw, "fun")) {
                    continue;
                }
            }

            const t_name = idx.tokens[i + 1];
            if (t_name.kind != .identifier) continue;
            if (!std.mem.eql(u8, t_name.text, var_name)) continue;

            // Ensure the name token is also before position.
            if (!rangeStartLessOrEqual(t_name.range, at)) continue;
            best = t_type.text;
        }
        return best;
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
                    pending_impl_type = idx.tokens[j].text;
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

        // If indexing failed (common while typing / for incomplete files), still return keyword completions.
        const idx = doc.index orelse {
            var items = std.ArrayList(CompletionItem).init(self.allocator);
            defer {
                for (items.items) |it| self.allocator.free(it.label);
                items.deinit();
            }

            const keywords = [_][]const u8{
                "imp",  "fun", "compound", "quirk", "impl", "ret", "if",  "elif", "else",  "for", "fit", "break", "continue",
                "void", "raw", "num",      "dec",   "str",  "bin", "chr", "true", "false",
            };
            for (keywords) |kw| {
                if (prefix.len == 0 or std.mem.startsWith(u8, kw, prefix)) {
                    try items.append(.{ .label = try self.allocator.dupe(u8, kw), .kind = 14 });
                }
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
            }
            items.deinit();
        }

        // If we're completing after a '.', offer members of the resolved receiver type.
        const tok_i_opt = findTokenIndexAt(idx.tokens, pos) orelse findLastTokenIndexBeforeOrAt(idx.tokens, pos);
        if (tok_i_opt) |tok_i| {
            const t = idx.tokens[tok_i];
            var receiver_last_ident_i: ?usize = null;

            if (isDotToken(t)) {
                if (tok_i >= 1 and idx.tokens[tok_i - 1].kind == .identifier) receiver_last_ident_i = tok_i - 1;
            } else if (t.kind == .identifier and tok_i >= 1 and isDotToken(idx.tokens[tok_i - 1])) {
                if (tok_i >= 2 and idx.tokens[tok_i - 2].kind == .identifier) receiver_last_ident_i = tok_i - 2;
            }

            if (receiver_last_ident_i) |ri| {
                if (self.resolveTypeOfChainUpTo(idx, uri, pos, ri)) |recv_type| {
                    var seen = std.StringHashMap(void).init(self.allocator);
                    defer {
                        var it = seen.iterator();
                        while (it.next()) |e| self.allocator.free(e.key_ptr.*);
                        seen.deinit();
                    }
                    try self.appendMemberCompletionsForType(&items, &seen, recv_type, prefix);

                    const list: CompletionList = .{ .items = items.items };
                    const json = try std.json.stringifyAlloc(self.allocator, list, .{});
                    defer self.allocator.free(json);
                    try self.sendResponseJson(id_val, json);
                    return;
                }
            }
        }

        // Keywords.
        const keywords = [_][]const u8{
            "imp",  "fun", "compound", "quirk", "impl", "ret", "if",  "elif", "else",  "for", "fit", "break", "continue",
            "void", "raw", "num",      "dec",   "str",  "bin", "chr", "true", "false",
        };
        for (keywords) |kw| {
            if (prefix.len == 0 or std.mem.startsWith(u8, kw, prefix)) {
                try items.append(.{ .label = try self.allocator.dupe(u8, kw), .kind = 14 });
            }
        }

        // Symbols (only current file + direct imports).
        var seen = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = seen.iterator();
            while (it.next()) |e| self.allocator.free(e.key_ptr.*);
            seen.deinit();
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
                });
            }
        }

        const list: CompletionList = .{ .items = items.items };
        const json = try std.json.stringifyAlloc(self.allocator, list, .{});
        defer self.allocator.free(json);
        try self.sendResponseJson(id_val, json);
    }

    fn parseImportSpecFromTokens(self: *LspServer, idx: *const Index, imp_i: usize) !?[]u8 {
        // Parses `imp a.b.c;` into "a.b.c".
        if (imp_i + 1 >= idx.tokens.len) return null;
        var i = imp_i + 1;
        if (idx.tokens[i].kind != .identifier) return null;

        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        // ident ('.' ident)* until ';'
        while (i < idx.tokens.len) : (i += 1) {
            const t = idx.tokens[i];
            if ((t.kind == .symbol or t.kind == .operator) and std.mem.eql(u8, t.text, ";")) break;
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

        // Split on '.'
        var parts = std.ArrayList([]const u8).init(self.allocator);
        defer parts.deinit();
        var it = std.mem.splitScalar(u8, after_imp, '.');
        while (it.next()) |p| {
            const trimmed = std.mem.trim(u8, p, " \t\r");
            try parts.append(trimmed);
        }
        if (parts.items.len == 0) return false;

        const ends_with_dot = after_imp.len != 0 and after_imp[after_imp.len - 1] == '.';
        const partial: []const u8 = if (ends_with_dot) "" else parts.items[parts.items.len - 1];
        const parent_count: usize = if (ends_with_dot) parts.items.len else (if (parts.items.len >= 1) parts.items.len - 1 else 0);
        var items = std.ArrayList(CompletionItem).init(self.allocator);
        defer {
            for (items.items) |ci| {
                self.allocator.free(ci.label);
                if (ci.detail) |d| self.allocator.free(d);
            }
            items.deinit();
        }

        // Always suggest `std` at top-level after `imp`.
        if (parent_count == 0 and std.mem.startsWith(u8, "std", partial)) {
            try items.append(.{ .label = try self.allocator.dupe(u8, "std"), .kind = 19 }); // Folder
        }

        const completing_under_std_alias = parts.items.len >= 1 and std.mem.eql(u8, parts.items[0], "std") and
            // `imp std.<partial>`
            ((!ends_with_dot and parent_count == 1) or
                // `imp std.` (split yields ["std", ""])
                (ends_with_dot and parts.items.len == 2 and parts.items[1].len == 0));

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

                // Treat `std.<module>` as an alias for `std.c.<module>` for completion,
                // so users can keep typing `std.io` and still get suggestions.
                if (completing_under_std_alias) {
                    try segs.append("c");
                    // Also explicitly include `c` as a completion option at `std.`.
                    if (partial.len == 0 or std.mem.startsWith(u8, "c", partial)) {
                        try items.append(.{ .label = try self.allocator.dupe(u8, "c"), .kind = 19 });
                    }
                }

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
                while (iter.next() catch null) |entry| {
                    if (entry.kind == .directory) {
                        if (partial.len != 0 and !std.mem.startsWith(u8, entry.name, partial)) continue;
                        try items.append(.{ .label = try self.allocator.dupe(u8, entry.name), .kind = 19 });
                    } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".fn")) {
                        const base = entry.name[0 .. entry.name.len - 3];
                        if (partial.len != 0 and !std.mem.startsWith(u8, base, partial)) continue;
                        try items.append(.{ .label = try self.allocator.dupe(u8, base), .kind = 17 });
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

    fn guessCallSignatureAt(self: *LspServer, uri: []const u8, idx: *const Index, p: Position) ?GuessedCallSignature {
        // Find the closest '(' before cursor, then resolve the callee.
        var tok_index: ?usize = null;
        for (idx.tokens, 0..) |t, ti| {
            if (t.range.start.line > p.line) break;
            if (t.range.start.line == p.line and t.range.start.character > p.character) break;
            tok_index = ti;
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
                    continue;
                }
                if (std.mem.eql(u8, t.text, "(")) {
                    if (paren_depth == 0) {
                        // previous non-comment token is the callee identifier
                        var callee_i_opt: ?usize = null;
                        var j: isize = i - 1;
                        while (j >= 0) : (j -= 1) {
                            const pt = idx.tokens[@intCast(j)];
                            if (pt.kind == .comment) continue;
                            callee_i_opt = @intCast(j);
                            break;
                        }
                        if (callee_i_opt == null) return null;
                        const callee_i = callee_i_opt.?;
                        const callee = idx.tokens[callee_i];
                        if (callee.kind != .identifier) return null;

                        // Member call: `recv.method(`
                        if (callee_i >= 2 and isDotToken(idx.tokens[callee_i - 1]) and idx.tokens[callee_i - 2].kind == .identifier) {
                            if (self.resolveTypeOfChainUpTo(idx, uri, p, callee_i - 2)) |recv_type| {
                                const hit = self.findMemberByContainer(uri, recv_type, callee.text, .method);
                                if (hit) |h| {
                                    const label = if (h.sym.detail) |d| d else callee.text;
                                    return .{ .label = label, .active_param = active_param };
                                }
                            }
                        }

                        // Plain function call.
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
                        return .{ .label = label, .active_param = active_param };
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

        const infos = [_]SignatureInformation{.{ .label = sig.label }};
        const help: SignatureHelp = .{ .signatures = &infos, .activeParameter = sig.active_param };
        const json = try std.json.stringifyAlloc(self.allocator, help, .{});
        defer self.allocator.free(json);
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

        // Build the new index first; if it fails, keep the old one so completion doesn't "die" mid-edit.
        const new_idx = buildIndexFromTextAt(self.allocator, doc_ptr.text, null) catch |err| {
            std.debug.print("[fls] rebuildIndex failed (keeping old index): {s}\n", .{@errorName(err)});
            return;
        };

        if (doc_ptr.index) |idx| idx.deinit();
        doc_ptr.index = new_idx;
        self.ensureImportsIndexed(uri);
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
                const maybe_target_uri = self.resolveImportUri(uri, s) catch null;
                if (maybe_target_uri) |target_uri| {
                    defer self.allocator.free(target_uri);
                    self.ensureDocIndexedFromDisk(target_uri) catch {};
                }
            }
        }
    }

    fn ensureDocIndexedFromDisk(self: *LspServer, uri: []const u8) !void {
        if (self.docs.get(uri) != null) return;
        const path = try uriToPath(self.allocator, uri);
        defer self.allocator.free(path);

        const text = try std.fs.cwd().readFileAlloc(self.allocator, path, 25 * 1024 * 1024);
        defer self.allocator.free(text);

        try self.upsertDoc(uri, 0, text);
        try self.rebuildIndex(uri);
    }

    fn resolveImportUri(self: *LspServer, current_uri: []const u8, raw_import: []const u8) !?[]u8 {
        // Supports:
        // - `imp std.c.io;` => <workspace>/stdlib/std/c/io.fn
        // - `imp std.io;`   => <workspace>/stdlib/std/c/io.fn (compat alias)
        // - `imp relative.parent;` => <current_dir>/relative/parent.fn
        // - `imp child;` => <current_dir>/child.fn
        const spec = std.mem.trim(u8, raw_import, " \t\r\n\"");
        if (spec.len == 0) return null;

        const current_path = uriToPath(self.allocator, current_uri) catch return null;
        defer self.allocator.free(current_path);
        const current_dir = std.fs.path.dirname(current_path) orelse return null;

        // Split on '.'
        var parts = std.ArrayList([]const u8).init(self.allocator);
        defer parts.deinit();
        var it = std.mem.splitScalar(u8, spec, '.');
        while (it.next()) |p| {
            const trimmed = std.mem.trim(u8, p, " \t\r");
            if (trimmed.len != 0) try parts.append(trimmed);
        }
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
            try segs.append(root);
            try segs.append("std");
            try segs.append("c");

            if (parts.items.len == 1) return null;
            if (parts.items.len >= 2 and std.mem.eql(u8, parts.items[1], "c")) {
                // `std.c.<module>`
                if (parts.items.len == 2) return null;
                for (parts.items[2..]) |p| try segs.append(p);
            } else {
                // `std.<module>` (compat alias)
                for (parts.items[1..]) |p| try segs.append(p);
            }
        } else {
            try segs.append(current_dir);
            for (parts.items) |p| try segs.append(p);
        }

        // Append .fn
        const joined = try std.fs.path.join(self.allocator, segs.items);
        defer self.allocator.free(joined);

        const full = try std.mem.concat(self.allocator, u8, &[_][]const u8{ joined, ".fn" });
        defer self.allocator.free(full);

        std.fs.cwd().access(full, .{}) catch return null;
        return try pathToUri(self.allocator, full);
    }

    fn publishDiagnostics(self: *LspServer, uri: []const u8, text: []const u8) !void {
        const diags_owned = try self.computeDiagnostics(uri, text);
        defer {
            for (diags_owned) |d| {
                self.allocator.free(d.uri);
                self.allocator.free(d.diag.message);
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
        const tmp_name = try std.fmt.bufPrint(&tmp_name_buf, "_fls_{d}_{d}.fn", .{ std.time.milliTimestamp(), std.time.nanoTimestamp() });

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
        var tmp_name_buf: [64]u8 = undefined;
        const tmp_name = try std.fmt.bufPrint(&tmp_name_buf, "_fls_fmt_{d}.fn", .{std.time.milliTimestamp()});

        {
            const f = try tmp_dir.createFile(tmp_name, .{ .read = true, .truncate = true });
            defer f.close();
            try f.writeAll(text);
        }
        defer tmp_dir.deleteFile(tmp_name) catch {};

        var stderr_buf = std.ArrayList(u8).init(self.allocator);
        defer stderr_buf.deinit();

        const argv = [_][]const u8{ self.fun_exe_path, "-in", tmp_name, "-fmt", "-no-exec" };
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

fn parseFunDiagnosticsByUri(allocator: Allocator, stderr_text: []const u8, current_uri: []const u8, tmp_name: []const u8) ![]DiagnosticWithUri {
    const current_path_opt = uriToPath(allocator, current_uri) catch null;
    defer if (current_path_opt) |p| allocator.free(p);
    const current_dir_opt = if (current_path_opt) |p| std.fs.path.dirname(p) else null;

    var diags = std.ArrayList(DiagnosticWithUri).init(allocator);
    errdefer {
        for (diags.items) |d| {
            allocator.free(d.uri);
            allocator.free(d.diag.message);
        }
        diags.deinit();
    }

    var it = std.mem.splitScalar(u8, stderr_text, '\n');
    var pending_severity: ?i64 = null;
    var pending_message: ?std.ArrayList(u8) = null;
    errdefer if (pending_message) |*m| m.deinit();

    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r\n");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "[Warning]")) {
            pending_severity = 2;
            if (pending_message) |*m| m.deinit();
            pending_message = null;
            continue;
        }
        if (std.mem.startsWith(u8, line, "[Error]") or std.mem.startsWith(u8, line, "[TypeError]")) {
            pending_severity = 1;
            if (pending_message) |*m| m.deinit();
            pending_message = null;
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
                    },
                });
            }

            pending_severity = null;
            if (pending_message) |*m| m.deinit();
            pending_message = null;
        }
    }

    if (pending_message) |*m| m.deinit();
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

    // Compat alias: `std.io` still resolves to the same file.
    const resolved2 = (try server.resolveImportUri(current_uri, "std.io")) orelse return error.TestUnexpectedResult;
    defer allocator.free(resolved2);
    try std.testing.expect(std.mem.eql(u8, resolved2, expected_uri));
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
        }
        allocator.free(diags);
    }

    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expect(std.mem.eql(u8, diags[0].uri, current_uri));
    try std.testing.expect(std.mem.eql(u8, diags[0].diag.message, "boom"));
    try std.testing.expectEqual(@as(i64, 1), diags[0].diag.severity);
    try std.testing.expectEqual(@as(i64, 1), diags[0].diag.range.start.line);
    try std.testing.expectEqual(@as(i64, 0), diags[0].diag.range.start.character);
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

fn findBestDefinition(symbols: []const SymbolLite, name: []const u8, at: Position) ?SymbolLite {
    var best_local: ?SymbolLite = null;
    var best_global: ?SymbolLite = null;

    for (symbols) |s| {
        if (!std.mem.eql(u8, s.name, name)) continue;

        if (s.container_fn_range) |cr| {
            if (!posInRange(at, cr)) continue;
            if (!rangeStartLessOrEqual(s.selection_range, at)) continue;
            if (best_local == null or rangeStartGreater(s.selection_range, best_local.?.selection_range)) {
                best_local = s;
            }
        } else {
            if (best_global == null) best_global = s;
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

const ParsedTextDocPosition = struct { uri: []const u8, pos: Position };

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
    return buildIndexFromTextAt(allocator, text, null);
}

fn buildIndexFromTextAt(allocator: Allocator, text: []const u8, tmp_dir_path_opt: ?[]const u8) !*Index {
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
        .{ .exec = false, .outf = false, .ast = false, .preload_imports = false, .preload_std_imports = false },
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

    // Best-effort parse. On success, we can use AST-backed types/ranges for globals/locals.
    var parse_ok: bool = true;
    {
        var pp = parser.ParseProcess.init(&tp);
        pp.parse() catch {
            parse_ok = false;
        };
    }

    var symbols_out = std.ArrayList(SymbolLite).init(tmp_alloc);

    // Always do lexer-driven indexing first (robust while typing), then optionally
    // overlay/replace globals+locals with AST-backed symbols.
    var symbols_token = std.ArrayList(SymbolLite).init(tmp_alloc);
    try collectSymbolsFromTokens(tmp_alloc, &symbols_token, tp.tokens.items());

    if (parse_ok) {
        // Keep member/field symbols from the lexer scan (AST lacks positions for some of these).
        // Also keep token-derived locals (including implicit `self` and params inside `impl` methods),
        // because the current AST-backed collection does not cover all method-body locals.
        for (symbols_token.items) |s| {
            switch (s.kind) {
                .field, .property, .method => try symbols_out.append(s),
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
    } else {
        // Fallback: token-only symbol index.
        symbols_out = symbols_token;
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

fn enrichSymbolsFromAst(allocator: Allocator, symbols: *std.ArrayList(SymbolLite), tp: *codegen.TranspileProcess) !void {
    var enrich = AstEnrichment.init(allocator);

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
                        try enrich.fn_rtype_by_name.put(fn_name, rt.type_str.items);
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
                        try enrich.field_type_by_key.put(key, f.dtype.type_str.items);
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
                        try enrich.member_rtype_by_key.put(key, m.rtype.type_str.items);
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
                            try enrich.member_rtype_by_key.put(key, rt.type_str.items);
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

    if (include_fun_prefix) {
        try buf.writer().print("fun {s}(", .{name});
    } else {
        try buf.writer().print("{s}(", .{name});
    }

    if (fnv.args) |args| {
        var first: bool = true;
        for (args.items()) |a| {
            if (a.type != .Variable or a.node_variant == null) continue;
            const av = a.node_variant.?.variable;
            if (!first) try buf.appendSlice(", ");
            first = false;
            try buf.writer().print("{s} {s}", .{ av.type.type_str.items, av.name.items });
        }
    }

    try buf.append(')');
    if (fnv.rtype) |rt| {
        try buf.writer().print(" {s}", .{rt.type_str.items});
    }
    return try buf.toOwnedSlice();
}

fn buildQuirkMethodSignatureFromAst(allocator: Allocator, m: ast.QuirkMethodSig) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    try buf.writer().print("{s}(", .{m.name.items});
    var first: bool = true;
    for (m.args.items()) |a| {
        if (!first) try buf.appendSlice(", ");
        first = false;
        try buf.writer().print("{s} {s}", .{ a.dtype.type_str.items, a.name.items });
    }
    try buf.append(')');
    try buf.writer().print(" {s}", .{m.rtype.type_str.items});
    return try buf.toOwnedSlice();
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

    const after_name_i = nextNonTrivialToken(tokens, name_i + 1) orelse return .{ .detail = null, .return_type = null };
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

    const name = tokenString(tokens[name_i]);
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    if (include_fun_prefix) {
        try buf.writer().print("fun {s}(", .{name});
    } else {
        try buf.writer().print("{s}(", .{name});
    }

    // Parse params as `Type name` pairs.
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

        if (!isTypeToken(pt)) {
            pi += 1;
            continue;
        }
        const ptype = tokenString(pt);
        const pname_i = nextNonTrivialToken(tokens, pi + 1) orelse break;
        if (!isIdent(tokens[pname_i])) {
            pi += 1;
            continue;
        }
        const pname = tokenString(tokens[pname_i]);
        if (!first) try buf.appendSlice(", ");
        first = false;
        try buf.writer().print("{s} {s}", .{ ptype, pname });
        pi = pname_i + 1;
    }

    try buf.append(')');

    // Optional return type: `<type>` before `{` or `;`.
    var rtype_owned: ?[]u8 = null;
    const after_rparen_i = nextNonTrivialToken(tokens, rparen_i.? + 1);
    if (after_rparen_i) |ri| {
        const rt = tokens[ri];
        if (isTypeToken(rt)) {
            const rts = tokenString(rt);
            rtype_owned = try allocator.dupe(u8, rts);
            try buf.writer().print(" {s}", .{rts});
        }
    }

    return .{ .detail = try buf.toOwnedSlice(), .return_type = rtype_owned };
}

fn collectSymbolsFromTokens(allocator: Allocator, out: *std.ArrayList(SymbolLite), tokens: []const token.Token) !void {
    var brace_depth: i64 = 0;
    var paren_depth: i64 = 0;

    const ParamLite = struct { name: []const u8, dtype: []const u8 };

    // Track when we're inside any function-ish body so we can index locals.
    // This includes:
    // - `fun name(...) { ... }`
    // - `impl Type { method(...) { ... } }`
    const PendingBodyKind = enum { none, fun_decl, impl_method };

    var pending_body: PendingBodyKind = .none;
    var pending_params = std.ArrayList(ParamLite).init(allocator);
    defer pending_params.deinit();
    var pending_impl_owner: ?[]const u8 = null;

    var in_body: bool = false;
    var body_brace_depth: i64 = 0;
    var body_range: ?Range = null;

    // Track `impl Type { ... }` so we can recognize method declarations.
    var pending_impl_block: bool = false;
    var in_impl_block: bool = false;
    var impl_brace_depth: i64 = 0;
    var impl_owner_name: ?[]const u8 = null;

    const resetPendingBody = struct {
        fn call(kind: *PendingBodyKind, params: *std.ArrayList(ParamLite), owner: *?[]const u8) void {
            kind.* = .none;
            params.clearRetainingCapacity();
            owner.* = null;
        }
    }.call;

    const parseParamsAfterLParen = struct {
        fn call(tokens_: []const token.Token, lparen_i: usize, params: *std.ArrayList(ParamLite)) void {
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
                if (isPunctChar(pt, ',')) {
                    pi += 1;
                    continue;
                }
                if (!isTypeToken(pt)) {
                    pi += 1;
                    continue;
                }
                const ptype = tokenString(pt);
                const pname_i = nextNonTrivialToken(tokens_, pi + 1) orelse break;
                if (!isIdent(tokens_[pname_i])) {
                    pi += 1;
                    continue;
                }
                const pname = tokenString(tokens_[pname_i]);
                params.append(.{ .name = pname, .dtype = ptype }) catch {};
                pi = pname_i + 1;
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
                }
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
                    .value_type = try allocator.dupe(u8, pinfo.dtype),
                    .detail = blk: {
                        var det_buf = std.ArrayList(u8).init(allocator);
                        defer det_buf.deinit();
                        try det_buf.writer().print("{s} {s}", .{ pinfo.dtype, pinfo.name });
                        break :blk try allocator.dupe(u8, det_buf.items);
                    },
                });
            }

            resetPendingBody(&pending_body, &pending_params, &pending_impl_owner);
        }
        if (pending_body != .none and isSymbolChar(t, ';')) {
            // Prototype/no-body.
            resetPendingBody(&pending_body, &pending_params, &pending_impl_owner);
        }
        if (in_body and isSymbolChar(t, '}') and brace_depth < body_brace_depth) {
            in_body = false;
            body_range = null;
        }

        if (isKeyword(t, "fun")) {
            resetPendingBody(&pending_body, &pending_params, &pending_impl_owner);
            pending_body = .fun_decl;
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
                    .container_type = null,
                    .value_type = null,
                    .detail = sig.detail,
                });
                continue;
            };
            if (isPunctChar(tokens[after_name_i], '(')) {
                parseParamsAfterLParen(tokens, after_name_i, &pending_params);
            }

            const sig = try buildSignatureFromTokens(allocator, tokens, name_i, true);
            try out.append(.{
                .name = try allocator.dupe(u8, name),
                .kind = .function,
                .decl_range = r,
                .selection_range = r,
                .container_type = null,
                .value_type = null,
                .detail = sig.detail,
            });
            continue;
        }

        if (isKeyword(t, "compound")) {
            const name_i = nextNonTrivialToken(tokens, i + 1) orelse continue;
            if (!isIdent(tokens[name_i])) continue;
            const name = tokenString(tokens[name_i]);
            const r = rangeFromTokenPos(tokens[name_i].pos);
            try out.append(.{
                .name = try allocator.dupe(u8, name),
                .kind = .struct_,
                .decl_range = r,
                .selection_range = r,
                .container_type = null,
                .value_type = null,
                .detail = null,
            });

            // Best-effort field indexing inside `compound Name { Type field; ... }`.
            // This is lexer-driven to stay robust while typing.
            const owner_name = name;
            // Find opening '{'
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

                        if (!isTypeToken(tk)) continue;
                        const field_name_i = nextNonTrivialToken(tokens, k + 1) orelse continue;
                        if (!isIdent(tokens[field_name_i])) continue;

                        const after_name_i = nextNonTrivialToken(tokens, field_name_i + 1) orelse continue;
                        if (!isSymbolChar(tokens[after_name_i], ';')) continue;

                        const ftype = tokenString(tk);
                        const fname = tokenString(tokens[field_name_i]);
                        const fr = rangeFromTokenPos(tokens[field_name_i].pos);
                        try out.append(.{
                            .name = try allocator.dupe(u8, fname),
                            .kind = .field,
                            .decl_range = fr,
                            .selection_range = fr,
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

        if (isKeyword(t, "quirk")) {
            const name_i = nextNonTrivialToken(tokens, i + 1) orelse continue;
            if (!isIdent(tokens[name_i])) continue;
            const name = tokenString(tokens[name_i]);
            const r = rangeFromTokenPos(tokens[name_i].pos);
            try out.append(.{
                .name = try allocator.dupe(u8, name),
                .kind = .interface,
                .decl_range = r,
                .selection_range = r,
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
            const type_i2 = nextNonTrivialToken(tokens, i + 1) orelse {
                impl_owner_name = null;
                continue;
            };
            if (isIdent(tokens[type_i2])) {
                impl_owner_name = tokenString(tokens[type_i2]);
            } else {
                impl_owner_name = null;
            }
            // impl <Type> [<Quirk>] { ... }
            const type_i = nextNonTrivialToken(tokens, i + 1) orelse continue;
            if (!isIdent(tokens[type_i])) continue;
            const owner_name = tokenString(tokens[type_i]);
            // Find opening '{'
            var j_opt = nextNonTrivialToken(tokens, type_i + 1);
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

                        const mname = tokenString(tk);
                        const r = rangeFromTokenPos(tk.pos);
                        try out.append(.{
                            .name = try allocator.dupe(u8, mname),
                            .kind = .method,
                            .decl_range = r,
                            .selection_range = r,
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
                resetPendingBody(&pending_body, &pending_params, &pending_impl_owner);
                pending_body = .impl_method;
                pending_impl_owner = impl_owner_name;
                parseParamsAfterLParen(tokens, after_name_i.?, &pending_params);
            }
        }

        // Best-effort local variable indexing (token-based): `Type name;` or `Type name = ...;`.
        // Attach locals to the enclosing `fun { ... }` body.
        if (in_body and isTypeToken(t)) {
            // Avoid `compound X`, `quirk X`, `impl X`, `fun name`.
            if (i > 0 and tokens[i - 1].type == .Keyword) {
                const kw = tokenString(tokens[i - 1]);
                if (std.mem.eql(u8, kw, "compound") or std.mem.eql(u8, kw, "quirk") or std.mem.eql(u8, kw, "impl") or std.mem.eql(u8, kw, "fun")) {
                    continue;
                }
            }

            const name_i = nextNonTrivialToken(tokens, i + 1) orelse continue;
            if (!isIdent(tokens[name_i])) continue;

            // Avoid pairing across lines (e.g. `p` then next-line `p.x...`) which would
            // create bogus locals like `p p`.
            if (tokens[i].pos.line != tokens[name_i].pos.line) continue;

            // Require declaration terminator after the name.
            const first_after_i = nextNonTrivialToken(tokens, name_i + 1) orelse continue;
            if (!(isPunctChar(tokens[first_after_i], ';') or isPunctChar(tokens[first_after_i], '=') or isPunctChar(tokens[first_after_i], ','))) continue;

            const vtype = tokenString(t);

            // Support `Type a, b, c;` by walking commas until a terminator.
            var cur_name_i: usize = name_i;
            while (true) {
                const vname = tokenString(tokens[cur_name_i]);
                const r = rangeFromTokenPos(tokens[cur_name_i].pos);

                var det_buf = std.ArrayList(u8).init(allocator);
                defer det_buf.deinit();
                try det_buf.writer().print("{s} {s}", .{ vtype, vname });

                try out.append(.{
                    .name = try allocator.dupe(u8, vname),
                    .kind = .variable,
                    .decl_range = r,
                    .selection_range = r,
                    .container_fn_range = body_range.?,
                    .container_type = null,
                    .value_type = try allocator.dupe(u8, vtype),
                    .detail = try allocator.dupe(u8, det_buf.items),
                });

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

            const name_i = nextNonTrivialToken(tokens, i + 1) orelse continue;
            if (!isIdent(tokens[name_i])) continue;
            const after_i = nextNonTrivialToken(tokens, name_i + 1) orelse continue;
            const after = tokens[after_i];
            if (!(isPunctChar(after, ';') or isPunctChar(after, '=') or isPunctChar(after, ','))) continue;

            const vtype = tokenString(t);
            const vname = tokenString(tokens[name_i]);
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
            });
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
            try detail_buf.writer().print("{s} {s}", .{ v.type.type_str.items, name });

            try out.append(.{
                .name = try allocator.dupe(u8, name),
                .kind = .variable,
                .decl_range = r,
                .selection_range = r,
                .container_type = null,
                .value_type = try allocator.dupe(u8, v.type.type_str.items),
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
            try out.append(.{
                .name = try allocator.dupe(u8, name),
                .kind = .struct_,
                .decl_range = r,
                .selection_range = r,
                .container_type = null,
                .value_type = null,
                .detail = null,
            });
        },
        .Quirk => {
            const q = n.node_variant.?.quirk;
            const name = q.name.items;
            const r = if (n.pos) |p| rangeFromTokenPos(p) else Range{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };
            try out.append(.{
                .name = try allocator.dupe(u8, name),
                .kind = .interface,
                .decl_range = r,
                .selection_range = r,
                .container_type = null,
                .value_type = null,
                .detail = null,
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
    try buf.writer().print("fun {s}(", .{name});
    if (fnv.args) |args| {
        var first = true;
        for (args.items()) |a| {
            if (a.type != .Variable or a.node_variant == null) continue;
            const vv = a.node_variant.?.variable;
            const arg_name = vv.name.items;
            const dt = vv.type.*;
            const dt_str = dt.type_str.items;
            if (!first) try buf.appendSlice(", ");
            first = false;
            try buf.writer().print("{s} {s}", .{ dt_str, arg_name });
        }
    }
    if (fnv.is_variadic) {
        if (fnv.args != null and fnv.args.?.items().len != 0) try buf.appendSlice(", ");
        try buf.appendSlice("...");
    }
    try buf.appendSlice(")");
    if (fnv.rtype) |rt| {
        if (rt.type != .Unknown) {
            try buf.writer().print(" -> {s}", .{rt.type_str.items});
        }
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
            try detail_buf.writer().print("{s} {s}", .{ v.type.type_str.items, name });
            const det = try detail_buf.toOwnedSlice();
            try out.append(.{
                .name = try allocator.dupe(u8, name),
                .kind = .variable,
                .decl_range = r,
                .selection_range = r,
                .container_fn_range = container_fn_range,
                .container_type = null,
                .value_type = try allocator.dupe(u8, v.type.type_str.items),
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

const GuessedCallSignature = struct { label: []const u8, active_param: i64 };

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
            .struct_, .interface => 7,
            .variable => 6,
            .field, .property, .constant => 6,
            else => 6,
        };
    }
    return 6;
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
            .boolean => 0,
            .operator, .symbol => 4,
            .identifier => blk: {
                // Member access: `.name` => variable/function depending on call usage.
                if (ti > 0 and isDotToken(idx.tokens[ti - 1])) {
                    var j1: usize = ti + 1;
                    while (j1 < idx.tokens.len and idx.tokens[j1].kind == .comment) : (j1 += 1) {}
                    if (j1 < idx.tokens.len) {
                        const nt1 = idx.tokens[j1];
                        if ((nt1.kind == .symbol or nt1.kind == .operator) and std.mem.eql(u8, nt1.text, "(")) {
                            break :blk 5; // function
                        }
                    }
                    break :blk 6; // variable
                }

                // Heuristic: treat `Type name;` / `Type name =` / `Type name,` as a type position,
                // even if the type name isn't in this document's symbol table.
                var j0: usize = ti + 1;
                while (j0 < idx.tokens.len and idx.tokens[j0].kind == .comment) : (j0 += 1) {}
                if (j0 < idx.tokens.len and idx.tokens[j0].kind == .identifier) {
                    var k0: usize = j0 + 1;
                    while (k0 < idx.tokens.len and idx.tokens[k0].kind == .comment) : (k0 += 1) {}
                    if (k0 < idx.tokens.len) {
                        const nt0 = idx.tokens[k0];
                        if ((nt0.kind == .symbol or nt0.kind == .operator) and
                            (std.mem.eql(u8, nt0.text, ";") or std.mem.eql(u8, nt0.text, "=") or std.mem.eql(u8, nt0.text, ",")))
                        {
                            // Check if the type is a known struct/compound/interface in the symbol table.
                            const type_by_symbol = classifyIdentifierTokenType(idx, t.text);
                            if (type_by_symbol == 7) {
                                break :blk 7; // type
                            }
                        }
                    }
                }

                // Prefer symbol-table classification.
                const by_symbol = classifyIdentifierTokenType(idx, t.text);
                if (by_symbol == 5 or by_symbol == 7) break :blk by_symbol;

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
        const modifiers: u32 = 0;

        try data.appendSlice(&[_]u32{ delta_line, delta_start, length, token_type, modifiers });
        last_line = start_line;
        last_start = start_char;
        have_last = true;
    }

    return data.toOwnedSlice();
}
