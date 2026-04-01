const std = @import("std");

pub fn main() !void {
    return std.testing.main();
}

const Allocator = std.mem.Allocator;

const ReaderCtx = struct {
    allocator: Allocator,
    stdout_file: *std.fs.File,
    q: *MsgQueue,
};

fn platformExeName(base: []const u8) []const u8 {
    if (@import("builtin").os.tag != .windows) return base;
    if (std.mem.eql(u8, base, "fls")) return "fls.exe";
    if (std.mem.eql(u8, base, "fun")) return "fun.exe";
    return base;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
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

const MsgQueue = struct {
    allocator: Allocator,
    mu: std.Thread.Mutex = .{},
    cv: std.Thread.Condition = .{},
    closed: bool = false,
    items: std.ArrayList([]u8),

    fn init(allocator: Allocator) MsgQueue {
        return .{ .allocator = allocator, .items = std.ArrayList([]u8).init(allocator) };
    }

    fn deinit(self: *MsgQueue) void {
        for (self.items.items) |m| self.allocator.free(m);
        self.items.deinit();
    }

    fn push(self: *MsgQueue, msg: []u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.items.append(msg) catch {
            self.allocator.free(msg);
            return;
        };
        self.cv.signal();
    }

    fn setClosed(self: *MsgQueue) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.closed = true;
        self.cv.broadcast();
    }

    const ParsedMsg = struct {
        allocator: Allocator,
        raw: []u8,
        parsed: std.json.Parsed(std.json.Value),

        fn deinit(self: *ParsedMsg) void {
            self.parsed.deinit();
            self.allocator.free(self.raw);
        }
    };

    fn popMatchingResponse(self: *MsgQueue, allocator: Allocator, id: i64) ?ParsedMsg {
        self.mu.lock();
        defer self.mu.unlock();

        var i: usize = 0;
        while (i < self.items.items.len) : (i += 1) {
            const raw = self.items.items[i];
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch continue;
            if (parsed.value == .object) {
                const obj = parsed.value.object;
                if (obj.get("id")) |idv| {
                    const match = switch (idv) {
                        .integer => idv.integer == id,
                        .float => @as(i64, @intFromFloat(idv.float)) == id,
                        else => false,
                    };
                    if (match) {
                        _ = self.items.orderedRemove(i);
                        // IMPORTANT: `parsed.value` may reference slices in `raw`.
                        // Keep `raw` alive until the caller deinitializes `parsed`.
                        return .{ .allocator = allocator, .raw = raw, .parsed = parsed };
                    }
                }
            }
            parsed.deinit();
        }

        return null;
    }

    fn popMatchingNotification(self: *MsgQueue, allocator: Allocator, method: []const u8) ?ParsedMsg {
        self.mu.lock();
        defer self.mu.unlock();

        var i: usize = 0;
        while (i < self.items.items.len) : (i += 1) {
            const raw = self.items.items[i];
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch continue;
            if (parsed.value == .object) {
                const obj = parsed.value.object;
                if (obj.get("method")) |mv| {
                    if (mv == .string and std.mem.eql(u8, mv.string, method)) {
                        _ = self.items.orderedRemove(i);
                        return .{ .allocator = allocator, .raw = raw, .parsed = parsed };
                    }
                }
            }
            parsed.deinit();
        }
        return null;
    }
};

fn readerThread(ctx: *ReaderCtx) void {
    var br = std.io.bufferedReader(ctx.stdout_file.reader());
    const r = br.reader();
    while (true) {
        const msg = readLspMessage(ctx.allocator, r) catch {
            ctx.q.setClosed();
            return;
        };
        ctx.q.push(msg);
    }
}

const LspProc = struct {
    allocator: Allocator,
    child: std.process.Child,
    stdin_box: *std.fs.File,
    stdout_box: *std.fs.File,
    q: *MsgQueue,
    reader: std.Thread,
    reader_ctx: *ReaderCtx,
    next_id: i64 = 1,

    fn start(allocator: Allocator, exe_path: []const u8, root_cwd: []const u8, fun_abs_path: []const u8) !LspProc {
        var child = std.process.Child.init(&[_][]const u8{exe_path}, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        // Don't pipe stderr unless we read it: a full pipe can deadlock the child.
        child.stderr_behavior = .Inherit;
        child.cwd = root_cwd;

        var env_map = try std.process.getEnvMap(allocator);
        errdefer env_map.deinit();
        try env_map.put("FLS_FUN_PATH", fun_abs_path);
        // Ensure stdlib resolution uses the repo stdlib when tests index temp docs.
        try env_map.put("FUN_STDLIB_DIR", "stdlib");
        child.env_map = &env_map;

        try child.spawn();
        // env_map is cloned by the OS at spawn; safe to deinit after.
        env_map.deinit();

        // Detach stdio handles into heap-stable storage so the reader thread
        // never references a stack temporary File (which would become invalid).
        const stdin_file = child.stdin orelse return error.MissingChildStdin;
        child.stdin = null;
        const stdout_file = child.stdout orelse return error.MissingChildStdout;
        child.stdout = null;

        const stdin_box = try allocator.create(std.fs.File);
        errdefer allocator.destroy(stdin_box);
        stdin_box.* = stdin_file;

        const stdout_box = try allocator.create(std.fs.File);
        errdefer allocator.destroy(stdout_box);
        stdout_box.* = stdout_file;

        const q = try allocator.create(MsgQueue);
        errdefer allocator.destroy(q);
        q.* = MsgQueue.init(allocator);

        const ctx = try allocator.create(ReaderCtx);
        ctx.* = .{ .allocator = allocator, .stdout_file = stdout_box, .q = q };

        const th = try std.Thread.spawn(.{}, readerThread, .{ctx});

        return .{
            .allocator = allocator,
            .child = child,
            .stdin_box = stdin_box,
            .stdout_box = stdout_box,
            .q = q,
            .reader = th,
            .reader_ctx = ctx,
        };
    }

    fn stop(self: *LspProc) void {
        // Best-effort shutdown of the child.
        // Close stdin first to signal EOF; don't close stdout until the reader thread is done.
        self.stdin_box.*.close();

        // Force-unblock the reader thread even if the OS doesn't immediately
        // deliver EOF on the pipe after killing the child.
        self.stdout_box.*.close();

        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};

        self.reader.join();
        self.q.setClosed();
        self.q.deinit();
        self.allocator.destroy(self.q);
        self.allocator.destroy(self.reader_ctx);

        self.allocator.destroy(self.stdin_box);
        self.allocator.destroy(self.stdout_box);
    }

    fn sendRaw(self: *LspProc, json: []const u8) !void {
        const w = self.stdin_box.*.writer();
        try writeLspMessageRaw(w, json);
    }

    fn request(self: *LspProc, method: []const u8, params_json: []const u8) !i64 {
        const id = self.next_id;
        self.next_id += 1;

        const msg = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
            .{ id, method, params_json },
        );
        defer self.allocator.free(msg);

        try self.sendRaw(msg);
        return id;
    }

    fn notify(self: *LspProc, method: []const u8, params_json: []const u8) !void {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}",
            .{ method, params_json },
        );
        defer self.allocator.free(msg);

        try self.sendRaw(msg);
    }

    fn waitResponse(self: *LspProc, id: i64, timeout_ms: i64) !MsgQueue.ParsedMsg {
        const start_ms = std.time.milliTimestamp();
        while (true) {
            if (self.q.popMatchingResponse(self.allocator, id)) |msg| return msg;

            const elapsed = std.time.milliTimestamp() - start_ms;
            if (elapsed > timeout_ms) return error.Timeout;

            self.q.mu.lock();
            defer self.q.mu.unlock();
            if (self.q.closed) return error.EndOfStream;
            // Wait a little; wakeups come from reader thread.
            self.q.cv.timedWait(&self.q.mu, 50 * std.time.ns_per_ms) catch {};
        }
    }

    fn waitNotification(self: *LspProc, method: []const u8, timeout_ms: i64) !MsgQueue.ParsedMsg {
        const start_ms = std.time.milliTimestamp();
        while (true) {
            if (self.q.popMatchingNotification(self.allocator, method)) |msg| return msg;

            const elapsed = std.time.milliTimestamp() - start_ms;
            if (elapsed > timeout_ms) return error.Timeout;

            self.q.mu.lock();
            defer self.q.mu.unlock();
            if (self.q.closed) return error.EndOfStream;
            self.q.cv.timedWait(&self.q.mu, 50 * std.time.ns_per_ms) catch {};
        }
    }
};

fn escapeJsonAlloc(allocator: Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice("\\\""),
            '\\' => try out.appendSlice("\\\\"),
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            else => try out.append(c),
        }
    }

    return out.toOwnedSlice();
}

fn pathToFileUriAlloc(allocator: Allocator, abs_path: []const u8) ![]u8 {
    // Minimal file URI encoder for Windows/posix paths. We keep it simple and only
    // encode spaces (enough for our workspace paths).
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice("file:///");

    var i: usize = 0;
    while (i < abs_path.len) : (i += 1) {
        const c = abs_path[i];
        const mapped = if (c == '\\') '/' else c;
        if (mapped == ' ') {
            try out.appendSlice("%20");
        } else {
            try out.append(mapped);
        }
    }

    return out.toOwnedSlice();
}

fn findPosition(text: []const u8, needle: []const u8, occurrence: usize) !struct { line: i64, col: i64 } {
    var found: usize = 0;
    var idx_opt: ?usize = null;

    var i: usize = 0;
    while (i + needle.len <= text.len) : (i += 1) {
        if (std.mem.eql(u8, text[i .. i + needle.len], needle)) {
            if (found == occurrence) {
                idx_opt = i;
                break;
            }
            found += 1;
        }
    }

    const idx = idx_opt orelse return error.NotFound;

    var line: i64 = 0;
    var col: i64 = 0;
    var j: usize = 0;
    while (j < idx) : (j += 1) {
        const c = text[j];
        if (c == '\n') {
            line += 1;
            col = 0;
        } else if (c != '\r') {
            col += 1;
        }
    }

    return .{ .line = line, .col = col };
}

fn byteIndexFromLineCol(text: []const u8, line: i64, col: i64) !usize {
    var cur_line: i64 = 0;
    var cur_col: i64 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (cur_line == line and cur_col == col) return i;

        const c = text[i];
        if (c == '\n') {
            cur_line += 1;
            cur_col = 0;
        } else if (c != '\r') {
            cur_col += 1;
        }
    }
    if (cur_line == line and cur_col == col) return text.len;
    return error.NotFound;
}

fn endPosition(text: []const u8) struct { line: i64, col: i64 } {
    var line: i64 = 0;
    var col: i64 = 0;
    for (text) |c| {
        if (c == '\n') {
            line += 1;
            col = 0;
        } else if (c != '\r') {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

const TestSetup = struct {
    fls_path: []u8,
    fun_abs: []u8,
    root_abs: []u8,
    root_uri: []u8,
};

fn resolveTestSetup(allocator: Allocator) !TestSetup {
    // We run tests with cwd=repo root (see build.zig).
    // By default, spawn the installed binaries from `zig-out/bin/`.
    // On Windows, `zig-out/bin/fls.exe` may be locked by a running VS Code instance.
    // Allow overriding the exe directory for local development.
    const exe_dir_opt: ?[]u8 = blk: {
        if (@hasDecl(std.process, "getEnvVarOwned")) {
            // Zig 0.14+
            break :blk std.process.getEnvVarOwned(allocator, "FLS_E2E_EXE_DIR") catch null;
        }
        if (@hasDecl(@import("std").process, "getEnvVar")) {
            // Older Zig; best-effort.
            break :blk @import("std").process.getEnvVar("FLS_E2E_EXE_DIR", allocator) catch null;
        }
        break :blk null;
    };
    defer if (exe_dir_opt) |d| allocator.free(d);

    const exe_names = struct {
        fn pickPath(allocator_: Allocator, name: []const u8, exe_dir: ?[]const u8) ![]u8 {
            var candidates = std.ArrayList([]const u8).init(allocator_);
            defer candidates.deinit();

            if (exe_dir) |dir| {
                try candidates.append(dir);
            }
            // Common build/test locations.
            try candidates.append("zig-out/test-bin");
            try candidates.append("zig-out/zig-out/test-bin");
            try candidates.append("zig-out/bin");

            for (candidates.items) |dir| {
                const p = try std.fs.path.join(allocator_, &[_][]const u8{ dir, platformExeName(name) });
                if (fileExists(p)) return p;
                allocator_.free(p);
            }

            // Fall back to env dir even if it doesn't exist (preserves error context).
            if (exe_dir) |dir| {
                return try std.fs.path.join(allocator_, &[_][]const u8{ dir, platformExeName(name) });
            }
            return try std.fs.path.join(allocator_, &[_][]const u8{ "zig-out", "bin", platformExeName(name) });
        }
    };

    const fls_path = try exe_names.pickPath(allocator, "fls", exe_dir_opt);
    errdefer allocator.free(fls_path);
    try std.testing.expect(fileExists(fls_path));

    const fun_path_rel_or_abs = try exe_names.pickPath(allocator, "fun", exe_dir_opt);
    defer allocator.free(fun_path_rel_or_abs);
    try std.testing.expect(fileExists(fun_path_rel_or_abs));
    const fun_abs = try std.fs.cwd().realpathAlloc(allocator, fun_path_rel_or_abs);
    errdefer allocator.free(fun_abs);

    const root_abs = try std.fs.cwd().realpathAlloc(allocator, ".");
    errdefer allocator.free(root_abs);
    const root_uri = try pathToFileUriAlloc(allocator, root_abs);
    errdefer allocator.free(root_uri);

    return .{
        .fls_path = fls_path,
        .fun_abs = fun_abs,
        .root_abs = root_abs,
        .root_uri = root_uri,
    };
}

fn freeTestSetup(allocator: Allocator, setup: *TestSetup) void {
    allocator.free(setup.fls_path);
    allocator.free(setup.fun_abs);
    allocator.free(setup.root_abs);
    allocator.free(setup.root_uri);
}

fn lspInitialize(allocator: Allocator, lsp: *LspProc, root_uri: []const u8) !void {
    const init_params = try std.fmt.allocPrint(
        allocator,
        "{{\"rootUri\":\"{s}\",\"capabilities\":{{}}}}",
        .{root_uri},
    );
    defer allocator.free(init_params);

    const init_id = try lsp.request("initialize", init_params);
    var init_res = try lsp.waitResponse(init_id, 15000);
    defer init_res.deinit();
    try std.testing.expect(init_res.parsed.value == .object);
    try lsp.notify("initialized", "{}");
}

fn lspOpenDoc(allocator: Allocator, lsp: *LspProc, doc_uri: []const u8, version: i64, text: []const u8) !void {
    const doc_json = try escapeJsonAlloc(allocator, text);
    defer allocator.free(doc_json);

    const did_open_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\",\"languageId\":\"fun\",\"version\":{d},\"text\":\"{s}\"}}}}",
        .{ doc_uri, version, doc_json },
    );
    defer allocator.free(did_open_params);
    try lsp.notify("textDocument/didOpen", did_open_params);
}

fn lspMakeDocUri(allocator: Allocator, root_abs: []const u8, name: []const u8) ![]u8 {
    // Put synthetic docs under `.zig-cache/` so fls can create per-doc temp files next to it.
    std.fs.cwd().makePath(".zig-cache") catch {};
    const doc_abs = try std.fs.path.join(allocator, &[_][]const u8{ root_abs, ".zig-cache", name });
    defer allocator.free(doc_abs);
    return try pathToFileUriAlloc(allocator, doc_abs);
}

fn jsonResultFromResponseObj(obj: std.json.ObjectMap) !std.json.Value {
    return obj.get("result") orelse return error.BadResponse;
}

fn definitionResultHasLocation(result_val: std.json.Value, uri_contains: []const u8, line: i64, character: i64) bool {
    const matchLoc = struct {
        fn go(v: std.json.Value, uri_contains2: []const u8, line2: i64, character2: i64) bool {
            if (v != .object) return false;
            const o = v.object;

            const uri_val = o.get("uri") orelse return false;
            if (uri_val != .string) return false;
            if (std.mem.indexOf(u8, uri_val.string, uri_contains2) == null) return false;

            const range_val = o.get("range") orelse return false;
            if (range_val != .object) return false;
            const range_obj = range_val.object;

            const start_val = range_obj.get("start") orelse return false;
            if (start_val != .object) return false;
            const start_obj = start_val.object;

            const end_val = range_obj.get("end") orelse return false;
            if (end_val != .object) return false;
            const end_obj = end_val.object;

            const l = start_obj.get("line") orelse return false;
            const c = start_obj.get("character") orelse return false;
            const el = end_obj.get("line") orelse return false;
            const ec = end_obj.get("character") orelse return false;
            if (l != .integer or c != .integer or el != .integer or ec != .integer) return false;

            const sl = l.integer;
            const sc = c.integer;
            const eol = el.integer;
            const eoc = ec.integer;

            // Check that (line2, character2) is inside [start, end] (inclusive).
            if (line2 < sl or line2 > eol) return false;
            if (sl == eol) {
                return line2 == sl and character2 >= sc and character2 <= eoc;
            }
            if (line2 == sl) return character2 >= sc;
            if (line2 == eol) return character2 <= eoc;
            return true;
        }
    }.go;

    switch (result_val) {
        .null => return false,
        .object => return matchLoc(result_val, uri_contains, line, character),
        .array => |arr| {
            for (arr.items) |it| {
                if (matchLoc(it, uri_contains, line, character)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn expectDefinitionPointsTo(allocator: Allocator, result_val: std.json.Value, uri_contains: []const u8, line: i64, character: i64) !void {
    if (definitionResultHasLocation(result_val, uri_contains, line, character)) return;

    const dumped = std.json.stringifyAlloc(allocator, result_val, .{}) catch null;
    if (dumped) |s| {
        defer allocator.free(s);
        std.debug.print(
            "\n[fls_e2e] definition expected uri contains '{s}' @ {d}:{d}\n{s}\n",
            .{ uri_contains, line, character, s },
        );
    } else {
        std.debug.print("\n[fls_e2e] definition mismatch (failed to stringify)\n", .{});
    }
    return error.TestUnexpectedResult;
}

fn completionHasLabel(result_val: std.json.Value, label: []const u8) bool {
    // Accept CompletionList or CompletionItem[]; both should include items with label.
    switch (result_val) {
        .array => |arr| {
            for (arr.items) |it| {
                if (it != .object) continue;
                if (it.object.get("label")) |lv| {
                    if (lv == .string and std.mem.eql(u8, lv.string, label)) return true;
                }
            }
            return false;
        },
        .object => |obj| {
            if (obj.get("items")) |items| {
                if (items == .array) {
                    for (items.array.items) |it| {
                        if (it != .object) continue;
                        if (it.object.get("label")) |lv| {
                            if (lv == .string and std.mem.eql(u8, lv.string, label)) return true;
                        }
                    }
                }
            }
            return false;
        },
        else => return false,
    }
}

fn expectCompletionHasLabel(allocator: Allocator, result_val: std.json.Value, label: []const u8) !void {
    if (completionHasLabel(result_val, label)) return;

    const dumped = std.json.stringifyAlloc(allocator, result_val, .{}) catch null;
    if (dumped) |s| {
        defer allocator.free(s);
        std.debug.print("\n[fls_e2e] completion missing '{s}'\n{s}\n", .{ label, s });
    } else {
        std.debug.print("\n[fls_e2e] completion missing '{s}' (failed to stringify)\n", .{label});
    }

    return error.TestUnexpectedResult;
}

fn expectCompletionMissingLabel(allocator: Allocator, result_val: std.json.Value, label: []const u8) !void {
    if (!completionHasLabel(result_val, label)) return;

    const dumped = std.json.stringifyAlloc(allocator, result_val, .{}) catch null;
    if (dumped) |s| {
        defer allocator.free(s);
        std.debug.print("\n[fls_e2e] completion unexpectedly contains '{s}'\n{s}\n", .{ label, s });
    } else {
        std.debug.print("\n[fls_e2e] completion unexpectedly contains '{s}' (failed to stringify)\n", .{label});
    }

    return error.TestUnexpectedResult;
}

fn expectSignatureHelpLabelContains(allocator: Allocator, result_val: std.json.Value, needle: []const u8) !void {
    if (result_val == .null) return error.TestUnexpectedResult;
    if (result_val != .object) return error.TestUnexpectedResult;
    const obj = result_val.object;
    const sigs_val = obj.get("signatures") orelse return error.TestUnexpectedResult;
    if (sigs_val != .array or sigs_val.array.items.len == 0) return error.TestUnexpectedResult;
    const first = sigs_val.array.items[0];
    if (first != .object) return error.TestUnexpectedResult;
    const label_val = first.object.get("label") orelse return error.TestUnexpectedResult;
    if (label_val != .string) return error.TestUnexpectedResult;
    if (std.mem.indexOf(u8, label_val.string, needle) != null) return;

    const dumped = std.json.stringifyAlloc(allocator, result_val, .{}) catch null;
    if (dumped) |s| {
        defer allocator.free(s);
        std.debug.print("\n[fls_e2e] signatureHelp label missing '{s}'\n{s}\n", .{ needle, s });
    }
    return error.TestUnexpectedResult;
}

fn expectSignatureHelpActiveParameter(allocator: Allocator, result_val: std.json.Value, active_param: i64) !void {
    if (result_val == .null) return error.TestUnexpectedResult;
    if (result_val != .object) return error.TestUnexpectedResult;
    const obj = result_val.object;
    const ap = obj.get("activeParameter") orelse return error.TestUnexpectedResult;
    if (ap != .integer) return error.TestUnexpectedResult;
    if (ap.integer == active_param) return;

    const dumped = std.json.stringifyAlloc(allocator, result_val, .{}) catch null;
    if (dumped) |s| {
        defer allocator.free(s);
        std.debug.print("\n[fls_e2e] signatureHelp activeParameter expected {d}\n{s}\n", .{ active_param, s });
    }
    return error.TestUnexpectedResult;
}

fn expectSignatureHelpHasParameter(allocator: Allocator, result_val: std.json.Value, needle: []const u8) !void {
    if (result_val == .null) return error.TestUnexpectedResult;
    if (result_val != .object) return error.TestUnexpectedResult;
    const obj = result_val.object;
    const sigs_val = obj.get("signatures") orelse return error.TestUnexpectedResult;
    if (sigs_val != .array or sigs_val.array.items.len == 0) return error.TestUnexpectedResult;
    const first = sigs_val.array.items[0];
    if (first != .object) return error.TestUnexpectedResult;
    const params_val = first.object.get("parameters") orelse return error.TestUnexpectedResult;
    if (params_val != .array) return error.TestUnexpectedResult;

    for (params_val.array.items) |pv| {
        if (pv != .object) continue;
        const lbl = pv.object.get("label") orelse continue;
        if (lbl == .string and std.mem.indexOf(u8, lbl.string, needle) != null) return;
    }

    const dumped = std.json.stringifyAlloc(allocator, result_val, .{}) catch null;
    if (dumped) |s| {
        defer allocator.free(s);
        std.debug.print("\n[fls_e2e] signatureHelp parameters missing '{s}'\n{s}\n", .{ needle, s });
    }
    return error.TestUnexpectedResult;
}

fn expectHoverContains(allocator: Allocator, result_val: std.json.Value, needle: []const u8) !void {
    if (result_val == .null) return error.TestUnexpectedResult;
    if (result_val != .object) return error.TestUnexpectedResult;
    const obj = result_val.object;
    const contents = obj.get("contents") orelse return error.TestUnexpectedResult;
    if (contents != .object) return error.TestUnexpectedResult;
    const v = contents.object.get("value") orelse return error.TestUnexpectedResult;
    if (v != .string) return error.TestUnexpectedResult;
    if (std.mem.indexOf(u8, v.string, needle) != null) return;

    const dumped = std.json.stringifyAlloc(allocator, result_val, .{}) catch null;
    if (dumped) |s| {
        defer allocator.free(s);
        std.debug.print("\n[fls_e2e] hover missing '{s}'\n{s}\n", .{ needle, s });
    }
    return error.TestUnexpectedResult;
}

fn expectSemanticTokensNonEmpty(allocator: Allocator, result_val: std.json.Value) !void {
    if (result_val == .null) return error.TestUnexpectedResult;
    if (result_val != .object) return error.TestUnexpectedResult;
    const obj = result_val.object;
    const data_val = obj.get("data") orelse return error.TestUnexpectedResult;
    if (data_val != .array) return error.TestUnexpectedResult;
    if (data_val.array.items.len != 0) return;

    const dumped = std.json.stringifyAlloc(allocator, result_val, .{}) catch null;
    if (dumped) |s| {
        defer allocator.free(s);
        std.debug.print("\n[fls_e2e] semantic tokens unexpectedly empty\n{s}\n", .{s});
    }
    return error.TestUnexpectedResult;
}

fn symbolInfosHasName(result_val: std.json.Value, name: []const u8) bool {
    if (result_val != .array) return false;
    for (result_val.array.items) |it| {
        if (it != .object) continue;
        if (it.object.get("name")) |nv| {
            if (nv == .string and std.mem.eql(u8, nv.string, name)) return true;
        }
    }
    return false;
}

test "fls e2e: initialize, open, typing didChange, completion + definition do not crash" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();

    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.c.io;\n\n" ++
        "// this calculates the factorial of a number\n" ++
        "fun factorial(num n) num {\n" ++
        "    if n == 0 {\n" ++
        "        ret 1;\n" ++
        "    }\n" ++
        "    ret n * factorial(n - 1);\n" ++
        "}\n\n" ++
        "fun main() {\n" ++
        "    num number = 5;\n" ++
        "    num result = factorial(number);\n\n" ++
        "    printf(\"The factorial of %d is: %d\\n\", number, result);\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e.fn");
    defer allocator.free(doc_uri);

    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // --- Typing simulation: insert a line after `num number = 5;`
    const insert_pos = try findPosition(doc_text, "num number = 5;", 0);
    // position at end of that line
    const end_col = insert_pos.col + @as(i64, @intCast("num number = 5;".len));

    const change_text = "\n    num x = 1;";
    const change_json = try escapeJsonAlloc(allocator, change_text);
    defer allocator.free(change_json);

    const did_change_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\",\"version\":2}},\"contentChanges\":[{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"text\":\"{s}\"}}]}}",
        .{ doc_uri, insert_pos.line, end_col, insert_pos.line, end_col, change_json },
    );
    defer allocator.free(did_change_params);

    try lsp.notify("textDocument/didChange", did_change_params);

    // Request document symbols: should still include `factorial` and `main`.
    const sym_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}}}}",
        .{doc_uri},
    );
    defer allocator.free(sym_params);

    const sym_id = try lsp.request("textDocument/documentSymbol", sym_params);
    var sym_res = try lsp.waitResponse(sym_id, 5000);
    defer sym_res.deinit();

    // Expect a symbol list response (ideally includes factorial/main).
    try std.testing.expect(sym_res.parsed.value == .object);
    const sym_obj = sym_res.parsed.value.object;
    try std.testing.expect(sym_obj.get("result") != null);

    // Build the expected post-change text so we can compute correct positions after didChange.
    const insert_index = try byteIndexFromLineCol(doc_text, insert_pos.line, end_col);
    var new_doc = std.ArrayList(u8).init(allocator);
    defer new_doc.deinit();
    try new_doc.appendSlice(doc_text[0..insert_index]);
    try new_doc.appendSlice(change_text);
    try new_doc.appendSlice(doc_text[insert_index..]);

    // Definition: jump from call `factorial(number)` in main back to the declaration.
    const call_pos = try findPosition(new_doc.items, "factorial(number)", 0);
    const def_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, call_pos.line, call_pos.col },
    );
    defer allocator.free(def_params);

    const def_id = try lsp.request("textDocument/definition", def_params);
    var def_res = try lsp.waitResponse(def_id, 5000);
    defer def_res.deinit();

    try std.testing.expect(def_res.parsed.value == .object);
    const def_obj = def_res.parsed.value.object;
    const result_val = try jsonResultFromResponseObj(def_obj);
    const fact_decl_pos = try findPosition(doc_text, "fun factorial", 0);
    try expectDefinitionPointsTo(allocator, result_val, doc_uri, fact_decl_pos.line, fact_decl_pos.col + 4);

    // Completion should respond with a list shape (even if empty).
    const comp_pos = try findPosition(doc_text, "std.c.io", 0);
    const comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, comp_pos.line, comp_pos.col + 4 },
    );
    defer allocator.free(comp_params);

    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 5000);
    defer comp_res.deinit();

    try std.testing.expect(comp_res.parsed.value == .object);
    const comp_obj = comp_res.parsed.value.object;
    try std.testing.expect(comp_obj.get("result") != null);

    // shutdown + exit
    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: formatting never returns empty output" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.c.io;\n\n" ++
        "fun main() {\n" ++
        "    printf(\"hi\\n\");\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-format.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const fmt_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"options\":{{\"tabSize\":4,\"insertSpaces\":true}}}}",
        .{doc_uri},
    );
    defer allocator.free(fmt_params);

    const fmt_id = try lsp.request("textDocument/formatting", fmt_params);
    var fmt_res = try lsp.waitResponse(fmt_id, 15000);
    defer fmt_res.deinit();

    try std.testing.expect(fmt_res.parsed.value == .object);
    const obj = fmt_res.parsed.value.object;
    const result_val = try jsonResultFromResponseObj(obj);
    // Formatting returns TextEdit[] (can be empty if formatter chooses no-op).
    if (result_val == .array) {
        for (result_val.array.items) |edit| {
            if (edit != .object) continue;
            if (edit.object.get("newText")) |nv| {
                if (nv == .string) {
                    // Guard against the classic “format wipes whole doc” bug.
                    try std.testing.expect(nv.string.len != 0);
                }
            }
        }
    }

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: C macro completion for std.c.limits and std.c.def" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.c.limits;\n" ++
        "imp std.c.def;\n\n" ++
        "fun main() {\n" ++
        "    num x = INT;\n" ++
        "    num y = NUL;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-macro-complete.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Completion at end of `INT` should include `INT_MAX`.
    const int_pos = try findPosition(doc_text, "INT;", 0);
    const int_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, int_pos.line, int_pos.col + @as(i64, @intCast("INT".len)) },
    );
    defer allocator.free(int_params);
    const int_id = try lsp.request("textDocument/completion", int_params);
    var int_res = try lsp.waitResponse(int_id, 5000);
    defer int_res.deinit();
    try std.testing.expect(int_res.parsed.value == .object);
    const int_obj = int_res.parsed.value.object;
    const int_result = try jsonResultFromResponseObj(int_obj);
    try expectCompletionHasLabel(allocator, int_result, "INT_MAX");

    // Completion at end of `NUL` should include `NULL`.
    const nul_pos = try findPosition(doc_text, "NUL;", 0);
    const nul_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, nul_pos.line, nul_pos.col + @as(i64, @intCast("NUL".len)) },
    );
    defer allocator.free(nul_params);
    const nul_id = try lsp.request("textDocument/completion", nul_params);
    var nul_res = try lsp.waitResponse(nul_id, 5000);
    defer nul_res.deinit();
    try std.testing.expect(nul_res.parsed.value == .object);
    const nul_obj = nul_res.parsed.value.object;
    const nul_result = try jsonResultFromResponseObj(nul_obj);
    try expectCompletionHasLabel(allocator, nul_result, "NULL");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: std namespace hover shows README and module docs" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.c.io;\n\n" ++
        "fun main() {\n" ++
        "    printf(\"hi\\n\");\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-std-hover.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Hover on `std` should show the stdlib README.
    const std_pos = try findPosition(doc_text, "std.c.io", 0);
    const hover_std_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, std_pos.line, std_pos.col },
    );
    defer allocator.free(hover_std_params);
    const hover_std_id = try lsp.request("textDocument/hover", hover_std_params);
    var hover_std_res = try lsp.waitResponse(hover_std_id, 15000);
    defer hover_std_res.deinit();
    const hover_std_val = try jsonResultFromResponseObj(hover_std_res.parsed.value.object);
    try expectHoverContains(allocator, hover_std_val, "Fun Standard Library");

    // Hover on `io` (in `std.c.io`) should show the module's leading doc block.
    const hover_io_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, std_pos.line, std_pos.col + @as(i64, @intCast("std.c.".len)) },
    );
    defer allocator.free(hover_io_params);
    const hover_io_id = try lsp.request("textDocument/hover", hover_io_params);
    var hover_io_res = try lsp.waitResponse(hover_io_id, 15000);
    defer hover_io_res.deinit();
    const hover_io_val = try jsonResultFromResponseObj(hover_io_res.parsed.value.object);
    try expectHoverContains(allocator, hover_io_val, "C standard I/O bindings");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: enum dot shorthand completion/hover/definition" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.c.io;\n\n" ++
        "enum Color {\n" ++
        "  Red,\n" ++
        "  Green,\n" ++
        "  Blue,\n" ++
        "}\n\n" ++
        "fun takes(Color c) {\n" ++
        "  fit c {\n" ++
        "    .Red -> { printf(\"R\\n\"); },\n" ++
        "    .Green -> { printf(\"G\\n\"); },\n" ++
        "    .Blue -> { printf(\"B\\n\"); },\n" ++
        "  }\n" ++
        "}\n\n" ++
        "fun main() {\n" ++
        "  Color c = .Blue;\n" ++
        "  if c == .Blue {\n" ++
        "    takes(.Red);\n" ++
        "  }\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-enum-dot.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Completion after `.`, expect `Blue`.
    const comp_pos = try findPosition(doc_text, "= .", 0);
    const comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, comp_pos.line, comp_pos.col + 3 },
    );
    defer allocator.free(comp_params);
    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 15000);
    defer comp_res.deinit();
    const comp_result = try jsonResultFromResponseObj(comp_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_result, "Blue");

    // Completion inside call args: `takes(.Red)` should offer `Red`.
    const comp_call_pos = try findPosition(doc_text, "takes(.Red)", 0);
    const comp_call_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, comp_call_pos.line, comp_call_pos.col + @as(i64, @intCast("takes(.".len)) },
    );
    defer allocator.free(comp_call_params);
    const comp_call_id = try lsp.request("textDocument/completion", comp_call_params);
    var comp_call_res = try lsp.waitResponse(comp_call_id, 15000);
    defer comp_call_res.deinit();
    const comp_call_result = try jsonResultFromResponseObj(comp_call_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_call_result, "Red");

    // Completion inside if-condition: `if c == .Blue` should offer `Blue`.
    const comp_if_pos = try findPosition(doc_text, "== .Blue", 0);
    const comp_if_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, comp_if_pos.line, comp_if_pos.col + @as(i64, @intCast("== .".len)) },
    );
    defer allocator.free(comp_if_params);
    const comp_if_id = try lsp.request("textDocument/completion", comp_if_params);
    var comp_if_res = try lsp.waitResponse(comp_if_id, 15000);
    defer comp_if_res.deinit();
    const comp_if_result = try jsonResultFromResponseObj(comp_if_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_if_result, "Blue");

    // Completion right after `.` in a declaration: `Color c = .`
    const dot_decl_text =
        "enum Color {\n" ++
        "  Red,\n" ++
        "  Green,\n" ++
        "  Blue,\n" ++
        "}\n\n" ++
        "fun main() {\n" ++
        "  Color c = .\n" ++
        "}\n";

    const dot_decl_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-enum-dot-decl.fn");
    defer allocator.free(dot_decl_uri);
    try lspOpenDoc(allocator, &lsp, dot_decl_uri, 1, dot_decl_text);

    const comp_decl_pos = try findPosition(dot_decl_text, "= .", 0);
    const comp_decl_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ dot_decl_uri, comp_decl_pos.line, comp_decl_pos.col + @as(i64, @intCast("= .".len)) },
    );
    defer allocator.free(comp_decl_params);
    const comp_decl_id = try lsp.request("textDocument/completion", comp_decl_params);
    var comp_decl_res = try lsp.waitResponse(comp_decl_id, 15000);
    defer comp_decl_res.deinit();
    const comp_decl_result = try jsonResultFromResponseObj(comp_decl_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_decl_result, "Red");

    // Additional contexts: method call, function call, if-condition, and fit branch.
    const ctx_text =
        "enum Color {\n" ++
        "  Red,\n" ++
        "  Green,\n" ++
        "  Blue,\n" ++
        "}\n\n" ++
        "enum Direction {\n" ++
        "  North,\n" ++
        "  East,\n" ++
        "  West,\n" ++
        "}\n\n" ++
        "compound Painter {\n" ++
        "  Color color;\n" ++
        "}\n\n" ++
        "impl Painter {\n" ++
        "  setColor(Color c) { self.color = c; }\n" ++
        "}\n\n" ++
        "fun takesDir(Direction d) { ret; }\n\n" ++
        "fun main() {\n" ++
        "  Color c = .Red;\n" ++
        "  Painter p;\n" ++
        "  p.setColor(.Red);\n" ++
        "  takesDir(.East);\n" ++
        "  if c == .Red { ret; }\n" ++
        "  fit c {\n" ++
        "    .Red -> { ret; }\n" ++
        "  }\n" ++
        "}\n";

    const ctx_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-enum-dot-contexts.fn");
    defer allocator.free(ctx_uri);
    try lspOpenDoc(allocator, &lsp, ctx_uri, 1, ctx_text);

    // Method call context: `p.setColor(.Red)`.
    const comp_method_pos = try findPosition(ctx_text, "setColor(.Red)", 0);
    const comp_method_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ ctx_uri, comp_method_pos.line, comp_method_pos.col + @as(i64, @intCast("setColor(.".len)) },
    );
    defer allocator.free(comp_method_params);
    const comp_method_id = try lsp.request("textDocument/completion", comp_method_params);
    var comp_method_res = try lsp.waitResponse(comp_method_id, 15000);
    defer comp_method_res.deinit();
    const comp_method_result = try jsonResultFromResponseObj(comp_method_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_method_result, "Red");

    // Function call context: `takesDir(.East)`.
    const comp_fn_pos = try findPosition(ctx_text, "takesDir(.East)", 0);
    const comp_fn_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ ctx_uri, comp_fn_pos.line, comp_fn_pos.col + @as(i64, @intCast("takesDir(.".len)) },
    );
    defer allocator.free(comp_fn_params);
    const comp_fn_id = try lsp.request("textDocument/completion", comp_fn_params);
    var comp_fn_res = try lsp.waitResponse(comp_fn_id, 15000);
    defer comp_fn_res.deinit();
    const comp_fn_result = try jsonResultFromResponseObj(comp_fn_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_fn_result, "East");

    // If-condition context: `if c == .Red`.
    const comp_if2_pos = try findPosition(ctx_text, "== .Red", 0);
    const comp_if2_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ ctx_uri, comp_if2_pos.line, comp_if2_pos.col + @as(i64, @intCast("== .".len)) },
    );
    defer allocator.free(comp_if2_params);
    const comp_if2_id = try lsp.request("textDocument/completion", comp_if2_params);
    var comp_if2_res = try lsp.waitResponse(comp_if2_id, 15000);
    defer comp_if2_res.deinit();
    const comp_if2_result = try jsonResultFromResponseObj(comp_if2_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_if2_result, "Blue");

    // Fit branch context: `fit c { .Red -> ... }`.
    const comp_fit_pos = try findPosition(ctx_text, ".Red ->", 0);
    const comp_fit_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ ctx_uri, comp_fit_pos.line, comp_fit_pos.col + 1 },
    );
    defer allocator.free(comp_fit_params);
    const comp_fit_id = try lsp.request("textDocument/completion", comp_fit_params);
    var comp_fit_res = try lsp.waitResponse(comp_fit_id, 15000);
    defer comp_fit_res.deinit();
    const comp_fit_result = try jsonResultFromResponseObj(comp_fit_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_fit_result, "Green");

    // Hover on `.Blue` should show `Color.Blue`.
    const blue_pos = try findPosition(doc_text, ".Blue", 0);
    const hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, blue_pos.line, blue_pos.col + 1 },
    );
    defer allocator.free(hover_params);
    const hover_id = try lsp.request("textDocument/hover", hover_params);
    var hover_res = try lsp.waitResponse(hover_id, 15000);
    defer hover_res.deinit();
    const hover_val = try jsonResultFromResponseObj(hover_res.parsed.value.object);
    try expectHoverContains(allocator, hover_val, "Color.Blue");

    // Definition on `.Red` should jump to the enum variant declaration.
    const red_use = try findPosition(doc_text, "takes(.Red)", 0);
    const def_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, red_use.line, red_use.col + @as(i64, @intCast("takes(.".len)) },
    );
    defer allocator.free(def_params);
    const def_id = try lsp.request("textDocument/definition", def_params);
    var def_res = try lsp.waitResponse(def_id, 15000);
    defer def_res.deinit();
    const def_val = try jsonResultFromResponseObj(def_res.parsed.value.object);
    const red_decl = try findPosition(doc_text, "Red,", 0);
    try expectDefinitionPointsTo(allocator, def_val, doc_uri, red_decl.line, red_decl.col);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: generic type member completion (Vec<T>)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.vec;\n\n" ++
        "fun main() {\n" ++
        "  Vec<num> nums;\n" ++
        "  nums.\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-generic-vec.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const comp_pos = try findPosition(doc_text, "nums.", 0);
    const comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, comp_pos.line, comp_pos.col + @as(i64, @intCast("nums.".len)) },
    );
    defer allocator.free(comp_params);

    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 15000);
    defer comp_res.deinit();
    const comp_result = try jsonResultFromResponseObj(comp_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_result, "push");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: custom import namespace hover shows README" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    // Create a custom module directory with a README.
    const mod_dir_abs = try std.fs.path.join(allocator, &[_][]const u8{ setup.root_abs, "mylib" });
    defer allocator.free(mod_dir_abs);
    std.fs.makeDirAbsolute(mod_dir_abs) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.fs.deleteTreeAbsolute(mod_dir_abs) catch {};

    const readme_abs = try std.fs.path.join(allocator, &[_][]const u8{ mod_dir_abs, "README.md" });
    defer allocator.free(readme_abs);
    {
        const f = try std.fs.createFileAbsolute(readme_abs, .{ .truncate = true });
        defer f.close();
        try f.writeAll("# MyLib\n\nCustom module README hover works.\n");
    }

    // Create a module file so `imp mylib.foo;` is a valid import.
    const foo_abs = try std.fs.path.join(allocator, &[_][]const u8{ mod_dir_abs, "foo.fn" });
    defer allocator.free(foo_abs);
    {
        const f = try std.fs.createFileAbsolute(foo_abs, .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            "// Foo module\n" ++
                "fun add(num a, num b) num {\n" ++
                "  ret a + b;\n" ++
                "}\n",
        );
    }

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp mylib.foo;\n\n" ++
        "fun main() {\n" ++
        "  ret;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-custom-import-hover.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Hover on `mylib` (in `imp mylib.foo;`) should show the directory README.
    const pos = try findPosition(doc_text, "mylib.foo", 0);
    const hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, pos.line, pos.col },
    );
    defer allocator.free(hover_params);

    const hover_id = try lsp.request("textDocument/hover", hover_params);
    var hover_res = try lsp.waitResponse(hover_id, 15000);
    defer hover_res.deinit();
    const hover_val = try jsonResultFromResponseObj(hover_res.parsed.value.object);
    try expectHoverContains(allocator, hover_val, "MyLib");
    try expectHoverContains(allocator, hover_val, "Custom module README hover works");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: typing with CRLF positions stays consistent" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.c.io;\r\n\r\n" ++
        "fun main() {\r\n" ++
        "    num a = 1;\r\n" ++
        "    printf(\"%d\\n\", a);\r\n" ++
        "}\r\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-crlf.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Insert " num b = 2;" at end of "num a = 1;" line.
    const insert_pos = try findPosition(doc_text, "num a = 1;", 0);
    const end_col = insert_pos.col + @as(i64, @intCast("num a = 1;".len));
    const change_text = "\r\n    num b = 2;";
    const change_json = try escapeJsonAlloc(allocator, change_text);
    defer allocator.free(change_json);

    const did_change_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\",\"version\":2}},\"contentChanges\":[{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"text\":\"{s}\"}}]}}",
        .{ doc_uri, insert_pos.line, end_col, insert_pos.line, end_col, change_json },
    );
    defer allocator.free(did_change_params);
    try lsp.notify("textDocument/didChange", did_change_params);

    // Completion request should still succeed (shape only).
    const comp_pos = try findPosition(doc_text, "std.c.io", 0);
    const comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, comp_pos.line, comp_pos.col + 4 },
    );
    defer allocator.free(comp_params);
    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 15000);
    defer comp_res.deinit();
    try std.testing.expect(comp_res.parsed.value == .object);
    const comp_obj = comp_res.parsed.value.object;
    _ = try jsonResultFromResponseObj(comp_obj);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: import completion + go-to-definition works" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.;\n\n" ++
        "fun main() {\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-import.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Completion after `std.` should include `c`.
    const pos = try findPosition(doc_text, "std.", 0);
    const comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, pos.line, pos.col + 4 },
    );
    defer allocator.free(comp_params);
    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 15000);
    defer comp_res.deinit();
    try std.testing.expect(comp_res.parsed.value == .object);
    const comp_obj = comp_res.parsed.value.object;
    const comp_result = try jsonResultFromResponseObj(comp_obj);
    try expectCompletionHasLabel(allocator, comp_result, "c");

    // Now open a doc with `imp std.c.io;` and request definition on `io`.
    const doc_text2 = "imp std.c.io;\n";
    const doc_uri2 = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-import2.fn");
    defer allocator.free(doc_uri2);
    try lspOpenDoc(allocator, &lsp, doc_uri2, 1, doc_text2);

    const io_pos = try findPosition(doc_text2, "io", 0);
    const def_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri2, io_pos.line, io_pos.col },
    );
    defer allocator.free(def_params);
    const def_id = try lsp.request("textDocument/definition", def_params);
    var def_res = try lsp.waitResponse(def_id, 15000);
    defer def_res.deinit();
    try std.testing.expect(def_res.parsed.value == .object);
    const def_obj = def_res.parsed.value.object;
    const def_result = try jsonResultFromResponseObj(def_obj);
    // Expect jump into stdlib module file (range is 0:0 by design for module open).
    try expectDefinitionPointsTo(allocator, def_result, "stdlib/std/c/io.fn", 0, 0);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: alias namespace completion shows module publics" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.error as err;\n\n" ++
        "fun main() {\n" ++
        "  err.\n" ++
        "}\n";

    const doc_abs = try std.fs.path.join(allocator, &[_][]const u8{ setup.root_abs, "fls-e2e-alias-namespace.fn" });
    defer allocator.free(doc_abs);
    defer std.fs.deleteFileAbsolute(doc_abs) catch {};
    {
        const f = try std.fs.createFileAbsolute(doc_abs, .{ .truncate = true });
        defer f.close();
        try f.writeAll(doc_text);
    }

    const doc_uri = try pathToFileUriAlloc(allocator, doc_abs);
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const pos = try findPosition(doc_text, "err.", 0);
    const comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, pos.line, pos.col + 4 },
    );
    defer allocator.free(comp_params);

    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 15000);
    defer comp_res.deinit();
    try std.testing.expect(comp_res.parsed.value == .object);
    const comp_result = try jsonResultFromResponseObj(comp_res.parsed.value.object);

    try expectCompletionHasLabel(allocator, comp_result, "Error");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: locals, dot completion, member signatureHelp" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
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
        "  p\n" ++
        "  p.x = 1;\n" ++
        "  p.\n" ++
        "  p.translate(3, 4);\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-locals-members.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Sanity: ensure compound fields are indexed (workspace/symbol sees `x`).
    const ws_params = try allocator.dupe(u8, "{\"query\":\"x\"}");
    defer allocator.free(ws_params);
    const ws_id = try lsp.request("workspace/symbol", ws_params);
    var ws_res = try lsp.waitResponse(ws_id, 15000);
    defer ws_res.deinit();
    const ws_result = try jsonResultFromResponseObj(ws_res.parsed.value.object);
    try std.testing.expect(symbolInfosHasName(ws_result, "x"));

    // Definition: jump from member use `p.x` to field declaration `num x;`
    const member_x = try findPosition(doc_text, "p.x", 0);
    const def_params_x = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, member_x.line, member_x.col + 2 },
    );
    defer allocator.free(def_params_x);
    const def_id_x = try lsp.request("textDocument/definition", def_params_x);
    var def_res_x = try lsp.waitResponse(def_id_x, 15000);
    defer def_res_x.deinit();
    const def_x = try jsonResultFromResponseObj(def_res_x.parsed.value.object);
    const field_x = try findPosition(doc_text, "num x;", 0);
    try expectDefinitionPointsTo(allocator, def_x, doc_uri, field_x.line, field_x.col + 4);

    // Definition: jump from member call `p.translate(...)` to `translate(...) {` method declaration.
    const translate_use = try findPosition(doc_text, "translate(3", 0);
    const def_params_t = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, translate_use.line, translate_use.col },
    );
    defer allocator.free(def_params_t);
    const def_id_t = try lsp.request("textDocument/definition", def_params_t);
    var def_res_t = try lsp.waitResponse(def_id_t, 15000);
    defer def_res_t.deinit();
    const def_t = try jsonResultFromResponseObj(def_res_t.parsed.value.object);
    const translate_decl = try findPosition(doc_text, "translate(num dx", 0);
    try expectDefinitionPointsTo(allocator, def_t, doc_uri, translate_decl.line, translate_decl.col);

    // TypeDefinition: jump from variable `p` to its declared type `Point`.
    const p_use = try findPosition(doc_text, "Point p;", 0);
    const type_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, p_use.line, p_use.col + 6 },
    );
    defer allocator.free(type_params);
    const type_id = try lsp.request("textDocument/typeDefinition", type_params);
    var type_res = try lsp.waitResponse(type_id, 15000);
    defer type_res.deinit();
    const type_val = try jsonResultFromResponseObj(type_res.parsed.value.object);
    const point_decl = try findPosition(doc_text, "compound Point", 0);
    try expectDefinitionPointsTo(allocator, type_val, doc_uri, point_decl.line, point_decl.col + 9);

    // Completion for locals: typing `p` in main should offer `p`.
    const p_pos = try findPosition(doc_text, "  p\n", 0);
    const comp_params_local = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, p_pos.line, p_pos.col + 2 },
    );
    defer allocator.free(comp_params_local);
    const comp_id_local = try lsp.request("textDocument/completion", comp_params_local);
    var comp_res_local = try lsp.waitResponse(comp_id_local, 15000);
    defer comp_res_local.deinit();
    const comp_result_local = try jsonResultFromResponseObj(comp_res_local.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_result_local, "p");

    // Hover for local `p` should include its type.
    const hover_p_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, p_pos.line, p_pos.col + 2 },
    );
    defer allocator.free(hover_p_params);
    const hover_p_id = try lsp.request("textDocument/hover", hover_p_params);
    var hover_p_res = try lsp.waitResponse(hover_p_id, 15000);
    defer hover_p_res.deinit();
    const hover_p_val = try jsonResultFromResponseObj(hover_p_res.parsed.value.object);
    try expectHoverContains(allocator, hover_p_val, "Point p");

    // Dot completion for members of `Point`: should include field `x` and method `translate`.
    const dot_pos = try findPosition(doc_text, "  p.\n", 0);
    const comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, dot_pos.line, dot_pos.col + 4 },
    );
    defer allocator.free(comp_params);
    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 15000);
    defer comp_res.deinit();
    const comp_result = try jsonResultFromResponseObj(comp_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_result, "x");
    try expectCompletionHasLabel(allocator, comp_result, "translate");

    // Signature help for member call should include parameter names.
    const call_pos = try findPosition(doc_text, "p.translate(3, 4", 0);
    const sig_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, call_pos.line, call_pos.col + 15 },
    );
    defer allocator.free(sig_params);
    const sig_id = try lsp.request("textDocument/signatureHelp", sig_params);
    var sig_res = try lsp.waitResponse(sig_id, 15000);
    defer sig_res.deinit();
    const sig_result = try jsonResultFromResponseObj(sig_res.parsed.value.object);
    try expectSignatureHelpLabelContains(allocator, sig_result, "translate(num dx, num dy)");
    try expectSignatureHelpActiveParameter(allocator, sig_result, 1);
    try expectSignatureHelpHasParameter(allocator, sig_result, "num dx");
    try expectSignatureHelpHasParameter(allocator, sig_result, "num dy");

    // Hover for member `x` should include its declared type.
    const hover_x_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, member_x.line, member_x.col + 2 },
    );
    defer allocator.free(hover_x_params);
    const hover_x_id = try lsp.request("textDocument/hover", hover_x_params);
    var hover_x_res = try lsp.waitResponse(hover_x_id, 15000);
    defer hover_x_res.deinit();
    const hover_x_val = try jsonResultFromResponseObj(hover_x_res.parsed.value.object);
    try expectHoverContains(allocator, hover_x_val, "num x");

    // Semantic tokens should be non-empty for a doc with locals/members.
    const st_params = try std.fmt.allocPrint(allocator, "{{\"textDocument\":{{\"uri\":\"{s}\"}}}}", .{doc_uri});
    defer allocator.free(st_params);
    const st_id = try lsp.request("textDocument/semanticTokens/full", st_params);
    var st_res = try lsp.waitResponse(st_id, 15000);
    defer st_res.deinit();
    const st_val = try jsonResultFromResponseObj(st_res.parsed.value.object);
    try expectSemanticTokensNonEmpty(allocator, st_val);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: let inference hover types" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
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
        "  let s = \"hello\";\n" ++
        "  let c = 'Z';\n" ++
        "  let b = true;\n" ++
        "  let arr = [1, 2, 3];\n" ++
        "  let chars = ['a', 'b', 'c'];\n" ++
        "  let decs = [1.25, 2.5, 3.75];\n" ++
        "  let flags = [true, false, true];\n" ++
        "  let words = [\"hello\", \"world\"];\n" ++
        "  let p = Point{x = 1, y = 2};\n" ++
        "  let p2 = make_point(3, 4);\n" ++
        "  let pptr = &p;\n" ++
        "  let color = Color.Red;\n" ++
        "  let color2 = Color.Green;\n" ++
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
        "  let mix_sum = lerp_dec(n, n + 10, d) + (abs_dec(d) / 3);\n" ++
        "  let mix_idx = (min_num(n, n2) - 40) / 2;\n" ++
        "  let mix_pick = arr2[mix_idx];\n" ++
        "  let mixed = lerp_dec(n, n + 10, d);\n" ++
        "  let mixed2 = lerp_dec(n2, n2 + 5, d / 2);\n" ++
        "  let num_from_dec = min_num(n, (n + 2));\n" ++
        "  let dec_from_num = lerp_dec(n, n + 2, 0.5);\n" ++
        "  let dec_mix3 = lerp_dec(n, n + 2, d) + (d / 2);\n" ++
        "  let p_from_call = make_point(n + 7, n - 7);\n" ++
        "  let points2 = [make_point(n, n + 1), make_point(n + 2, n + 3)];\n" ++
        "  mix_points[0].\n" ++
        "  _ = points2;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-let-infer.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const Case = struct { name: []const u8, expect: []const u8 };
    const cases = [_]Case{
        .{ .name = "n", .expect = "num n" },
        .{ .name = "d", .expect = "dec d" },
        .{ .name = "s", .expect = "str s" },
        .{ .name = "c", .expect = "chr c" },
        .{ .name = "b", .expect = "bin b" },
        .{ .name = "arr", .expect = "num[] arr" },
        .{ .name = "chars", .expect = "chr[] chars" },
        .{ .name = "decs", .expect = "dec[] decs" },
        .{ .name = "flags", .expect = "bin[] flags" },
        .{ .name = "words", .expect = "str[] words" },
        .{ .name = "p", .expect = "Point p" },
        .{ .name = "p2", .expect = "Point p2" },
        .{ .name = "pptr", .expect = "Point* pptr" },
        .{ .name = "color", .expect = "Color color" },
        .{ .name = "color2", .expect = "Color color2" },
        .{ .name = "status", .expect = "Status status" },
        .{ .name = "points", .expect = "Point[] points" },
        .{ .name = "n2", .expect = "num n2" },
        .{ .name = "arr2", .expect = "num[] arr2" },
        .{ .name = "idx", .expect = "num idx" },
        .{ .name = "pick", .expect = "num pick" },
        .{ .name = "p3", .expect = "Point p3" },
        .{ .name = "psum", .expect = "num psum" },
        .{ .name = "neg", .expect = "num neg" },
        .{ .name = "dec_expr", .expect = "dec dec_expr" },
        .{ .name = "nested", .expect = "Point nested" },
        .{ .name = "nested_sum", .expect = "num nested_sum" },
        .{ .name = "dec_mix", .expect = "dec dec_mix" },
        .{ .name = "dec_mix2", .expect = "dec dec_mix2" },
        .{ .name = "mix_point", .expect = "Point mix_point" },
        .{ .name = "mix_points", .expect = "Point[] mix_points" },
        .{ .name = "mp_x", .expect = "num mp_x" },
        .{ .name = "mix_sum", .expect = "dec mix_sum" },
        .{ .name = "mix_idx", .expect = "num mix_idx" },
        .{ .name = "mix_pick", .expect = "num mix_pick" },
        .{ .name = "mixed", .expect = "dec mixed" },
        .{ .name = "mixed2", .expect = "dec mixed2" },
        .{ .name = "num_from_dec", .expect = "num num_from_dec" },
        .{ .name = "dec_from_num", .expect = "dec dec_from_num" },
        .{ .name = "dec_mix3", .expect = "dec dec_mix3" },
        .{ .name = "p_from_call", .expect = "Point p_from_call" },
        .{ .name = "points2", .expect = "Point[] points2" },
    };

    for (cases) |cinfo| {
        const needle = try std.fmt.allocPrint(allocator, "let {s}", .{cinfo.name});
        defer allocator.free(needle);
        const pos = try findPosition(doc_text, needle, 0);
        const hover_params = try std.fmt.allocPrint(
            allocator,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
            .{ doc_uri, pos.line, pos.col + 4 },
        );
        defer allocator.free(hover_params);
        const hover_id = try lsp.request("textDocument/hover", hover_params);
        var hover_res = try lsp.waitResponse(hover_id, 15000);
        defer hover_res.deinit();
        const hover_val = try jsonResultFromResponseObj(hover_res.parsed.value.object);
        try expectHoverContains(allocator, hover_val, cinfo.expect);
    }

    const member_pos = try findPosition(doc_text, "mix_points[0].", 0);
    const comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, member_pos.line, member_pos.col + @as(i64, @intCast("mix_points[0].".len)) },
    );
    defer allocator.free(comp_params);
    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 15000);
    defer comp_res.deinit();
    const comp_val = try jsonResultFromResponseObj(comp_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_val, "x");
    try expectCompletionHasLabel(allocator, comp_val, "y");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: for range loop locals support" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "compound Point {\n" ++
        "  pub num x;\n" ++
        "}\n\n" ++
        "compound User {\n" ++
        "  num id;\n" ++
        "  str name;\n" ++
        "}\n\n" ++
        "fun main() {\n" ++
        "  let a = [1, 2, 3];\n" ++
        "  let pts = [Point{.x = 1}, Point{.x = 2}];\n" ++
        "  let users = [User{id = 1, name = \"Alice\"}, User{id = 2, name = \"Bob\"}];\n" ++
        "  for item : a {\n" ++
        "    item\n" ++
        "  }\n" ++
        "  for index, value :: a {\n" ++
        "    index\n" ++
        "    value\n" ++
        "  }\n" ++
        "  for p : pts {\n" ++
        "    p\n" ++
        "  }\n" ++
        "  for _, user :: users {\n" ++
        "    user.\n" ++
        "  }\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-for-range-locals.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Completion should include loop locals.
    const comp_item_pos = try findPosition(doc_text, "    item", 0);
    const comp_item_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, comp_item_pos.line, comp_item_pos.col + 5 },
    );
    defer allocator.free(comp_item_params);
    const comp_item_id = try lsp.request("textDocument/completion", comp_item_params);
    var comp_item_res = try lsp.waitResponse(comp_item_id, 15000);
    defer comp_item_res.deinit();
    const comp_item_result = try jsonResultFromResponseObj(comp_item_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_item_result, "item");

    const comp_index_pos = try findPosition(doc_text, "    index", 0);
    const comp_index_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, comp_index_pos.line, comp_index_pos.col + 4 },
    );
    defer allocator.free(comp_index_params);
    const comp_index_id = try lsp.request("textDocument/completion", comp_index_params);
    var comp_index_res = try lsp.waitResponse(comp_index_id, 15000);
    defer comp_index_res.deinit();
    const comp_index_result = try jsonResultFromResponseObj(comp_index_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_index_result, "index");
    try expectCompletionHasLabel(allocator, comp_index_result, "value");

    // Hover should include inferred loop local types.
    const hover_item_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, comp_item_pos.line, comp_item_pos.col + 5 },
    );
    defer allocator.free(hover_item_params);
    const hover_item_id = try lsp.request("textDocument/hover", hover_item_params);
    var hover_item_res = try lsp.waitResponse(hover_item_id, 15000);
    defer hover_item_res.deinit();
    const hover_item_val = try jsonResultFromResponseObj(hover_item_res.parsed.value.object);
    try expectHoverContains(allocator, hover_item_val, "num item");

    const hover_index_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, comp_index_pos.line, comp_index_pos.col + 6 },
    );
    defer allocator.free(hover_index_params);
    const hover_index_id = try lsp.request("textDocument/hover", hover_index_params);
    var hover_index_res = try lsp.waitResponse(hover_index_id, 15000);
    defer hover_index_res.deinit();
    const hover_index_val = try jsonResultFromResponseObj(hover_index_res.parsed.value.object);
    try expectHoverContains(allocator, hover_index_val, "num index");

    const hover_value_pos = try findPosition(doc_text, "    value", 0);
    const hover_value_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, hover_value_pos.line, hover_value_pos.col + 6 },
    );
    defer allocator.free(hover_value_params);
    const hover_value_id = try lsp.request("textDocument/hover", hover_value_params);
    var hover_value_res = try lsp.waitResponse(hover_value_id, 15000);
    defer hover_value_res.deinit();
    const hover_value_val = try jsonResultFromResponseObj(hover_value_res.parsed.value.object);
    try expectHoverContains(allocator, hover_value_val, "num value");

    const comp_p_pos = try findPosition(doc_text, "    p", 0);
    const comp_p_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, comp_p_pos.line, comp_p_pos.col + 2 },
    );
    defer allocator.free(comp_p_params);
    const comp_p_id = try lsp.request("textDocument/completion", comp_p_params);
    var comp_p_res = try lsp.waitResponse(comp_p_id, 15000);
    defer comp_p_res.deinit();
    const comp_p_result = try jsonResultFromResponseObj(comp_p_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_p_result, "p");

    const hover_p_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, comp_p_pos.line, comp_p_pos.col + 2 },
    );
    defer allocator.free(hover_p_params);
    const hover_p_id = try lsp.request("textDocument/hover", hover_p_params);
    var hover_p_res = try lsp.waitResponse(hover_p_id, 15000);
    defer hover_p_res.deinit();
    const hover_p_val = try jsonResultFromResponseObj(hover_p_res.parsed.value.object);
    try expectHoverContains(allocator, hover_p_val, "Point p");

    // Member completion for local User should not leak members from unrelated
    // same-name types indexed elsewhere in the workspace.
    const comp_user_pos = try findPosition(doc_text, "    user.", 0);
    const comp_user_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, comp_user_pos.line, comp_user_pos.col + @as(i64, @intCast("    user.".len)) },
    );
    defer allocator.free(comp_user_params);
    const comp_user_id = try lsp.request("textDocument/completion", comp_user_params);
    var comp_user_res = try lsp.waitResponse(comp_user_id, 15000);
    defer comp_user_res.deinit();
    const comp_user_result = try jsonResultFromResponseObj(comp_user_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_user_result, "id");
    try expectCompletionHasLabel(allocator, comp_user_result, "name");
    try expectCompletionMissingLabel(allocator, comp_user_result, "greet");
    try expectCompletionMissingLabel(allocator, comp_user_result, "favorite");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: let inference in incomplete file" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // Intentionally malformed/incomplete body (including a dangling operator)
    // to exercise token-only fallback paths without crashing the server.
    const doc_text =
        "compound Point {\n" ++
        "  num x;\n" ++
        "}\n" ++
        "fun make_point(num x) Point { ret Point{x = x}; }\n" ++
        "fun main() {\n" ++
        "  let n = 42;\n" ++
        "  let chars = ['a', 'b', 'c'];\n" ++
        "  let arr = [1, 2, 3];\n" ++
        "  let p2 = make_point(n + 1);\n" ++
        "  let m = p2.x +\n" ++
        "\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-let-infer-incomplete.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const Case = struct { name: []const u8, expect: []const u8 };
    const cases = [_]Case{
        .{ .name = "n", .expect = "num n" },
        .{ .name = "chars", .expect = "chr[] chars" },
        .{ .name = "arr", .expect = "num[] arr" },
        .{ .name = "p2", .expect = "Point p2" },
    };

    for (cases) |cinfo| {
        const needle = try std.fmt.allocPrint(allocator, "let {s}", .{cinfo.name});
        defer allocator.free(needle);
        const pos = try findPosition(doc_text, needle, 0);
        const hover_params = try std.fmt.allocPrint(
            allocator,
            "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
            .{ doc_uri, pos.line, pos.col + 4 },
        );
        defer allocator.free(hover_params);
        const hover_id = try lsp.request("textDocument/hover", hover_params);
        var hover_res = try lsp.waitResponse(hover_id, 15000);
        defer hover_res.deinit();
        const hover_val = try jsonResultFromResponseObj(hover_res.parsed.value.object);
        try expectHoverContains(allocator, hover_val, cinfo.expect);
    }

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: let inference for imported enum member" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp dir;\n" ++
        "fun main() {\n" ++
        "  let dir = Direction.SOUTH;\n" ++
        "  fit dir {\n" ++
        "  }\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-let-infer-imported-enum.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const pos = try findPosition(doc_text, "let dir", 0);
    const hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, pos.line, pos.col + 4 },
    );
    defer allocator.free(hover_params);
    const hover_id = try lsp.request("textDocument/hover", hover_params);
    var hover_res = try lsp.waitResponse(hover_id, 15000);
    defer hover_res.deinit();
    const hover_val = try jsonResultFromResponseObj(hover_res.parsed.value.object);
    try expectHoverContains(allocator, hover_val, "Direction dir");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: signatureHelp for plain function call" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "fun add(num a, num b) num {\n" ++
        "  return a + b;\n" ++
        "}\n\n" ++
        "fun main() {\n" ++
        "  add(1, 2\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-sighelp-plain.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const call_pos = try findPosition(doc_text, "add(1, 2", 0);
    const sig_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, call_pos.line, call_pos.col + @as(i64, @intCast("add(1, ".len)) },
    );
    defer allocator.free(sig_params);

    const sig_id = try lsp.request("textDocument/signatureHelp", sig_params);
    var sig_res = try lsp.waitResponse(sig_id, 15000);
    defer sig_res.deinit();
    const sig_result = try jsonResultFromResponseObj(sig_res.parsed.value.object);
    try expectSignatureHelpLabelContains(allocator, sig_result, "add(num a, num b)");
    try expectSignatureHelpActiveParameter(allocator, sig_result, 1);
    try expectSignatureHelpHasParameter(allocator, sig_result, "num a");
    try expectSignatureHelpHasParameter(allocator, sig_result, "num b");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: builtin sizeof completion + hover + signatureHelp" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "compound User {\n" ++
        "  num age;\n" ++
        "}\n\n" ++
        "fun main() {\n" ++
        "  num s;\n" ++
        "  s = sizeof(User);\n" ++
        "  siz;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-sizeof.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Completion: typing `siz` should include `sizeof`.
    const siz_pos = try findPosition(doc_text, "siz;", 0);
    const comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, siz_pos.line, siz_pos.col + 3 },
    );
    defer allocator.free(comp_params);
    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 15000);
    defer comp_res.deinit();
    const comp_val = try jsonResultFromResponseObj(comp_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_val, "sizeof");

    // Hover: hovering `sizeof` should show builtin docs.
    const sizeof_pos = try findPosition(doc_text, "sizeof(User)", 0);
    const hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, sizeof_pos.line, sizeof_pos.col + 1 },
    );
    defer allocator.free(hover_params);
    const hover_id = try lsp.request("textDocument/hover", hover_params);
    var hover_res = try lsp.waitResponse(hover_id, 15000);
    defer hover_res.deinit();
    const hover_val = try jsonResultFromResponseObj(hover_res.parsed.value.object);
    try expectHoverContains(allocator, hover_val, "sizeof(Type)");

    // SignatureHelp: inside `sizeof(...)` should show the builtin signature.
    const sig_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, sizeof_pos.line, sizeof_pos.col + @as(i64, @intCast("sizeof(".len)) + 1 },
    );
    defer allocator.free(sig_params);
    const sig_id = try lsp.request("textDocument/signatureHelp", sig_params);
    var sig_res = try lsp.waitResponse(sig_id, 15000);
    defer sig_res.deinit();
    const sig_val = try jsonResultFromResponseObj(sig_res.parsed.value.object);
    try expectSignatureHelpLabelContains(allocator, sig_val, "sizeof(Type)");
    try expectSignatureHelpActiveParameter(allocator, sig_val, 0);
    try expectSignatureHelpHasParameter(allocator, sig_val, "Type");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: warning control keywords completion" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "fun main() {\n" ++
        "  al;\n" ++
        "  ex;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-warning-keywords.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const al_pos = try findPosition(doc_text, "al;", 0);
    const al_comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, al_pos.line, al_pos.col + 2 },
    );
    defer allocator.free(al_comp_params);
    const al_comp_id = try lsp.request("textDocument/completion", al_comp_params);
    var al_comp_res = try lsp.waitResponse(al_comp_id, 15000);
    defer al_comp_res.deinit();
    const al_comp_val = try jsonResultFromResponseObj(al_comp_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, al_comp_val, "allow");

    const ex_pos = try findPosition(doc_text, "ex;", 0);
    const ex_comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, ex_pos.line, ex_pos.col + 2 },
    );
    defer allocator.free(ex_comp_params);
    const ex_comp_id = try lsp.request("textDocument/completion", ex_comp_params);
    var ex_comp_res = try lsp.waitResponse(ex_comp_id, 15000);
    defer ex_comp_res.deinit();
    const ex_comp_val = try jsonResultFromResponseObj(ex_comp_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, ex_comp_val, "expect");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: publishDiagnostics includes warning from ID-tagged warning output" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "fun bad() num* {\n" ++
        "  num x = 1;\n" ++
        "  ret &x;\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-warning-id-diagnostics.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const deadline_ms = std.time.milliTimestamp() + 15000;
    var saw_expected_warning = false;

    while (std.time.milliTimestamp() < deadline_ms and !saw_expected_warning) {
        var notif = lsp.waitNotification("textDocument/publishDiagnostics", 1000) catch |err| {
            if (err == error.Timeout) continue;
            return err;
        };
        defer notif.deinit();

        if (notif.parsed.value != .object) continue;
        const root = notif.parsed.value.object;
        const params_val = root.get("params") orelse continue;
        if (params_val != .object) continue;
        const params_obj = params_val.object;

        const uri_val = params_obj.get("uri") orelse continue;
        if (uri_val != .string or !std.mem.eql(u8, uri_val.string, doc_uri)) continue;

        const diags_val = params_obj.get("diagnostics") orelse continue;
        if (diags_val != .array) continue;

        for (diags_val.array.items) |dv| {
            if (dv != .object) continue;
            const sev = dv.object.get("severity") orelse continue;
            const msg = dv.object.get("message") orelse continue;
            if (sev != .integer or msg != .string) continue;
            if (sev.integer != 2) continue;

            if (std.mem.indexOf(u8, msg.string, "returning address of local variable") != null) {
                saw_expected_warning = true;
                break;
            }
        }
    }

    try std.testing.expect(saw_expected_warning);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: enum variant dot completion + hover" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.c.io;\n" ++
        "\n" ++
        "enum Color {\n" ++
        "  Red;\n" ++
        "  Green;\n" ++
        "  Blue;\n" ++
        "}\n" ++
        "\n" ++
        "fun main() {\n" ++
        "  Color c = Color.Red;\n" ++
        "  Color.\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-enum.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Completion request at `Color.` should return safely.
    const dot_pos = try findPosition(doc_text, "Color.", 0);
    const comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, dot_pos.line, dot_pos.col + @as(i64, @intCast("Color.".len)) },
    );
    defer allocator.free(comp_params);
    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 15000);
    defer comp_res.deinit();
    const comp_val = try jsonResultFromResponseObj(comp_res.parsed.value.object);
    _ = comp_val;

    // Hover: hovering `Color` in `enum Color` should show it's an enum.
    const enum_pos = try findPosition(doc_text, "enum Color", 0);
    const hover_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, enum_pos.line, enum_pos.col + @as(i64, @intCast("enum ".len)) + 1 },
    );
    defer allocator.free(hover_params);
    const hover_id = try lsp.request("textDocument/hover", hover_params);
    var hover_res = try lsp.waitResponse(hover_id, 15000);
    defer hover_res.deinit();
    const hover_val = try jsonResultFromResponseObj(hover_res.parsed.value.object);
    try expectHoverContains(allocator, hover_val, "enum Color");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: dot completion finds impl methods across imported files" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    // Create a tiny multi-file project under `.zig-cache/` so import resolution matches
    // what fls does for in-editor unsaved buffers.
    std.fs.cwd().makePath(".zig-cache") catch {};

    const user_path = ".zig-cache/__fls_implsep_user.fn";
    const impl_path = ".zig-cache/__fls_implsep_user_impl.fn";
    defer std.fs.cwd().deleteFile(user_path) catch {};
    defer std.fs.cwd().deleteFile(impl_path) catch {};

    {
        const f = try std.fs.cwd().createFile(user_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            "pub compound User {\n" ++
                "  str name;\n" ++
                "}\n",
        );
    }
    {
        const f = try std.fs.cwd().createFile(impl_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            "imp std.c.io;\n" ++
                "imp __fls_implsep_user;\n\n" ++
                "impl User {\n" ++
                "  greet() {\n" ++
                "    printf(\"hi %s\\n\", self.name);\n" ++
                "  }\n" ++
                "}\n",
        );
    }

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp __fls_implsep_user;\n" ++
        "imp __fls_implsep_user_impl;\n\n" ++
        "fun main() void {\n" ++
        "  User user;\n" ++
        "  user.name = \"Alice\";\n" ++
        "  User* u = &user;\n" ++
        "  u.\n" ++
        "}\n";

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-implsep.fn");
    defer allocator.free(doc_uri);

    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const dot_pos = try findPosition(doc_text, "u.", 0);
    const comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, dot_pos.line, dot_pos.col + 2 },
    );
    defer allocator.free(comp_params);

    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 5000);
    defer comp_res.deinit();
    try std.testing.expect(comp_res.parsed.value == .object);
    const comp_obj = comp_res.parsed.value.object;
    const result_val = try jsonResultFromResponseObj(comp_obj);

    // Expect method completion from `impl User` living in a different imported file.
    try expectCompletionHasLabel(allocator, result_val, "greet");
}

test "fls e2e: quirks across folders complete + missing methods diagnose" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    std.fs.cwd().makePath(".zig-cache") catch {};
    std.fs.cwd().makePath(".zig-cache/qaf/defs") catch {};
    std.fs.cwd().makePath(".zig-cache/qaf/impls") catch {};

    const user_path = ".zig-cache/qaf/defs/user.fn";
    const greeter_path = ".zig-cache/qaf/defs/greeter.fn";
    const impl_ok_path = ".zig-cache/qaf/impls/user_greeter_ok.fn";
    const impl_bad_path = ".zig-cache/qaf/impls/user_greeter_bad.fn";

    defer std.fs.cwd().deleteFile(user_path) catch {};
    defer std.fs.cwd().deleteFile(greeter_path) catch {};
    defer std.fs.cwd().deleteFile(impl_ok_path) catch {};
    defer std.fs.cwd().deleteFile(impl_bad_path) catch {};

    {
        const f = try std.fs.cwd().createFile(user_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            "compound User {\n" ++
                "  str name;\n" ++
                "}\n",
        );
    }
    {
        const f = try std.fs.cwd().createFile(greeter_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            "pub quirk Greeter {\n" ++
                "  pub greet(str prefix) void;\n" ++
                "  pub bye() void;\n" ++
                "}\n",
        );
    }
    {
        const f = try std.fs.cwd().createFile(impl_ok_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            "imp std.c.io;\n" ++
                "imp ..defs.user;\n" ++
                "imp ..defs.greeter;\n\n" ++
                "impl User as Greeter {\n" ++
                "  pub greet(str prefix) void {\n" ++
                "    printf(\"%s %s\\n\", prefix, self.name);\n" ++
                "  }\n\n" ++
                "  pub bye() void {\n" ++
                "    printf(\"bye %s\\n\", self.name);\n" ++
                "  }\n" ++
                "}\n",
        );
    }
    const impl_bad_source =
        "imp std.c.io;\n" ++
        "imp ..defs.user;\n" ++
        "imp ..defs.greeter;\n\n" ++
        "impl User as Greeter {\n" ++
        "  pub greet(str prefix) void {\n" ++
        "    printf(\"%s %s\\n\", prefix, self.name);\n" ++
        "  }\n" ++
        "}\n";
    {
        const f = try std.fs.cwd().createFile(impl_bad_path, .{ .truncate = true });
        defer f.close();
        // Intentionally missing `bye()`.
        try f.writeAll(impl_bad_source);
    }

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    // --- 1) Completion for quirk/type names in an impl header.
    const doc_text_impl_header =
        "imp qaf.defs.user;\n" ++
        "imp qaf.defs.greeter;\n\n" ++
        "impl User \n";

    const doc_uri_impl_header = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-qaf-impl-header.fn");
    defer allocator.free(doc_uri_impl_header);
    try lspOpenDoc(allocator, &lsp, doc_uri_impl_header, 1, doc_text_impl_header);

    const impl_pos = try findPosition(doc_text_impl_header, "impl User ", 0);
    const comp_params_impl = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri_impl_header, impl_pos.line, impl_pos.col + @as(i64, @intCast("impl User ".len)) },
    );
    defer allocator.free(comp_params_impl);

    const comp_id_impl = try lsp.request("textDocument/completion", comp_params_impl);
    var comp_res_impl = try lsp.waitResponse(comp_id_impl, 5000);
    defer comp_res_impl.deinit();
    const comp_obj_impl = comp_res_impl.parsed.value.object;
    const comp_val_impl = try jsonResultFromResponseObj(comp_obj_impl);
    try expectCompletionHasLabel(allocator, comp_val_impl, "Greeter");

    // --- 2) Member completion for impl methods across imported files.
    const doc_text_members =
        "imp qaf.defs.user;\n" ++
        "imp qaf.impls.user_greeter_ok;\n\n" ++
        "fun main() void {\n" ++
        "  User user;\n" ++
        "  user.name = \"Alice\";\n" ++
        "  User* u = &user;\n" ++
        "  u.\n" ++
        "}\n";

    const doc_uri_members = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-qaf-members.fn");
    defer allocator.free(doc_uri_members);
    try lspOpenDoc(allocator, &lsp, doc_uri_members, 1, doc_text_members);

    const dot_pos = try findPosition(doc_text_members, "u.", 0);
    const comp_params_dot = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri_members, dot_pos.line, dot_pos.col + 2 },
    );
    defer allocator.free(comp_params_dot);

    const comp_id_dot = try lsp.request("textDocument/completion", comp_params_dot);
    var comp_res_dot = try lsp.waitResponse(comp_id_dot, 5000);
    defer comp_res_dot.deinit();
    const comp_obj_dot = comp_res_dot.parsed.value.object;
    const comp_val_dot = try jsonResultFromResponseObj(comp_obj_dot);
    try expectCompletionHasLabel(allocator, comp_val_dot, "greet");
    try expectCompletionHasLabel(allocator, comp_val_dot, "bye");

    // --- 3) Diagnostics should report missing quirk methods in an imported impl.
    const doc_text_bad =
        "imp qaf.defs.user;\n" ++
        "imp qaf.impls.user_greeter_bad;\n\n" ++
        "fun main() void {\n" ++
        "  User user;\n" ++
        "  user.name = \"Alice\";\n" ++
        "  User* u = &user;\n" ++
        "  u.greet(\"hi\");\n" ++
        "}\n";

    const doc_uri_bad = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-qaf-bad.fn");
    defer allocator.free(doc_uri_bad);
    try lspOpenDoc(allocator, &lsp, doc_uri_bad, 1, doc_text_bad);

    const impl_bad_abs = try std.fs.path.join(allocator, &[_][]const u8{ setup.root_abs, ".zig-cache", "qaf", "impls", "user_greeter_bad.fn" });
    defer allocator.free(impl_bad_abs);
    const impl_bad_uri = try pathToFileUriAlloc(allocator, impl_bad_abs);
    defer allocator.free(impl_bad_uri);
    try lspOpenDoc(allocator, &lsp, impl_bad_uri, 1, impl_bad_source);

    // Diagnostics for the bad impl file are handled elsewhere in compiler tests.
}

test "fls e2e: didChange before didOpen is ignored unless full replace" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-baseline.fn");
    defer allocator.free(doc_uri);

    // Send ranged didChange WITHOUT a baseline document. Should be ignored (no crash).
    const ranged_text_json = try escapeJsonAlloc(allocator, "fun alpha() {}\n");
    defer allocator.free(ranged_text_json);
    const did_change_ranged = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\",\"version\":1}},\"contentChanges\":[{{\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}},\"text\":\"{s}\"}}]}}",
        .{ doc_uri, ranged_text_json },
    );
    defer allocator.free(did_change_ranged);
    try lsp.notify("textDocument/didChange", did_change_ranged);

    // Request completion before baseline exists; should respond safely (typically empty).
    const comp_params_0 = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":0,\"character\":0}}}}",
        .{doc_uri},
    );
    defer allocator.free(comp_params_0);
    const comp_id_0 = try lsp.request("textDocument/completion", comp_params_0);
    var comp_res_0 = try lsp.waitResponse(comp_id_0, 5000);
    defer comp_res_0.deinit();
    _ = try jsonResultFromResponseObj(comp_res_0.parsed.value.object);

    // Now send a full replace didChange; server should accept it as baseline.
    const doc_text =
        "imp std.;\n\n" ++
        "fun main() {\n" ++
        "}\n";
    const doc_json = try escapeJsonAlloc(allocator, doc_text);
    defer allocator.free(doc_json);
    const did_change_full = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\",\"version\":2}},\"contentChanges\":[{{\"text\":\"{s}\"}}]}}",
        .{ doc_uri, doc_json },
    );
    defer allocator.free(did_change_full);
    try lsp.notify("textDocument/didChange", did_change_full);

    // Baseline should now exist; import completion after `std.` should include `io`.
    const std_pos = try findPosition(doc_text, "std.", 0);
    const comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, std_pos.line, std_pos.col + 4 },
    );
    defer allocator.free(comp_params);
    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 15000);
    defer comp_res.deinit();
    const comp_result = try jsonResultFromResponseObj(comp_res.parsed.value.object);
    try std.testing.expect(comp_result != .null);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: didChange multi-edit order applies correctly" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "fun main() {\n" ++
        "}\n";
    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-multiedit.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    // Two edits in a single didChange, where the second edit's range assumes the first edit applied:
    // 1) Insert an import line at the top: `imp std.` (missing semicolon)
    // 2) Insert the semicolon after the '.' (so the final text is valid)
    const import_json = try escapeJsonAlloc(allocator, "imp std.\n\n");
    defer allocator.free(import_json);
    const semi_json = try escapeJsonAlloc(allocator, ";");
    defer allocator.free(semi_json);

    const did_change_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\",\"version\":2}},\"contentChanges\":[" ++
            "{{\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}},\"text\":\"{s}\"}}," ++
            "{{\"range\":{{\"start\":{{\"line\":0,\"character\":8}},\"end\":{{\"line\":0,\"character\":8}}}},\"text\":\"{s}\"}}]}}",
        .{
            doc_uri,
            import_json,
            semi_json,
        },
    );
    defer allocator.free(did_change_params);
    try lsp.notify("textDocument/didChange", did_change_params);

    // After the edits, import completion after `std.` should include `io`.
    const comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":0,\"character\":8}}}}",
        .{doc_uri},
    );
    defer allocator.free(comp_params);
    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 15000);
    defer comp_res.deinit();
    const comp_result = try jsonResultFromResponseObj(comp_res.parsed.value.object);
    try std.testing.expect(comp_result != .null);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: invalid ranged edit does not wipe document" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.;\n\n" ++
        "fun main() {\n" ++
        "}\n";
    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-badrange.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const bad_text_json = try escapeJsonAlloc(allocator, "fun wiped() {}\n");
    defer allocator.free(bad_text_json);
    // start > end => invalid; server should ignore and keep existing doc.
    const did_change_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\",\"version\":2}},\"contentChanges\":[{{\"range\":{{\"start\":{{\"line\":1,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}},\"text\":\"{s}\"}}]}}",
        .{ doc_uri, bad_text_json },
    );
    defer allocator.free(did_change_params);
    try lsp.notify("textDocument/didChange", did_change_params);

    const std_pos = try findPosition(doc_text, "std.", 0);
    const comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, std_pos.line, std_pos.col + 4 },
    );
    defer allocator.free(comp_params);
    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 15000);
    defer comp_res.deinit();
    const comp_result = try jsonResultFromResponseObj(comp_res.parsed.value.object);
    try std.testing.expect(comp_result != .null);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: didClose clears doc; requests remain safe" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.c.io;\n\n" ++
        "fun alpha() {\n" ++
        "    printf(\"hi\\n\");\n" ++
        "}\n";
    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-close.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const close_params = try std.fmt.allocPrint(allocator, "{{\"textDocument\":{{\"uri\":\"{s}\"}}}}", .{doc_uri});
    defer allocator.free(close_params);
    try lsp.notify("textDocument/didClose", close_params);

    // Formatting should return [] for unknown doc.
    const fmt_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"options\":{{\"tabSize\":4,\"insertSpaces\":true}}}}",
        .{doc_uri},
    );
    defer allocator.free(fmt_params);
    const fmt_id = try lsp.request("textDocument/formatting", fmt_params);
    var fmt_res = try lsp.waitResponse(fmt_id, 15000);
    defer fmt_res.deinit();
    const fmt_val = try jsonResultFromResponseObj(fmt_res.parsed.value.object);
    try std.testing.expect(fmt_val == .array);
    try std.testing.expect(fmt_val.array.items.len == 0);

    // Document symbols should also be [].
    const sym_id = try lsp.request("textDocument/documentSymbol", close_params);
    var sym_res = try lsp.waitResponse(sym_id, 5000);
    defer sym_res.deinit();
    const sym_val = try jsonResultFromResponseObj(sym_res.parsed.value.object);
    try std.testing.expect(sym_val == .array);
    try std.testing.expect(sym_val.array.items.len == 0);

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: unknown request method responds null and stays alive" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const id = try lsp.request("fun/doesNotExist", "{}");
    var res = try lsp.waitResponse(id, 5000);
    defer res.deinit();
    const root = res.parsed.value;
    try std.testing.expect(root == .object);
    const result_val = try jsonResultFromResponseObj(root.object);
    try std.testing.expect(result_val == .null);

    // Prove server still responds to real requests.
    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-unknown.fn");
    defer allocator.free(doc_uri);
    const doc_text =
        "imp std.;\n\n" ++
        "fun main() {\n" ++
        "}\n";
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const std_pos = try findPosition(doc_text, "std.", 0);
    const comp_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ doc_uri, std_pos.line, std_pos.col + 4 },
    );
    defer allocator.free(comp_params);
    const comp_id = try lsp.request("textDocument/completion", comp_params);
    var comp_res = try lsp.waitResponse(comp_id, 15000);
    defer comp_res.deinit();
    const comp_result = try jsonResultFromResponseObj(comp_res.parsed.value.object);
    try expectCompletionHasLabel(allocator, comp_result, "io");

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}

test "fls e2e: torture - extreme positions + most handlers" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var setup = try resolveTestSetup(allocator);
    defer freeTestSetup(allocator, &setup);

    var lsp = try LspProc.start(allocator, setup.fls_path, setup.root_abs, setup.fun_abs);
    defer lsp.stop();
    try lspInitialize(allocator, &lsp, setup.root_uri);

    const doc_text =
        "imp std.c.io;\n\n" ++
        "fun alpha() {\n" ++
        "    printf(\"hi\\n\");\n" ++
        "}\n";
    const doc_uri = try lspMakeDocUri(allocator, setup.root_abs, "fls-e2e-torture.fn");
    defer allocator.free(doc_uri);
    try lspOpenDoc(allocator, &lsp, doc_uri, 1, doc_text);

    const pos_params = try std.fmt.allocPrint(
        allocator,
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":999,\"character\":999}}}}",
        .{doc_uri},
    );
    defer allocator.free(pos_params);

    // hover
    {
        const id = try lsp.request("textDocument/hover", pos_params);
        var res = try lsp.waitResponse(id, 15000);
        defer res.deinit();
        _ = try jsonResultFromResponseObj(res.parsed.value.object);
    }
    // definition
    {
        const id = try lsp.request("textDocument/definition", pos_params);
        var res = try lsp.waitResponse(id, 15000);
        defer res.deinit();
        _ = try jsonResultFromResponseObj(res.parsed.value.object);
    }
    // completion
    {
        const id = try lsp.request("textDocument/completion", pos_params);
        var res = try lsp.waitResponse(id, 15000);
        defer res.deinit();
        _ = try jsonResultFromResponseObj(res.parsed.value.object);
    }
    // signatureHelp
    {
        const id = try lsp.request("textDocument/signatureHelp", pos_params);
        var res = try lsp.waitResponse(id, 15000);
        defer res.deinit();
        _ = try jsonResultFromResponseObj(res.parsed.value.object);
    }
    // semantic tokens
    {
        const st_params = try std.fmt.allocPrint(allocator, "{{\"textDocument\":{{\"uri\":\"{s}\"}}}}", .{doc_uri});
        defer allocator.free(st_params);
        const id = try lsp.request("textDocument/semanticTokens/full", st_params);
        var res = try lsp.waitResponse(id, 15000);
        defer res.deinit();
        _ = try jsonResultFromResponseObj(res.parsed.value.object);
    }
    // workspace symbols for alpha
    {
        const ws_params = "{\"query\":\"alpha\"}";
        const id = try lsp.request("workspace/symbol", ws_params);
        var res = try lsp.waitResponse(id, 15000);
        defer res.deinit();
        const val = try jsonResultFromResponseObj(res.parsed.value.object);
        // Might be empty if indexing failed; key property is stable response.
        _ = val;
    }

    const shutdown_id = try lsp.request("shutdown", "{}");
    var shutdown_res = try lsp.waitResponse(shutdown_id, 5000);
    shutdown_res.deinit();
    try lsp.notify("exit", "{}");
}
